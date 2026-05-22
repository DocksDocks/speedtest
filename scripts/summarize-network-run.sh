#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sqlite.sh
. "$SCRIPT_DIR/lib/sqlite.sh"

PHASE="${1:-after}"
RUN_DIR="${2:-$(speedtest_default_run_dir)}"
DB_PATH="${DB_PATH:-$(speedtest_default_db)}"
SQLITE_BIN="${SQLITE_BIN:-$(speedtest_sqlite_bin)}"
RUN_ID="$(basename "$RUN_DIR")"
GATEWAY_TARGET="${GATEWAY_TARGET:-gateway}"

summary_file="$RUN_DIR/${PHASE}-summary.md"
sql_file="$RUN_DIR/${PHASE}-sqlite-update.sql"

extract_speed_value() {
  local label="$1"
  local file="$2"
  awk -F'[: ]+' -v label="$label" '$1 == label {print $2; exit}' "$file" 2>/dev/null
}

extract_ping_stat() {
  local field="$1"
  local file="$2"
  awk -v field="$field" '
    /packets transmitted/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /%/ && $(i + 1) == "packet" && $(i + 2) == "loss,") {
          gsub(/%/, "", $i)
          loss = $i
        }
      }
    }
    /^rtt / {
      split($4, values, "/")
      avg = values[2]
      max = values[3]
    }
    END {
      if (field == "loss") print loss
      if (field == "avg") print avg
      if (field == "max") print max
    }
  ' "$file" 2>/dev/null
}

extract_dns_avg() {
  local resolver="$1"
  local file="$2"
  awk -v resolver="$resolver" '
    $0 == "===== DNS " resolver " =====" {
      in_resolver = 1
      next
    }
    /^===== DNS / && in_resolver {
      in_resolver = 0
    }
    in_resolver && /;; Query time:/ {
      total += $4
      count += 1
    }
    END {
      if (count > 0) printf "%.3f\n", total / count
    }
  ' "$file" 2>/dev/null
}

sql_string() {
  printf "%s" "$1" | sed "s/'/''/g"
}

speed_file="$RUN_DIR/${PHASE}-speedtest-cli.txt"
dns_file="$RUN_DIR/${PHASE}-dns-benchmark.txt"

speed_ping="$(extract_speed_value Ping "$speed_file")"
download="$(extract_speed_value Download "$speed_file")"
upload="$(extract_speed_value Upload "$speed_file")"

{
  printf '# %s Network Summary\n\n' "$PHASE"
  printf 'Run directory: `%s`\n\n' "$RUN_DIR"
  printf '## Speed Test\n\n'
  printf -- '- Ping: `%s ms`\n' "${speed_ping:-unknown}"
  printf -- '- Download: `%s Mbit/s`\n' "${download:-unknown}"
  printf -- '- Upload: `%s Mbit/s`\n\n' "${upload:-unknown}"
  printf '## Latency\n\n'
  printf '| Target | Loss | Avg | Max | Source |\n'
  printf '| --- | ---: | ---: | ---: | --- |\n'
} > "$summary_file"

{
  printf 'PRAGMA foreign_keys = ON;\n\n'
  printf "DELETE FROM speed_tests WHERE run_id = '%s' AND phase = '%s';\n" "$(sql_string "$RUN_ID")" "$(sql_string "$PHASE")"
  if [ -n "${speed_ping:-}" ] || [ -n "${download:-}" ] || [ -n "${upload:-}" ]; then
    printf "INSERT INTO speed_tests (run_id, phase, ping_ms, download_mbps, upload_mbps, source_file) VALUES ('%s', '%s', %s, %s, %s, '%s');\n" \
      "$(sql_string "$RUN_ID")" \
      "$(sql_string "$PHASE")" \
      "${speed_ping:-NULL}" \
      "${download:-NULL}" \
      "${upload:-NULL}" \
      "$(sql_string "$(basename "$speed_file")")"
  fi
} > "$sql_file"

