# Toolchain and Filesystem

## Users and Home

The runtime user is `abc`. `CUSTOM_USER` controls the desktop login name, not the Unix account name.

Common facts:

- `$HOME` is `/config`.
- `/workspace` is the working directory and is usually a bind mount.
- `PUID` and `PGID` remap `abc` to match the host user.
- `sudo` is passwordless.

When creating files in `/workspace`, preserve normal user ownership. Avoid leaving root-owned files unless a root-owned artifact is intentional.

## Mise

`mise` manages language runtimes and agent CLIs. If a shim says no version is selected, use `mise exec`:

```bash
mise exec node@lts -- npm --version
mise exec codex@latest -- codex --version
mise exec claude@latest -- claude --version
```

For persistent interactive use:

```bash
mise use -g node@lts
mise use -g codex
mise use -g claude
```

Wrapper scripts avoid persistent installs:

```bash
devimage-codex
devimage-claude
```

## Config Persistence

`/config` is persistent and seeded from `/defaults` on first boot. Agent credentials and config should live under `/config`, for example:

- `/config/.codex`
- `/config/.claude`
- `/config/.claude.json`

Do not assume files baked into `/workspace` survive a bind mount. Put image defaults under `/defaults` or `/opt`, and user/session state under `/config`.

## Package Installation

Use `sudo apt-get` when system packages are needed. Under the throttle overlay, apt must use the configured proxy path; if TLS fails, check `references/networking.md`.

For Node tools, prefer `mise exec node@<version> -- npm ...` unless the project already pins a Node version.
