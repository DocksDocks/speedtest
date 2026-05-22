#!/usr/bin/env bash

if [ -z "${SPEEDTEST_ROOT_DIR:-}" ]; then
  SPEEDTEST_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

speedtest_root() {
  printf '%s\n' "$SPEEDTEST_ROOT_DIR"
}

speedtest_default_db() {
  printf '%s/logs/speedtest.sqlite\n' "$SPEEDTEST_ROOT_DIR"
}

speedtest_default_run_id() {
  date +%Y%m%d-%H%M%S
}

speedtest_default_run_dir() {
  local run_id="${RUN_ID:-$(speedtest_default_run_id)}"
  printf '%s/logs/%s\n' "$SPEEDTEST_ROOT_DIR" "$run_id"
}

speedtest_default_wifi_iface() {
  local route_iface
  route_iface="$(ip route 2>/dev/null | awk '/^default / {for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
  if [ -n "$route_iface" ]; then
    printf '%s\n' "$route_iface"
    return
  fi

  nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null |
    awk -F: '$2 == "wifi" && $3 == "connected" {print $1; exit}'
}

speedtest_default_connection_name() {
  nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null |
    awk -F: '$2 == "802-11-wireless" {print $1; exit}'
}

speedtest_sqlite_bin() {
  if [ -n "${SQLITE_BIN:-}" ]; then
    printf '%s\n' "$SQLITE_BIN"
    return
  fi

  if command -v sqlite3 >/dev/null 2>&1; then
    command -v sqlite3
    return
  fi

  printf '%s\n' "sqlite3"
}
