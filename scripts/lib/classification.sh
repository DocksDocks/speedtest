#!/usr/bin/env bash

classify_phase() {
  case "$1" in
    before-*) printf '%s\n' "before" ;;
    after-final-*) printf '%s\n' "after-final" ;;
    after-*) printf '%s\n' "after" ;;
    current-*) printf '%s\n' "current" ;;
    optimize-*) printf '%s\n' "optimize" ;;
    rollback-*) printf '%s\n' "rollback" ;;
    *) printf '%s\n' "" ;;
  esac
}

classify_kind() {
  case "$1" in
    *speedtest*) printf '%s\n' "speedtest" ;;
    *ping*) printf '%s\n' "ping" ;;
    *mtr*) printf '%s\n' "mtr" ;;
    *dns*) printf '%s\n' "dns" ;;
    *tracepath*|*mtu*) printf '%s\n' "mtu" ;;
    *wifi*|*wireless*|*bssid*|*wavemon*|*iperf3*|*flent*|*netperf*|*iwd*|*iw-*) printf '%s\n' "wifi" ;;
    *resolvectl*) printf '%s\n' "resolver" ;;
    *avahi*|*mdns*) printf '%s\n' "mdns" ;;
    *.html) printf '%s\n' "html" ;;
    *.md) printf '%s\n' "summary" ;;
    *.sql) printf '%s\n' "sql" ;;
    *) printf '%s\n' "log" ;;
  esac
}

classify_log() {
  local name="$1"

  LOG_SECTION_KEY="uncategorized"
  LOG_SIGNAL_TYPE="raw"
  LOG_SOURCE_TOOL="unknown"
  LOG_TARGET=""
  LOG_DISPLAY_LABEL="$name"
  LOG_DISPLAY_ORDER=900
  LOG_IS_PRIMARY=0

  case "$name" in
    *speedtest-cli*) _log_class "speed" "throughput" "speedtest-cli" "" "Speedtest throughput" 10 1 ;;
    *service-ping*) _log_class "service" "service_ping" "ping" "chatgpt.com claude.ai api.openai.com api.anthropic.com" "Service ping: ChatGPT, Claude, OpenAI API, Anthropic API" 10 1 ;;
    *service-dns*) _log_class "service" "service_dns" "dig" "chatgpt.com claude.ai api.openai.com api.anthropic.com" "Service DNS: ChatGPT, Claude, OpenAI API, Anthropic API" 20 1 ;;
    *service-https*) _log_class "service" "service_https" "curl" "chatgpt.com claude.ai api.openai.com api.anthropic.com" "Service HTTPS timing: ChatGPT, Claude, OpenAI API, Anthropic API" 30 1 ;;
    *dns-benchmark*) _log_class "dns" "dns_benchmark" "dig" "public resolvers" "DNS resolver benchmark" 10 1 ;;
    *resolvectl-status*|*resolvectl*|*resolver*) _log_class "dns" "resolver_state" "resolvectl" "systemd-resolved" "Resolver state" 20 0 ;;
    *ping-gateway*) _log_class "latency" "icmp_ping" "ping" "gateway" "Gateway latency" 10 1 ;;
    *ping-1.1.1.1*) _log_class "latency" "icmp_ping" "ping" "1.1.1.1" "1.1.1.1 latency" 20 1 ;;
    *ping-8.8.8.8*) _log_class "latency" "icmp_ping" "ping" "8.8.8.8" "8.8.8.8 latency" 30 1 ;;
    *ping-google.com*) _log_class "latency" "icmp_ping" "ping" "google.com" "google.com latency" 40 1 ;;
    *mtr-*) _log_class "latency" "route_loss" "mtr" "1.1.1.1" "Route loss and jitter" 50 1 ;;
    *tracepath*) _log_class "mtu" "path_mtu" "tracepath" "1.1.1.1" "Path MTU discovery" 10 1 ;;
    *mtu-ping*) _log_class "mtu" "df_ping" "ping" "1.1.1.1" "DF ping MTU validation" 20 1 ;;
    *wifi-list*|*bssid-wifi-list*) _log_class "wifi" "wifi_scan" "nmcli" "access points" "Wi-Fi access point scan" 10 1 ;;
    *wifi-stability*|*bssid-ab*) _log_class "wifi" "wifi_stability" "iw/nmcli" "wifi interface" "Wi-Fi stability and BSSID A/B samples" 12 1 ;;
    *wifi-tool-tests*|*wifi-tools*|*wavemon*|*iperf3*|*flent*|*netperf*|*iwd*|*iw-link*|*iw-station*|*iw-survey*|*iw-dev*) _log_class "wifi" "wifi_tool_test" "mixed" "wifi interface" "Wi-Fi diagnostic tool output" 14 1 ;;
    *proc-net-wireless*) _log_class "wifi" "wifi_signal" "procfs" "wifi interface" "Kernel Wi-Fi signal sample" 20 1 ;;
    *profile-safe-fields*|*connection-safe-fields*) _log_class "wifi" "wifi_profile" "nmcli" "Wi-Fi connection" "Wi-Fi profile safe fields" 30 0 ;;
    *device-safe-fields*|*safe-device-show*) _log_class "system" "interface_state" "nmcli" "wifi interface" "Active interface state" 20 0 ;;
    *avahi*|*mdns*) _log_class "mdns" "mdns_state" "systemctl" "avahi-daemon" "Avahi/mDNS state" 10 1 ;;
    *state-capture*) _log_class "system" "state_capture" "mixed" "host network" "Combined state capture" 10 1 ;;
    *ip-route*) _log_class "system" "routes" "ip" "routing table" "IP route table" 30 0 ;;
    *ip-addr*) _log_class "system" "addresses" "ip" "interfaces" "IP addresses" 40 0 ;;
    *nmcli-devices*|*nmcli-active-connections*) _log_class "system" "networkmanager_state" "nmcli" "NetworkManager" "NetworkManager state" 50 0 ;;
    *nmcli-permissions*) _log_class "system" "networkmanager_permissions" "nmcli" "NetworkManager" "NetworkManager permissions" 55 0 ;;
    *nmcli-man*|*nm-settings-nmcli-man*) _log_class "system" "local_documentation" "man" "NetworkManager" "Local NetworkManager documentation" 70 0 ;;
    *system-uname*|*networkmanager-version*|*tool-availability*|*working-directory*|*run-start-date*|*which-tracepath*) _log_class "system" "environment" "shell" "host" "Environment metadata" 60 0 ;;
    *rescan-command*) _log_class "wifi" "wifi_rescan" "nmcli" "wifi interface" "Wi-Fi scan refresh command" 15 0 ;;
    *optimize-*|*apply-approved*|*rollback-*|*proposed-optimizations*) _log_class "actions" "action_log" "mixed" "network profile" "Optimization or rollback action log" 10 1 ;;
    *summary.md|*comparison.md|findings.md|report.html) _log_class "overview" "human_summary" "report" "run" "Human-readable summary/report" 10 1 ;;
    *.sql|*.log) _log_class "overview" "supporting_artifact" "sqlite/shell" "run" "Supporting generated artifact" 90 0 ;;
  esac
}

_log_class() {
  LOG_SECTION_KEY="$1"
  LOG_SIGNAL_TYPE="$2"
  LOG_SOURCE_TOOL="$3"
  LOG_TARGET="$4"
  LOG_DISPLAY_LABEL="$5"
  LOG_DISPLAY_ORDER="$6"
  LOG_IS_PRIMARY="$7"
}
