#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/path.sh
. "$SCRIPT_DIR/lib/path.sh"

RUN_ID="${1:-}"
DB_PATH="${2:-$(speedtest_default_db)}"
OUT_PATH="${3:-$(speedtest_root)/data/report.sqlite}"

"$SCRIPT_DIR/publish-report-db.sh" "$DB_PATH" "$OUT_PATH"

if [ -n "$RUN_ID" ]; then
  printf '%s\n' "Open http://127.0.0.1:8765/?run=$RUN_ID after starting scripts/serve-report.sh"
else
  printf '%s\n' "Open http://127.0.0.1:8765/ after starting scripts/serve-report.sh"
fi
