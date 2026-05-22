#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sqlite.sh
. "$SCRIPT_DIR/lib/sqlite.sh"

PHASE="${1:-wifi-current}"
RUN_DIR="${2:-$(speedtest_default_run_dir)}"
DB_PATH="${3:-$(speedtest_default_db)}"
IFACE="${IFACE:-$(speedtest_default_wifi_iface)}"
CONNECTION_NAME="${CONNECTION_NAME:-$(speedtest_default_connection_name)}"
IPERF3_SERVER="${IPERF3_SERVER:-}"
IPERF3_PORT="${IPERF3_PORT:-5201}"
IPERF3_BIN="${IPERF3_BIN:-}"
IPERF3_LD_LIBRARY_PATH="${IPERF3_LD_LIBRARY_PATH:-}"
FLENT_SERVER="${FLENT_SERVER:-}"
FLENT_BIN="${FLENT_BIN:-}"
FLENT_PYTHONPATH="${FLENT_PYTHONPATH:-}"
NETPERF_BIN="${NETPERF_BIN:-}"
WAVEMON_BIN="${WAVEMON_BIN:-}"
IW_BIN="${IW_BIN:-}"

if [ -z "$FLENT_BIN" ] && command -v flent >/dev/null 2>&1; then
  FLENT_BIN="$(command -v flent)"
fi

if [ -z "$NETPERF_BIN" ] && command -v netperf >/dev/null 2>&1; then
  NETPERF_BIN="$(command -v netperf)"
fi

if [ -z "$WAVEMON_BIN" ] && command -v wavemon >/dev/null 2>&1; then
  WAVEMON_BIN="$(command -v wavemon)"
fi

if [ -z "$IW_BIN" ] && command -v iw >/dev/null 2>&1; then
  IW_BIN="$(command -v iw)"
fi

if [ -z "$IPERF3_BIN" ] && command -v iperf3 >/dev/null 2>&1; then
  IPERF3_BIN="$(command -v iperf3)"
fi

if [ -z "$IFACE" ]; then
  printf '%s\n' "No active Wi-Fi interface detected. Set IFACE=<interface>." >&2
  exit 1
fi

mkdir -p "$RUN_DIR"
speedtest_init_schema "$DB_PATH"

RUN_ID="$(basename "$RUN_DIR")"

sqlite_exec "$DB_PATH" "
INSERT OR IGNORE INTO runs (run_id, started_at, run_dir, connection_name, interface_name, notes)
VALUES (
  '$(sql_quote "$RUN_ID")',
  '$(date -Is 2>/dev/null || date)',
  '$(sql_quote "$RUN_DIR")',
  '$(sql_quote "$CONNECTION_NAME")',
  '$(sql_quote "$IFACE")',
  'Wi-Fi diagnostic tool pass'
);
"

record_test() {
  local tool_key="$1"
  local category="$2"
  local status="$3"
  local result="$4"
  local source_file="$5"

  sqlite_exec "$DB_PATH" "
  INSERT INTO wifi_tool_tests (
    run_id,
    phase,
    tool_key,
    category,
    status,
    result,
    source_file
  ) VALUES (
    '$(sql_quote "$RUN_ID")',
    '$(sql_quote "$PHASE")',
    '$(sql_quote "$tool_key")',
    '$(sql_quote "$category")',
    '$(sql_quote "$status")',
    '$(sql_quote "$result")',
    '$(sql_quote "$source_file")'
  )
  ON CONFLICT(run_id, phase, tool_key, category, source_file) DO UPDATE SET
    status = excluded.status,
    result = excluded.result,
    captured_at = CURRENT_TIMESTAMP;
  "
}

run_logged() {
  local label="$1"
  local output_file="$2"
  shift 2

  {
    printf '%s\n' "[$(date)] START $label"
    printf '%s\n' "Command: $*"
  } >> "$RUN_DIR/${PHASE}-wifi-tool-tests.log"

  "$@" > "$output_file" 2>&1
  local status=$?

  {
    printf '%s\n' "[$(date)] END $label status=$status"
    printf '%s\n' ""
  } >> "$RUN_DIR/${PHASE}-wifi-tool-tests.log"

  return "$status"
}

