#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=path.sh
. "$SCRIPT_LIB_DIR/path.sh"

sql_quote() {
  printf "%s" "$1" | sed "s/'/''/g"
}

sqlite_exec() {
  local db_path="$1"
  local sql="$2"
  "$(speedtest_sqlite_bin)" \
    -bail \
    -cmd "PRAGMA foreign_keys = ON;" \
    -cmd ".timeout 5000" \
    "$db_path" "$sql"
}

sqlite_scalar() {
  local db_path="$1"
  local sql="$2"
  "$(speedtest_sqlite_bin)" \
    -batch \
    -noheader \
    -cmd "PRAGMA foreign_keys = ON;" \
    -cmd ".timeout 5000" \
    "$db_path" "$sql"
}

sqlite_table_html() {
  local db_path="$1"
  local sql="$2"
  "$(speedtest_sqlite_bin)" \
    -batch \
    -header \
    -html \
    -cmd "PRAGMA foreign_keys = ON;" \
    -cmd ".timeout 5000" \
    "$db_path" "$sql"
}

sqlite_add_column_if_missing() {
  local db_path="$1"
  local table_name="$2"
  local column_name="$3"
  local column_definition="$4"
  local exists

  exists="$(sqlite_scalar "$db_path" "SELECT COUNT(*) FROM pragma_table_info('$(sql_quote "$table_name")') WHERE name = '$(sql_quote "$column_name")';")"
  if [ "$exists" = "0" ]; then
    sqlite_exec "$db_path" "ALTER TABLE $table_name ADD COLUMN $column_definition;" >/dev/null
  fi
}

speedtest_migrate_runs_table() {
  local db_path="$1"
  local legacy_not_null

  # Older databases created runs with NOT NULL report_path/connection_name/
  # gateway/mtu and no defaults; CREATE TABLE IF NOT EXISTS never migrates
  # them, which makes ingest's 4-column INSERT fail. Rebuild to the current
  # shape from db/schema/001_core.sql.
  legacy_not_null="$(sqlite_scalar "$db_path" "SELECT COUNT(*) FROM pragma_table_info('runs') WHERE name = 'report_path' AND \"notnull\" = 1;")"
  if [ "$legacy_not_null" = "0" ]; then
    return 0
  fi

  "$(speedtest_sqlite_bin)" \
    -batch \
    -bail \
    -cmd ".timeout 5000" \
    "$db_path" <<'SQL'
PRAGMA foreign_keys = OFF;
BEGIN IMMEDIATE;
CREATE TABLE runs_migrate_new (
  run_id TEXT PRIMARY KEY,
  started_at TEXT NOT NULL,
  run_dir TEXT NOT NULL,
  report_path TEXT,
  connection_name TEXT,
  interface_name TEXT,
  gateway TEXT,
  mtu INTEGER,
  approval_status TEXT NOT NULL DEFAULT 'not applied',
  notes TEXT NOT NULL DEFAULT ''
);
INSERT INTO runs_migrate_new (run_id, started_at, run_dir, report_path, connection_name, interface_name, gateway, mtu, approval_status, notes)
SELECT run_id, started_at, run_dir, report_path, connection_name, interface_name, gateway, mtu, approval_status, notes FROM runs;
DROP TABLE runs;
ALTER TABLE runs_migrate_new RENAME TO runs;
COMMIT;
PRAGMA foreign_keys = ON;
SQL
}

speedtest_init_schema() {
  local db_path="${1:-$(speedtest_default_db)}"
  local root
  root="$(speedtest_root)"

  mkdir -p "$(dirname "$db_path")"

  "$(speedtest_sqlite_bin)" \
    -batch \
    -bail \
    -cmd ".timeout 5000" \
    "$db_path" \
    "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;" >/dev/null

  for sql_file in "$root"/db/schema/*.sql "$root"/db/defaults/*.sql; do
    "$(speedtest_sqlite_bin)" \
      -batch \
      -bail \
      -cmd "PRAGMA foreign_keys = ON;" \
      -cmd ".timeout 5000" \
      "$db_path" < "$sql_file" >/dev/null
  done

  speedtest_migrate_runs_table "$db_path"

  sqlite_add_column_if_missing "$db_path" "wifi_backend_tests" "base_run_id" "base_run_id TEXT REFERENCES runs(run_id) ON DELETE SET NULL"
  sqlite_add_column_if_missing "$db_path" "wifi_backend_tests" "connection_uuid" "connection_uuid TEXT"
  sqlite_add_column_if_missing "$db_path" "wifi_backend_tests" "test_connection_name" "test_connection_name TEXT"
  sqlite_add_column_if_missing "$db_path" "wifi_backend_tests" "test_connection_uuid" "test_connection_uuid TEXT"

  sqlite_exec "$db_path" "PRAGMA foreign_key_check; PRAGMA optimize;" >/dev/null
}