for item in \
  "$GATEWAY_TARGET|$RUN_DIR/${PHASE}-ping-gateway.txt" \
  "1.1.1.1|$RUN_DIR/${PHASE}-ping-1.1.1.1.txt" \
  "8.8.8.8|$RUN_DIR/${PHASE}-ping-8.8.8.8.txt" \
  "google.com|$RUN_DIR/${PHASE}-ping-google.com.txt"
do
  target="${item%%|*}"
  file="${item#*|}"
  loss="$(extract_ping_stat loss "$file")"
  avg="$(extract_ping_stat avg "$file")"
  max="$(extract_ping_stat max "$file")"
  printf '| %s | %s%% | %s ms | %s ms | `%s` |\n' "$target" "${loss:-unknown}" "${avg:-unknown}" "${max:-unknown}" "$(basename "$file")" >> "$summary_file"
  printf "DELETE FROM latency_tests WHERE run_id = '%s' AND phase = '%s' AND target = '%s';\n" "$(sql_string "$RUN_ID")" "$(sql_string "$PHASE")" "$(sql_string "$target")" >> "$sql_file"
  if [ "$target" = "$GATEWAY_TARGET" ]; then
    printf "DELETE FROM latency_tests WHERE run_id = '%s' AND phase = '%s' AND target = 'gateway';\n" "$(sql_string "$RUN_ID")" "$(sql_string "$PHASE")" >> "$sql_file"
  fi
  if [ -n "${loss:-}" ] || [ -n "${avg:-}" ] || [ -n "${max:-}" ]; then
    printf "INSERT INTO latency_tests (run_id, phase, target, packet_loss_percent, avg_ms, max_ms, source_file) VALUES ('%s', '%s', '%s', %s, %s, %s, '%s');\n" \
      "$(sql_string "$RUN_ID")" \
      "$(sql_string "$PHASE")" \
      "$(sql_string "$target")" \
      "${loss:-NULL}" \
      "${avg:-NULL}" \
      "${max:-NULL}" \
      "$(sql_string "$(basename "$file")")" >> "$sql_file"
  fi
done

{
  printf '\n## DNS Benchmark\n\n'
  printf '| Resolver | Avg Query Time | Source |\n'
  printf '| --- | ---: | --- |\n'
} >> "$summary_file"

printf "DELETE FROM dns_benchmarks WHERE run_id = '%s' AND phase = '%s';\n" "$(sql_string "$RUN_ID")" "$(sql_string "$PHASE")" >> "$sql_file"
for resolver in 208.67.222.222 208.67.220.220 1.1.1.1 8.8.8.8 9.9.9.9; do
  dns_avg="$(extract_dns_avg "$resolver" "$dns_file")"
  printf '| %s | %s ms | `%s` |\n' "$resolver" "${dns_avg:-unknown}" "$(basename "$dns_file")" >> "$summary_file"
  if [ -n "${dns_avg:-}" ]; then
    printf "INSERT INTO dns_benchmarks (run_id, phase, resolver, avg_query_ms, source_file) VALUES ('%s', '%s', '%s', %s, '%s');\n" \
      "$(sql_string "$RUN_ID")" \
      "$(sql_string "$PHASE")" \
      "$(sql_string "$resolver")" \
      "$dns_avg" \
      "$(sql_string "$(basename "$dns_file")")" >> "$sql_file"
  fi
done

{
  printf '\n## Notes\n\n'
  printf -- '- Summary generated at `%s`.\n' "$(date)"
  printf -- '- SQLite update SQL: `%s`.\n' "$sql_file"
} >> "$summary_file"

if { command -v "$SQLITE_BIN" >/dev/null 2>&1 || [ -x "$SQLITE_BIN" ]; } && [ -f "$DB_PATH" ]; then
  "$SQLITE_BIN" "$DB_PATH" < "$sql_file" > "$RUN_DIR/${PHASE}-sqlite-update.log" 2>&1
  sqlite_status=$?
else
  sqlite_status=127
  printf '%s\n' "SQLite binary or DB not found." > "$RUN_DIR/${PHASE}-sqlite-update.log"
fi

printf '%s\n' "Summary written to $summary_file"
printf '%s\n' "SQLite update SQL written to $sql_file"
printf '%s\n' "SQLite update status: $sqlite_status"
exit "$sqlite_status"