tool_path() {
  if [ "$1" = "iw" ] && [ -n "$IW_BIN" ] && [ -x "$IW_BIN" ]; then
    printf '%s\n' "$IW_BIN"
    return
  fi

  if [ "$1" = "wavemon" ] && [ -n "$WAVEMON_BIN" ] && [ -x "$WAVEMON_BIN" ]; then
    printf '%s\n' "$WAVEMON_BIN"
    return
  fi

  if [ "$1" = "iperf3" ] && [ -n "$IPERF3_BIN" ] && [ -x "$IPERF3_BIN" ]; then
    printf '%s\n' "$IPERF3_BIN"
    return
  fi

  if [ "$1" = "flent" ] && [ -n "$FLENT_BIN" ] && [ -x "$FLENT_BIN" ]; then
    printf '%s\n' "$FLENT_BIN"
    return
  fi

  if [ "$1" = "netperf" ] && [ -n "$NETPERF_BIN" ] && [ -x "$NETPERF_BIN" ]; then
    printf '%s\n' "$NETPERF_BIN"
    return
  fi

  if command -v "$1" >/dev/null 2>&1; then
    command -v "$1"
  else
    printf '%s\n' "missing"
  fi
}

tool_available() {
  if [ "$1" = "iw" ] && [ -n "$IW_BIN" ] && [ -x "$IW_BIN" ]; then
    return 0
  fi

  if [ "$1" = "wavemon" ] && [ -n "$WAVEMON_BIN" ] && [ -x "$WAVEMON_BIN" ]; then
    return 0
  fi

  if [ "$1" = "iperf3" ] && [ -n "$IPERF3_BIN" ] && [ -x "$IPERF3_BIN" ]; then
    return 0
  fi

  if [ "$1" = "flent" ] && [ -n "$FLENT_BIN" ] && [ -x "$FLENT_BIN" ]; then
    return 0
  fi

  if [ "$1" = "netperf" ] && [ -n "$NETPERF_BIN" ] && [ -x "$NETPERF_BIN" ]; then
    return 0
  fi

  command -v "$1" >/dev/null 2>&1
}

summarize_file_lines() {
  local file="$1"
  local pattern="$2"
  local summary
  summary="$(grep -E "$pattern" "$file" 2>/dev/null | head -n 6 | tr '\n' '; ' | sed 's/[[:space:]][[:space:]]*/ /g;s/; $//')"
  if [ -n "$summary" ]; then
    printf '%s\n' "$summary"
  else
    printf '%s\n' "see $file"
  fi
}

status_word() {
  if [ "$1" -eq 0 ]; then
    printf '%s\n' "ok"
  else
    printf '%s\n' "failed"
  fi
}

availability_file="$RUN_DIR/${PHASE}-wifi-tools-availability.txt"
{
  printf '%s\n' "Phase: $PHASE"
  printf '%s\n' "Interface: $IFACE"
  printf '%s\n' "Connection: $CONNECTION_NAME"
  printf '%s\n' "Started: $(date)"
  printf '%s\n' ""
  for tool in wavemon iw iperf3 flent netperf netserver iwctl iwd; do
    printf '%s\t%s\n' "$tool" "$(tool_path "$tool")"
  done
} > "$availability_file"

for tool in wavemon iw iperf3 flent netperf netserver iwctl iwd; do
  if tool_available "$tool"; then
    record_test "$tool" "availability" "available" "$(tool_path "$tool")" "$(basename "$availability_file")"
  else
    record_test "$tool" "availability" "missing" "not installed" "$(basename "$availability_file")"
  fi
done

nmcli_file="$RUN_DIR/${PHASE}-wifi-nmcli-state.txt"
run_logged "NetworkManager Wi-Fi state" "$nmcli_file" nmcli -f GENERAL.DEVICE,GENERAL.TYPE,GENERAL.MTU,GENERAL.CONNECTION,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,IP4.DOMAIN device show "$IFACE"
nmcli_status=$?
record_test "networkmanager" "state" "$(status_word "$nmcli_status")" "$(summarize_file_lines "$nmcli_file" 'GENERAL.CONNECTION|GENERAL.MTU|IP4.DNS|IP4.GATEWAY')" "$(basename "$nmcli_file")"

wifi_list_file="$RUN_DIR/${PHASE}-wifi-nmcli-list.txt"
run_logged "NetworkManager Wi-Fi list" "$wifi_list_file" nmcli -f ACTIVE,SSID,BSSID,CHAN,FREQ,RATE,SIGNAL,BARS,SECURITY device wifi list --rescan no
wifi_list_status=$?
record_test "networkmanager" "wifi_scan" "$(status_word "$wifi_list_status")" "$(summarize_file_lines "$wifi_list_file" '^ACTIVE|^yes|^\*|BSSID')" "$(basename "$wifi_list_file")"

