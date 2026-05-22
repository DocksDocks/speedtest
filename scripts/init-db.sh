#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sqlite.sh
. "$SCRIPT_DIR/lib/sqlite.sh"

DB_PATH="${1:-$(speedtest_default_db)}"

speedtest_init_schema "$DB_PATH"

printf '%s\n' "Initialized $DB_PATH"
