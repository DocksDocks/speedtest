#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/path.sh
. "$SCRIPT_DIR/lib/path.sh"

PHASE="${1:-after}"
RUN_DIR="${2:-$(speedtest_default_run_dir)}"
IFACE="${IFACE:-$(speedtest_default_wifi_iface)}"
CONNECTION_NAME="${CONNECTION_NAME:-$(speedtest_default_connection_name)}"
DNS_SERVERS="${DNS_SERVERS:-208.67.222.222 208.67.220.220 1.1.1.1 8.8.8.8 9.9.9.9}"
DNS_DOMAINS="${DNS_DOMAINS:-www.google.com www.cloudflare.com www.github.com www.wikipedia.org www.amazon.com}"

mkdir -p "$RUN_DIR"

run_logged() {
  local label="$1"
  local output_file="$2"
  shift 2

  {
    printf '%s\n' "[$(date)] START $label"
    printf '%s\n' "Command: $*"
  } >> "$RUN_DIR/${PHASE}-collection.log"

  "$@" > "$output_file" 2>&1
  local status=$?

  {
    printf '%s\n' "[$(date)] END $label status=$status"
    printf '%s\n' ""
  } >> "$RUN_DIR/${PHASE}-collection.log"

  return "$status"
}

gateway="$(ip route 2>/dev/null | awk '/^default / {print $3; exit}')"
if [ -z "$gateway" ]; then
  gateway="1.1.1.1"
fi

{
  printf '%s\n' "Phase: $PHASE"
  printf '%s\n' "Run dir: $RUN_DIR"
  printf '%s\n' "Interface: $IFACE"
  printf '%s\n' "Connection: $CONNECTION_NAME"
  printf '%s\n' "Gateway: $gateway"
  printf '%s\n' "Started: $(date)"
  printf '%s\n' ""
} > "$RUN_DIR/${PHASE}-collection.log"

run_logged "speedtest-cli" "$RUN_DIR/${PHASE}-speedtest-cli.txt" timeout 180 speedtest-cli --secure --simple

run_logged "ping gateway" "$RUN_DIR/${PHASE}-ping-gateway.txt" ping -c 30 -i 0.2 "$gateway"
run_logged "ping 1.1.1.1" "$RUN_DIR/${PHASE}-ping-1.1.1.1.txt" ping -c 30 -i 0.2 1.1.1.1
run_logged "ping 8.8.8.8" "$RUN_DIR/${PHASE}-ping-8.8.8.8.txt" ping -c 30 -i 0.2 8.8.8.8
run_logged "ping google.com" "$RUN_DIR/${PHASE}-ping-google.com.txt" ping -c 20 -i 0.2 google.com
run_logged "tracepath 1.1.1.1" "$RUN_DIR/${PHASE}-tracepath-1.1.1.1.txt" tracepath -n 1.1.1.1
run_logged "MTU DF ping 1472 1.1.1.1" "$RUN_DIR/${PHASE}-mtu-ping-1472-1.1.1.1.txt" ping -M do -s 1472 -c 5 1.1.1.1
run_logged "mtr 1.1.1.1" "$RUN_DIR/${PHASE}-mtr-1.1.1.1.txt" mtr -rwzc 30 1.1.1.1

{
  for server in $DNS_SERVERS; do
    printf '%s\n' "===== DNS $server ====="
    for domain in $DNS_DOMAINS; do
      printf '%s\n' "--- $domain ---"
      dig @"$server" "$domain" A +tries=1 +time=2 +noall +answer +stats
    done
  done
} > "$RUN_DIR/${PHASE}-dns-benchmark.txt" 2>&1

{
  printf '%s\n' "[$(date)] START state capture"
  nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device
  printf '%s\n' ""
  nmcli connection show --active
  printf '%s\n' ""
  nmcli -f ACTIVE,SSID,BSSID,CHAN,FREQ,RATE,SIGNAL,BARS,SECURITY device wifi list --rescan no
  printf '%s\n' ""
  if [ -n "$IFACE" ]; then
    nmcli -f GENERAL.DEVICE,GENERAL.TYPE,GENERAL.MTU,GENERAL.CONNECTION,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,IP4.DOMAIN device show "$IFACE"
  else
    printf '%s\n' "No active Wi-Fi interface detected."
  fi
  printf '%s\n' ""
  resolvectl status
  printf '%s\n' ""
  cat /proc/net/wireless
  printf '%s\n' ""
  systemctl is-active avahi-daemon
  printf '%s\n' "[$(date)] END state capture"
} > "$RUN_DIR/${PHASE}-state-capture.txt" 2>&1

printf '%s\n' "Finished: $(date)" >> "$RUN_DIR/${PHASE}-collection.log"
printf '%s\n' "Network test collection complete for phase '$PHASE'. Logs written to $RUN_DIR."
