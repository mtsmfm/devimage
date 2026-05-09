# syntax=docker/dockerfile:1.7
#
# Browser-accessible Linux desktop pre-configured for AI coding agents.
# Built on top of the Selkies WebRTC desktop image (KDE Plasma + Ubuntu 24.04).

ARG SELKIES_VERSION=1.6.2
ARG BLENDER_VERSION=4.2.20
ARG BLENDER_MAJOR=4.2
ARG BLENDER_SHA256=1f73f797d62be8aa2161f8c88a12f474cf23611592fa77b8fc003d60f0594a83
ARG FREECAD_VERSION=1.1.1
ARG USERNAME=ubuntu

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

# Selkies: 4 co-versioned release artifacts (GStreamer build, Python wheel,
# web client, js-interposer .deb). Must be applied together.
FROM dl-base AS selkies-fetch
ARG SELKIES_VERSION
RUN mkdir /out \
 && for f in \
      "gstreamer-selkies_gpl_v${SELKIES_VERSION}_ubuntu24.04_amd64.tar.gz" \
      "selkies_gstreamer-${SELKIES_VERSION}-py3-none-any.whl" \
      "selkies-gstreamer-web_v${SELKIES_VERSION}.tar.gz" \
      "selkies-js-interposer_v${SELKIES_VERSION}_ubuntu24.04_amd64.deb"; \
    do \
      curl -fsSL -o "/out/$f" \
        "https://github.com/selkies-project/selkies/releases/download/v${SELKIES_VERSION}/$f"; \
    done

# Blender 4.2 LTS. We pin to 4.2 rather than the current 5.x because that
# version's bpy API has the most stable AI training data — newer releases
# produce hallucinated calls.
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
# at runtime — Blender 4.2 no longer auto-scans <install>/<version>/scripts/addons/,
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

