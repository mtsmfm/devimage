# devimage

A browser-accessible Linux desktop pre-configured for AI coding agents.

## Motivation

I want to let coding agents (Claude Code, etc.) loose on a real machine without giving them my laptop. The container bundles:

- **A real desktop the agent can drive** — for tasks that need a GUI (e.g. running Blender to verify a generated `bpy` script). [Selkies](https://github.com/selkies-project/selkies) streams the desktop over WebRTC, which is dramatically faster than noVNC. Pinned to the current upstream release on top of the base image, since the base image lags by a couple of releases.
- **The tools agents reach for by default** — `git`, `gh`, `ripgrep`, `fd`, `jq`, build toolchain, Python, plus [`mise`](https://mise.jdx.dev/) for installing language runtimes on demand.
- **GUI automation primitives** — `xdotool`, `wmctrl`, `scrot`, `xclip` so an agent can drive the desktop, take screenshots, and read the clipboard from the shell.
- **Wine** (latest stable from WineHQ) for running Windows apps inside the desktop, with i386 multilib enabled so 32-bit installers work.
- **3D / CAD MCP stack** — Blender 4.2 LTS and FreeCAD 1.1 (extracted from the upstream AppImage so the container doesn't need FUSE at runtime), plus the [Blender MCP](https://github.com/ahujasid/blender-mcp) and [FreeCAD MCP](https://github.com/neka-nat/freecad-mcp) servers and their companion add-ons. An agent can model in either app over MCP after a one-shot `setup-mcp` call.
- **`zsh` + oh-my-zsh** as the default shell for the `ubuntu` user. `bash` still works if you prefer it.
- **Free movement inside the box** — the `ubuntu` user has passwordless `sudo`, and `mise` shims survive the `sudo` boundary, so the agent can `apt install` or `mise use node@lts` without ceremony.

Blender 4.2 LTS specifically (rather than the current 5.x) because that version's `bpy` API has the most stable AI training data — newer releases tend to produce hallucinated API calls.

## Usage

Pull and run:

```bash
docker run --rm -it \
  --gpus all \
  -p 8080:8080 \
  -e SELKIES_BASIC_AUTH_PASSWORD=changeme \
  -v "$PWD:/workspace" \
  -v "$HOME/.claude:/home/ubuntu/.claude" \
  -v "$HOME/.claude.json:/home/ubuntu/.claude.json" \
  -v "$HOME/.codex:/home/ubuntu/.codex" \
  ghcr.io/mtsmfm/devimage:latest
```

Then open <http://localhost:8080> and log in as `ubuntu` / `changeme`.

The default working directory is `/workspace` — that's where your bind-mounted repo will be, and where `docker exec ... <cmd>` lands too. The `~/.claude` and `~/.codex` mounts persist agent login state across runs; drop them if you don't need it.

### Without an NVIDIA GPU

Drop `--gpus all` and force a software encoder:

```bash
docker run --rm -it \
  -p 8080:8080 \
  -e SELKIES_BASIC_AUTH_PASSWORD=changeme \
  -e SELKIES_ENCODER=x264enc \
  -v "$PWD:/workspace" \
  ghcr.io/mtsmfm/devimage:latest
```

### Installing a coding agent

Agents are intentionally **not** baked into the image — pick whichever you want at runtime via `mise`. The registry has shortnames for the common ones:

```bash
mise use -g claude    # Claude Code
mise use -g codex     # OpenAI Codex CLI
```

Anything else with an `npm` / `pipx` / GitHub-Releases distribution works too: `mise` already provides Node / Python, so `npm i -g <agent>` or `pipx install <agent>` will land its binary on PATH.

### MCP servers (Blender / FreeCAD)

Both apps come with their MCP server (`/usr/local/bin/blender-mcp`, `/usr/local/bin/freecad-mcp`) and companion add-ons pre-installed:

- Blender: `~/.config/blender/4.2/scripts/addons/blender_mcp.py` — pre-enabled in `userpref.blend` at build time.
- FreeCAD: `~/.local/share/FreeCAD/Mod/FreeCADMCP/` — auto-loaded on FreeCAD start.

After installing an agent, run:

```bash
setup-mcp
```

It registers the MCP servers with whichever of `claude` / `codex` are on PATH (skipping the others) and is idempotent — re-run it any time the agent configs get reset, e.g. after a fresh bind mount of `~/.claude` or `~/.codex` from the host. Under the hood:

```
claude mcp add --scope user blender -- /usr/local/bin/blender-mcp
claude mcp add --scope user freecad -- /usr/local/bin/freecad-mcp
codex  mcp add               blender -- /usr/local/bin/blender-mcp
codex  mcp add               freecad -- /usr/local/bin/freecad-mcp
```
