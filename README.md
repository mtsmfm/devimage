# devimage

A browser-accessible Linux desktop pre-configured for AI coding agents.

## Motivation

I want to let coding agents (Claude Code, etc.) loose on a real machine without giving them my laptop. The container bundles:

- **A real desktop the agent can drive** — for tasks that need a GUI (e.g. running Blender to verify a generated `bpy` script). [Selkies](https://github.com/selkies-project/selkies) streams the desktop over WebRTC, which is dramatically faster than noVNC. Pinned to the current upstream release on top of the base image, since the base image lags by a couple of releases.
- **The tools agents reach for by default** — `git`, `gh`, `ripgrep`, `fd`, `jq`, build toolchain, Python, plus [`mise`](https://mise.jdx.dev/) for installing language runtimes on demand.
- **GUI automation primitives** — `xdotool`, `wmctrl`, `scrot`, `xclip` so an agent can drive the desktop, take screenshots, and read the clipboard from the shell.
- **Wine** (latest stable from WineHQ) for running Windows apps inside the desktop, with i386 multilib enabled so 32-bit installers work.
- **3D / CAD MCP stack** — Blender 4.2 LTS and FreeCAD 1.1 (extracted from the upstream AppImage so the container doesn't need FUSE at runtime), plus the [Blender MCP](https://github.com/ahujasid/blender-mcp) and [FreeCAD MCP](https://github.com/neka-nat/freecad-mcp) servers and their companion add-ons. An agent can model in either app over MCP after a one-shot `devimage-mcp setup` call.
- **`zsh` + oh-my-zsh** as the default shell for the `ubuntu` user. `bash` still works if you prefer it.
- **Free movement inside the box** — the `ubuntu` user has passwordless `sudo`, and `mise` shims survive the `sudo` boundary, so the agent can `apt install` or `mise use node@lts` without ceremony.

Blender 4.2 LTS specifically (rather than the current 5.x) because that version's `bpy` API has the most stable AI training data — newer releases tend to produce hallucinated API calls.

## Usage

Pull and run:

```bash
docker run --rm -it \
  --name devimage \
  --gpus all \
  -p 8080:8080 \
  -e SELKIES_BASIC_AUTH_PASSWORD=changeme \
  -v "$PWD:/workspace" \
  -v "$HOME/.claude:/home/ubuntu/.claude" \
  -v "$HOME/.claude.json:/home/ubuntu/.claude.json" \
  -v "$HOME/.codex:/home/ubuntu/.codex" \
  ghcr.io/mtsmfm/devimage:latest
```

The desktop stack is off by default. Start it only when a task needs GUI access:

```bash
docker exec devimage devimage-gui start
```

Then open <http://localhost:8080> and log in as `ubuntu` / `changeme`. To restore the old eager-start behavior, pass `-e DEVIMAGE_ENABLE_GUI=true` when starting the container.

Use `devimage-gui status` to inspect the supervised GUI processes, and `devimage-gui stop` to tear them back down.

The default working directory is `/workspace` — that's where your bind-mounted repo will be, and where `docker exec ... <cmd>` lands too. The `~/.claude` and `~/.codex` mounts persist agent login state across runs; drop them if you don't need it.

### Or via Docker Compose

```bash
DEVIMAGE_PASSWORD=changeme docker compose up
```

The bundled [`compose.yml`](compose.yml) wires up the same mounts, ports, and GPU passthrough. Start the GUI later with `docker exec devimage devimage-gui start`, or uncomment `DEVIMAGE_ENABLE_GUI=true` in the compose file to start it at boot. Drop the `gpus: all` line and uncomment `SELKIES_ENCODER=x264enc` for CPU-only.

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

### On WSL2 (NVIDIA GPU)

`--gpus all` from inside a WSL2 distro hands the container the *compute* slice of the GPU — CUDA, NVENC, `nvidia-smi`, so Selkies happily streams over hardware H264 — but **not** the OpenGL slice. There's no `libGLX_nvidia.so` for the toolkit to inject because WSL2 talks to the GPU through the Windows WDDM driver via `/dev/dxg`, not the Linux NVIDIA userland. Anything that needs GL (Blender's viewport, in particular) falls back to `llvmpipe` and feels mushy.

The fix is to also mount the WSL host's d3d12 userland into the container so Mesa's `d3d12` Gallium driver can route GL → DirectX 12 → Windows GPU driver. Uncomment the WSL2 lines in [`compose.yml`](compose.yml), or add the equivalent flags to `docker run`:

```yaml
volumes:
  - "/usr/lib/wsl:/usr/lib/wsl:ro"
environment:
  LD_LIBRARY_PATH: "/usr/lib/wsl/lib"
  GALLIUM_DRIVER: "d3d12"
  MESA_D3D12_DEFAULT_ADAPTER_NAME: "NVIDIA"  # only matters with multi-GPU laptops
```

Confirm by running `glxinfo | grep "OpenGL renderer"` from a terminal inside the desktop — it should report `D3D12 (NVIDIA <your card>)` instead of `llvmpipe`. (`/dev/dxg` itself is already exposed by `--gpus all` on WSL2, so no extra `devices:` entry is needed.)

The architecture this leans on (WSL GPU paravirtualization via `/dev/dxg`, Mesa's [d3d12 driver](https://docs.mesa3d.org/drivers/d3d12.html) for OpenGL, NVIDIA's [explicit ban](https://docs.nvidia.com/cuda/wsl-user-guide/index.html) on installing Linux NVIDIA drivers inside WSL) is documented by Microsoft and NVIDIA. The specific recipe for surfacing it from inside a Docker container is *not* — it mirrors what [WSLg](https://devblogs.microsoft.com/commandline/wslg-architecture/) does internally. Performance is much better than llvmpipe, but won't match a native Linux GPU host.

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
devimage-mcp setup
```

It registers the MCP servers with whichever of `claude` / `codex` are on PATH (skipping the others) and is idempotent — re-run it any time the agent configs get reset, e.g. after a fresh bind mount of `~/.claude` or `~/.codex` from the host. Under the hood:

```
claude mcp add --scope user blender -- /usr/local/bin/blender-mcp
claude mcp add --scope user freecad -- /usr/local/bin/freecad-mcp
codex  mcp add               blender -- /usr/local/bin/blender-mcp
codex  mcp add               freecad -- /usr/local/bin/freecad-mcp
```
