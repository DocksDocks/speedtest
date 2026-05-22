#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sqlite.sh
. "$SCRIPT_DIR/lib/sqlite.sh"

RUN_DIR="${1:-$(speedtest_default_run_dir)}"
DB_PATH="${2:-$(speedtest_default_db)}"
CONNECTION_NAME="${CONNECTION_NAME:-$(speedtest_default_connection_name)}"
IFACE="${IFACE:-$(speedtest_default_wifi_iface)}"
PREFERRED_BSSID="${PREFERRED_BSSID:-}"
SQLITE_BIN="${SQLITE_BIN:-$(speedtest_sqlite_bin)}"
STABILITY_SECONDS="${STABILITY_SECONDS:-300}"
AB_SECONDS="${AB_SECONDS:-60}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"
IWD_CONF="/etc/NetworkManager/conf.d/90-speedtest-iwd.conf"

if [ "$(id -u)" -ne 0 ]; then
  printf '%s\n' "Run with sudo. This test changes NetworkManager's Wi-Fi backend temporarily." >&2
  exit 1
fi

if [ "${CONFIRM_IWD_TEST:-}" != "YES" ]; then
  printf '%s\n' "Refusing to run without CONFIRM_IWD_TEST=YES." >&2
  printf '%s\n' "Example: sudo CONFIRM_IWD_TEST=YES $0 $RUN_DIR $DB_PATH" >&2
  exit 1
fi

if [ -z "$CONNECTION_NAME" ] || [ -z "$IFACE" ]; then
  printf '%s\n' "No active Wi-Fi connection detected. Set CONNECTION_NAME and IFACE explicitly." >&2
  exit 1
fi

mkdir -p "$RUN_DIR"

RUN_ID="$(basename "$RUN_DIR")"
BACKUP_DIR="$RUN_DIR/iwd-backup-$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$RUN_DIR/iwd-backend-test.log"
ROLLBACK_SCRIPT="$RUN_DIR/iwd-rollback.sh"
ORIGINAL_BSSID=""
RESTORE_DONE=0
ROLLBACK_READY=0
BACKEND_TEST_STATUS="started"

need_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "Missing required command: $1" >&2
    exit 1
  fi
}

write_rollback_script() {
  local escaped_connection
  local escaped_bssid
  local escaped_backup_conf
  escaped_connection="$(printf '%s' "$CONNECTION_NAME" | sed "s/'/'\\\\''/g")"
  escaped_bssid="$(printf '%s' "$ORIGINAL_BSSID" | sed "s/'/'\\\\''/g")"
  escaped_backup_conf="$(printf '%s' "$BACKUP_DIR/90-speedtest-iwd.conf.before" | sed "s/'/'\\\\''/g")"

  cat > "$ROLLBACK_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u

CONNECTION_NAME='$escaped_connection'
ORIGINAL_BSSID='$escaped_bssid'
IWD_CONF='$IWD_CONF'
BACKUP_CONF='$escaped_backup_conf'

printf '%s\n' "Rolling back NetworkManager Wi-Fi backend to wpa_supplicant..."
if [ -f "\$BACKUP_CONF" ]; then
  cp "\$BACKUP_CONF" "\$IWD_CONF"
else
  rm -f "\$IWD_CONF"
fi
systemctl restart NetworkManager
sleep 8
nmcli connection modify "\$CONNECTION_NAME" 802-11-wireless.bssid "\$ORIGINAL_BSSID"
nmcli connection up "\$CONNECTION_NAME"
systemctl stop iwd.service 2>/dev/null || true
printf '%s\n' "Rollback complete."
EOF

  chmod +x "$ROLLBACK_SCRIPT"
  ROLLBACK_READY=1
}

restore_backend() {
  if [ "$RESTORE_DONE" -eq 1 ]; then
    return
  fi
  if [ "$ROLLBACK_READY" -ne 1 ] || [ ! -x "$ROLLBACK_SCRIPT" ]; then
    return
  fi

  {
    printf '%s\n' "[$(date)] Restoring NetworkManager backend to wpa_supplicant/default"
    printf '%s\n' "Rollback script: $ROLLBACK_SCRIPT"
  } >> "$LOG_FILE"

  "$ROLLBACK_SCRIPT" >> "$LOG_FILE" 2>&1 || true
  RESTORE_DONE=1
}

