#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sqlite.sh
. "$SCRIPT_DIR/lib/sqlite.sh"
# shellcheck source=lib/classification.sh
. "$SCRIPT_DIR/lib/classification.sh"

RUN_DIR="${1:-$(speedtest_default_run_dir)}"
DB_PATH="${2:-$(speedtest_default_db)}"

if [ ! -d "$RUN_DIR" ]; then
  printf '%s\n' "Run directory not found: $RUN_DIR" >&2
  exit 1
fi

speedtest_init_schema "$DB_PATH"

run_id="$(basename "$RUN_DIR")"
started_at="unknown"
if [ -f "$RUN_DIR/run-start-date.txt" ]; then
  started_at="$(tr '\n' ' ' < "$RUN_DIR/run-start-date.txt" | sed 's/[[:space:]]*$//')"
fi

sqlite_exec "$DB_PATH" "
INSERT OR IGNORE INTO runs (run_id, started_at, run_dir, notes)
VALUES ('$(sql_quote "$run_id")', '$(sql_quote "$started_at")', '$(sql_quote "$RUN_DIR")', 'ingested from raw log directory');
"

count=0
while IFS= read -r file; do
  base="$(basename "$file")"
  case "$base" in
    *.sqlite|*.sqlite-*|*.db|*.db-*) continue ;;
  esac

  phase="$(classify_phase "$base")"
  kind="$(classify_kind "$base")"
  classify_log "$base"
  size="$(stat -c '%s' "$file")"
  sha=""
  if command -v sha256sum >/dev/null 2>&1; then
    sha="$(sha256sum "$file" | cut -d ' ' -f 1)"
  fi

  sqlite_exec "$DB_PATH" "
  INSERT INTO raw_logs (run_id, relative_path, kind, phase, content, size_bytes, sha256)
  VALUES (
    '$(sql_quote "$run_id")',
    '$(sql_quote "$base")',
    '$(sql_quote "$kind")',
    NULLIF('$(sql_quote "$phase")', ''),
    readfile('$(sql_quote "$file")'),
    $size,
    NULLIF('$(sql_quote "$sha")', '')
  )
  ON CONFLICT(run_id, relative_path) DO UPDATE SET
    kind = excluded.kind,
    phase = excluded.phase,
    content = excluded.content,
    size_bytes = excluded.size_bytes,
    sha256 = excluded.sha256,
    captured_at = CURRENT_TIMESTAMP;
  "

  sqlite_exec "$DB_PATH" "
  INSERT INTO raw_log_classifications (
    raw_log_id,
    section_key,
    signal_type,
    source_tool,
    target,
    phase,
    display_label,
    display_order,
    is_primary
  )
  SELECT
    id,
    '$(sql_quote "$LOG_SECTION_KEY")',
    '$(sql_quote "$LOG_SIGNAL_TYPE")',
    '$(sql_quote "$LOG_SOURCE_TOOL")',
    NULLIF('$(sql_quote "$LOG_TARGET")', ''),
    NULLIF('$(sql_quote "$phase")', ''),
    '$(sql_quote "$LOG_DISPLAY_LABEL")',
    $LOG_DISPLAY_ORDER,
    $LOG_IS_PRIMARY
  FROM raw_logs
  WHERE run_id = '$(sql_quote "$run_id")'
    AND relative_path = '$(sql_quote "$base")'
  ON CONFLICT(raw_log_id) DO UPDATE SET
    section_key = excluded.section_key,
    signal_type = excluded.signal_type,
    source_tool = excluded.source_tool,
    target = excluded.target,
    phase = excluded.phase,
    display_label = excluded.display_label,
    display_order = excluded.display_order,
    is_primary = excluded.is_primary,
    updated_at = CURRENT_TIMESTAMP;
  "
  count=$((count + 1))
done < <(find "$RUN_DIR" -maxdepth 1 -type f | sort)

printf '%s\n' "Ingested $count files from $RUN_DIR into $DB_PATH"
