#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
ORIGINAL_ARGS=("$@")
# shellcheck source=lib/path.sh
. "$SCRIPT_DIR/lib/path.sh"
# shellcheck source=lib/warnings.sh
. "$SCRIPT_DIR/lib/warnings.sh"

RUN_DIR="${RUN_DIR:-$(speedtest_default_run_dir)}"
WIFI_DRIVER="${WIFI_DRIVER:-}"
CONNECTION_NAME="${CONNECTION_NAME:-}"
ASSUME_YES=0
REQUIRED_COMMANDS=(nmcli systemctl modprobe)

usage() {
  cat <<'EOF'
Usage:
  ./scripts/recover-wifi-interface.sh [-y|--yes]

Recovers a Wi-Fi interface that disappeared entirely (no Wi-Fi device in
nmcli/iw, no Wi-Fi toggle in the desktop UI). This happens when a daemon that
created the interface (iwd) stops and deletes it. The script stops iwd when it
conflicts with the configured backend, reloads the Wi-Fi driver module, and
hands the interface back to NetworkManager.

Options:
  -y, --yes   skip the typed confirmation
  -h, --help  show this help

Environment:
  WIFI_DRIVER      kernel module to reload (auto-detected via lspci when unset)
  CONNECTION_NAME  profile to bring up after recovery (autoconnect otherwise)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

rerun_with_sudo() {
  ui_warn "Recovering the Wi-Fi interface needs root for modprobe and systemctl. Asking sudo now."
  exec sudo --preserve-env=RUN_DIR,WIFI_DRIVER,CONNECTION_NAME,SPEEDTEST_ROOT_DIR "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
}

if [ "$(id -u)" -ne 0 ]; then
  speedtest_require_commands sudo "${REQUIRED_COMMANDS[@]}" || exit 1
  rerun_with_sudo
fi

speedtest_require_commands "${REQUIRED_COMMANDS[@]}" || exit 1

mkdir -p "$RUN_DIR"
LOG_FILE="$RUN_DIR/recover-wifi-interface.log"

log() {
  printf '%s\n' "$1"
  printf '[%s] %s\n' "$(date)" "$1" >> "$LOG_FILE"
}

wifi_ifaces() {
  local dev
  for dev in /sys/class/net/*; do
    if [ -d "$dev/wireless" ]; then
      basename "$dev"
    fi
  done
}

detect_wifi_driver() {
  if [ -n "$WIFI_DRIVER" ]; then
    printf '%s\n' "$WIFI_DRIVER"
    return
  fi

  local iface
  iface="$(wifi_ifaces | head -1)"
  if [ -n "$iface" ]; then
    basename "$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null)" 2>/dev/null
    return
  fi

  if command -v lspci >/dev/null 2>&1; then
    lspci -k 2>/dev/null |
      awk '/[Nn]etwork controller/ {found = 1} found && /Kernel driver in use:/ {print $NF; exit}'
  fi
}

nm_wifi_backend() {
  NetworkManager --print-config 2>/dev/null |
    awk -F= '/^[[:space:]]*wifi\.backend[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); backend = $2} END {print backend}'
}

if [ "$ASSUME_YES" -ne 1 ]; then
  cat <<EOF
This will recover the Wi-Fi interface on this machine:
  - stop iwd if it is running against a wpa_supplicant backend
  - reload the Wi-Fi driver module (briefly removes the device)
  - ensure NetworkManager manages the interface and reconnect

Type RECOVER to continue:
EOF
  read -r confirmation
  if [ "$confirmation" != "RECOVER" ]; then
    printf '%s\n' "Aborted. No changes applied."
    exit 1
  fi
fi

driver="$(detect_wifi_driver)"
if [ -z "$driver" ]; then
  ui_error "Could not detect the Wi-Fi driver module. Rerun with WIFI_DRIVER=<module> (for example WIFI_DRIVER=iwlwifi)."
  exit 1
fi
log "Wi-Fi driver module: $driver"

existing="$(wifi_ifaces | tr '\n' ' ')"
log "Wi-Fi interfaces before recovery: ${existing:-<none>}"

backend="$(nm_wifi_backend)"
log "NetworkManager wifi.backend: ${backend:-wpa_supplicant (default)}"

if systemctl is-active iwd.service >/dev/null 2>&1; then
  if [ "${backend:-wpa_supplicant}" = "iwd" ]; then
    log "iwd is the configured backend; restarting iwd instead of stopping it."
    systemctl restart iwd.service >> "$LOG_FILE" 2>&1
  else
    log "iwd is running but the backend is ${backend:-wpa_supplicant}; stopping iwd."
    systemctl stop iwd.service >> "$LOG_FILE" 2>&1
  fi
fi

log "Reloading driver module $driver."
modprobe -r "$driver" >> "$LOG_FILE" 2>&1
modprobe "$driver" >> "$LOG_FILE" 2>&1

iface=""
for _ in $(seq 1 15); do
  iface="$(wifi_ifaces | head -1)"
  if [ -n "$iface" ]; then
    break
  fi
  sleep 1
done

if [ -z "$iface" ]; then
  ui_error "No Wi-Fi interface appeared after reloading $driver. Check 'journalctl -k' for driver errors; a reboot may be required."
  exit 1
fi
log "Wi-Fi interface present: $iface"

nmcli radio wifi on >> "$LOG_FILE" 2>&1 || true
nmcli device set "$iface" managed yes >> "$LOG_FILE" 2>&1 || true
sleep 3

if [ -n "$CONNECTION_NAME" ]; then
  log "Bringing up profile: $CONNECTION_NAME"
  nmcli connection up id "$CONNECTION_NAME" ifname "$iface" >> "$LOG_FILE" 2>&1 || true
fi

state=""
for _ in $(seq 1 15); do
  state="$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: -v dev="$iface" '$1 == dev {print $2; exit}')"
  if [ "$state" = "connected" ]; then
    break
  fi
  sleep 1
done

log "Interface $iface state: ${state:-unknown}"
if [ "$state" = "connected" ]; then
  log "Recovery complete: $iface is connected."
else
  log "Interface restored but not connected yet. Pick a network with: nmcli device wifi connect <SSID> --ask"
fi
log "Log written to $LOG_FILE"
