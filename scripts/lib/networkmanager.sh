#!/usr/bin/env bash

nm_active_wifi_connection_uuid() {
  nmcli -t --escape no -f UUID,TYPE connection show --active 2>/dev/null |
    awk -F: '$2 == "802-11-wireless" { print $1; exit }'
}

nm_connection_uuid_for_name() {
  local connection_name="${1:-}"
  if [ -z "$connection_name" ]; then
    return 1
  fi

  nmcli -g connection.uuid connection show id "$connection_name" 2>/dev/null | head -n 1
}

nm_connection_name_for_uuid() {
  local connection_uuid="${1:-}"
  if [ -z "$connection_uuid" ]; then
    return 1
  fi

  nmcli -g connection.id connection show uuid "$connection_uuid" 2>/dev/null | head -n 1
}

nm_connection_field_value() {
  local connection_uuid="${1:-}"
  local connection_name="${2:-}"
  local field_name="${3:-}"

  if [ -z "$field_name" ]; then
    return 1
  fi

  if [ -n "$connection_uuid" ]; then
    nmcli -g "$field_name" connection show uuid "$connection_uuid" 2>/dev/null | head -n 1
  elif [ -n "$connection_name" ]; then
    nmcli -g "$field_name" connection show id "$connection_name" 2>/dev/null | head -n 1
  else
    return 1
  fi
}

nm_connection_modify() {
  local connection_uuid="${1:-}"
  local connection_name="${2:-}"
  shift 2

  if [ -n "$connection_uuid" ]; then
    nmcli connection modify uuid "$connection_uuid" "$@"
  elif [ -n "$connection_name" ]; then
    nmcli connection modify id "$connection_name" "$@"
  else
    return 1
  fi
}

nm_connection_up() {
  local connection_uuid="${1:-}"
  local connection_name="${2:-}"
  local iface="${3:-}"
  local bssid="${4:-}"
  local cmd=(nmcli connection up)

  if [ -n "$connection_uuid" ]; then
    cmd+=(uuid "$connection_uuid")
  elif [ -n "$connection_name" ]; then
    cmd+=(id "$connection_name")
  else
    return 1
  fi

  if [ -n "$iface" ]; then
    cmd+=(ifname "$iface")
  fi

  if [ -n "$bssid" ]; then
    cmd+=(ap "$bssid")
  fi

  "${cmd[@]}"
}

nm_unescape_colons() {
  sed 's/\\:/:/g'
}
