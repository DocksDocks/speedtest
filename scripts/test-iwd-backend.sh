#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sqlite.sh
. "$SCRIPT_DIR/lib/sqlite.sh"
# shellcheck source=lib/networkmanager.sh
. "$SCRIPT_DIR/lib/networkmanager.sh"

usage() {
  cat <<'EOF'
Usage:
  sudo scripts/test-iwd-backend.sh [options] [run_dir] [db_path]

Default behavior:
  - quick smoke test: 60s current stability, 30s per BSSID mode, 5s samples
  - active Wi-Fi profile and interface are auto-detected
  - preferred BSSID defaults to the currently connected AP
  - interactive TTY runs show selection prompts and require typing YES

Options:
  -y, --yes                 skip prompts; still requires sudo
      --quick               60s current, 30s per BSSID mode (default)
      --standard            300s current, 60s per BSSID mode
      --thorough            600s current, 120s per BSSID mode
      --stability-seconds N override current stability duration
      --ab-seconds N        override each BSSID A/B duration
      --sample-interval N   override sample interval
      --bssid BSSID         preferred AP BSSID to pin
      --connection-uuid ID  source NetworkManager profile UUID
      --connection-name NAME source NetworkManager profile name
      --iface IFACE         Wi-Fi interface
      --run-dir DIR         base run directory
      --db PATH             SQLite database path
      --non-interactive     fail instead of prompting unless --yes is used
  -h, --help                show this help
EOF
}

die_usage() {
  printf '%s\n' "$1" >&2
  printf '%s\n' "" >&2
  usage >&2
  exit 2
}

require_option_value() {
  local option_name="$1"
  local option_value="${2:-}"
  if [ -z "$option_value" ]; then
    die_usage "Missing value for $option_name."
  fi
}

REQUESTED_RUN_DIR=""
DB_PATH=""
SOURCE_CONNECTION_UUID="${CONNECTION_UUID:-}"
SOURCE_CONNECTION_NAME="${CONNECTION_NAME:-}"
IFACE="${IFACE:-}"
PREFERRED_BSSID="${PREFERRED_BSSID:-}"
SQLITE_BIN="${SQLITE_BIN:-}"
STABILITY_SECONDS="${STABILITY_SECONDS:-}"
AB_SECONDS="${AB_SECONDS:-}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-}"
IWD_MODE_EXPLICIT=0
if [ -n "${IWD_TEST_MODE:-}" ]; then
  IWD_MODE_EXPLICIT=1
fi
IWD_TEST_MODE="${IWD_TEST_MODE:-quick}"
IWD_NON_INTERACTIVE="${IWD_NON_INTERACTIVE:-0}"
IWD_ASSUME_YES=0

POSITIONAL_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -y|--yes)
      CONFIRM_IWD_TEST=YES
      IWD_ASSUME_YES=1
      ;;
    --quick|--smoke)
      IWD_TEST_MODE="quick"
      IWD_MODE_EXPLICIT=1
      ;;
    --standard)
      IWD_TEST_MODE="standard"
      IWD_MODE_EXPLICIT=1
      ;;
    --thorough)
      IWD_TEST_MODE="thorough"
      IWD_MODE_EXPLICIT=1
      ;;
    --stability-seconds)
      shift
      require_option_value "--stability-seconds" "${1:-}"
      STABILITY_SECONDS="$1"
      IWD_TEST_MODE="custom"
      IWD_MODE_EXPLICIT=1
      ;;
    --ab-seconds)
      shift
      require_option_value "--ab-seconds" "${1:-}"
      AB_SECONDS="$1"
      IWD_TEST_MODE="custom"
      IWD_MODE_EXPLICIT=1
      ;;
    --sample-interval)
      shift
      require_option_value "--sample-interval" "${1:-}"
      SAMPLE_INTERVAL="$1"
      IWD_TEST_MODE="custom"
      IWD_MODE_EXPLICIT=1
      ;;
    --bssid)
      shift
      require_option_value "--bssid" "${1:-}"
      PREFERRED_BSSID="$1"
      ;;
    --connection-uuid)
      shift
      require_option_value "--connection-uuid" "${1:-}"
      SOURCE_CONNECTION_UUID="$1"
      ;;
    --connection-name)
      shift
      require_option_value "--connection-name" "${1:-}"
      SOURCE_CONNECTION_NAME="$1"
      ;;
    --iface)
      shift
      require_option_value "--iface" "${1:-}"
      IFACE="$1"
      ;;
    --run-dir)
      shift
      require_option_value "--run-dir" "${1:-}"
      REQUESTED_RUN_DIR="$1"
      ;;
    --db)
      shift
      require_option_value "--db" "${1:-}"
      DB_PATH="$1"
      ;;
    --non-interactive)
      IWD_NON_INTERACTIVE=1
      ;;
    --interactive)
      IWD_NON_INTERACTIVE=0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        POSITIONAL_ARGS+=("$1")
        shift
      done
      break
      ;;
    -*)
      die_usage "Unknown option: $1"
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      ;;
  esac
  shift
