#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sqlite.sh
. "$SCRIPT_DIR/lib/sqlite.sh"
# shellcheck source=lib/networkmanager.sh
. "$SCRIPT_DIR/lib/networkmanager.sh"

REQUESTED_RUN_DIR="${1:-$(speedtest_default_run_dir)}"
DB_PATH="${2:-$(speedtest_default_db)}"
SOURCE_CONNECTION_UUID="${CONNECTION_UUID:-$(nm_active_wifi_connection_uuid)}"
SOURCE_CONNECTION_NAME="${CONNECTION_NAME:-}"
IFACE="${IFACE:-$(speedtest_default_wifi_iface)}"
PREFERRED_BSSID="${PREFERRED_BSSID:-}"
SQLITE_BIN="${SQLITE_BIN:-$(speedtest_sqlite_bin)}"
STABILITY_SECONDS="${STABILITY_SECONDS:-300}"
AB_SECONDS="${AB_SECONDS:-60}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"
IWD_CONF="/etc/NetworkManager/conf.d/90-speedtest-iwd.conf"
BASE_RUN_DIR="${BASE_RUN_DIR:-$REQUESTED_RUN_DIR}"
BASE_RUN_ID="${BASE_RUN_ID:-$(basename "$BASE_RUN_DIR")}"
IWD_UNIQUE_RUN="${IWD_UNIQUE_RUN:-1}"

if [ "$IWD_UNIQUE_RUN" = "1" ]; then
  RUN_ID="${IWD_RUN_ID:-${BASE_RUN_ID}-iwd-$(date +%Y%m%d-%H%M%S)}"
  RUN_DIR="$(dirname "$BASE_RUN_DIR")/$RUN_ID"
else
  RUN_DIR="$BASE_RUN_DIR"
  RUN_ID="$(basename "$RUN_DIR")"
fi

BASE_RUN_ID_FOR_SQL="$BASE_RUN_ID"
if [ "$BASE_RUN_ID_FOR_SQL" = "$RUN_ID" ]; then
  BASE_RUN_ID_FOR_SQL=""
fi

if [ "$(id -u)" -ne 0 ]; then
  printf '%s\n' "Run with sudo. This test changes NetworkManager's Wi-Fi backend temporarily." >&2
  exit 1
fi

if [ "${CONFIRM_IWD_TEST:-}" != "YES" ]; then
  printf '%s\n' "Refusing to run without CONFIRM_IWD_TEST=YES." >&2
  printf '%s\n' "Example: sudo CONFIRM_IWD_TEST=YES $0 $RUN_DIR $DB_PATH" >&2
  exit 1
fi

if [ -z "$SOURCE_CONNECTION_NAME" ] && [ -z "$SOURCE_CONNECTION_UUID" ]; then
  SOURCE_CONNECTION_NAME="$(speedtest_default_connection_name)"
fi
if [ -z "$SOURCE_CONNECTION_UUID" ] && [ -n "$SOURCE_CONNECTION_NAME" ]; then
  SOURCE_CONNECTION_UUID="$(nm_connection_uuid_for_name "$SOURCE_CONNECTION_NAME")"
fi
if [ -z "$SOURCE_CONNECTION_NAME" ] && [ -n "$SOURCE_CONNECTION_UUID" ]; then
  SOURCE_CONNECTION_NAME="$(nm_connection_name_for_uuid "$SOURCE_CONNECTION_UUID")"
fi

if [ -z "$SOURCE_CONNECTION_UUID" ] || [ -z "$SOURCE_CONNECTION_NAME" ] || [ -z "$IFACE" ]; then
  printf '%s\n' "No active Wi-Fi connection detected. Set CONNECTION_NAME/CONNECTION_UUID and IFACE explicitly." >&2
  exit 1
fi

mkdir -p "$RUN_DIR"

BACKUP_DIR="$RUN_DIR/iwd-backup-$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$RUN_DIR/iwd-backend-test.log"
ROLLBACK_SCRIPT="$RUN_DIR/iwd-rollback.sh"
TEST_CONNECTION_NAME="${IWD_TEST_CONNECTION_NAME:-speedtest-iwd-$RUN_ID}"
TEST_CONNECTION_UUID=""
ORIGINAL_BSSID=""
ORIGINAL_AUTOCONNECT=""
RESTORE_DONE=0
ROLLBACK_READY=0
BACKEND_TEST_STATUS="started"
ROLLBACK_RC=0

need_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "Missing required command: $1" >&2
    exit 1
  fi
}

