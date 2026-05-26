#!/usr/bin/env bash

if [ -z "${SPEEDTEST_WARNINGS_SH:-}" ]; then
  SPEEDTEST_WARNINGS_SH=1

  WARNINGS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib/colors.sh
  . "$WARNINGS_LIB_DIR/colors.sh"

  speedtest_command_available() {
    local command_name="${1:-}"

    if [ -z "$command_name" ]; then
      return 1
    fi
    command -v "$command_name" >/dev/null 2>&1 || [ -x "$command_name" ]
  }

  speedtest_install_hint_for_command() {
    local command_name="${1:-}"
    local command_base

    command_base="$(basename "$command_name")"
    case "$command_base" in
      sqlite3)
        printf '%s\n' "sudo apt install sqlite3"
        ;;
      speedtest|speedtest-cli)
        printf '%s\n' "sudo apt install speedtest-cli"
        ;;
      dig)
        printf '%s\n' "sudo apt install bind9-dnsutils"
        ;;
      ping)
        printf '%s\n' "sudo apt install iputils-ping"
        ;;
      tracepath)
        printf '%s\n' "sudo apt install iputils-tracepath"
        ;;
      mtr)
        printf '%s\n' "sudo apt install mtr-tiny"
        ;;
      nmcli|NetworkManager)
        printf '%s\n' "sudo apt install network-manager"
        ;;
      iw)
        printf '%s\n' "sudo apt install iw"
        ;;
      iwctl|iwd)
        printf '%s\n' "sudo apt install iwd"
        ;;
      wavemon)
        printf '%s\n' "sudo apt install wavemon"
        ;;
      iperf3)
        printf '%s\n' "sudo apt install iperf3"
        ;;
      flent)
        printf '%s\n' "sudo apt install flent"
        ;;
      netperf)
        printf '%s\n' "sudo apt install netperf"
        ;;
      resolvectl|systemctl)
        printf '%s\n' "sudo apt install systemd"
        ;;
      python3)
        printf '%s\n' "sudo apt install python3"
        ;;
    esac
  }

  speedtest_warn_missing_commands() {
    local command_name
    local install_hint
    local install_hints
    local missing_without_hint=0

    ui_error "Missing required commands for this script:"
    for command_name in "$@"; do
      printf '  - %s\n' "$command_name" >&2
    done

    install_hints=""
    for command_name in "$@"; do
      install_hint="$(speedtest_install_hint_for_command "$command_name")"
      if [ -z "$install_hint" ]; then
        missing_without_hint=1
        continue
      fi

      case "
$install_hints
" in
        *"
$install_hint
"*)
          ;;
        *)
          install_hints="${install_hints}${install_hint}
"
          ;;
      esac
    done

    if [ -n "$install_hints" ]; then
      ui_info "Install missing packages with:"
      while IFS= read -r install_hint; do
        if [ -n "$install_hint" ]; then
          ui_command_hint "$install_hint"
        fi
      done <<EOF
$install_hints
EOF
    fi

    if [ "$missing_without_hint" -eq 1 ]; then
      ui_info "Install the packages that provide the remaining missing commands, then rerun this script."
    fi
  }

  speedtest_warn_missing_command() {
    speedtest_warn_missing_commands "$1"
  }

  speedtest_require_command() {
    local command_name="${1:-}"

    if speedtest_command_available "$command_name"; then
      return 0
    fi

    speedtest_warn_missing_command "$command_name"
    return 1
  }

  speedtest_require_commands() {
    local missing=()
    local command_name

    for command_name in "$@"; do
      if ! speedtest_command_available "$command_name"; then
        missing+=("$command_name")
      fi
    done

    if [ "${#missing[@]}" -ne 0 ]; then
      speedtest_warn_missing_commands "${missing[@]}"
      return 1
    fi

    return 0
  }
fi