wireless_file="$RUN_DIR/${PHASE}-wifi-proc-net-wireless.txt"
run_logged "kernel wireless counters" "$wireless_file" cat /proc/net/wireless
wireless_status=$?
record_test "iw" "kernel_counters" "$(status_word "$wireless_status")" "$(summarize_file_lines "$wireless_file" "$IFACE|Inter-|face")" "$(basename "$wireless_file")"

if tool_available iw; then
  iw_dev_file="$RUN_DIR/${PHASE}-wifi-iw-dev.txt"
  run_logged "iw dev" "$iw_dev_file" "$IW_BIN" dev
  iw_dev_status=$?
  record_test "iw" "device" "$(status_word "$iw_dev_status")" "$(summarize_file_lines "$iw_dev_file" 'Interface|ssid|channel|addr')" "$(basename "$iw_dev_file")"

  iw_link_file="$RUN_DIR/${PHASE}-wifi-iw-link.txt"
  run_logged "iw link" "$iw_link_file" "$IW_BIN" dev "$IFACE" link
  iw_link_status=$?
  record_test "iw" "link" "$(status_word "$iw_link_status")" "$(summarize_file_lines "$iw_link_file" 'Connected to|SSID:|freq:|signal:|bitrate:')" "$(basename "$iw_link_file")"

  iw_station_file="$RUN_DIR/${PHASE}-wifi-iw-station.txt"
  run_logged "iw station dump" "$iw_station_file" "$IW_BIN" dev "$IFACE" station dump
  iw_station_status=$?
  record_test "iw" "station" "$(status_word "$iw_station_status")" "$(summarize_file_lines "$iw_station_file" 'Station|signal:|tx bitrate:|rx bitrate:|tx retries:|tx failed:')" "$(basename "$iw_station_file")"

  iw_survey_file="$RUN_DIR/${PHASE}-wifi-iw-survey.txt"
  run_logged "iw survey dump" "$iw_survey_file" "$IW_BIN" dev "$IFACE" survey dump
  iw_survey_status=$?
  record_test "iw" "survey" "$(status_word "$iw_survey_status")" "$(summarize_file_lines "$iw_survey_file" 'in use|channel|time:|busy time:|receive time:|transmit time:')" "$(basename "$iw_survey_file")"

  record_test "iw" "summary" "measured" "$(summarize_file_lines "$iw_link_file" 'Connected to|SSID:|freq:|signal:|bitrate:')" "$(basename "$iw_link_file")"
else
  record_test "iw" "summary" "missing" "install iw for scriptable Wi-Fi link, station, and survey telemetry" "$(basename "$availability_file")"
fi

if tool_available wavemon; then
  wavemon_help_file="$RUN_DIR/${PHASE}-wifi-wavemon-help.txt"
  run_logged "wavemon help" "$wavemon_help_file" "$WAVEMON_BIN" -h

  wavemon_version_file="$RUN_DIR/${PHASE}-wifi-wavemon-version.txt"
  run_logged "wavemon version" "$wavemon_version_file" "$WAVEMON_BIN" -v

  if grep -q -- "-d" "$wavemon_help_file"; then
    wavemon_dump_file="$RUN_DIR/${PHASE}-wifi-wavemon-dump.txt"
    run_logged "wavemon dump" "$wavemon_dump_file" timeout 12 "$WAVEMON_BIN" -i "$IFACE" -d
    wavemon_status=$?
    if [ "$wavemon_status" -eq 0 ]; then
      record_test "wavemon" "summary" "measured" "$(summarize_file_lines "$wavemon_dump_file" 'signal|noise|link|rx|tx|bitrate|quality')" "$(basename "$wavemon_dump_file")"
    else
      record_test "wavemon" "summary" "available" "available; non-interactive dump failed, use wavemon live while moving the laptop" "$(basename "$wavemon_dump_file")"
    fi
  else
    record_test "wavemon" "summary" "available" "available; this wavemon version is interactive-only, use it live while moving the laptop" "$(basename "$wavemon_version_file")"
  fi
else
  record_test "wavemon" "summary" "missing" "install wavemon for live Wi-Fi monitoring" "$(basename "$availability_file")"
fi

