#!/usr/bin/env bash
# lib/log.sh

set -euo pipefail
IFS=$'\n\t'

#__ANSI_COLOUR_CODES__#
#BLACK='\033[0;30m'
#RED='\033[0;31m'
#LIGHTGREEN='\033[1;32m'
#GREEN='\033[0;32m'
#ORANGE='\033[0;33m'
#YELLOW='\033[1;33m'
#BLUE='\033[0;34m'
#LIGHTBLUE='\033[1;34m'
#PURPLE='\033[0;35m'
#LIGHTPURPLE='\033[1;35m'
#CYAN='\033[0;36m'
#LIGHTCYAN='\033[1;36m'
#LIGHTGRAY='\033[0;37m'
#WHITE='\033[1;37m'
#DARKGREY='\033[1;30m'
#LIGHTRED='\033[1;31m'
#RESET='\033[0m'

#__TPUT_COLOUR_ANSI_FALLBACK__#
if command -v tput &>/dev/null && [[ "$(tput colors)" -ge 8 ]]; then
  COLOR_BLACK="$(tput setaf 0)";  COLOR_RED="$(tput setaf 1)"
  COLOR_GREEN="$(tput setaf 2)";  COLOR_YELLOW="$(tput setaf 3)"
  COLOR_BLUE="$(tput setaf 4)";   COLOR_MAGENTA="$(tput setaf 5)"
  COLOR_CYAN="$(tput setaf 6)";   COLOR_WHITE="$(tput setaf 7)"
  BG_BLACK="$(tput setab 0)";     BG_RED="$(tput setab 1)"
  BG_GREEN="$(tput setab 2)";     BG_YELLOW="$(tput setab 3)"
  BG_BLUE="$(tput setab 4)";      BG_MAGENTA="$(tput setab 5)"
  BG_CYAN="$(tput setab 6)";      BG_WHITE="$(tput setab 7)"
  COLOR_RESET="$(tput sgr0)"
else
  COLOR_BLACK='\033[0;30m';  COLOR_RED='\033[0;31m'
  COLOR_GREEN='\033[0;32m';  COLOR_YELLOW='\033[1;33m'
  COLOR_BLUE='\033[0;34m';   COLOR_MAGENTA='\033[0;35m'
  COLOR_CYAN='\033[0;36m';   COLOR_WHITE='\033[1;37m'
  BG_BLACK='\033[40m';       BG_RED='\033[41m'
  BG_GREEN='\033[42m';       BG_YELLOW='\033[43m'
  BG_BLUE='\033[44m';        BG_MAGENTA='\033[45m'
  BG_CYAN='\033[46m';        BG_WHITE='\033[47m'
  COLOR_RESET='\033[0m'
fi

# 0=ERROR, 1=WARNING, 2=INFO, 3=DEBUG
: "${LOG_LEVEL:=2}"

LOG_COLOR_ERROR="$COLOR_RED"
LOG_COLOR_WARN="$COLOR_YELLOW"
LOG_COLOR_INFO="$COLOR_GREEN"
LOG_COLOR_DEBUG="$COLOR_BLUE"

#__Prevent_double_sourcing__#
if [[ -n "${__LOG_SH_LOADED:-}" ]]; then
  return
fi
readonly __LOG_SH_LOADED=1

#__Core log(): timestamp (default), [LABEL] (colored), message (default)__#
log() {
  local level="${1:?level missing}"
  local label="${2:?label missing}"
  local color="${3:-}"
  shift 3

  if (( level <= LOG_LEVEL )); then
    local ts; ts="$(date +'%Y-%m-%dT%H:%M:%S%:z')"
    # %s = plain timestamp, [%bLABEL%b] = colored label, %s = plain message
    printf '%s [%b%s%b] %s\n' \
      "$ts" "$color" "$label" "$COLOR_RESET" "$*" >&2
  fi
}

error() { log 0 ERROR   "$LOG_COLOR_ERROR" "$*"; exit 1; }
warn()  { log 1 WARNING "$LOG_COLOR_WARN"  "$*"; }
info()  { log 2 INFO    "$LOG_COLOR_INFO"  "$*"; }
debug() { log 3 DEBUG   "$LOG_COLOR_DEBUG" "$*"; }

#__custom_log: arbitrary label + fg/bg color__#
#    Usage: custom_log LABEL FG_COLOR_VAR [BG_COLOR_VAR] <message…>
custom_log() {
  local label="${1:?custom label missing}"
  local fg="${2:?fg color var missing}"; shift 2
  local bg=""
  # if next arg is a known BG_* var, use it
  if [[ ${!1+isset} && $1 == BG_* ]]; then
    bg="${!1}"; shift
  fi
  # rest is the message
  local msg="$*"
  log 2 "$label" "${!fg}${bg}" "$msg"
}

#__color_print: wrap ANY text in any fg/bg__#
#    Usage: color_print FG_COLOR_VAR [BG_COLOR_VAR] <text…>
color_print() {
  local fg="${1:?fg color var missing}"; shift
  local bg=""
  if [[ ${!1+isset} && $1 == BG_* ]]; then
    bg="${!1}"; shift
  fi
  local txt="$*"
  printf '%b%s%b\n' "${!fg}${bg}" "$txt" "$COLOR_RESET"
}

print_palette() {
  local palette=( \
    COLOR_BLACK COLOR_RED COLOR_GREEN COLOR_YELLOW \
    COLOR_BLUE COLOR_MAGENTA COLOR_CYAN COLOR_WHITE \
  )
  for var in "${palette[@]}"; do
    local code="${!var}"
    printf '%b%s%b\n' "$code" "$var" "$COLOR_RESET"
  done
}
