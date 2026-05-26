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
PRIMARY_DNS="${PRIMARY_DNS:-9.9.9.9}"
SECONDARY_DNS="${SECONDARY_DNS:-1.1.1.1}"
DNS_SEARCH="${DNS_SEARCH:-}"
PREFERRED_BSSID="${PREFERRED_BSSID:-}"
IWD_MAIN_CONF="${IWD_MAIN_CONF:-/etc/iwd/main.conf}"
WIFI_DRIVER="${WIFI_DRIVER:-}"
REQUIRED_COMMANDS=(nmcli iw resolvectl systemctl)

if [ -z "$CONNECTION_NAME" ] || [ -z "$IFACE" ]; then
  printf '%s\n' "No active Wi-Fi connection detected. Set CONNECTION_NAME and IFACE explicitly." >&2
  exit 1
fi

rerun_with_sudo() {
  ui_warn "This script changes NetworkManager, DNS, iwd, and service state. Asking sudo now."
  exec sudo --preserve-env=RUN_DIR,CONNECTION_NAME,IFACE,PRIMARY_DNS,SECONDARY_DNS,DNS_SEARCH,PREFERRED_BSSID,IWD_MAIN_CONF,WIFI_DRIVER,SPEEDTEST_ROOT_DIR "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
}

if [ "$(id -u)" -ne 0 ]; then
  speedtest_require_commands sudo "${REQUIRED_COMMANDS[@]}" || exit 1
  rerun_with_sudo
fi

speedtest_require_commands "${REQUIRED_COMMANDS[@]}" || exit 1

wifi_driver_for_iface() {
  local iface="$1"
  local driver_path

  driver_path="$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null || true)"
  if [ -n "$driver_path" ]; then
    basename "$driver_path"
  fi
}

