#!/usr/bin/env bash
# Downloads the models and points Continue at the one it chose.
#
# Safe to re-run: Ollama skips layers it already has, so a second run after a
# failed download resumes rather than starting over.
#
# Pass a model name to override the automatic choice:
#     ./pull-models.sh qwen3-coder:30b

set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")"
# shellcheck disable=SC1091
[ -f .env ] && set -a && . ./.env && set +a

APPDATA="${APPDATA:-/mnt/user/appdata}"
CONTINUE_DIR="$APPDATA/code-server/.continue"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m    %s\033[0m\n' "$*"; }
die()  { printf '\033[31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

docker ps --format '{{.Names}}' | grep -qx ollama \
  || die "The ollama container is not running. Start the stack first: docker compose up -d"

# ---- Work out how much card there is to work with -------------------------

# Ask the container, not the host: what matters is the VRAM Ollama can see,
# which is what NVIDIA_VISIBLE_DEVICES decided.
#
# The total across every visible card is the budget, not the largest one.
# Ollama splits a model's layers over all the GPUs it can see, so two 8GB
# cards will hold a model that no single one of them could. An earlier version
# of this took the largest card and picked a model a size too small on exactly
# that hardware.
GPU_MEM="$(docker exec ollama nvidia-smi \
             --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
           | tr -d '\r')"

GPU_COUNT="$(printf '%s\n' "$GPU_MEM" | grep -c '^[0-9][0-9]*$' || true)"
VRAM_MB="$(printf '%s\n' "$GPU_MEM" | awk '/^[0-9]+$/ {sum += $1} END {print sum + 0}')"

if ! [[ "$VRAM_MB" =~ ^[0-9]+$ ]] || [ "$VRAM_MB" -eq 0 ]; then
  warn "Could not read GPU memory from inside the container."
  warn "That usually means the nvidia runtime is not attached - the models will"
  warn "still download, but they will run on CPU and be far too slow to code with."
  warn "Check 'docker exec ollama nvidia-smi' before you blame the model."
  VRAM_MB=0
  GPU_COUNT=0
fi

VRAM_GB=$(( VRAM_MB / 1024 ))

# ---- Pick a chat model ----------------------------------------------------

# Sizes below are Q4_K_M weights only. The KV cache for a 32k context is on top
# of that, which is why each tier leaves several GB of headroom rather than
# filling the card to its stated capacity.
if [ "$#" -ge 1 ]; then
  CHAT_MODEL="$1"
  say "Using the model you named: $CHAT_MODEL"
  EXTRA_MODEL=""
elif [ "$VRAM_GB" -ge 40 ]; then
  CHAT_MODEL="qwen3-coder:30b"; EXTRA_MODEL="devstral:24b"
elif [ "$VRAM_GB" -ge 22 ]; then
  CHAT_MODEL="qwen3-coder:30b"; EXTRA_MODEL=""
elif [ "$VRAM_GB" -ge 15 ]; then
  # 30B at Q4 is about 19GB and will fit a 16GB card only by spilling its
  # context into system RAM. The 14B stays on the card and stays fast.
  CHAT_MODEL="qwen2.5-coder:14b"; EXTRA_MODEL=""
elif [ "$VRAM_GB" -ge 9 ]; then
  CHAT_MODEL="qwen2.5-coder:7b"; EXTRA_MODEL=""
else
  CHAT_MODEL="qwen2.5-coder:7b"; EXTRA_MODEL=""
  SMALL_CARD=1
fi

if [ "$#" -lt 1 ]; then
  if [ "${GPU_COUNT:-0}" -gt 1 ]; then
    say "Detected ${VRAM_GB}GB of VRAM across ${GPU_COUNT} GPUs. Chat model: $CHAT_MODEL"
    warn "A model larger than one card is split over the others across PCIe."
    warn "That works, and costs some speed against the same model on a single"
    warn "card of the same total size. If it feels slow, ./pull-models.sh with a"
    warn "smaller model will fit on one card and run faster."
  else
    say "Detected ${VRAM_GB}GB of VRAM. Chat model: $CHAT_MODEL"
  fi
  if [ -n "${SMALL_CARD:-}" ]; then
    warn "That is a small card for this. The 7B model is the smallest that is"
    warn "genuinely useful for code, but expect it to be slow and weak on"
    warn "anything spanning more than one file."
  fi
fi

# ---- Pull -----------------------------------------------------------------

FAILED=()
pull() {
  say "Pulling $1"
  # Ollama's tag list moves. If a name has been retired upstream this is where
  # you find out, so the failure is collected and reported rather than swallowed.
  docker exec ollama ollama pull "$1" || FAILED+=("$1")
}

pull "$CHAT_MODEL"
pull "qwen2.5-coder:1.5b-base"   # fill-in-the-middle autocomplete
pull "nomic-embed-text"          # @codebase indexing
[ -n "${EXTRA_MODEL:-}" ] && pull "$EXTRA_MODEL"

# ---- Point Continue at whatever actually landed ---------------------------

if printf '%s\n' "${FAILED[@]:-}" | grep -qx "$CHAT_MODEL"; then
  warn "The chat model did not download, so Continue's config was left alone."
  warn "Pick another from https://ollama.com/library and re-run:"
  warn "    ./pull-models.sh <model:tag>"
else
  mkdir -p "$CONTINUE_DIR"
  sed "s|PLACEHOLDER_CHAT_MODEL|$CHAT_MODEL|" continue/config.yaml > "$CONTINUE_DIR/config.yaml"
  chown -R "${PUID:-99}:${PGID:-100}" "$CONTINUE_DIR" 2>/dev/null || true
  say "Continue configured to use $CHAT_MODEL"
fi

say "Models now installed"
docker exec ollama ollama list

if [ "${#FAILED[@]}" -gt 0 ]; then
  printf '\n\033[31m!!  These did not download: %s\033[0m\n' "${FAILED[*]}"
  printf '    Re-run this script to retry - finished layers are kept.\n'
  exit 1
fi