# FreeCAD MCP add-on — only the addon/FreeCADMCP subtree of the upstream repo.
FROM dl-base AS freecad-mcp-fetch
RUN apt-get update && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/* \
 && git clone --depth 1 https://github.com/neka-nat/freecad-mcp.git /tmp/freecad-mcp \
 && mv /tmp/freecad-mcp/addon/FreeCADMCP /out

# Winetricks (single shell script).
FROM dl-base AS winetricks-fetch
RUN curl -fsSL -o /out \
      https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks

# mise binary (single static binary; the installer takes a full destination path).
FROM dl-base AS mise-fetch
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/out sh

# ============================================================================
# Final image
# ============================================================================
FROM ghcr.io/selkies-project/nvidia-egl-desktop:24.04
ARG USERNAME
ARG BLENDER_MAJOR
USER 0
ENV DEBIAN_FRONTEND=noninteractive

# bash for RUN heredocs (arrays + readable inline comments).
SHELL ["/bin/bash", "-c"]

# ----------------------------------------------------------------------------
# One consolidated apt step: register WineHQ + GitHub CLI repos, enable i386,
# install everything in a single apt-get update + install pass. Packages are
# grouped inline so the rationale survives future edits.
# ----------------------------------------------------------------------------
COPY --from=selkies-fetch /out /tmp/selkies/
RUN <<'EOF'
set -euo pipefail

# Pin all apt traffic to the Azure mirror (same logic as in dl-base).
sed -i -E \
    -e 's|https?://archive\.ubuntu\.com/ubuntu|http://azure.archive.ubuntu.com/ubuntu|g' \
    -e 's|https?://security\.ubuntu\.com/ubuntu|http://azure.archive.ubuntu.com/ubuntu|g' \
    /etc/apt/sources.list.d/ubuntu.sources
{
  echo 'Acquire::Retries "3";'
  echo 'Acquire::http::Timeout "30";'
} > /etc/apt/apt.conf.d/80-resilient

# The base image already registers WineHQ via a different keyring filename;
# wipe it so apt does not see two conflicting source entries for the URL.
rm -f /etc/apt/sources.list.d/*wine* /etc/apt/keyrings/*wine*

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

apt_packages=(
    # Core dev tools, TLS, transport
    git curl wget ca-certificates gnupg openssh-client rsync direnv

    # Archive handling
    unzip zip xz-utils

    # C/C++ build chain (used by mise installs and native gem/npm builds)
    build-essential pkg-config

    # Search / parse / display utilities AI agents reach for constantly
    jq yq ripgrep fd-find fzf tree less

    # GUI automation primitives (drive desktop, take screenshots, clipboard)
    xdotool wmctrl scrot xclip

    # Shell stack
    zsh sudo locales man-db bash-completion

    # System Python (per-project versions go via mise)
    python3 python3-pip python3-venv pipx

    # Blender 4.2 runtime libs (its tarball is otherwise self-contained)
    libxi6 libxxf86vm1 libxfixes3 libxrender1 libxkbcommon0
    libsm6 libgl1 libegl1 libgomp1 libdbus-1-3

    # GitHub CLI
    gh
)

apt-get update
apt-get install -y --no-install-recommends "${apt_packages[@]}"

# Wine wants its Recommends so the i386 split installs alongside amd64.
apt-get install -y --install-recommends winehq-stable

# Selkies js-interposer .deb (downloaded in selkies-fetch); apt resolves its
# deps and ties it into the same dpkg state as the rest.
apt-get install -y --no-install-recommends /tmp/selkies/selkies-js-interposer_*.deb

locale-gen en_US.UTF-8
ln -s "$(command -v fdfind)" /usr/local/bin/fd

rm -rf /var/lib/apt/lists/*
EOF

# ----------------------------------------------------------------------------
# Selkies upgrade — apply the remaining 3 co-versioned artifacts on top of the
# base image's bundled version (the .deb half went in via apt above).
# ----------------------------------------------------------------------------
RUN <<'EOF'
set -euo pipefail
cd /opt
tar -xzf /tmp/selkies/gstreamer-selkies_gpl_*.tar.gz
tar -xzf /tmp/selkies/selkies-gstreamer-web_*.tar.gz
pip3 install --break-system-packages --no-cache-dir --force-reinstall \
    /tmp/selkies/selkies_gstreamer-*.whl "websockets<14.0"
rm -rf /tmp/selkies
EOF

# ----------------------------------------------------------------------------
# Bring in artifacts from the parallel fetch stages and wire them up.
# ----------------------------------------------------------------------------

# Blender.
COPY --from=blender-fetch /out /opt/blender
RUN ln -s /opt/blender/blender /usr/local/bin/blender \
 && install -Dm 0644 /opt/blender/blender.desktop /usr/share/applications/blender.desktop \
 && install -Dm 0644 /opt/blender/blender.svg /usr/share/icons/hicolor/scalable/apps/blender.svg \
 && update-desktop-database /usr/share/applications

# Blender MCP add-on into the user's scripts dir (canonical place for legacy
# add-ons in Blender 4.2). Owned by the ubuntu user so save_userpref() can
# rewrite the surrounding state.
COPY --from=blender-mcp-fetch --chown=${USERNAME}:${USERNAME} \
      /out /home/${USERNAME}/.config/blender/${BLENDER_MAJOR}/scripts/addons/blender_mcp.py

# FreeCAD (extracted AppImage tree).
COPY --from=freecad-fetch /out /opt/freecad
RUN ln -s /opt/freecad/AppRun /usr/local/bin/freecad \
 && install -Dm 0644 /opt/freecad/org.freecad.FreeCAD.desktop /usr/share/applications/freecad.desktop \
 && sed -i 's|^Exec=.*|Exec=/usr/local/bin/freecad %F|' /usr/share/applications/freecad.desktop \
 && install -Dm 0644 /opt/freecad/org.freecad.FreeCAD.svg /usr/share/icons/hicolor/scalable/apps/freecad.svg \
 && update-desktop-database /usr/share/applications

# Single-file binaries.
COPY --from=winetricks-fetch --chmod=0755 /out /usr/local/bin/winetricks
COPY --from=mise-fetch /out /usr/local/bin/mise

# FreeCAD MCP add-on into the user's Mod dir (FreeCAD always scans this,
# regardless of where FreeCAD itself is installed).
COPY --from=freecad-mcp-fetch --chown=${USERNAME}:${USERNAME} \
      /out /home/${USERNAME}/.local/share/FreeCAD/Mod/FreeCADMCP

# Helper that registers MCP servers with both agents post-mount.
COPY --chmod=0755 scripts/setup-mcp /usr/local/bin/setup-mcp

# MCP server CLIs (Python). pipx system-wide so /usr/local/bin/* is universal.
RUN PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install blender-mcp \
 && PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install freecad-mcp

# mise on PATH for every shell (sh, login shells, sudo -i).
RUN printf '%s\n%s\n' \
      'export PATH="/usr/local/bin:$HOME/.local/share/mise/shims:$PATH"' \
      'command -v mise >/dev/null && eval "$(mise activate bash)"' \
      > /etc/profile.d/10-mise.sh \
 && chmod 0644 /etc/profile.d/10-mise.sh

# Sudo NOPASSWD + secure_path that includes mise shims; default shell to zsh;
# create the workspace dir owned by the user.
#
# The base image's /etc/sudoers.d/kdesu-sudoers ships with non-0440 perms which
# would make `visudo -c` fail across the whole drop-in dir, so normalise perms
# on every file before validating.
RUN echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-${USERNAME} \
 && echo 'Defaults secure_path="/home/'${USERNAME}'/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' \
      > /etc/sudoers.d/91-secure-path \
 && chmod 0440 /etc/sudoers.d/* \
 && visudo -c \
 && usermod --shell /usr/bin/zsh ${USERNAME} \
 && install -d -o ${USERNAME} -g ${USERNAME} /workspace

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

USER ${USERNAME}
WORKDIR /workspace

# ----------------------------------------------------------------------------
# Per-user setup: oh-my-zsh, mise activation in rc files, and the Blender MCP
# add-on enabled in userpref.blend. Coding agents (Claude Code, Codex, etc.)
# are intentionally NOT installed here — pick yours at runtime via mise.
# ----------------------------------------------------------------------------
RUN <<'EOF'
set -euo pipefail

# oh-my-zsh installs to $HOME/.oh-my-zsh and creates a default ~/.zshrc.
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

mkdir -p ~/.config/mise

# profile.d covers login shells; these rc-file entries cover non-login
# interactive shells (e.g. terminals spawned inside the Selkies desktop).
for shell in bash zsh; do
    {
        echo 'export PATH="$HOME/.local/share/mise/shims:$PATH"'
        echo "eval \"\$(/usr/local/bin/mise activate ${shell})\""
        echo "eval \"\$(/usr/bin/direnv hook ${shell})\""
    } >> "$HOME/.${shell}rc"
done

# Auto-enable the Blender MCP add-on so the agent doesn't have to click through
# Preferences. Saves to ~/.config/blender/4.2/config/userpref.blend.
blender --background --python-expr \
  "import bpy; bpy.ops.preferences.addon_enable(module='blender_mcp'); bpy.ops.wm.save_userpref()"
EOF
