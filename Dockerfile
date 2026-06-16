# syntax=docker/dockerfile:1.7
#
# Browser-accessible Linux desktop pre-configured for AI coding agents.
# Built on linuxserver.io's baseimage-selkies (openbox/labwc + Ubuntu 24.04),
# which tracks Selkies HEAD with PixelFlux WebSocket pixel streaming.

ARG BLENDER_VERSION=5.1.2
ARG BLENDER_MAJOR=5.1
ARG BLENDER_SHA256=aaccb355f50183979b698bcce7467103a76261b5fa59f4972295842662a285fb
ARG FREECAD_VERSION=1.1.1

# ============================================================================
# Parallel download stages
#
# BuildKit runs these concurrently when their /out is referenced by COPY
# --from in the final image. Each stage drops its artifact under /out so the
# downstream COPY idiom is uniform.
# ============================================================================

FROM ubuntu:24.04 AS dl-base
# Pin all apt traffic to the Azure mirror — much more reliable from CI runners
# than archive.ubuntu.com, and identical content. The pattern matches both
# http and https URIs since the default scheme has flipped between Ubuntu
# releases. Add retry config too so transient blips don't fail the build.
RUN sed -i -E \
        -e 's|https?://archive\.ubuntu\.com/ubuntu|http://azure.archive.ubuntu.com/ubuntu|g' \
        -e 's|https?://security\.ubuntu\.com/ubuntu|http://azure.archive.ubuntu.com/ubuntu|g' \
        /etc/apt/sources.list.d/ubuntu.sources \
 && { \
      echo 'Acquire::Retries "3";'; \
      echo 'Acquire::http::Timeout "30";'; \
    } > /etc/apt/apt.conf.d/80-resilient \
 && apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates xz-utils \
 && rm -rf /var/lib/apt/lists/*

# Blender 5.x stable, pinned to the latest corrective release.
FROM dl-base AS blender-fetch
ARG BLENDER_VERSION
ARG BLENDER_MAJOR
ARG BLENDER_SHA256
RUN curl -fsSL -o /tmp/blender.tar.xz \
      "https://download.blender.org/release/Blender${BLENDER_MAJOR}/blender-${BLENDER_VERSION}-linux-x64.tar.xz" \
 && echo "${BLENDER_SHA256}  /tmp/blender.tar.xz" | sha256sum -c - \
 && mkdir -p /out \
 && tar -xJf /tmp/blender.tar.xz -C /out --strip-components=1 \
 && rm /tmp/blender.tar.xz

# Blender MCP add-on (single .py file). Goes into the user's BLENDER_USER_SCRIPTS
# at runtime — Blender no longer auto-scans <install>/<version>/scripts/addons/,
# only addons_core/ (bundled) and the per-user scripts dir.
FROM dl-base AS blender-mcp-fetch
RUN curl -fsSL -o /out \
      https://raw.githubusercontent.com/ahujasid/blender-mcp/main/addon.py

# FreeCAD 1.x AppImage extracted in place. Extraction (vs. running the
# AppImage directly at runtime) avoids the FUSE requirement.
FROM dl-base AS freecad-fetch
ARG FREECAD_VERSION
RUN curl -fsSL -o /tmp/FreeCAD.AppImage \
      "https://github.com/FreeCAD/FreeCAD/releases/download/${FREECAD_VERSION}/FreeCAD_${FREECAD_VERSION}-Linux-x86_64-py311.AppImage" \
 && chmod +x /tmp/FreeCAD.AppImage \
 && mkdir /tmp/extract \
 && cd /tmp/extract && /tmp/FreeCAD.AppImage --appimage-extract >/dev/null \
 && mv /tmp/extract/squashfs-root /out \
 && rm -rf /tmp/extract /tmp/FreeCAD.AppImage

FROM dl-base AS freecad-mcp-fetch
RUN apt-get update && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/* \
 && git clone --depth 1 https://github.com/neka-nat/freecad-mcp.git /tmp/freecad-mcp \
 && mv /tmp/freecad-mcp/addon/FreeCADMCP /out

FROM dl-base AS winetricks-fetch
RUN curl -fsSL -o /out \
      https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks

# MISE_INSTALL_PATH so the installer drops a single binary at /out.
FROM dl-base AS mise-fetch
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/out sh

# ============================================================================
# Final image
# ============================================================================
#
# LSIO baseimage-selkies ships:
#   - s6-overlay v3 init
#   - abc user (PUID/PGID remapped at runtime; HOME=/config)
#   - selkies in /lsiopy venv, with PixelFlux + WebSocket pixel streaming
#   - openbox + labwc, Xvfb, nginx, pulseaudio, dbus
#   - sudo NOPASSWD for the abc user
#   - HTTP port 3000 / HTTPS port 3001
#
# We layer dev tooling, Wine, Blender/FreeCAD, mise on top, then rewire the
# s6-rc bundles so the GUI services don't auto-start (devimage-gui controls).
FROM ghcr.io/linuxserver/baseimage-selkies:ubuntunoble
ARG BLENDER_MAJOR
# Surface BLENDER_MAJOR as an env var so heredoc'd RUN steps (where ARG
# expansion doesn't reach) can reference it. Persists at runtime too —
# self-documents which Blender major lives in /opt/blender.
ENV BLENDER_MAJOR=${BLENDER_MAJOR}
ENV DEBIAN_FRONTEND=noninteractive

# bash for RUN heredocs (arrays + readable inline comments).
SHELL ["/bin/bash", "-c"]

# ----------------------------------------------------------------------------
# One consolidated apt step: register WineHQ + GitHub CLI repos, enable i386,
# install everything in a single apt-get update + install pass. Packages are
# grouped inline so the rationale survives future edits.
# ----------------------------------------------------------------------------
RUN <<'EOF'
set -euo pipefail

# Pin all apt traffic to the Azure mirror. LSIO baseimage-ubuntu replaces
# the Ubuntu 24.04 cloud-image `ubuntu.sources` with the legacy
# `sources.list`, so target whichever exists.
for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
    [ -f "$f" ] && sed -i -E \
        -e 's|https?://archive\.ubuntu\.com/ubuntu|http://azure.archive.ubuntu.com/ubuntu|g' \
        -e 's|https?://security\.ubuntu\.com/ubuntu|http://azure.archive.ubuntu.com/ubuntu|g' \
        "$f"
done
{
  echo 'Acquire::Retries "3";'
  echo 'Acquire::http::Timeout "30";'
} > /etc/apt/apt.conf.d/80-resilient

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://dl.winehq.org/wine-builds/winehq.key \
  | gpg --dearmor -o /etc/apt/keyrings/winehq-archive.gpg
codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
echo "deb [arch=amd64,i386 signed-by=/etc/apt/keyrings/winehq-archive.gpg] https://dl.winehq.org/wine-builds/ubuntu/ ${codename} main" \
  > /etc/apt/sources.list.d/winehq.list

curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | gpg --dearmor -o /etc/apt/keyrings/githubcli.gpg
arch="$(dpkg --print-architecture)"
echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list

# 32-bit Wine packages
dpkg --add-architecture i386

# Packages NOT already in LSIO baseimage-selkies. Things like ca-certificates,
# openssh-client, sudo, locales-all, python3, python3-venv, xdotool, xclip,
# dbus-x11 are pre-installed there.
apt_packages=(
    # Core dev tools, TLS, transport
    git curl wget gnupg rsync direnv

    # Archive handling
    unzip zip xz-utils

    # C/C++ build chain (used by mise installs and native gem/npm builds)
    build-essential pkg-config

    # Search / parse / display utilities AI agents reach for constantly
    jq yq ripgrep fd-find fzf tree less

    # GUI automation primitives beyond what LSIO ships
    wmctrl scrot

    # File manager (LSIO's openbox baseimage ships only xterm)
    pcmanfm

    # update-desktop-database for Blender / FreeCAD .desktop entries
    desktop-file-utils

    # Media swiss-army knife (transcode, capture, probe)
    ffmpeg

    # Shell stack
    zsh man-db bash-completion

    # pip + pipx for the MCP server CLIs below
    python3-pip pipx

    # Blender runtime libs (its tarball is otherwise self-contained)
    libxi6 libxxf86vm1 libxfixes3 libxrender1 libxkbcommon0
    libsm6 libgl1 libegl1 libgomp1 libdbus-1-3

    # GitHub CLI
    gh
)

apt-get update
apt-get install -y --no-install-recommends "${apt_packages[@]}"

# Wine wants its Recommends so the i386 split installs alongside amd64.
apt-get install -y --install-recommends winehq-stable

ln -s "$(command -v fdfind)" /usr/local/bin/fd

rm -rf /var/lib/apt/lists/*
EOF

# ----------------------------------------------------------------------------
# Bring in artifacts from the parallel fetch stages and wire them up.
# ----------------------------------------------------------------------------

COPY --from=blender-fetch /out /opt/blender
RUN ln -s /opt/blender/blender /usr/local/bin/blender \
 && install -Dm 0644 /opt/blender/blender.desktop /usr/share/applications/blender.desktop \
 && install -Dm 0644 /opt/blender/blender.svg /usr/share/icons/hicolor/scalable/apps/blender.svg \
 && update-desktop-database /usr/share/applications

# Add-ons under /defaults get copied to /config on first boot by
# init-devimage-config. Blender only auto-scans the per-user scripts dir
# for legacy add-ons, so the path must be inside $HOME at runtime.
COPY --from=blender-mcp-fetch /out \
      /defaults/.config/blender/${BLENDER_MAJOR}/scripts/addons/blender_mcp.py

COPY --from=freecad-fetch /out /opt/freecad
RUN ln -s /opt/freecad/AppRun /usr/local/bin/freecad \
 && install -Dm 0644 /opt/freecad/org.freecad.FreeCAD.desktop /usr/share/applications/freecad.desktop \
 && sed -i 's|^Exec=.*|Exec=/usr/local/bin/freecad %F|' /usr/share/applications/freecad.desktop \
 && install -Dm 0644 /opt/freecad/org.freecad.FreeCAD.svg /usr/share/icons/hicolor/scalable/apps/freecad.svg \
 && update-desktop-database /usr/share/applications

COPY --from=winetricks-fetch --chmod=0755 /out /usr/local/bin/winetricks
COPY --from=mise-fetch /out /usr/local/bin/mise

COPY --from=freecad-mcp-fetch /out \
      /defaults/.local/share/FreeCAD/Mod/FreeCADMCP

# openbox / labwc don't auto-scan /usr/share/applications/*.desktop — their
# right-click root menu is a static XML file. Append Blender / FreeCAD entries
# to both the X11 (openbox) and Wayland (labwc) defaults. init-selkies-config
# copies these to $HOME/.config/{openbox,labwc}/menu.xml on first GUI boot.
RUN <<'EOF'
set -euo pipefail
entries='<item label="Files (pcmanfm)"><action name="Execute"><command>pcmanfm /workspace</command></action></item>\n<item label="Blender" icon="/usr/share/icons/hicolor/scalable/apps/blender.svg"><action name="Execute"><command>/usr/local/bin/blender</command></action></item>\n<item label="FreeCAD" icon="/usr/share/icons/hicolor/scalable/apps/freecad.svg"><action name="Execute"><command>/usr/local/bin/freecad</command></action></item>'
for f in /defaults/menu.xml /defaults/menu_wayland.xml; do
    [ -f "$f" ] || continue
    sed -i "s|</menu>|${entries}\n</menu>|" "$f"
done
EOF

COPY --chmod=0755 scripts/devimage-gui /usr/local/bin/devimage-gui
COPY --chmod=0755 scripts/devimage-mcp /usr/local/bin/devimage-mcp
COPY --chmod=0755 scripts/devimage-claude /usr/local/bin/devimage-claude
COPY --chmod=0755 scripts/devimage-codex /usr/local/bin/devimage-codex

# MCP server CLIs (Python). pipx system-wide so /usr/local/bin/* is universal.
RUN PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install blender-mcp \
 && PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install freecad-mcp

# mise on PATH for every login shell (sh, sudo -i). The per-user .bashrc /
# .zshrc seeded into /defaults below covers interactive non-login shells.
RUN printf '%s\n%s\n' \
      'export PATH="/usr/local/bin:$HOME/.local/share/mise/shims:$PATH"' \
      'command -v mise >/dev/null && eval "$(mise activate bash)"' \
      > /etc/profile.d/10-mise.sh \
 && chmod 0644 /etc/profile.d/10-mise.sh

# sudoers: LSIO baseimage already grants abc NOPASSWD via the sudo group, but
# extend secure_path to include mise shims so `sudo mise-installed-cmd` works.
RUN echo 'Defaults secure_path="/config/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' \
      > /etc/sudoers.d/91-secure-path \
 && chmod 0440 /etc/sudoers.d/91-secure-path \
 && visudo -c

RUN usermod --shell /usr/bin/zsh abc

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# ----------------------------------------------------------------------------
# Per-user defaults — seeded into /defaults, copied to /config on first boot.
#
# /config is the runtime HOME for abc; it's typically a named volume, so we
# can't write to it at build time. Instead, install everything into /defaults
# and let init-devimage-config (oneshot) copy missing entries on boot.
# ----------------------------------------------------------------------------
RUN <<'EOF'
set -euo pipefail

# oh-my-zsh installs to $HOME/.oh-my-zsh and creates a default ~/.zshrc.
# Force HOME so the install lands in /defaults/, not /root/.
export HOME=/defaults
mkdir -p /defaults
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

mkdir -p /defaults/.config/mise

# profile.d covers login shells; these rc-file entries cover non-login
# interactive shells (e.g. terminals spawned inside the desktop).
for shell in bash zsh; do
    {
        echo 'export PATH="$HOME/.local/share/mise/shims:$PATH"'
        echo "eval \"\$(/usr/local/bin/mise activate ${shell})\""
        echo "eval \"\$(/usr/bin/direnv hook ${shell})\""
    } >> "/defaults/.${shell}rc"
done

# Auto-enable Blender MCP so the agent doesn't have to click through
# Preferences. HOME=/defaults (set above) steers userpref.blend into the
# seed tree; BLENDER_USER_SCRIPTS points at where the add-on COPY landed.
BLENDER_USER_SCRIPTS="/defaults/.config/blender/${BLENDER_MAJOR}/scripts" \
  blender --background --python-expr \
    "import bpy; bpy.ops.preferences.addon_enable(module='blender_mcp'); bpy.ops.wm.save_userpref()"
EOF

# ----------------------------------------------------------------------------
# s6-rc rewiring: move GUI services out of the default `user` bundle into a
# `gui` bundle so they don't auto-start. devimage-gui controls them with
# `s6-rc -u change gui` / `s6-rc -d change gui`.
# ----------------------------------------------------------------------------
RUN <<'EOF'
set -euo pipefail
cd /etc/s6-overlay/s6-rc.d

# GUI longrun services + their init oneshots. svc-watchdog and svc-docker
# stay in `user` (lightweight, do not need the desktop stack).
gui_services=(
    svc-de svc-selkies svc-xorg svc-xsettingsd
    svc-pulseaudio svc-dbus svc-nginx
    init-video init-selkies init-selkies-config init-selkies-end
)

for svc in "${gui_services[@]}"; do
    rm -f "user/contents.d/${svc}"
done

# init-config depends on init-selkies-end (LSIO upstream wires it that way to
# stage default /config files after selkies is configured). Since we yanked
# init-selkies-end out of the boot bundle, also drop init-config — we'll seed
# /config from our own oneshot (init-devimage-config) regardless of GUI state.
rm -f user/contents.d/init-config

# Define the on-demand `gui` bundle. The bundle expansion brings in transitive
# deps (svc-pulseaudio→init-services etc.) automatically; listing just the
# top-level GUI entries is enough.
mkdir -p gui/contents.d
echo bundle > gui/type
for svc in "${gui_services[@]}" init-config; do
    touch "gui/contents.d/${svc}"
done

# A boot-time oneshot that seeds /config from /defaults (idempotent) and
# creates /workspace owned by abc. Runs after init-adduser remaps abc's
# UID/GID to PUID/PGID, so chown lands on the right numeric IDs.
mkdir -p init-devimage-config/dependencies.d
echo oneshot > init-devimage-config/type
cat > init-devimage-config/up <<'UP'
/etc/s6-overlay/s6-rc.d/init-devimage-config/run
UP
touch init-devimage-config/dependencies.d/init-services
cat > init-devimage-config/run <<'RUN'
#!/usr/bin/with-contenv bash
set -euo pipefail

# Recursively seed /config from /defaults. --ignore-existing preserves any
# file the user (or an earlier init) already wrote to /config and only
# materializes the rest. The previous top-level "skip if /config/<name>
# exists" check left deeply-nested seeds (Blender / FreeCAD addons under
# .config/, .local/) stranded once LSIO's selkies init pre-created those
# parent dirs.
rsync -a --ignore-existing \
    --exclude='/autostart' \
    --exclude='/autostart_wayland' \
    --exclude='/default.conf' \
    --exclude='/labwc.xml' \
    --exclude='/menu.xml' \
    --exclude='/menu_wayland.xml' \
    --exclude='/startwm.sh' \
    --exclude='/startwm_wayland.sh' \
    --exclude='/pid' \
    --exclude='/native' \
    /defaults/ /config/
chown -R abc:abc /config 2>/dev/null || true

install -d -o abc -g abc /workspace
RUN
chmod 0755 init-devimage-config/run

touch user/contents.d/init-devimage-config

# Trust the throttle sidecar's generated MITM CA every boot.
mkdir -p init-devimage-trust-proxy-ca/dependencies.d
echo oneshot > init-devimage-trust-proxy-ca/type
cat > init-devimage-trust-proxy-ca/up <<'UP'
/etc/s6-overlay/s6-rc.d/init-devimage-trust-proxy-ca/run
UP
touch init-devimage-trust-proxy-ca/dependencies.d/init-services
cat > init-devimage-trust-proxy-ca/run <<'RUN'
#!/usr/bin/with-contenv bash
set -euo pipefail

src=/mnt/mitm-ca/mitmproxy-ca-cert.pem
dst=/usr/local/share/ca-certificates/devimage-throttle.crt

if [[ ! -r "$src" ]]; then
    echo "devimage: $src not present, nothing to trust"
    exit 0
fi

install -m 0644 "$src" "$dst"
update-ca-certificates >/dev/null
echo "trusted: $dst"
RUN
chmod 0755 init-devimage-trust-proxy-ca/run
touch user/contents.d/init-devimage-trust-proxy-ca

# Boot-time opt-in: DEVIMAGE_ENABLE_GUI=true starts the gui bundle at the
# end of init. Implemented as a oneshot that drives s6-rc against the
# live state once init-services has finished.
mkdir -p init-devimage-gui-autostart/dependencies.d
echo oneshot > init-devimage-gui-autostart/type
cat > init-devimage-gui-autostart/up <<'UP'
/etc/s6-overlay/s6-rc.d/init-devimage-gui-autostart/run
UP
touch init-devimage-gui-autostart/dependencies.d/init-devimage-config
cat > init-devimage-gui-autostart/run <<'RUN'
#!/usr/bin/with-contenv bash
case "$(printf '%s' "${DEVIMAGE_ENABLE_GUI:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on)
        s6-rc -u change gui >/dev/null || true
        ;;
esac
RUN
chmod 0755 init-devimage-gui-autostart/run
touch user/contents.d/init-devimage-gui-autostart
EOF

# Runtime networking is intentionally routed through the always-on throttle
# sidecar from compose.yml. Bake the defaults into the image so sudo and apt
# do not depend on inheriting proxy environment variables from the caller.
ENV HTTP_PROXY=http://throttle:8080 \
    HTTPS_PROXY=http://throttle:8080 \
    NO_PROXY=localhost,127.0.0.1,::1 \
    http_proxy=http://throttle:8080 \
    https_proxy=http://throttle:8080 \
    no_proxy=localhost,127.0.0.1,::1 \
    NODE_USE_ENV_PROXY=1 \
    NODE_EXTRA_CA_CERTS=/mnt/mitm-ca/mitmproxy-ca-cert.pem \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

RUN printf '%s\n' \
      'Acquire::http::Proxy "http://throttle:8080";' \
      'Acquire::https::Proxy "http://throttle:8080";' \
      > /etc/apt/apt.conf.d/90-devimage-proxy

# WORKDIR after the abc user exists; /workspace itself is created at runtime
# by init-devimage-config so its ownership tracks PUID/PGID.
WORKDIR /workspace