done

if [ "${#POSITIONAL_ARGS[@]}" -gt 2 ]; then
  die_usage "Too many positional arguments."
fi

REQUESTED_RUN_DIR="${REQUESTED_RUN_DIR:-${POSITIONAL_ARGS[0]:-$(speedtest_default_run_dir)}}"
DB_PATH="${DB_PATH:-${POSITIONAL_ARGS[1]:-$(speedtest_default_db)}}"
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

SOURCE_CONNECTION_UUID="${SOURCE_CONNECTION_UUID:-$(nm_active_wifi_connection_uuid)}"
IFACE="${IFACE:-$(speedtest_default_wifi_iface)}"
SQLITE_BIN="${SQLITE_BIN:-$(speedtest_sqlite_bin)}"

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

is_interactive() {
  [ "$IWD_ASSUME_YES" != "1" ] && [ "$IWD_NON_INTERACTIVE" != "1" ] && [ -t 0 ] && [ -t 1 ]
}

set_duration_defaults() {
  local default_stability
  local default_ab
  local default_interval

  case "$IWD_TEST_MODE" in
    quick|smoke)
      default_stability=60
      default_ab=30
      default_interval=5
      ;;
    standard)
      default_stability=300
      default_ab=60
      default_interval=5
      ;;
    thorough)
      default_stability=600
      default_ab=120
      default_interval=5
      ;;
    custom)
      default_stability=60
      default_ab=30
      default_interval=5
      ;;
    *)
      die_usage "Unknown test mode: $IWD_TEST_MODE"
      ;;
  esac

  STABILITY_SECONDS="${STABILITY_SECONDS:-$default_stability}"
  AB_SECONDS="${AB_SECONDS:-$default_ab}"
  SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-$default_interval}"
}

validate_positive_int() {
  local label="$1"
  local value="$2"

  case "$value" in
    ''|*[!0-9]*)
      die_usage "$label must be a positive integer."
      ;;
  esac
  if [ "$value" -lt 1 ]; then
    die_usage "$label must be greater than zero."
  fi
}

prompt_test_mode() {
  local answer

  printf '%s\n' ""
  printf '%s\n' "Select iwd test length:"
  printf '%s\n' "  1) quick    60s current + 30s auto + 30s pinned (recommended first run)"
  printf '%s\n' "  2) standard 300s current + 60s auto + 60s pinned"
  printf '%s\n' "  3) thorough 600s current + 120s auto + 120s pinned"
  printf '%s' "Choice [1]: "
  read -r answer

  case "${answer:-1}" in
    1) IWD_TEST_MODE="quick" ;;
    2) IWD_TEST_MODE="standard" ;;
    3) IWD_TEST_MODE="thorough" ;;
    *) die_usage "Invalid test length choice: $answer" ;;
  esac
}

current_bssid_for_iface() {
  local iface="$1"
  iw dev "$iface" link 2>/dev/null |
    awk '/Connected to/ { print toupper($3); exit }'
}

append_bssid_candidate() {
  local candidate_bssid="$1"
  local candidate_label="$2"
  local existing

  if [ -z "$candidate_bssid" ]; then
    return
  fi

  for existing in "${BSSID_CANDIDATES[@]:-}"; do
    if [ "$existing" = "$candidate_bssid" ]; then
      return
    fi
  done

  BSSID_CANDIDATES+=("$candidate_bssid")
  BSSID_LABELS+=("$candidate_label")
}

load_bssid_candidates() {
  local current_bssid="$1"
  local line
  local active
  local bssid
  local signal
  local channel
  local freq

  BSSID_CANDIDATES=()
  BSSID_LABELS=()
  append_bssid_candidate "$current_bssid" "current connection"
  append_bssid_candidate "$ORIGINAL_BSSID" "profile pin"

  while IFS=$'\t' read -r active bssid signal channel freq; do
    bssid="$(printf '%s' "$bssid" | tr '[:lower:]' '[:upper:]')"
    if [ -z "$bssid" ]; then
      continue
    fi
    line="scan signal=${signal:-n/a} channel=${channel:-n/a} freq=${freq:-n/a}"
    if [ "$active" = "yes" ]; then
      line="active $line"
    fi
    append_bssid_candidate "$bssid" "$line"
  done < <(
    nmcli -f ACTIVE,BSSID,SIGNAL,CHAN,FREQ device wifi list --rescan yes ifname "$IFACE" 2>/dev/null |
      awk 'NR > 1 && $2 ~ /^[0-9A-Fa-f][0-9A-Fa-f]:/ { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 }'
  )
}