shell_escape_single() {
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

record_backend_test() {
  sqlite_exec "$DB_PATH" "
  INSERT INTO wifi_backend_tests (
    run_id,
    base_run_id,
    phase,
    backend,
    connection_name,
    connection_uuid,
    test_connection_name,
    test_connection_uuid,
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
    NULLIF('$(sql_quote "$BASE_RUN_ID_FOR_SQL")', ''),
    'wifi-iwd-experiments',
    'iwd',
    '$(sql_quote "$SOURCE_CONNECTION_NAME")',
    '$(sql_quote "$SOURCE_CONNECTION_UUID")',
    NULLIF('$(sql_quote "$TEST_CONNECTION_NAME")', ''),
    NULLIF('$(sql_quote "$TEST_CONNECTION_UUID")', ''),
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
    base_run_id = excluded.base_run_id,
    connection_name = excluded.connection_name,
    connection_uuid = excluded.connection_uuid,
    test_connection_name = excluded.test_connection_name,
    test_connection_uuid = excluded.test_connection_uuid,
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

write_rollback_script() {
  local escaped_source_uuid
  local escaped_source_name
  local escaped_test_uuid
  local escaped_iface
  local escaped_bssid
  local escaped_autoconnect
  local escaped_backup_conf

  escaped_source_uuid="$(shell_escape_single "$SOURCE_CONNECTION_UUID")"
  escaped_source_name="$(shell_escape_single "$SOURCE_CONNECTION_NAME")"
  escaped_test_uuid="$(shell_escape_single "$TEST_CONNECTION_UUID")"
  escaped_iface="$(shell_escape_single "$IFACE")"
  escaped_bssid="$(shell_escape_single "$ORIGINAL_BSSID")"
  escaped_autoconnect="$(shell_escape_single "$ORIGINAL_AUTOCONNECT")"
  escaped_backup_conf="$(shell_escape_single "$BACKUP_DIR/90-speedtest-iwd.conf.before")"

  cat > "$ROLLBACK_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u

SOURCE_CONNECTION_UUID='$escaped_source_uuid'
SOURCE_CONNECTION_NAME='$escaped_source_name'
TEST_CONNECTION_UUID='$escaped_test_uuid'
IFACE='$escaped_iface'
ORIGINAL_BSSID='$escaped_bssid'
ORIGINAL_AUTOCONNECT='$escaped_autoconnect'
IWD_CONF='$IWD_CONF'
BACKUP_CONF='$escaped_backup_conf'
ROLLBACK_FAILED=0

mark_failed() {
  local rc="\$1"
  shift
  printf '%s\n' "Rollback command failed (\$rc): \$*" >&2
  ROLLBACK_FAILED=1
}

run_or_mark() {
  "\$@"
  local rc=\$?
  if [ "\$rc" -ne 0 ]; then
    mark_failed "\$rc" "\$@"
  fi
  return "\$rc"
}

nm_source_modify() {
  if [ -n "\$SOURCE_CONNECTION_UUID" ]; then
    nmcli connection modify uuid "\$SOURCE_CONNECTION_UUID" "\$@"
  else
    nmcli connection modify id "\$SOURCE_CONNECTION_NAME" "\$@"
  fi
}

nm_source_up() {
  local cmd=(nmcli connection up)
  if [ -n "\$SOURCE_CONNECTION_UUID" ]; then
    cmd+=(uuid "\$SOURCE_CONNECTION_UUID")
  else
    cmd+=(id "\$SOURCE_CONNECTION_NAME")
  fi
  if [ -n "\$IFACE" ]; then
    cmd+=(ifname "\$IFACE")
  fi
  "\${cmd[@]}"
}

printf '%s\n' "Rolling back NetworkManager Wi-Fi backend to wpa_supplicant..."
if [ -f "\$BACKUP_CONF" ]; then
  run_or_mark cp "\$BACKUP_CONF" "\$IWD_CONF"
else
  run_or_mark rm -f "\$IWD_CONF"
fi

run_or_mark systemctl restart NetworkManager
sleep 8
nmcli radio wifi on 2>/dev/null || true
nmcli device set "\$IFACE" managed yes 2>/dev/null || true

if [ -n "\$ORIGINAL_AUTOCONNECT" ]; then
  run_or_mark nm_source_modify connection.autoconnect "\$ORIGINAL_AUTOCONNECT"
fi
run_or_mark nm_source_modify 802-11-wireless.bssid "\$ORIGINAL_BSSID"
run_or_mark nm_source_up

if [ "\$ROLLBACK_FAILED" -eq 0 ] && [ -n "\$TEST_CONNECTION_UUID" ]; then
  nmcli connection delete uuid "\$TEST_CONNECTION_UUID" >/dev/null 2>&1 || true
fi

if [ "\$ROLLBACK_FAILED" -eq 0 ]; then
  systemctl stop iwd.service 2>/dev/null || true
  printf '%s\n' "Rollback complete."
  exit 0
fi

printf '%s\n' "Rollback finished with errors. The cloned test profile was left in NetworkManager for manual recovery." >&2
exit 1
EOF

  chmod +x "$ROLLBACK_SCRIPT"
  ROLLBACK_READY=1
}

restore_backend() {
  local rc

  if [ "$RESTORE_DONE" -eq 1 ]; then
    return 0
  fi
  if [ "$ROLLBACK_READY" -ne 1 ] || [ ! -x "$ROLLBACK_SCRIPT" ]; then
    return 0
  fi

  {
    printf '%s\n' "[$(date)] Restoring NetworkManager backend to wpa_supplicant/default"
    printf '%s\n' "Rollback script: $ROLLBACK_SCRIPT"
  } >> "$LOG_FILE"

  "$ROLLBACK_SCRIPT" >> "$LOG_FILE" 2>&1
  rc=$?
  RESTORE_DONE=1
  return "$rc"
}

finish_ownership() {
  if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
    chown -R "$SUDO_UID:$SUDO_GID" "$RUN_DIR" 2>/dev/null || true
  fi
}

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    restore_backend >/dev/null 2>&1 || true
  fi
  finish_ownership
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
  '$(sql_quote "$SOURCE_CONNECTION_NAME")',
  '$(sql_quote "$IFACE")',
  'iwd backend test'
);
"

if [ -n "$BASE_RUN_ID_FOR_SQL" ]; then
  sqlite_exec "$DB_PATH" "
  INSERT OR IGNORE INTO runs (run_id, started_at, run_dir, notes)
  VALUES (
    '$(sql_quote "$BASE_RUN_ID_FOR_SQL")',
    '$(date -Is 2>/dev/null || date)',
    '$(sql_quote "$BASE_RUN_DIR")',
    'base run linked to iwd backend test'
  );
  "
fi

{
  printf '%s\n' "Started: $(date)"
  printf '%s\n' "Run: $RUN_ID"
  printf '%s\n' "Base run: ${BASE_RUN_ID_FOR_SQL:-<same>}"
  printf '%s\n' "Run dir: $RUN_DIR"
  printf '%s\n' "Source connection: $SOURCE_CONNECTION_NAME"
  printf '%s\n' "Source UUID: $SOURCE_CONNECTION_UUID"
  printf '%s\n' "Test connection: $TEST_CONNECTION_NAME"
  printf '%s\n' "Interface: $IFACE"
  printf '%s\n' "Preferred BSSID: $PREFERRED_BSSID"
  printf '%s\n' "NetworkManager version: $(NetworkManager --version 2>/dev/null || true)"
  printf '%s\n' "iwctl: $(command -v iwctl)"
  printf '%s\n' ""
} > "$LOG_FILE"

NetworkManager --print-config > "$BACKUP_DIR/networkmanager-print-config-before.txt" 2>&1 || true
nm_connection_field_value "$SOURCE_CONNECTION_UUID" "$SOURCE_CONNECTION_NAME" 802-11-wireless.bssid > "$BACKUP_DIR/original-bssid.txt" 2>&1 || true
ORIGINAL_BSSID="$(head -n 1 "$BACKUP_DIR/original-bssid.txt" | nm_unescape_colons)"
ORIGINAL_AUTOCONNECT="$(nm_connection_field_value "$SOURCE_CONNECTION_UUID" "$SOURCE_CONNECTION_NAME" connection.autoconnect)"
if [ -z "$PREFERRED_BSSID" ]; then
  PREFERRED_BSSID="$ORIGINAL_BSSID"
fi
if [ -z "$PREFERRED_BSSID" ]; then
  printf '%s\n' "Set PREFERRED_BSSID before running the iwd BSSID A/B test." >&2
  exit 1
fi
printf '%s\n' "Effective preferred BSSID: $PREFERRED_BSSID" >> "$LOG_FILE"
printf '%s\n' "Original autoconnect: ${ORIGINAL_AUTOCONNECT:-<unknown>}" >> "$LOG_FILE"

{
  printf '%s\n' "[$(date)] Cloning source NetworkManager profile for isolated iwd test"
  printf '%s\n' "Source selector: uuid $SOURCE_CONNECTION_UUID"
} >> "$LOG_FILE"
if ! nmcli connection clone uuid "$SOURCE_CONNECTION_UUID" "$TEST_CONNECTION_NAME" >> "$LOG_FILE" 2>&1; then
  BACKEND_TEST_STATUS="failed"
  record_backend_test "failed to clone source NetworkManager profile"
  exit 1
fi
TEST_CONNECTION_UUID="$(nm_connection_uuid_for_name "$TEST_CONNECTION_NAME")"
if [ -z "$TEST_CONNECTION_UUID" ]; then
  BACKEND_TEST_STATUS="failed"
  record_backend_test "cloned profile UUID could not be resolved"
  exit 1
fi
if ! nm_connection_modify "$TEST_CONNECTION_UUID" "$TEST_CONNECTION_NAME" \
  connection.autoconnect yes \
  802-11-wireless.bssid "$PREFERRED_BSSID" >> "$LOG_FILE" 2>&1; then
  nmcli connection delete uuid "$TEST_CONNECTION_UUID" >/dev/null 2>&1 || true
  BACKEND_TEST_STATUS="failed"
  record_backend_test "failed to prepare cloned NetworkManager profile"
  exit 1
fi

write_rollback_script
BACKEND_TEST_STATUS="rollback_ready"
record_backend_test "rollback script written before backend switch; iwd test uses cloned profile"

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
[main]
iwd-config-path=auto

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
  printf '%s\n' "[$(date)] Bringing up cloned profile on iwd backend"
  printf '%s\n' "Test selector: uuid $TEST_CONNECTION_UUID"
} >> "$LOG_FILE"

if ! nm_connection_up "$TEST_CONNECTION_UUID" "$TEST_CONNECTION_NAME" "$IFACE" "$PREFERRED_BSSID" >> "$LOG_FILE" 2>&1; then
  BACKEND_TEST_STATUS="failed"
  record_backend_test "failed to activate cloned profile on iwd backend; rollback attempted"
  restore_backend || true
  exit 1
fi
sleep 12
BACKEND_TEST_STATUS="connected_iwd"
record_backend_test "cloned profile connection up requested on iwd backend"

NetworkManager --print-config > "$BACKUP_DIR/networkmanager-print-config-iwd.txt" 2>&1 || true
systemctl is-active iwd.service > "$BACKUP_DIR/iwd-active.txt" 2>&1 || true
iwctl device list > "$BACKUP_DIR/iwctl-device-list.txt" 2>&1 || true
nmcli -f ACTIVE,SSID,BSSID,CHAN,FREQ,RATE,SIGNAL,BARS,SECURITY device wifi list --rescan no > "$BACKUP_DIR/nmcli-wifi-list-iwd.txt" 2>&1 || true

{
  printf '%s\n' "[$(date)] Running Wi-Fi stability and BSSID A/B samples on iwd backend"
} >> "$LOG_FILE"

env \
  PHASE=wifi-iwd-experiments \
  STABILITY_SECONDS="$STABILITY_SECONDS" \
  AB_SECONDS="$AB_SECONDS" \
  SAMPLE_INTERVAL="$SAMPLE_INTERVAL" \
  SQLITE_BIN="$SQLITE_BIN" \
  IFACE="$IFACE" \
  CONNECTION_NAME="$TEST_CONNECTION_NAME" \
  CONNECTION_UUID="$TEST_CONNECTION_UUID" \
  PREFERRED_BSSID="$PREFERRED_BSSID" \
  RESTORE_CONNECTION_UP=0 \
  "$SCRIPT_DIR/run-wifi-stability-bssid-ab.sh" "$RUN_DIR" "$DB_PATH" >> "$LOG_FILE" 2>&1

if restore_backend; then
  BACKEND_TEST_STATUS="rolled_back"
  record_backend_test "rollback completed after iwd sample; cloned test profile removed"
else
  ROLLBACK_RC=$?
  BACKEND_TEST_STATUS="failed"
  record_backend_test "iwd sample completed, but rollback failed; manual recovery may be required"
fi

NetworkManager --print-config > "$BACKUP_DIR/networkmanager-print-config-after-rollback.txt" 2>&1 || true
nmcli -f ACTIVE,SSID,BSSID,CHAN,FREQ,RATE,SIGNAL,BARS,SECURITY device wifi list --rescan no > "$BACKUP_DIR/nmcli-wifi-list-after-rollback.txt" 2>&1 || true

{
  printf '%s\n' "[$(date)] Finished iwd backend test and rollback"
  printf '%s\n' "Manual rollback, if needed: sudo $ROLLBACK_SCRIPT"
} >> "$LOG_FILE"

finish_ownership
if [ "$ROLLBACK_RC" -ne 0 ]; then
  printf '%s\n' "iwd backend test finished, but rollback reported errors. Logs: $LOG_FILE" >&2
  printf '%s\n' "Manual rollback: sudo $ROLLBACK_SCRIPT" >&2
  exit "$ROLLBACK_RC"
fi

printf '%s\n' "iwd backend test complete. Logs: $LOG_FILE"
printf '%s\n' "Manual rollback, if needed: sudo $ROLLBACK_SCRIPT"
