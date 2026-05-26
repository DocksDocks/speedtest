#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
ORIGINAL_ARGS=("$@")
# shellcheck source=lib/path.sh
. "$SCRIPT_DIR/lib/path.sh"
# shellcheck source=lib/warnings.sh
. "$SCRIPT_DIR/lib/warnings.sh"
# shellcheck source=lib/networkmanager.sh
. "$SCRIPT_DIR/lib/networkmanager.sh"

RUN_DIR="${RUN_DIR:-$(speedtest_default_run_dir)}"
CONNECTION_NAME="${CONNECTION_NAME:-$(speedtest_default_connection_name)}"
IFACE="${IFACE:-$(speedtest_default_wifi_iface)}"
PRIMARY_DNS="${PRIMARY_DNS:-9.9.9.9}"
SECONDARY_DNS="${SECONDARY_DNS:-1.1.1.1}"
DNS_SEARCH="${DNS_SEARCH:-}"
PREFERRED_BSSID="${PREFERRED_BSSID:-}"
IWD_MAIN_CONF="${IWD_MAIN_CONF:-/etc/iwd/main.conf}"
WIFI_DRIVER="${WIFI_DRIVER:-}"
CONNECTION_UUID="${CONNECTION_UUID:-}"
REQUIRED_COMMANDS=(nmcli iw resolvectl systemctl)

if [ -z "$CONNECTION_NAME" ] || [ -z "$IFACE" ]; then
  printf '%s\n' "No active Wi-Fi connection detected. Set CONNECTION_NAME and IFACE explicitly." >&2
  exit 1
fi

rerun_with_sudo() {
  ui_warn "This script changes NetworkManager, DNS, iwd, and service state. Asking sudo now."
  exec sudo --preserve-env=RUN_DIR,CONNECTION_NAME,CONNECTION_UUID,IFACE,PRIMARY_DNS,SECONDARY_DNS,DNS_SEARCH,PREFERRED_BSSID,IWD_MAIN_CONF,WIFI_DRIVER,SPEEDTEST_ROOT_DIR "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
}

if [ "$(id -u)" -ne 0 ]; then
  speedtest_require_commands sudo "${REQUIRED_COMMANDS[@]}" || exit 1
  rerun_with_sudo
fi

speedtest_require_commands "${REQUIRED_COMMANDS[@]}" || exit 1

CONNECTION_UUID="${CONNECTION_UUID:-$(nm_connection_uuid_for_name "$CONNECTION_NAME")}"

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

stop_avahi_session() {
  local log_file="$1"
  local units=()
  local unit
  local mask_status=0
  local service_status=0
  local socket_status=0
  local service_retry_status=0
  local socket_retry_status=0
  local socket_state
  local service_state

  for unit in avahi-daemon.service avahi-daemon.socket; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      units+=("$unit")
    fi
  done

  if [ "${#units[@]}" -eq 0 ]; then
    printf '%s\n' "Avahi units are not installed; nothing to stop." > "$log_file"
    return 0
  fi

  {
    printf '%s\n' "Runtime-masking Avahi service/socket to prevent activation until reboot or rollback."
    systemctl mask --runtime "${units[@]}"
    mask_status=$?
    printf '%s\n' "runtime mask status: $mask_status"
    printf '%s\n' ""

    printf '%s\n' "Stopping avahi-daemon.service."
    systemctl stop avahi-daemon.service
    service_status=$?
    printf '%s\n' "service stop status: $service_status"
    printf '%s\n' ""

    printf '%s\n' "Stopping avahi-daemon.socket."
    systemctl stop avahi-daemon.socket
    socket_status=$?
    printf '%s\n' "socket stop status: $socket_status"
    printf '%s\n' ""

    socket_state="$(systemctl is-active avahi-daemon.socket 2>/dev/null || true)"
    service_state="$(systemctl is-active avahi-daemon.service 2>/dev/null || true)"

    if [ "$service_state" = "active" ] || [ "$service_state" = "activating" ] ||
      [ "$socket_state" = "active" ] || [ "$socket_state" = "activating" ]; then
      printf '%s\n' "Retrying Avahi stop after initial final-state check."
      systemctl stop avahi-daemon.service
      service_retry_status=$?
      printf '%s\n' "service retry stop status: $service_retry_status"
      systemctl stop avahi-daemon.socket
      socket_retry_status=$?
      printf '%s\n' "socket retry stop status: $socket_retry_status"
      printf '%s\n' ""
      socket_state="$(systemctl is-active avahi-daemon.socket 2>/dev/null || true)"
      service_state="$(systemctl is-active avahi-daemon.service 2>/dev/null || true)"
    fi

    printf '%s\n' "socket final state: ${socket_state:-unknown}"
    printf '%s\n' "service final state: ${service_state:-unknown}"
  } > "$log_file" 2>&1

  case "${socket_state:-unknown}" in
    active|activating|reloading) return 1 ;;
    *) ;;
  esac
  case "${service_state:-unknown}" in
    active|activating|reloading) return 1 ;;
    *) ;;
  esac

  return 0
}

WIFI_DRIVER="${WIFI_DRIVER:-$(wifi_driver_for_iface "$IFACE")}"

mkdir -p "$RUN_DIR"

trim_words() {
  awk '{$1=$1; print}'
}

display_or_empty() {
  local value="${1:-}"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "<empty>"
  fi
}

display_or_unknown() {
  local value="${1:-}"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "<unknown>"
  fi
}

