# A local coding agent on Unraid

Puts an LLM coding agent on an Unraid server, running on the server's own GPU,
with nothing leaving the LAN and no API key anywhere.

Three containers:

| Container | What it is | Default port |
|---|---|---|
| `ollama` | Holds the models and runs them on the GPU. The only service that touches the card. | 11434 |
| `open-webui` | Chat interface. For talking to a model. | 3000 |
| `code-server` | Browser VS Code with the Continue extension. For editing code with a model. | 8443 |

Only `code-server` is the coding agent proper — it reads and writes real files
and can run commands. Open WebUI is a chat window; it cannot touch your disk.

## Before you start

Two Community Applications plugins, both of which need a reboot:

- **Nvidia Driver** — registers `nvidia` as a Docker runtime. Without it the
  containers still start and still answer, but on CPU, at a speed that reads as
  a hang rather than as slowness. `setup.sh` checks for this and warns.
- **Docker Compose Manager** — gives you `docker compose` on the Unraid
  terminal.

Check your Docker vDisk before you start. These three images need roughly
15GB unpacked, and on Unraid images go into `docker.img`, a fixed-size file
that is commonly 20GB and often already mostly spent on containers you run
today. When it fills, the pull dies partway with `no space left on device`,
which reads as a disk problem but is only this one file being full. `docker
system df` shows what is in there. To make room, raise **Docker vDisk size**
under Settings > Docker, with **Enable Docker** set to No while you change it;
existing containers survive.

That limit is separate from where the models go, and the models are much the
larger of the two.

You also want somewhere real for the models to live. A 30B model at Q4 is about
19GB and you will end up with more than one. If your `appdata` share is on a
cache pool or SSD, you are fine; if it is on the array, expect a slow first load
of every model.

## Install

On the server, as root, from the Unraid web terminal or over SSH:

```
git clone https://github.com/jryantomes/LocalCodingLLM.git /mnt/user/appdata/localcodingllm
cd /mnt/user/appdata/localcodingllm
./setup.sh
```

Clone it onto a share, as above, and not into `/boot` or `/root`. Unraid's root
filesystem lives in RAM and is rebuilt on every boot, so anything left in
`/root` is gone after a restart. `/boot` is the USB flash drive and is FAT32,
which carries no Unix permission bits, so a clone there arrives with the
executable bit stripped off both scripts and `./setup.sh` simply will not run.

If the repository is private, that clone stops at an authentication prompt,
and GitHub has not accepted account passwords over HTTPS for years. Nothing in
here is secret — `.env` is generated on the server and never committed — so
making it public is the simplest fix. Otherwise clone with a personal access
token from <https://github.com/settings/tokens>, scope `repo`:

```
git clone https://<token>@github.com/jryantomes/LocalCodingLLM.git \
  /mnt/user/appdata/localcodingllm
```

A token used that way is stored in plain text in `.git/config` inside the
clone. To pull later without keeping it on disk, strip it once the clone is
down:

```
git -C /mnt/user/appdata/localcodingllm remote set-url origin \
  https://github.com/jryantomes/LocalCodingLLM.git
```

Do not reach for `git config --global credential.helper store` here. It writes
to `/root`, which Unraid rebuilds on every boot, so the credential is gone the
next time the server restarts and the failure looks like it came from nowhere.

You can also skip git altogether. These are seven small files; downloading the
repository as a zip from the GitHub web interface and unpacking it onto the
share works exactly as well, as long as you restore the executable bit
afterwards with `chmod +x setup.sh pull-models.sh`.

`setup.sh` checks the host, writes a `.env`, asks you for a code-server
password, creates the directories, brings the stack up, installs the Continue
extension and downloads models sized to your GPU. The model download is the
slow part and it is tens of gigabytes.

It is safe to re-run. Everything it does is idempotent, and interrupted model
downloads resume rather than restart.

One constraint on the password: it cannot contain a single quote. `.env` is
read by two parsers with different escaping rules — the shell, and Compose's
own dotenv reader — and no way of escaping a single quote satisfies both.
Every other character works, spaces and `$` and backticks included.

Then open `http://<server-ip>:3000` and **create your account immediately**.
Open WebUI hands admin to the first account made, so claim it before anyone
else on the network can. After that, set `ENABLE_SIGNUP=false` in `.env` and
run `docker compose up -d` again.

## Which model you get

`pull-models.sh` reads the VRAM Ollama can actually see and picks from it. The
sizes below are the weights at Q4_K_M; the context window costs more on top,
which is why each tier leaves headroom rather than filling the card.

