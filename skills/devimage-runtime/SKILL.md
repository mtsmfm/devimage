---
name: devimage-runtime
description: Use when working inside the devimage container, especially for networking/proxy access, MITM TLS certificates, WSL2 Docker GPU/WebGPU, Chrome/Dawn, Playwright GPU launch, desktop/Selkies startup, mise-managed toolchains, sudo/user permissions, /config home, /workspace mounts, or environment diagnostics.
---

# devimage Runtime

Devimage is not a generic Linux container. Before diagnosing failures, collect runtime facts:

```bash
bash scripts/doctor.sh --markdown
```

Resolve `scripts/doctor.sh` relative to this skill directory. If the skill path is unclear, find it:

```bash
find ~/.codex ~/.agents ~/.claude -path '*/devimage-runtime/scripts/doctor.sh' -print -quit 2>/dev/null
```

Core facts:

- Network egress may be fail-closed and only available through the throttle MITM proxy.
- `$HOME` is `/config`; `/workspace` is usually a bind mount from outside the image.
- The real runtime user is `abc`; `CUSTOM_USER` is the desktop login name.
- `sudo` is passwordless, but generated workspace files should normally remain owned by `abc`.
- `mise` manages Node, Python, Codex, Claude, and other tools; use `mise exec <tool>@<version> -- <cmd>` when shims have no selected version.
- Desktop services are off by default; use `devimage-gui start` and `devimage-gui status`.
- WSL2 browser GPU/WebGPU requires `/dev/dxg`, `/usr/lib/wsl/lib`, patched Mesa `dzn`, and Chrome/Dawn flags. Do not infer browser GPU from `nvidia-smi`.

Read only the relevant reference:

- `references/networking.md` for proxy, TLS, `NO_PROXY`, Node fetch, Chrome cert, and raw SSH failures.
- `references/gpu-webgpu.md` for WSL2 GPU, Mesa `d3d12`/`dzn`, Chrome, Playwright, SwiftShader, and llvmpipe.
- `references/desktop.md` for Selkies, openbox/labwc, GUI startup, ports, audio, screenshots, and MCP desktop apps.
- `references/toolchain.md` for `mise`, `sudo`, `/config`, `/workspace`, user mapping, and agent CLIs.
