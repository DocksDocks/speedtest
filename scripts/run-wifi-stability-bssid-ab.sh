#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sqlite.sh
. "$SCRIPT_DIR/lib/sqlite.sh"

RUN_DIR="${1:-$(speedtest_default_run_dir)}"
DB_PATH="${2:-$(speedtest_default_db)}"
PHASE="${PHASE:-wifi-experiments}"
IFACE="${IFACE:-$(speedtest_default_wifi_iface)}"
CONNECTION_NAME="${CONNECTION_NAME:-$(speedtest_default_connection_name)}"
PREFERRED_BSSID="${PREFERRED_BSSID:-}"
STABILITY_SECONDS="${STABILITY_SECONDS:-300}"
AB_SECONDS="${AB_SECONDS:-60}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"
IW_BIN="${IW_BIN:-}"

if [ -z "$IW_BIN" ] && command -v iw >/dev/null 2>&1; then
  IW_BIN="$(command -v iw)"
fi

if [ -z "$IW_BIN" ] || [ ! -x "$IW_BIN" ]; then
  printf '%s\n' "iw is required for this experiment. Install package: iw" >&2
  exit 1
fi

if [ -z "$IFACE" ] || [ -z "$CONNECTION_NAME" ]; then
  printf '%s\n' "No active Wi-Fi connection detected. Set IFACE and CONNECTION_NAME explicitly." >&2
  exit 1
fi

mkdir -p "$RUN_DIR"
speedtest_init_schema "$DB_PATH"

RUN_ID="$(basename "$RUN_DIR")"
LOG_FILE="$RUN_DIR/${PHASE}-wifi-stability-bssid-ab.log"
RESTORE_NEEDED=0
ORIGINAL_BSSID=""

sql_text_or_null() {
  if [ -n "${1:-}" ]; then
    printf "'%s'" "$(sql_quote "$1")"
  else
    printf '%s' "NULL"
  fi
}

sql_num_or_null() {
  if [ -n "${1:-}" ]; then
    printf '%s' "$1"
  else
    printf '%s' "NULL"
  fi
}

