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

  sqlite_exec "$db_path" "PRAGMA foreign_key_check; PRAGMA optimize;" >/dev/null
}