ensure_iwd_powersave_disabled() {
  local conf="$1"
  local driver="$2"
  local log_file="$3"
  local tmp_file

  if [ -z "$driver" ]; then
    printf '%s\n' "Skipped: could not detect Wi-Fi driver for iwd PowerSaveDisable." > "$log_file"
    return 0
  fi

  if [ "$(id -u)" -ne 0 ]; then
    {
      printf '%s\n' "Skipped: root is required to update $conf."
      printf '%s\n' "Run with sudo to persist iwd DriverQuirks PowerSaveDisable=$driver."
    } > "$log_file"
    return 0
  fi

  mkdir -p "$(dirname "$conf")"
  if [ -f "$conf" ]; then
    cp "$conf" "$RUN_DIR/iwd-main.conf.before-powersave"
  fi

  tmp_file="$(mktemp)"
  if [ -f "$conf" ] && grep -q '^\[DriverQuirks\]' "$conf"; then
    awk -v driver="$driver" '
      BEGIN { in_section = 0; wrote = 0 }
      /^\[/ {
        if (in_section && !wrote) {
          print "PowerSaveDisable=" driver
          wrote = 1
        }
        in_section = ($0 == "[DriverQuirks]")
      }
      in_section && /^[[:space:]]*PowerSaveDisable[[:space:]]*=/ {
        if (!wrote) {
          print "PowerSaveDisable=" driver
          wrote = 1
        }
        next
      }
      { print }
      END {
        if (in_section && !wrote) {
          print "PowerSaveDisable=" driver
        }
      }
    ' "$conf" > "$tmp_file"
  elif [ -f "$conf" ]; then
    cp "$conf" "$tmp_file"
    {
      printf '%s\n' ""
      printf '%s\n' "[DriverQuirks]"
      printf 'PowerSaveDisable=%s\n' "$driver"
    } >> "$tmp_file"
  else
    {
      printf '%s\n' "[DriverQuirks]"
      printf 'PowerSaveDisable=%s\n' "$driver"
    } > "$tmp_file"
  fi

  install -m 0644 "$tmp_file" "$conf"
  rm -f "$tmp_file"
  printf 'Set [DriverQuirks] PowerSaveDisable=%s in %s\n' "$driver" "$conf" > "$log_file"
}

WIFI_DRIVER="${WIFI_DRIVER:-$(wifi_driver_for_iface "$IFACE")}"

mkdir -p "$RUN_DIR"

cat <<EOF
This will apply network optimizations to:
  connection: $CONNECTION_NAME
  interface:  $IFACE
  DNS:        $PRIMARY_DNS $SECONDARY_DNS
  search:     ${DNS_SEARCH:-<unchanged>}
  BSSID pin:  ${PREFERRED_BSSID:-<unchanged>}
  driver:     ${WIFI_DRIVER:-<unknown>}

It will also disable Wi-Fi power saving for this profile, flush DNS cache,
force runtime Wi-Fi power saving off, persist the iwd powersave driver quirk
when run as root, and stop Avahi/mDNS for this session.

Type APPLY to continue:
EOF

read -r confirmation
if [ "$confirmation" != "APPLY" ]; then
  printf '%s\n' "Aborted. No changes applied." | tee "$RUN_DIR/apply-approved-optimizations.log"
  exit 1
fi

{
  printf '%s\n' "Started: $(date)"
  printf '%s\n' "Connection: $CONNECTION_NAME"
  printf '%s\n' "Interface: $IFACE"
  printf '%s\n' "DNS: $PRIMARY_DNS $SECONDARY_DNS"
  printf '%s\n' "DNS search: ${DNS_SEARCH:-<unchanged>}"
  printf '%s\n' "BSSID pin: ${PREFERRED_BSSID:-<unchanged>}"
  printf '%s\n' "Wi-Fi driver: ${WIFI_DRIVER:-<unknown>}"
  printf '%s\n' ""
  printf '%s\n' "Commands:"
  printf '%s\n' "nmcli connection modify \"$CONNECTION_NAME\" ipv4.dns \"$PRIMARY_DNS $SECONDARY_DNS\" ipv4.ignore-auto-dns yes 802-11-wireless.powersave disable"
  if [ -n "$DNS_SEARCH" ]; then
    printf '%s\n' "nmcli connection modify \"$CONNECTION_NAME\" ipv4.dns-search \"$DNS_SEARCH\""
  fi
  if [ -n "$PREFERRED_BSSID" ]; then
    printf '%s\n' "nmcli connection modify \"$CONNECTION_NAME\" 802-11-wireless.bssid \"$PREFERRED_BSSID\""
  fi
  printf '%s\n' "nmcli connection up \"$CONNECTION_NAME\""
  printf '%s\n' "iw dev \"$IFACE\" set power_save off"
  printf '%s\n' "iw dev \"$IFACE\" get power_save"
  printf '%s\n' "ensure $IWD_MAIN_CONF has [DriverQuirks] PowerSaveDisable=${WIFI_DRIVER:-<detected-driver>} when run as root"
  printf '%s\n' "resolvectl flush-caches"
  printf '%s\n' "systemctl stop avahi-daemon.service avahi-daemon.socket"
  printf '%s\n' ""
} > "$RUN_DIR/apply-approved-optimizations.log"

nmcli_args=(
  connection modify "$CONNECTION_NAME"
  ipv4.dns "$PRIMARY_DNS $SECONDARY_DNS"
  ipv4.ignore-auto-dns yes
  802-11-wireless.powersave disable
)
if [ -n "$DNS_SEARCH" ]; then
  nmcli_args+=(ipv4.dns-search "$DNS_SEARCH")
fi
if [ -n "$PREFERRED_BSSID" ]; then
  nmcli_args+=(802-11-wireless.bssid "$PREFERRED_BSSID")
fi

nmcli "${nmcli_args[@]}" > "$RUN_DIR/optimize-nmcli-modify.txt" 2>&1
nmcli_modify_status=$?

nmcli connection up "$CONNECTION_NAME" > "$RUN_DIR/optimize-nmcli-connection-up.txt" 2>&1
nmcli_up_status=$?

if command -v iw >/dev/null 2>&1; then
  iw dev "$IFACE" set power_save off > "$RUN_DIR/optimize-iw-power-save-off.txt" 2>&1
  iw_power_save_off_status=$?
  iw dev "$IFACE" get power_save > "$RUN_DIR/optimize-iw-power-save-state.txt" 2>&1
  iw_power_save_state_status=$?
else
  printf '%s\n' "Missing required command: iw" > "$RUN_DIR/optimize-iw-power-save-off.txt"
  printf '%s\n' "Missing required command: iw" > "$RUN_DIR/optimize-iw-power-save-state.txt"
  iw_power_save_off_status=127
  iw_power_save_state_status=127
fi

ensure_iwd_powersave_disabled "$IWD_MAIN_CONF" "$WIFI_DRIVER" "$RUN_DIR/optimize-iwd-powersave-disable.txt"
iwd_powersave_status=$?

resolvectl flush-caches > "$RUN_DIR/optimize-resolvectl-flush-caches.txt" 2>&1
resolvectl_status=$?

systemctl stop avahi-daemon.service avahi-daemon.socket > "$RUN_DIR/optimize-avahi-stop.txt" 2>&1
avahi_status=$?

{
  printf '%s\n' "Exit statuses:"
  printf '%s\n' "  nmcli modify: $nmcli_modify_status"
  printf '%s\n' "  nmcli connection up: $nmcli_up_status"
  printf '%s\n' "  iw power_save off: $iw_power_save_off_status"
  printf '%s\n' "  iw power_save state: $iw_power_save_state_status"
  printf '%s\n' "  iwd powersave disable: $iwd_powersave_status"
  printf '%s\n' "  resolvectl flush-caches: $resolvectl_status"
  printf '%s\n' "  avahi stop: $avahi_status"
  printf '%s\n' "Finished: $(date)"
  printf '%s\n' ""
  printf '%s\n' "Rollback:"
  printf '%s\n' "nmcli connection modify \"$CONNECTION_NAME\" ipv4.dns \"\" ipv4.ignore-auto-dns no ipv4.dns-search \"\" 802-11-wireless.powersave disable 802-11-wireless.bssid \"\""
  printf '%s\n' "nmcli connection up \"$CONNECTION_NAME\""
  printf '%s\n' "iw dev \"$IFACE\" set power_save off"
  printf '%s\n' "resolvectl flush-caches"
  printf '%s\n' "systemctl restart avahi-daemon.socket avahi-daemon.service"
} >> "$RUN_DIR/apply-approved-optimizations.log"

if [ "$nmcli_modify_status" -ne 0 ] ||
  [ "$nmcli_up_status" -ne 0 ] ||
  [ "$iw_power_save_off_status" -ne 0 ] ||
  [ "$iw_power_save_state_status" -ne 0 ] ||
  [ "$iwd_powersave_status" -ne 0 ] ||
  [ "$resolvectl_status" -ne 0 ] ||
  [ "$avahi_status" -ne 0 ]; then
  printf '%s\n' "One or more optimization commands failed. Check logs in $RUN_DIR."
  exit 1
fi

printf '%s\n' "Optimizations applied. Logs written to $RUN_DIR."
