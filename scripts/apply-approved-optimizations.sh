#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/path.sh
. "$SCRIPT_DIR/lib/path.sh"

RUN_DIR="${RUN_DIR:-$(speedtest_default_run_dir)}"
CONNECTION_NAME="${CONNECTION_NAME:-$(speedtest_default_connection_name)}"
IFACE="${IFACE:-$(speedtest_default_wifi_iface)}"
PRIMARY_DNS="${PRIMARY_DNS:-9.9.9.9}"
SECONDARY_DNS="${SECONDARY_DNS:-1.1.1.1}"
DNS_SEARCH="${DNS_SEARCH:-}"
PREFERRED_BSSID="${PREFERRED_BSSID:-}"

if [ -z "$CONNECTION_NAME" ] || [ -z "$IFACE" ]; then
  printf '%s\n' "No active Wi-Fi connection detected. Set CONNECTION_NAME and IFACE explicitly." >&2
  exit 1
fi

mkdir -p "$RUN_DIR"

cat <<EOF
This will apply network optimizations to:
  connection: $CONNECTION_NAME
  interface:  $IFACE
  DNS:        $PRIMARY_DNS $SECONDARY_DNS
  search:     ${DNS_SEARCH:-<unchanged>}
  BSSID pin:  ${PREFERRED_BSSID:-<unchanged>}

It will also disable Wi-Fi power saving for this profile, flush DNS cache,
and stop Avahi/mDNS for this session.

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

resolvectl flush-caches > "$RUN_DIR/optimize-resolvectl-flush-caches.txt" 2>&1
resolvectl_status=$?

systemctl stop avahi-daemon.service avahi-daemon.socket > "$RUN_DIR/optimize-avahi-stop.txt" 2>&1
avahi_status=$?

{
  printf '%s\n' "Exit statuses:"
  printf '%s\n' "  nmcli modify: $nmcli_modify_status"
  printf '%s\n' "  nmcli connection up: $nmcli_up_status"
  printf '%s\n' "  resolvectl flush-caches: $resolvectl_status"
  printf '%s\n' "  avahi stop: $avahi_status"
  printf '%s\n' "Finished: $(date)"
  printf '%s\n' ""
  printf '%s\n' "Rollback:"
  printf '%s\n' "nmcli connection modify \"$CONNECTION_NAME\" ipv4.dns \"\" ipv4.ignore-auto-dns no ipv4.dns-search \"\" 802-11-wireless.powersave default 802-11-wireless.bssid \"\""
  printf '%s\n' "nmcli connection up \"$CONNECTION_NAME\""
  printf '%s\n' "resolvectl flush-caches"
  printf '%s\n' "systemctl restart avahi-daemon.socket avahi-daemon.service"
} >> "$RUN_DIR/apply-approved-optimizations.log"

if [ "$nmcli_modify_status" -ne 0 ] ||
  [ "$nmcli_up_status" -ne 0 ] ||
  [ "$resolvectl_status" -ne 0 ] ||
  [ "$avahi_status" -ne 0 ]; then
  printf '%s\n' "One or more optimization commands failed. Check logs in $RUN_DIR."
  exit 1
fi

printf '%s\n' "Optimizations applied. Logs written to $RUN_DIR."