if tool_available iperf3; then
  iperf3_version_file="$RUN_DIR/${PHASE}-wifi-iperf3-version.txt"
  run_logged "iperf3 version" "$iperf3_version_file" env LD_LIBRARY_PATH="$IPERF3_LD_LIBRARY_PATH" "$IPERF3_BIN" --version

  if [ -n "$IPERF3_SERVER" ]; then
    iperf3_file="$RUN_DIR/${PHASE}-wifi-iperf3-client.txt"
    run_logged "iperf3 client" "$iperf3_file" env LD_LIBRARY_PATH="$IPERF3_LD_LIBRARY_PATH" timeout 45 "$IPERF3_BIN" -c "$IPERF3_SERVER" -p "$IPERF3_PORT" -t 20
    iperf3_status=$?
    if [ "$iperf3_status" -eq 0 ]; then
      record_test "iperf3" "summary" "measured" "$(summarize_file_lines "$iperf3_file" 'sender|receiver|bits/sec')" "$(basename "$iperf3_file")"
    else
      record_test "iperf3" "summary" "failed" "server test failed; see $(basename "$iperf3_file")" "$(basename "$iperf3_file")"
    fi
  else
    record_test "iperf3" "summary" "skipped" "installed; set IPERF3_SERVER to a LAN or controlled server for a meaningful Wi-Fi throughput test" "$(basename "$iperf3_version_file")"
  fi
else
  record_test "iperf3" "summary" "missing" "install iperf3 and provide IPERF3_SERVER for controlled throughput testing" "$(basename "$availability_file")"
fi

if tool_available flent && tool_available netperf; then
  flent_version_file="$RUN_DIR/${PHASE}-wifi-flent-version.txt"
  run_logged "flent version" "$flent_version_file" env PYTHONPATH="$FLENT_PYTHONPATH" "$FLENT_BIN" --version
  netperf_version_file="$RUN_DIR/${PHASE}-wifi-netperf-version.txt"
  run_logged "netperf version" "$netperf_version_file" "$NETPERF_BIN" -V

  if [ -n "$FLENT_SERVER" ]; then
    flent_file="$RUN_DIR/${PHASE}-wifi-flent-rrul.txt"
    run_logged "flent rrul" "$flent_file" env PYTHONPATH="$FLENT_PYTHONPATH" NETPERF="$NETPERF_BIN" timeout 120 "$FLENT_BIN" rrul -l 60 -H "$FLENT_SERVER" -o "$RUN_DIR/${PHASE}-wifi-flent-rrul.flent.gz"
    flent_status=$?
    if [ "$flent_status" -eq 0 ]; then
      record_test "flent_netperf" "summary" "measured" "rrul test complete; see $(basename "$flent_file")" "$(basename "$flent_file")"
    else
      record_test "flent_netperf" "summary" "failed" "flent rrul failed; see $(basename "$flent_file")" "$(basename "$flent_file")"
    fi
  else
    record_test "flent_netperf" "summary" "skipped" "installed; set FLENT_SERVER to a controlled netperf server for bufferbloat testing" "$(basename "$flent_version_file")"
  fi
else
  record_test "flent_netperf" "summary" "missing" "install flent and netperf; needs a controlled netperf server" "$(basename "$availability_file")"
fi

if command -v iwctl >/dev/null 2>&1 || command -v iwd >/dev/null 2>&1; then
  iwd_file="$RUN_DIR/${PHASE}-wifi-iwd-state.txt"
  {
    printf '%s\n' "iwctl: $(tool_path iwctl)"
    printf '%s\n' "iwd: $(tool_path iwd)"
    printf '%s\n' ""
    printf '%s\n' "Configured NetworkManager Wi-Fi backend references:"
    grep -R "wifi.backend" /etc/NetworkManager/conf.d /usr/lib/NetworkManager/conf.d 2>/dev/null || true
    printf '%s\n' ""
    systemctl is-enabled iwd 2>/dev/null || true
    systemctl is-active iwd 2>/dev/null || true
  } > "$iwd_file" 2>&1

  if grep -qs "wifi.backend=iwd" "$iwd_file"; then
    record_test "iwd" "summary" "active" "iwd appears configured as NetworkManager Wi-Fi backend" "$(basename "$iwd_file")"
  else
    record_test "iwd" "summary" "installed" "installed; NetworkManager backend switch not applied during this non-destructive Wi-Fi pass" "$(basename "$iwd_file")"
  fi
else
  record_test "iwd" "summary" "missing" "install iwd to evaluate it as a future NetworkManager Wi-Fi backend" "$(basename "$availability_file")"
fi

printf '%s\n' "Finished: $(date)" >> "$RUN_DIR/${PHASE}-wifi-tool-tests.log"
printf '%s\n' "Wi-Fi tool test collection complete for phase '$PHASE'. Logs written to $RUN_DIR."