record_test() {
  local category="$1"
  local status="$2"
  local result="$3"
  local source_file="$4"

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
    'wifi_stability',
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

restore_bssid() {
  if [ "$RESTORE_NEEDED" -ne 1 ]; then
    return
  fi

  {
    printf '%s\n' "[$(date)] Restoring original BSSID setting: ${ORIGINAL_BSSID:-<empty>}"
  } >> "$LOG_FILE"

  nmcli connection modify "$CONNECTION_NAME" 802-11-wireless.bssid "$ORIGINAL_BSSID" >> "$LOG_FILE" 2>&1
  nmcli connection up "$CONNECTION_NAME" >> "$LOG_FILE" 2>&1
}

trap restore_bssid EXIT INT TERM

sqlite_exec "$DB_PATH" "
INSERT OR IGNORE INTO runs (run_id, started_at, run_dir, connection_name, interface_name, notes)
VALUES (
  '$(sql_quote "$RUN_ID")',
  '$(date -Is 2>/dev/null || date)',
  '$(sql_quote "$RUN_DIR")',
  '$(sql_quote "$CONNECTION_NAME")',
  '$(sql_quote "$IFACE")',
  'Wi-Fi stability and BSSID A/B experiment'
);
"

parse_proc_wireless() {
  local file="$1"
  local field="$2"
  awk -v iface="$IFACE" -v wanted="$field" '
    $1 ~ iface ":" {
      quality=$3
      level=$4
      gsub(/\./, "", quality)
      gsub(/\./, "", level)
      if (wanted == "quality") print quality
      if (wanted == "level") print level
    }
  ' "$file"
}

parse_nm_signal() {
  local file="$1"
  awk -F: '$1 == "yes" { print $2; exit }' "$file"
}

collect_sample() {
  local sample_group="$1"
  local mode="$2"
  local configured_bssid="$3"
  local sample_index="$4"
  local tsv_file="$5"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local link_file="$tmp_dir/iw-link.txt"
  local station_file="$tmp_dir/iw-station.txt"
  local info_file="$tmp_dir/iw-info.txt"
  local nm_file="$tmp_dir/nm-wifi.txt"
  local proc_file="$tmp_dir/proc-wireless.txt"

  "$IW_BIN" dev "$IFACE" link > "$link_file" 2>&1
  "$IW_BIN" dev "$IFACE" station dump > "$station_file" 2>&1
  "$IW_BIN" dev "$IFACE" info > "$info_file" 2>&1
  nmcli -t --escape no -f ACTIVE,SIGNAL device wifi list --rescan no > "$nm_file" 2>&1
  cat /proc/net/wireless > "$proc_file" 2>&1

  local sampled_at connected_bssid ssid freq_mhz channel nm_signal proc_quality proc_level
  local iw_signal iw_signal_avg rx_bitrate tx_bitrate tx_retries tx_failed beacon_loss rx_drop_misc

  sampled_at="$(date -Is 2>/dev/null || date)"
  connected_bssid="$(awk '/Connected to/ {print $3; exit}' "$link_file")"
  ssid="$(awk -F': ' '/SSID:/ {print $2; exit}' "$link_file")"
  freq_mhz="$(awk '/freq:/ {print $2; exit}' "$link_file")"
  channel="$(awk '/channel / {print $2; exit}' "$info_file")"
  nm_signal="$(parse_nm_signal "$nm_file")"
  proc_quality="$(parse_proc_wireless "$proc_file" quality)"
  proc_level="$(parse_proc_wireless "$proc_file" level)"
  iw_signal="$(awk '/signal:/ {print $2; exit}' "$link_file")"
  iw_signal_avg="$(awk '/signal avg:/ {print $3; exit}' "$station_file")"
  rx_bitrate="$(awk '/rx bitrate:/ {print $3; exit}' "$link_file")"
  tx_bitrate="$(awk '/tx bitrate:/ {print $3; exit}' "$link_file")"
  tx_retries="$(awk '/tx retries:/ {print $3; exit}' "$station_file")"
  tx_failed="$(awk '/tx failed:/ {print $3; exit}' "$station_file")"
  beacon_loss="$(awk '/beacon loss:/ {print $3; exit}' "$station_file")"
  rx_drop_misc="$(awk '/rx drop misc:/ {print $4; exit}' "$station_file")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$sample_index" "$sampled_at" "$mode" "$configured_bssid" "$connected_bssid" "$ssid" \
    "$freq_mhz" "$channel" "$nm_signal" "$proc_quality" "$proc_level" "$iw_signal" \
    "$iw_signal_avg" "$rx_bitrate" "$tx_bitrate" "$tx_retries" "$tx_failed" \
    "$beacon_loss" "$rx_drop_misc" "$(basename "$tsv_file")" >> "$tsv_file"

  sqlite_exec "$DB_PATH" "
  INSERT INTO wifi_stability_samples (
    run_id,
    phase,
    sample_group,
    sample_index,
    sampled_at,
    mode,
    configured_bssid,
    connected_bssid,
    ssid,
    freq_mhz,
    channel,
    nm_signal,
    proc_quality,
    proc_level_dbm,
    iw_signal_dbm,
    iw_signal_avg_dbm,
    rx_bitrate_mbps,
    tx_bitrate_mbps,
    tx_retries,
    tx_failed,
    beacon_loss,
    rx_drop_misc,
    source_file
  ) VALUES (
    '$(sql_quote "$RUN_ID")',
    '$(sql_quote "$PHASE")',
    '$(sql_quote "$sample_group")',
    $sample_index,
    '$(sql_quote "$sampled_at")',
    '$(sql_quote "$mode")',
    $(sql_text_or_null "$configured_bssid"),
    $(sql_text_or_null "$connected_bssid"),
    $(sql_text_or_null "$ssid"),
    $(sql_num_or_null "$freq_mhz"),
    $(sql_num_or_null "$channel"),
    $(sql_num_or_null "$nm_signal"),
    $(sql_num_or_null "$proc_quality"),
    $(sql_num_or_null "$proc_level"),
    $(sql_num_or_null "$iw_signal"),
    $(sql_num_or_null "$iw_signal_avg"),
    $(sql_num_or_null "$rx_bitrate"),
    $(sql_num_or_null "$tx_bitrate"),
    $(sql_num_or_null "$tx_retries"),
    $(sql_num_or_null "$tx_failed"),
    $(sql_num_or_null "$beacon_loss"),
    $(sql_num_or_null "$rx_drop_misc"),
    '$(sql_quote "$(basename "$tsv_file")")'
  )
  ON CONFLICT(run_id, phase, sample_group, sample_index) DO UPDATE SET
    sampled_at = excluded.sampled_at,
    mode = excluded.mode,
    configured_bssid = excluded.configured_bssid,
    connected_bssid = excluded.connected_bssid,
    ssid = excluded.ssid,
    freq_mhz = excluded.freq_mhz,
    channel = excluded.channel,
    nm_signal = excluded.nm_signal,
    proc_quality = excluded.proc_quality,
    proc_level_dbm = excluded.proc_level_dbm,
    iw_signal_dbm = excluded.iw_signal_dbm,
    iw_signal_avg_dbm = excluded.iw_signal_avg_dbm,
    rx_bitrate_mbps = excluded.rx_bitrate_mbps,
    tx_bitrate_mbps = excluded.tx_bitrate_mbps,
    tx_retries = excluded.tx_retries,
    tx_failed = excluded.tx_failed,
    beacon_loss = excluded.beacon_loss,
    rx_drop_misc = excluded.rx_drop_misc,
    source_file = excluded.source_file;
  "

  printf '%s\n' "[$(date)] $sample_group sample $sample_index: bssid=${connected_bssid:-n/a} signal=${iw_signal:-n/a}dBm tx=${tx_bitrate:-n/a}Mbit/s retries=${tx_retries:-n/a} failed=${tx_failed:-n/a}" | tee -a "$LOG_FILE"

  rm -rf "$tmp_dir"
}

summarize_group() {
  local sample_group="$1"
  local source_file="$2"
  local result

  result="$(sqlite_scalar "$DB_PATH" "
    WITH s AS (
      SELECT *
      FROM wifi_stability_samples
      WHERE run_id = '$(sql_quote "$RUN_ID")'
        AND phase = '$(sql_quote "$PHASE")'
        AND sample_group = '$(sql_quote "$sample_group")'
    )
    SELECT
      printf(
        '%d samples, avg signal %.1f dBm, worst %.1f dBm, avg tx %.1f Mbit/s, tx failed delta %d, connected BSSID %s',
        COUNT(*),
        AVG(iw_signal_dbm),
        MIN(iw_signal_dbm),
        AVG(tx_bitrate_mbps),
        COALESCE(MAX(tx_failed) - MIN(tx_failed), 0),
        COALESCE(MAX(connected_bssid), 'n/a')
      )
    FROM s;
  ")"

  record_test "$sample_group" "measured" "$result" "$(basename "$source_file")"
}

collect_group() {
  local sample_group="$1"
  local mode="$2"
  local configured_bssid="$3"
  local duration="$4"
  local tsv_file="$RUN_DIR/${PHASE}-${sample_group}-samples.tsv"

  printf '%s\n' "sample_index	sampled_at	mode	configured_bssid	connected_bssid	ssid	freq_mhz	channel	nm_signal	proc_quality	proc_level_dbm	iw_signal_dbm	iw_signal_avg_dbm	rx_bitrate_mbps	tx_bitrate_mbps	tx_retries	tx_failed	beacon_loss	rx_drop_misc	source_file" > "$tsv_file"

  local samples
  samples=$((duration / SAMPLE_INTERVAL))
  if [ "$samples" -lt 1 ]; then
    samples=1
  fi

  printf '%s\n' "[$(date)] Starting $sample_group: ${samples} samples over about ${duration}s" | tee -a "$LOG_FILE"

  local i
  i=1
  while [ "$i" -le "$samples" ]; do
    collect_sample "$sample_group" "$mode" "$configured_bssid" "$i" "$tsv_file"
    if [ "$i" -lt "$samples" ]; then
      sleep "$SAMPLE_INTERVAL"
    fi
    i=$((i + 1))
  done

  summarize_group "$sample_group" "$tsv_file"
}

set_bssid() {
  local label="$1"
  local bssid="$2"

  printf '%s\n' "[$(date)] Setting BSSID mode $label to ${bssid:-<auto>}" | tee -a "$LOG_FILE"
  nmcli connection modify "$CONNECTION_NAME" 802-11-wireless.bssid "$bssid" >> "$LOG_FILE" 2>&1
  nmcli device wifi rescan ifname "$IFACE" >> "$LOG_FILE" 2>&1 || true
  nmcli connection up "$CONNECTION_NAME" >> "$LOG_FILE" 2>&1
  sleep 20
}

{
  printf '%s\n' "Started: $(date)"
  printf '%s\n' "Run: $RUN_ID"
  printf '%s\n' "Interface: $IFACE"
  printf '%s\n' "Connection: $CONNECTION_NAME"
  printf '%s\n' "Preferred BSSID: $PREFERRED_BSSID"
  printf '%s\n' "Stability seconds: $STABILITY_SECONDS"
  printf '%s\n' "A/B seconds per mode: $AB_SECONDS"
  printf '%s\n' "Sample interval: $SAMPLE_INTERVAL"
  printf '%s\n' ""
} > "$LOG_FILE"

ORIGINAL_BSSID="$(nmcli -g 802-11-wireless.bssid connection show "$CONNECTION_NAME" 2>/dev/null | head -n 1)"
if [ -z "$PREFERRED_BSSID" ]; then
  PREFERRED_BSSID="$ORIGINAL_BSSID"
fi
if [ -z "$PREFERRED_BSSID" ]; then
  printf '%s\n' "Set PREFERRED_BSSID to run the pinned side of the BSSID A/B test." >&2
  exit 1
fi
RESTORE_NEEDED=1
printf '%s\n' "[$(date)] Original configured BSSID: ${ORIGINAL_BSSID:-<empty>}" | tee -a "$LOG_FILE"
printf '%s\n' "[$(date)] Effective preferred BSSID: $PREFERRED_BSSID" | tee -a "$LOG_FILE"

collect_group "stability-current" "current" "$ORIGINAL_BSSID" "$STABILITY_SECONDS"

set_bssid "auto" ""
collect_group "bssid-auto" "auto" "" "$AB_SECONDS"

set_bssid "pinned" "$PREFERRED_BSSID"
collect_group "bssid-pinned" "pinned" "$PREFERRED_BSSID" "$AB_SECONDS"

restore_bssid
RESTORE_NEEDED=0

printf '%s\n' "[$(date)] Finished Wi-Fi stability and BSSID A/B experiment" | tee -a "$LOG_FILE"
