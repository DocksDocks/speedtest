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

  sqlite_add_column_if_missing "$db_path" "wifi_backend_tests" "base_run_id" "base_run_id TEXT REFERENCES runs(run_id) ON DELETE SET NULL"

  sqlite_exec "$db_path" "PRAGMA foreign_key_check; PRAGMA optimize;" >/dev/null
}