normalize_list_value() {
  printf '%s' "${1:-}" | tr ',' ' ' | trim_words
}

profile_setting() {
  nm_connection_field_value "$CONNECTION_UUID" "$CONNECTION_NAME" "$1" | nm_unescape_colons
}

runtime_powersave_state() {
  local state

  state="$(iw dev "$IFACE" get power_save 2>/dev/null | awk -F': ' '/Power save:/ {print $2; exit}')"
  display_or_unknown "$state"
}

iwd_powersave_disable_value() {
  if [ ! -f "$IWD_MAIN_CONF" ]; then
    printf '%s\n' "<unset>"
    return
  fi

  awk '
    /^\[DriverQuirks\]$/ {
      in_section = 1
      next
    }
    /^\[/ {
      in_section = 0
    }
    in_section && /^[[:space:]]*PowerSaveDisable[[:space:]]*=/ {
      sub(/^[^=]*=/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print
      found = 1
      exit
    }
    END {
      if (!found) {
        print "<unset>"
      }
    }
  ' "$IWD_MAIN_CONF" 2>/dev/null
}

profile_powersave_value() {
  local value

  value="$(profile_setting 802-11-wireless.powersave)"
  case "$value" in
    "")
      printf '%s\n' "<empty>"
      ;;
    *disable*|2)
      printf '%s\n' "disable"
      ;;
    *enable*|3)
      printf '%s\n' "enable"
      ;;
    *default*|0)
      printf '%s\n' "default"
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

service_state() {
  local service_name="$1"
  local state

  state="$(systemctl is-active "$service_name" 2>/dev/null || true)"
  display_or_unknown "$state"
}

print_change_row() {
  local label="$1"
  local before="$2"
  local after="$3"
  local arrow="=="
  local arrow_color="$COLOR_RESET"
  local after_color="$COLOR_RESET"

  if [ "$before" != "$after" ]; then
    arrow="->"
    arrow_color="$COLOR_YELLOW"
    after_color="$COLOR_YELLOW"
  fi

  printf '  %-24s %-32s %s%s%s %s%s%s\n' \
    "$label" \
    "$before" \
    "$arrow_color" "$arrow" "$COLOR_RESET" \
    "$after_color" "$after" "$COLOR_RESET"
}

show_change_preview() {
  local current_dns
  local target_dns
  local current_dns_search
  local target_dns_search
  local current_bssid
  local target_bssid
  local current_powersave
  local target_iwd_powersave

  current_dns="$(display_or_empty "$(normalize_list_value "$(profile_setting ipv4.dns)")")"
  target_dns="$(normalize_list_value "$PRIMARY_DNS $SECONDARY_DNS")"
  current_dns_search="$(display_or_empty "$(normalize_list_value "$(profile_setting ipv4.dns-search)")")"
  target_dns_search="$current_dns_search"
  if [ -n "$DNS_SEARCH" ]; then
    target_dns_search="$(normalize_list_value "$DNS_SEARCH")"
  fi

  current_bssid="$(display_or_empty "$(profile_setting 802-11-wireless.bssid)")"
  target_bssid="$current_bssid"
  if [ -n "$PREFERRED_BSSID" ]; then
    target_bssid="$PREFERRED_BSSID"
  fi

  current_powersave="$(profile_powersave_value)"
  target_iwd_powersave="$(display_or_unknown "$WIFI_DRIVER")"

  printf '%s\n' "This will apply network optimizations:"
  printf '  %s%-24s%s %s%-32s%s    %s%-32s%s\n' "$COLOR_BOLD" "Setting" "$COLOR_RESET" "$COLOR_CYAN" "Before" "$COLOR_RESET" "$COLOR_GREEN" "After" "$COLOR_RESET"
  printf '  %-24s %s%-32s%s %s%s%s %s%-32s%s\n' "" "$COLOR_CYAN" "current" "$COLOR_RESET" "$COLOR_YELLOW" "->" "$COLOR_RESET" "$COLOR_GREEN" "target" "$COLOR_RESET"
  print_change_row "connection" "$CONNECTION_NAME" "$CONNECTION_NAME"
  print_change_row "interface" "$IFACE" "$IFACE"
  print_change_row "profile DNS" "$current_dns" "$target_dns"
  print_change_row "ignore auto DNS" "$(display_or_empty "$(profile_setting ipv4.ignore-auto-dns)")" "yes"
  print_change_row "DNS search" "$current_dns_search" "$target_dns_search"
  print_change_row "BSSID pin" "$current_bssid" "$target_bssid"
  print_change_row "profile powersave" "$current_powersave" "disable"
  print_change_row "runtime powersave" "$(runtime_powersave_state)" "off"
  print_change_row "iwd PowerSaveDisable" "$(iwd_powersave_disable_value)" "$target_iwd_powersave"
  print_change_row "DNS cache" "current cache" "flushed"
  print_change_row "Avahi/mDNS" "$(service_state avahi-daemon.service)" "inactive (runtime mask)"
  printf '%s\n' ""
  printf '%s\n' "Changed target values are highlighted in yellow. Unchanged rows stay neutral."
  printf '%s\n' ""
  printf '%s\n' "Type APPLY to continue:"
}

show_change_preview

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
  printf '%s\n' "runtime-mask and stop avahi-daemon.service avahi-daemon.socket"
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

stop_avahi_session "$RUN_DIR/optimize-avahi-stop.txt"
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
