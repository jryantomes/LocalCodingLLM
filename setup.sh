#!/usr/bin/env bash
# One-shot install. Run this on the Unraid server itself, over SSH or from the
# web terminal, as root.
#
#     ./setup.sh
#
# It checks the things that are worth failing on early, writes a .env if there
# isn't one, brings the stack up, and downloads the models.

set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m    %s\033[0m\n' "$*"; }
die()  { printf '\033[31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

# Rewrites one KEY=VALUE line in .env, with the value single-quoted.
#
# Deliberately not sed. A password is arbitrary text, and the moment it holds
# the sed delimiter, a backslash or an ampersand, a sed-built .env is quietly
# wrong. The quoting matters for the same reason: these scripts read .env with
# the shell, so an unquoted space, $ or backtick in a value would be
# interpreted rather than stored. The substitution below is the usual way to
# put a literal single quote inside a single-quoted shell string.
#
# The value must not itself contain a single quote, and the caller is
# responsible for checking that. There is no escape that would help: this file
# is read by two parsers with different rules - the shell, and Compose's own
# dotenv reader - and the backslash escape that works in the shell makes
# Compose fail to parse the file at all. Forbidding the character is the only
# behaviour both agree on.
#
# The rewritten key moves to the end of the file. Nothing reads .env
# positionally, so that costs nothing but the tidiness of the comments.
set_env() {
  local key="$1" val="$2"
  grep -v "^${key}=" .env > .env.tmp
  printf "%s='%s'\n" "$key" "$val" >> .env.tmp
  mv .env.tmp .env
}

# ---- Preflight ------------------------------------------------------------

say "Checking the host"

[ "$(id -u)" -eq 0 ] || die "Run this as root. Unraid's shares are owned by nobody:users and this has to write into them."

command -v docker >/dev/null || die "Docker is not on PATH. Is the Docker service enabled in Settings > Docker?"

# Unraid ships compose through the Docker Compose Manager plugin from Community
# Applications. Both spellings are accepted because which one you have depends
# on the plugin version.
if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  die "No docker compose found. Install 'Docker Compose Manager' from Community Applications, then run this again."
fi
say "Using: ${COMPOSE[*]}"

# The GPU check is the one most worth doing up front. Without the nvidia
# runtime the stack still starts and still answers, just on CPU and roughly two
# orders of magnitude slower - which reads as "broken" long before anyone
# thinks to check the runtime.
if ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
  warn "Docker has no 'nvidia' runtime registered."
  warn "Install the 'Nvidia Driver' plugin from Community Applications and reboot."
  warn "Without it the models run on CPU, which is too slow to code with."
  printf '    Continue anyway? [y/N] '
  read -r reply
  [ "$reply" = "y" ] || [ "$reply" = "Y" ] || die "Stopped. Install the plugin and re-run."
fi

# ---- .env -----------------------------------------------------------------

if [ ! -f .env ]; then
  say "Creating .env"
  cp .env.example .env

  # A signing key nobody has to think about.
  set_env WEBUI_SECRET_KEY "$(head -c 32 /dev/urandom | base64 | tr -d '\n/+=')"

  # The code-server password is deliberately not generated. This unlocks an
  # editor with a shell in it on your LAN, and a password you never saw is a
  # password you will never change.
  while :; do
    printf '    Password for code-server (the browser editor): '
    read -rs PW; printf '\n'
    if [ -z "$PW" ]; then
      warn "Empty. This unlocks an editor with a shell in it; it needs a password."
    elif [ "${PW//\'/}" != "$PW" ]; then
      warn "Single quotes cannot be stored in .env - Compose's reader chokes on"
      warn "every way of escaping one. Any other character is fine."
    else
      break
    fi
  done
  set_env CODESERVER_PASSWORD "$PW"
  chmod 600 .env

  warn "Edit .env before you go further if PROJECTS_DIR is not where you keep code."
  warn "It is currently: $(grep '^PROJECTS_DIR=' .env | cut -d= -f2)"
  printf '    Press enter to continue, or Ctrl-C to go and edit it. '
  read -r _
else
  say ".env already exists, leaving it alone"
fi

# shellcheck disable=SC1091
set -a; . ./.env; set +a

# ---- Directories ----------------------------------------------------------

say "Creating directories"
for d in "$APPDATA/ollama" "$APPDATA/open-webui" "$APPDATA/code-server" "$PROJECTS_DIR"; do
  mkdir -p "$d"
  printf '    %s\n' "$d"
done
# open-webui and ollama run as root inside their containers; only code-server
# drops to PUID/PGID, so it is the only one whose ownership matters.
chown -R "${PUID:-99}:${PGID:-100}" "$APPDATA/code-server" "$PROJECTS_DIR"

# ---- Up -------------------------------------------------------------------

say "Pulling images"
"${COMPOSE[@]}" pull

say "Starting the stack"
"${COMPOSE[@]}" up -d

say "Waiting for Ollama to answer"
for i in $(seq 1 60); do
  if docker exec ollama ollama list >/dev/null 2>&1; then
    printf '    up after %ss\n' "$((i*2))"; break
  fi
  [ "$i" -eq 60 ] && die "Ollama did not come up in two minutes. Check: docker logs ollama"
  sleep 2
done

# ---- Continue extension ---------------------------------------------------

say "Installing the Continue extension into code-server"
# The linuxserver image exposes VS Code's CLI as install-extension. It can fail
# on a slow first boot before the editor has finished unpacking, so this is not
# fatal - the README says how to install it by hand from the marketplace.
if ! docker exec code-server install-extension Continue.continue 2>/dev/null; then
  warn "Could not install Continue automatically."
  warn "Open code-server, search the Extensions panel for 'Continue', install it there."
fi

# ---- Models ---------------------------------------------------------------

say "Downloading models - this is the slow part, tens of GB"
./pull-models.sh || warn "Some models failed. Re-run ./pull-models.sh to retry."

# ---- Done -----------------------------------------------------------------

IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
IP="${IP:-<your-server-ip>}"

say "Ready"
cat <<DONE

    Chat            http://$IP:${OPENWEBUI_PORT:-3000}
    Editor          http://$IP:${CODESERVER_PORT:-8443}
    Ollama API      http://$IP:${OLLAMA_PORT:-11434}

    Two things to do now:

    1. Open the chat URL and create your account. The first one made is the
       admin, so make it yours before anyone else on the network does. Then set
       ENABLE_SIGNUP=false in .env and run: ${COMPOSE[*]} up -d

    2. Open the editor, log in with the password you set, and check that
       Continue's sidebar lists a model. If it is empty, the config did not
       land - see the README.

DONE