choose_preferred_bssid() {
  local current_bssid
  local answer
  local index

  if [ -n "$PREFERRED_BSSID" ]; then
    return
  fi

  current_bssid="$(current_bssid_for_iface "$IFACE")"
  current_bssid="$(printf '%s' "$current_bssid" | tr '[:lower:]' '[:upper:]')"

  if ! is_interactive; then
    PREFERRED_BSSID="${current_bssid:-$ORIGINAL_BSSID}"
    return
  fi

  load_bssid_candidates "$current_bssid"

  printf '%s\n' ""
  printf '%s\n' "Select preferred BSSID for the pinned side of the iwd test:"
  if [ "${#BSSID_CANDIDATES[@]}" -eq 0 ]; then
    printf '%s\n' "  No BSSID candidates detected."
  else
    index=0
    while [ "$index" -lt "${#BSSID_CANDIDATES[@]}" ]; do
      printf '  %d) %s  (%s)\n' "$((index + 1))" "${BSSID_CANDIDATES[$index]}" "${BSSID_LABELS[$index]}"
      index=$((index + 1))
    done
  fi
  printf '%s\n' "  m) enter BSSID manually"
  printf '%s' "Choice [1]: "
  read -r answer

  if [ -z "$answer" ]; then
    answer=1
  fi
  if [ "$answer" = "m" ] || [ "$answer" = "M" ]; then
    printf '%s' "BSSID: "
    read -r PREFERRED_BSSID
    return
  fi
  case "$answer" in
    ''|*[!0-9]*)
      die_usage "Invalid BSSID choice: $answer"
      ;;
  esac
  if [ "$answer" -lt 1 ] || [ "$answer" -gt "${#BSSID_CANDIDATES[@]}" ]; then
    die_usage "BSSID choice out of range: $answer"
  fi
  PREFERRED_BSSID="${BSSID_CANDIDATES[$((answer - 1))]}"
}

confirm_iwd_test() {
  local answer

  if [ "${CONFIRM_IWD_TEST:-}" = "YES" ]; then
    return
  fi
  if ! is_interactive; then
    printf '%s\n' "Refusing to run without confirmation." >&2
    printf '%s\n' "Use --yes for non-interactive runs, or run from a TTY and type YES at the prompt." >&2
    exit 1
  fi

  printf '%s\n' ""
  printf '%s\n' "This will restart NetworkManager, briefly drop Wi-Fi, switch to iwd for the test, then roll back."
  printf '%s\n' "Run: $RUN_ID"
  printf '%s\n' "Source connection: $SOURCE_CONNECTION_NAME"
  printf '%s\n' "Interface: $IFACE"
  printf '%s\n' "Preferred BSSID: $PREFERRED_BSSID"
  printf '%s\n' "Durations: current=${STABILITY_SECONDS}s auto=${AB_SECONDS}s pinned=${AB_SECONDS}s interval=${SAMPLE_INTERVAL}s"
  printf '%s' "Type YES to continue: "
  read -r answer
  if [ "$answer" != "YES" ]; then
    printf '%s\n' "Cancelled."
    exit 1
  fi
  CONFIRM_IWD_TEST=YES
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

if is_interactive && [ "$IWD_MODE_EXPLICIT" -ne 1 ]; then
  prompt_test_mode
fi
set_duration_defaults
validate_positive_int "STABILITY_SECONDS" "$STABILITY_SECONDS"
validate_positive_int "AB_SECONDS" "$AB_SECONDS"
validate_positive_int "SAMPLE_INTERVAL" "$SAMPLE_INTERVAL"

ORIGINAL_BSSID="$(nm_connection_field_value "$SOURCE_CONNECTION_UUID" "$SOURCE_CONNECTION_NAME" 802-11-wireless.bssid | nm_unescape_colons)"
ORIGINAL_AUTOCONNECT="$(nm_connection_field_value "$SOURCE_CONNECTION_UUID" "$SOURCE_CONNECTION_NAME" connection.autoconnect)"
choose_preferred_bssid
if [ -z "$PREFERRED_BSSID" ]; then
  printf '%s\n' "Could not auto-detect a BSSID. Use --bssid <ap-bssid>." >&2
  exit 1
fi
confirm_iwd_test

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
printf '%s\n' "$ORIGINAL_BSSID" > "$BACKUP_DIR/original-bssid.txt"
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
