#!/usr/bin/env bash
set -euo pipefail

markdown=false
case "${1:-}" in
  --markdown|"")
    markdown=true
    ;;
  *)
    echo "usage: $0 [--markdown]" >&2
    exit 2
    ;;
esac

section() {
  if [[ "${markdown}" == true ]]; then
    printf '\n## %s\n\n' "$1"
  else
    printf '\n[%s]\n' "$1"
  fi
}

kv() {
  printf -- '- %s: %s\n' "$1" "${2:-}"
}

exists() {
  [[ -e "$1" ]] && printf present || printf missing
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_short() {
  local timeout_s="$1"
  shift
  if cmd_exists timeout; then
    timeout "${timeout_s}" "$@" 2>&1 || true
  else
    "$@" 2>&1 || true
  fi
}

section "Identity"
kv "user" "$(id -un 2>/dev/null || true)"
kv "uid_gid" "$(id -u 2>/dev/null || true):$(id -g 2>/dev/null || true)"
kv "groups" "$(id -Gn 2>/dev/null || true)"
kv "home" "${HOME:-}"
kv "pwd" "$(pwd)"
kv "shell" "${SHELL:-}"

section "Filesystem"
kv "/config" "$(exists /config)"
kv "/workspace" "$(exists /workspace)"
if [[ -e /workspace ]]; then
  kv "/workspace owner" "$(stat -c '%U:%G %a' /workspace 2>/dev/null || true)"
  kv "/workspace mount" "$(findmnt -T /workspace -no SOURCE,FSTYPE,OPTIONS 2>/dev/null || true)"
fi

section "Networking"
kv "HTTP_PROXY" "${HTTP_PROXY:-${http_proxy:-}}"
kv "HTTPS_PROXY" "${HTTPS_PROXY:-${https_proxy:-}}"
kv "NO_PROXY" "${NO_PROXY:-${no_proxy:-}}"
kv "NODE_EXTRA_CA_CERTS" "${NODE_EXTRA_CA_CERTS:-}"
kv "NODE_USE_ENV_PROXY" "${NODE_USE_ENV_PROXY:-}"
kv "mitm CA" "$(exists /mnt/mitm-ca/mitmproxy-ca-cert.pem)"
kv "system CA copy" "$(exists /usr/local/share/ca-certificates/devimage-throttle.crt)"
kv "Chrome NSS DB" "$(exists /config/.pki/nssdb/cert9.db)"
if cmd_exists ip; then
  kv "default route" "$(ip route show default 2>/dev/null | head -1 || true)"
fi

section "Desktop"
if cmd_exists devimage-gui; then
  printf '```text\n'
  devimage-gui status 2>/dev/null || true
  printf '```\n'
else
  kv "devimage-gui" "missing"
fi
kv "DISPLAY" "${DISPLAY:-}"
kv "WAYLAND_DISPLAY" "${WAYLAND_DISPLAY:-}"
kv "XDG_RUNTIME_DIR" "${XDG_RUNTIME_DIR:-}"

section "Toolchain"
kv "sudo" "$(cmd_exists sudo && printf present || printf missing)"
kv "mise" "$(command -v mise 2>/dev/null || printf missing)"
if cmd_exists mise; then
  printf '```text\n'
  mise current 2>/dev/null || true
  printf '```\n'
fi
kv "node" "$(command -v node 2>/dev/null || printf missing)"
kv "npm" "$(command -v npm 2>/dev/null || printf missing)"
kv "codex" "$(command -v codex 2>/dev/null || printf missing)"
kv "claude" "$(command -v claude 2>/dev/null || printf missing)"

section "GPU"
kv "/dev/dxg" "$(exists /dev/dxg)"
kv "/usr/lib/wsl/lib" "$(exists /usr/lib/wsl/lib)"
kv "/opt/mesa-dzn" "$(exists /opt/mesa-dzn)"
kv "LD_LIBRARY_PATH" "${LD_LIBRARY_PATH:-}"
kv "GALLIUM_DRIVER" "${GALLIUM_DRIVER:-}"
kv "VK_DRIVER_FILES" "${VK_DRIVER_FILES:-}"
kv "MESA_D3D12_DEFAULT_ADAPTER_NAME" "${MESA_D3D12_DEFAULT_ADAPTER_NAME:-}"
kv "nvidia-smi" "$(command -v nvidia-smi 2>/dev/null || printf missing)"
if cmd_exists nvidia-smi; then
  printf '```text\n'
  run_short 5s nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
  printf '```\n'
fi
kv "vulkaninfo" "$(command -v vulkaninfo 2>/dev/null || printf missing)"
if cmd_exists vulkaninfo; then
  printf '```text\n'
  vulkan_env=(
    "LD_LIBRARY_PATH=/opt/mesa-dzn/lib/x86_64-linux-gnu:/usr/lib/wsl/lib:${LD_LIBRARY_PATH:-}"
    "MESA_D3D12_DEFAULT_ADAPTER_NAME=${MESA_D3D12_DEFAULT_ADAPTER_NAME:-NVIDIA}"
  )
  if [[ -n "${VK_DRIVER_FILES:-}" ]]; then
    vulkan_env+=("VK_DRIVER_FILES=${VK_DRIVER_FILES}")
  elif [[ -r /opt/mesa-dzn/share/vulkan/icd.d/dzn_icd.x86_64.json ]]; then
    vulkan_env+=("VK_DRIVER_FILES=/opt/mesa-dzn/share/vulkan/icd.d/dzn_icd.x86_64.json")
  fi
  run_short 8s env "${vulkan_env[@]}" vulkaninfo --summary
  printf '```\n'
fi
kv "google-chrome" "$(command -v google-chrome 2>/dev/null || printf missing)"
kv "devimage-chrome-webgpu" "$(command -v devimage-chrome-webgpu 2>/dev/null || printf missing)"
