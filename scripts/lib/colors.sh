#!/usr/bin/env bash

COLOR_RESET=""
COLOR_BOLD=""
COLOR_RED=""
COLOR_YELLOW=""
COLOR_CYAN=""
COLOR_GREEN=""

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  COLOR_RESET="$(printf '\033[0m')"
  COLOR_BOLD="$(printf '\033[1m')"
  COLOR_RED="$(printf '\033[31m')"
  COLOR_YELLOW="$(printf '\033[33m')"
  COLOR_CYAN="$(printf '\033[36m')"
  COLOR_GREEN="$(printf '\033[32m')"
fi

ui_error() {
  printf '%s%sERROR:%s %s\n' "$COLOR_BOLD" "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

ui_warn() {
  printf '%s%sWARN:%s %s\n' "$COLOR_BOLD" "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
}

ui_info() {
  printf '%s%sINFO:%s %s\n' "$COLOR_BOLD" "$COLOR_CYAN" "$COLOR_RESET" "$*" >&2
}

ui_success() {
  printf '%s%sOK:%s %s\n' "$COLOR_BOLD" "$COLOR_GREEN" "$COLOR_RESET" "$*" >&2
}

ui_command_hint() {
  printf '  %s%s%s\n' "$COLOR_CYAN" "$*" "$COLOR_RESET" >&2
}
