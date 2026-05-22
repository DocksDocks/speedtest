#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/path.sh
. "$SCRIPT_DIR/lib/path.sh"

PORT="${PORT:-8765}"
BIND="${BIND:-127.0.0.1}"

if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' "python3 is required to serve the report locally." >&2
  exit 1
fi

cd "$(speedtest_root)"
printf '%s\n' "Serving report at http://$BIND:$PORT/"
python3 -m http.server "$PORT" --bind "$BIND"
