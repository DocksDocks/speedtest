#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sqlite.sh
. "$SCRIPT_LIB_DIR/sqlite.sh"

report_scalar() {
  sqlite_scalar "$1" "$2"
}

report_table_html() {
  sqlite_table_html "$1" "$2"
}