| VRAM | Chat model | Notes |
|---|---|---|
| 40GB+ | `qwen3-coder:30b` plus `devstral:24b` | Devstral is trained for multi-file agentic edits, so it is worth having both and switching. |
| 22–40GB | `qwen3-coder:30b` | 30B mixture-of-experts, ~3B active. Roughly the best quality per gigabyte available. |
| 15–22GB | `qwen2.5-coder:14b` | The 30B fits a 16GB card only by pushing its context into system RAM, which costs more speed than the larger model wins back. |
| under 15GB | `qwen2.5-coder:7b` | Usable, noticeably weaker at anything multi-file. |

To override, name one yourself:

```
./pull-models.sh qwen3-coder:30b
```

The script also pulls `qwen2.5-coder:1.5b-base` for inline autocomplete and
`nomic-embed-text` so Continue's `@codebase` can index a project. The
autocomplete model is a *base* model on purpose — the instruct variant answers
inline completions with conversational prose.

Ollama's tag list moves over time. If a pull fails, the script says which one
and keeps going; check <https://ollama.com/library> for what the current tag
is and pass it in.

## Using it

**Chat**: `http://<server-ip>:3000`.

**Coding**: `http://<server-ip>:8443`, password from your `.env`. Your projects
are mounted at `/config/workspace` inside the editor, from whatever you set
`PROJECTS_DIR` to. Continue's sidebar gives you chat, inline edit (Ctrl-I) and
autocomplete against the local model.

**From a desktop IDE**: nothing forces you to use the browser editor. Install
Continue in VS Code or a JetBrains IDE on your workstation and point it at
`http://<server-ip>:11434`, using `continue/config.yaml` here as the starting
point. Change `apiBase` from `http://ollama:11434` to the server's LAN address,
since that container name only resolves inside the compose network.

Aider is also worth knowing about if you prefer a terminal agent — it drives
Ollama directly with `--model ollama_chat/<model>` and needs nothing added to
this stack.

## What this is and is not

Local models have got genuinely good, and the ones here will handle a
well-scoped function, a test, a refactor within a file, and explaining
unfamiliar code. They are meaningfully behind the frontier hosted models on
long multi-file work, on holding a large codebase in context, and on knowing
when they are wrong. That is the trade you made by choosing local: no
per-token cost, no data leaving the house, and a lower ceiling.

If you later want both, Open WebUI can hold an API key for a hosted model
alongside Ollama, and Continue can list both and let you pick per request.

## Security

Everything binds to your LAN and nothing here is built to face the internet.
Do not forward these ports on your router.

`code-server` is an editor with a shell attached. Anyone on your network who
reaches port 8443 with that password can run commands as the container's user
against `PROJECTS_DIR`. That is why `setup.sh` refuses to start without a
password and why `.env` is `chmod 600` and gitignored.

`PROJECTS_DIR` is the whole of what the agent can edit. Keep it a dedicated
share. Pointing it at `/mnt/user` gives an agent your entire array.

To reach any of this from outside, add Tailscale or use whatever VPN you
already run. Do not open a port.

## Troubleshooting

**Generation is unbearably slow.** The GPU is not attached. Run
`docker exec ollama nvidia-smi`. If that errors, the Nvidia Driver plugin is
missing or the box has not been rebooted since installing it. If it works but
generation is still slow, the model is spilling out of VRAM — run
`docker exec ollama ollama ps`, which shows the CPU/GPU split, and either lower
`OLLAMA_CONTEXT_LENGTH` or drop to the next model down.

**Continue's sidebar has no models.** The config did not land. It belongs at
`$APPDATA/code-server/.continue/config.yaml`, and `PLACEHOLDER_CHAT_MODEL` in
it should have been replaced with a real name. Re-run `./pull-models.sh`, then
reload the editor window.

**Continue is installed but does nothing.** Check the extension is actually
there — automatic installation can lose a race with the editor's first boot.
Search the Extensions panel for Continue and install it by hand.

**Open WebUI shows no models.** It talks to Ollama by container name over the
compose network. Confirm both are on it with `docker network inspect llm`, and
that models exist with `docker exec ollama ollama list`.

**Compose says a required variable is missing.** `CODESERVER_PASSWORD` or
`WEBUI_SECRET_KEY` is unset in `.env`. That is deliberate — the stack refuses
to start rather than put an unauthenticated editor on your network. Run
`./setup.sh`, or set them by hand.

**The array is filling up.** Models are under `$APPDATA/ollama`. List them with
`docker exec ollama ollama list` and remove what you are not using with
`docker exec ollama ollama rm <model>`.

**Everyday commands**, run from this folder:

```
docker compose ps                 # what is up
docker compose logs -f ollama     # follow one service
docker compose restart ollama     # restart one
docker compose down               # stop everything, keep the models
docker compose pull && docker compose up -d   # update images
```
