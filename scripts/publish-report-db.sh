#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sqlite.sh
. "$SCRIPT_DIR/lib/sqlite.sh"

DB_PATH="${1:-$(speedtest_default_db)}"
OUT_PATH="${2:-$(speedtest_root)/data/report.sqlite}"

if [ ! -f "$DB_PATH" ]; then
  printf '%s\n' "Database not found: $DB_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_PATH")"

tmp_path="${OUT_PATH}.tmp.$$"
trap 'rm -f "$tmp_path" "$tmp_path-wal" "$tmp_path-shm"' EXIT

sqlite_exec "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA optimize;" >/dev/null

"$(speedtest_sqlite_bin)" \
  -batch \
  -bail \
  -cmd "PRAGMA foreign_keys = ON;" \
  -cmd ".timeout 5000" \
  "$DB_PATH" \
  "VACUUM INTO '$(sql_quote "$tmp_path")';" >/dev/null

"$(speedtest_sqlite_bin)" \
  -batch \
  -bail \
  -cmd ".timeout 5000" \
  "$tmp_path" \
  "PRAGMA journal_mode = DELETE; PRAGMA optimize;" >/dev/null

mv "$tmp_path" "$OUT_PATH"
chmod 600 "$OUT_PATH"

printf '%s\n' "Published browser-readable SQLite snapshot: $OUT_PATH"
