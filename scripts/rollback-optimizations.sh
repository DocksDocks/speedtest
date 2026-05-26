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
CONNECTION_NAME="${CONNECTION_NAME:-$(speedtest_default_connection_name)}"
IFACE="${IFACE:-$(speedtest_default_wifi_iface)}"
REQUIRED_COMMANDS=(nmcli iw resolvectl systemctl)

if [ -z "$CONNECTION_NAME" ] || [ -z "$IFACE" ]; then
  printf '%s\n' "No active Wi-Fi connection detected. Set CONNECTION_NAME and IFACE explicitly." >&2
  exit 1
fi

rerun_with_sudo() {
  ui_warn "This script changes NetworkManager, DNS, Wi-Fi powersave, and service state. Asking sudo now."
  exec sudo --preserve-env=RUN_DIR,CONNECTION_NAME,IFACE,SPEEDTEST_ROOT_DIR "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
}

if [ "$(id -u)" -ne 0 ]; then
  speedtest_require_commands sudo "${REQUIRED_COMMANDS[@]}" || exit 1
  rerun_with_sudo
fi

speedtest_require_commands "${REQUIRED_COMMANDS[@]}" || exit 1

mkdir -p "$RUN_DIR"

cat <<EOF
This will roll back the network optimizations on:
  connection: $CONNECTION_NAME
  interface:  $IFACE

It will restore automatic DNS, clear the pinned BSSID, keep Wi-Fi power saving
disabled, flush DNS cache, and restart Avahi/mDNS.

Type ROLLBACK to continue:
EOF

read -r confirmation
if [ "$confirmation" != "ROLLBACK" ]; then
  printf '%s\n' "Aborted. No changes applied." | tee "$RUN_DIR/rollback-optimizations.log"
  exit 1
fi

{
  printf '%s\n' "Started: $(date)"
  printf '%s\n' "Connection: $CONNECTION_NAME"
  printf '%s\n' "Interface: $IFACE"
  printf '%s\n' ""
  printf '%s\n' "Commands:"
  printf '%s\n' "nmcli connection modify \"$CONNECTION_NAME\" ipv4.dns \"\" ipv4.ignore-auto-dns no ipv4.dns-search \"\" 802-11-wireless.powersave disable 802-11-wireless.bssid \"\""
  printf '%s\n' "nmcli connection up \"$CONNECTION_NAME\""
  printf '%s\n' "iw dev \"$IFACE\" set power_save off"
  printf '%s\n' "iw dev \"$IFACE\" get power_save"
  printf '%s\n' "resolvectl flush-caches"
  printf '%s\n' "systemctl restart avahi-daemon.socket avahi-daemon.service"
  printf '%s\n' ""
} > "$RUN_DIR/rollback-optimizations.log"

nmcli connection modify "$CONNECTION_NAME" \
  ipv4.dns "" \
  ipv4.ignore-auto-dns no \
  ipv4.dns-search "" \
  802-11-wireless.powersave disable \
  802-11-wireless.bssid "" \
  > "$RUN_DIR/rollback-nmcli-modify.txt" 2>&1
nmcli_modify_status=$?

nmcli connection up "$CONNECTION_NAME" > "$RUN_DIR/rollback-nmcli-connection-up.txt" 2>&1
nmcli_up_status=$?

if command -v iw >/dev/null 2>&1; then
  iw dev "$IFACE" set power_save off > "$RUN_DIR/rollback-iw-power-save-off.txt" 2>&1
  iw_power_save_off_status=$?
  iw dev "$IFACE" get power_save > "$RUN_DIR/rollback-iw-power-save-state.txt" 2>&1
  iw_power_save_state_status=$?
else
  printf '%s\n' "Missing required command: iw" > "$RUN_DIR/rollback-iw-power-save-off.txt"
  printf '%s\n' "Missing required command: iw" > "$RUN_DIR/rollback-iw-power-save-state.txt"
  iw_power_save_off_status=127
  iw_power_save_state_status=127
fi

resolvectl flush-caches > "$RUN_DIR/rollback-resolvectl-flush-caches.txt" 2>&1
resolvectl_status=$?

systemctl restart avahi-daemon.socket avahi-daemon.service > "$RUN_DIR/rollback-avahi-restart.txt" 2>&1
avahi_status=$?

{
  printf '%s\n' "Exit statuses:"
  printf '%s\n' "  nmcli modify: $nmcli_modify_status"
  printf '%s\n' "  nmcli connection up: $nmcli_up_status"
  printf '%s\n' "  iw power_save off: $iw_power_save_off_status"
  printf '%s\n' "  iw power_save state: $iw_power_save_state_status"
  printf '%s\n' "  resolvectl flush-caches: $resolvectl_status"
  printf '%s\n' "  avahi restart: $avahi_status"
  printf '%s\n' "Finished: $(date)"
} >> "$RUN_DIR/rollback-optimizations.log"

if [ "$nmcli_modify_status" -ne 0 ] ||
  [ "$nmcli_up_status" -ne 0 ] ||
  [ "$iw_power_save_off_status" -ne 0 ] ||
  [ "$iw_power_save_state_status" -ne 0 ] ||
  [ "$resolvectl_status" -ne 0 ] ||
  [ "$avahi_status" -ne 0 ]; then
  printf '%s\n' "One or more rollback commands failed. Check logs in $RUN_DIR."
  exit 1
fi

printf '%s\n' "Optimizations rolled back. Logs written to $RUN_DIR."