record_backend_test() {
  sqlite_exec "$DB_PATH" "
  INSERT INTO wifi_backend_tests (
    run_id,
    phase,
    backend,
    connection_name,
    interface_name,
    original_bssid,
    preferred_bssid,
    backend_config_path,
    backup_dir,
    rollback_script,
    status,
    notes
  ) VALUES (
    '$(sql_quote "$RUN_ID")',
    'wifi-iwd-experiments',
    'iwd',
    '$(sql_quote "$CONNECTION_NAME")',
    '$(sql_quote "$IFACE")',
    NULLIF('$(sql_quote "$ORIGINAL_BSSID")', ''),
    NULLIF('$(sql_quote "$PREFERRED_BSSID")', ''),
    '$(sql_quote "$IWD_CONF")',
    '$(sql_quote "$BACKUP_DIR")',
    '$(sql_quote "$ROLLBACK_SCRIPT")',
    '$(sql_quote "$BACKEND_TEST_STATUS")',
    '$(sql_quote "${1:-}")'
  )
  ON CONFLICT(run_id, phase, backend) DO UPDATE SET
    connection_name = excluded.connection_name,
    interface_name = excluded.interface_name,
    original_bssid = excluded.original_bssid,
    preferred_bssid = excluded.preferred_bssid,
    backend_config_path = excluded.backend_config_path,
    backup_dir = excluded.backup_dir,
    rollback_script = excluded.rollback_script,
    status = excluded.status,
    finished_at = CASE
      WHEN excluded.status IN ('rolled_back', 'failed') THEN CURRENT_TIMESTAMP
      ELSE wifi_backend_tests.finished_at
    END,
    notes = excluded.notes;
  "
}

finish_ownership() {
  if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
    chown -R "$SUDO_UID:$SUDO_GID" "$RUN_DIR" 2>/dev/null || true
  fi
}

trap 'restore_backend; finish_ownership' EXIT INT TERM

need_command iwctl
need_command iw
need_command nmcli
need_command systemctl
need_command NetworkManager
need_command "$SQLITE_BIN"

mkdir -p "$BACKUP_DIR"
speedtest_init_schema "$DB_PATH"

sqlite_exec "$DB_PATH" "
INSERT OR IGNORE INTO runs (run_id, started_at, run_dir, connection_name, interface_name, notes)
VALUES (
  '$(sql_quote "$RUN_ID")',
  '$(date -Is 2>/dev/null || date)',
  '$(sql_quote "$RUN_DIR")',
  '$(sql_quote "$CONNECTION_NAME")',
  '$(sql_quote "$IFACE")',
  'iwd backend test'
);
"

{
  printf '%s\n' "Started: $(date)"
  printf '%s\n' "Run: $RUN_ID"
  printf '%s\n' "Connection: $CONNECTION_NAME"
  printf '%s\n' "Interface: $IFACE"
  printf '%s\n' "Preferred BSSID: $PREFERRED_BSSID"
  printf '%s\n' "NetworkManager version: $(NetworkManager --version 2>/dev/null || true)"
  printf '%s\n' "iwctl: $(command -v iwctl)"
  printf '%s\n' ""
} > "$LOG_FILE"

NetworkManager --print-config > "$BACKUP_DIR/networkmanager-print-config-before.txt" 2>&1 || true
nmcli -g 802-11-wireless.bssid connection show "$CONNECTION_NAME" > "$BACKUP_DIR/original-bssid.txt" 2>&1 || true
ORIGINAL_BSSID="$(head -n 1 "$BACKUP_DIR/original-bssid.txt" | sed 's/\\:/:/g')"
if [ -z "$PREFERRED_BSSID" ]; then
  PREFERRED_BSSID="$ORIGINAL_BSSID"
fi
if [ -z "$PREFERRED_BSSID" ]; then
  printf '%s\n' "Set PREFERRED_BSSID before running the iwd BSSID A/B test." >&2
  exit 1
fi
if [ -z "$ORIGINAL_BSSID" ]; then
  ORIGINAL_BSSID="$PREFERRED_BSSID"
fi
printf '%s\n' "Effective preferred BSSID: $PREFERRED_BSSID" >> "$LOG_FILE"
write_rollback_script
BACKEND_TEST_STATUS="rollback_ready"
record_backend_test "rollback script written before backend switch"

if [ -f "$IWD_CONF" ]; then
  cp "$IWD_CONF" "$BACKUP_DIR/90-speedtest-iwd.conf.before"
fi

{
  printf '%s\n' "[$(date)] Starting iwd service"
} >> "$LOG_FILE"
systemctl start iwd.service >> "$LOG_FILE" 2>&1
BACKEND_TEST_STATUS="iwd_started"
record_backend_test "iwd service start requested"

cat > "$IWD_CONF" <<EOF
[device]
wifi.backend=iwd
wifi.iwd.autoconnect=false
wifi.scan-rand-mac-address=no
EOF

{
  printf '%s\n' "[$(date)] Wrote $IWD_CONF"
  cat "$IWD_CONF"
  printf '%s\n' "[$(date)] Restarting NetworkManager"
} >> "$LOG_FILE"

systemctl restart NetworkManager >> "$LOG_FILE" 2>&1
sleep 10
BACKEND_TEST_STATUS="networkmanager_iwd"
record_backend_test "NetworkManager restarted with iwd backend config"

{
  printf '%s\n' "[$(date)] Bringing up $CONNECTION_NAME on iwd backend"
} >> "$LOG_FILE"

nmcli connection modify "$CONNECTION_NAME" 802-11-wireless.bssid "$PREFERRED_BSSID" >> "$LOG_FILE" 2>&1
nmcli connection up "$CONNECTION_NAME" >> "$LOG_FILE" 2>&1
sleep 12
BACKEND_TEST_STATUS="connected_iwd"
record_backend_test "connection up requested on iwd backend"

NetworkManager --print-config > "$BACKUP_DIR/networkmanager-print-config-iwd.txt" 2>&1 || true
systemctl is-active iwd.service > "$BACKUP_DIR/iwd-active.txt" 2>&1 || true
iwctl device list > "$BACKUP_DIR/iwctl-device-list.txt" 2>&1 || true
nmcli -f ACTIVE,SSID,BSSID,CHAN,FREQ,RATE,SIGNAL,BARS,SECURITY device wifi list --rescan no > "$BACKUP_DIR/nmcli-wifi-list-iwd.txt" 2>&1 || true

{
  printf '%s\n' "[$(date)] Running Wi-Fi stability and BSSID A/B samples on iwd backend"
} >> "$LOG_FILE"

PHASE=wifi-iwd-experiments \
STABILITY_SECONDS="$STABILITY_SECONDS" \
AB_SECONDS="$AB_SECONDS" \
SAMPLE_INTERVAL="$SAMPLE_INTERVAL" \
SQLITE_BIN="$SQLITE_BIN" \
IFACE="$IFACE" \
CONNECTION_NAME="$CONNECTION_NAME" \
PREFERRED_BSSID="$PREFERRED_BSSID" \
"$SCRIPT_DIR/run-wifi-stability-bssid-ab.sh" "$RUN_DIR" "$DB_PATH" >> "$LOG_FILE" 2>&1

restore_backend
BACKEND_TEST_STATUS="rolled_back"
record_backend_test "rollback completed after iwd sample"
NetworkManager --print-config > "$BACKUP_DIR/networkmanager-print-config-after-rollback.txt" 2>&1 || true
nmcli -f ACTIVE,SSID,BSSID,CHAN,FREQ,RATE,SIGNAL,BARS,SECURITY device wifi list --rescan no > "$BACKUP_DIR/nmcli-wifi-list-after-rollback.txt" 2>&1 || true

{
  printf '%s\n' "[$(date)] Finished iwd backend test and rollback"
  printf '%s\n' "Manual rollback, if needed: sudo $ROLLBACK_SCRIPT"
} >> "$LOG_FILE"

finish_ownership
printf '%s\n' "iwd backend test complete. Logs: $LOG_FILE"
printf '%s\n' "Manual rollback, if needed: sudo $ROLLBACK_SCRIPT"
