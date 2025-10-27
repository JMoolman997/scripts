#!/usr/bin/env bash
# lib/log.sh — structured logging helpers with colour fallbacks
#
# Exposes leveled logging (`error`, `warn`, `info`, `debug`) plus helpers for
# custom labels and palette dumps. Terminfo-driven colour codes are preferred
# when available; otherwise ANSI escape fallbacks are used so output remains
# readable on minimal consoles.
set -euo pipefail
[[ -n "${ZSH_VERSION:-}" ]] && setopt NULL_GLOB
IFS=$'\n\t'

# Colour palette initialisation (prefers terminfo, falls back to ANSI)
__LOG_TPUT_COLORS=0
if command -v tput >/dev/null 2>&1; then
  __LOG_TPUT_COLORS="$(tput colors 2>/dev/null || echo 0)"
fi

if (( __LOG_TPUT_COLORS >= 8 )); then
  # standard 8-colour foregrounds
  COLOR_BLACK="$(tput setaf 0)";   COLOR_RED="$(tput setaf 1)"
  COLOR_GREEN="$(tput setaf 2)";   COLOR_YELLOW="$(tput setaf 3)"
  COLOR_BLUE="$(tput setaf 4)";    COLOR_MAGENTA="$(tput setaf 5)"
  COLOR_CYAN="$(tput setaf 6)";    COLOR_WHITE="$(tput setaf 7)"

  # standard backgrounds
  BG_BLACK="$(tput setab 0)";      BG_RED="$(tput setab 1)"
  BG_GREEN="$(tput setab 2)";      BG_YELLOW="$(tput setab 3)"
  BG_BLUE="$(tput setab 4)";       BG_MAGENTA="$(tput setab 5)"
  BG_CYAN="$(tput setab 6)";       BG_WHITE="$(tput setab 7)"

  # populate 256-colour backgrounds when supported
  if (( __LOG_TPUT_COLORS >= 256 )); then
    bg_var=
    for n in {0..255}; do
      bg_var="BG_256_$n"
      printf -v "$bg_var" '%s' "$(tput setab "$n")"
    done
  fi

  COLOR_RESET="$(tput sgr0)"
else
  # ANSI fallback palette
  COLOR_BLACK='\033[0;30m'; COLOR_RED='\033[0;31m'
  COLOR_GREEN='\033[0;32m'; COLOR_YELLOW='\033[1;33m'
  COLOR_BLUE='\033[0;34m'; COLOR_MAGENTA='\033[0;35m'
  COLOR_CYAN='\033[0;36m'; COLOR_WHITE='\033[1;37m'

  BG_BLACK='\033[40m'; BG_RED='\033[41m'
  BG_GREEN='\033[42m'; BG_YELLOW='\033[43m'
  BG_BLUE='\033[44m'; BG_MAGENTA='\033[45m'
  BG_CYAN='\033[46m'; BG_WHITE='\033[47m'

  bg_var=
  for n in {0..255}; do
    bg_var="BG_256_$n"
    printf -v "$bg_var" '\033[48;5;%sm' "$n"
  done

  COLOR_RESET='\033[0m'
fi

# baseline style sequences (override with terminfo when available)
STYLE_BOLD='\033[1m'
STYLE_DIM='\033[2m'
STYLE_ITALIC='\033[3m'
STYLE_UNDERLINE='\033[4m'
STYLE_BLINK='\033[5m'
STYLE_REVERSE='\033[7m'
STYLE_CONCEAL='\033[8m'

if command -v tput >/dev/null 2>&1; then
  __log_set_style_cap() {
    local var="$1" cap="$2"
    local seq
    if seq="$(tput "$cap" 2>/dev/null)"; then
      printf -v "$var" '%s' "$seq"
    fi
  }
  __log_set_style_cap STYLE_BOLD bold
  __log_set_style_cap STYLE_DIM dim
  __log_set_style_cap STYLE_ITALIC sitm
  __log_set_style_cap STYLE_UNDERLINE smul
  __log_set_style_cap STYLE_BLINK blink
  __log_set_style_cap STYLE_REVERSE rev
  __log_set_style_cap STYLE_CONCEAL invis
  unset -f __log_set_style_cap
fi

STYLE_RESET="$COLOR_RESET"
unset -v __LOG_TPUT_COLORS || true

__log_getvar() {
  local name="${1:?variable name required}"
  if [[ -n "${BASH_VERSION:-}" ]]; then
    printf '%s' "${!name-}"
  else
    eval "printf '%s' \"\${${name}-}\""
  fi
}

# Log level & default colours
: "${LOG_LEVEL:=2}"      # 0=ERROR, 1=WARN, 2=INFO, 3=DEBUG

LOG_COLOR_ERROR="$COLOR_RED"
LOG_COLOR_WARN="$COLOR_YELLOW"
LOG_COLOR_INFO="$COLOR_GREEN"
LOG_COLOR_DEBUG="$COLOR_BLUE"

# Prevent double sourcing
if [[ -n "${__LOG_SH_LOADED:-}" ]]; then
  return
fi
readonly __LOG_SH_LOADED=1

# Core logging routine: log <level> <LABEL> <FULL_COLOUR_SEQ> <message…>
log() {
  local level="${1:?level missing}"
  local label="${2:?label missing}"
  local colour_seq="${3:-}"
  shift 3
  (( level <= LOG_LEVEL )) || return 0

  local ts; ts="$(date +'%Y-%m-%dT%H:%M:%S%:z')"
  printf '%s [%b%s%b] %s\n' \
	  "$ts" "$colour_seq" "$label" "$COLOR_RESET" "$*" >&2
}

# Convenience wrappers (foreground only)
error() { log 0 ERROR "$LOG_COLOR_ERROR" "$*"; exit 1; }
warn()  { log 1 WARNING "$LOG_COLOR_WARN"  "$*"; }
info()  { log 2 INFO    "$LOG_COLOR_INFO"  "$*"; }
debug() { log 3 DEBUG   "$LOG_COLOR_DEBUG" "$*"; }

# custom_log LABEL FG_VAR [BG_VAR] <message…>
custom_log() {
  local label="${1:?label missing}"
  local fg_var="${2:?fg var missing}"; shift 2
  local fg_seq bg_seq=""

  fg_seq="$(__log_getvar "$fg_var")"

  if [[ -n "${1:-}" && $1 == BG_* ]]; then
    bg_seq="$(__log_getvar "$1")"
    shift
  fi
  local style_seq=""
  while [[ -n "${1:-}" && $1 == STYLE_* ]]; do
    style_seq+="$(__log_getvar "$1")"
    shift
  done

  local full_seq="${fg_seq}${bg_seq}${style_seq}"
  log 2 "$label" "$full_seq" "$*"
}

# log_with_bg <level> <LABEL> <FG_VAR> <BG_VAR> <msg…>
log_with_bg() {
  local level="${1:?level missing}"
  local label="${2:?label missing}"
  local fg_var="${3:?fg var missing}"
  local bg_var="${4:?bg var missing}"
  shift 4
  local fg_seq bg_seq style_seq=""
  fg_seq="$(__log_getvar "$fg_var")"
  bg_seq="$(__log_getvar "$bg_var")"
  while [[ -n "${1:-}" && $1 == STYLE_* ]]; do
    style_seq+="$(__log_getvar "$1")"
    shift
  done
  local full_seq="${fg_seq}${bg_seq}${style_seq}"
  log "$level" "$label" "$full_seq" "$*"
}

# color_print FG_VAR [BG_VAR] <text…>
color_print() {
  local fg_var="${1:?fg var missing}"; shift
  local fg_seq bg_seq="" style_seq=""
  fg_seq="$(__log_getvar "$fg_var")"
  if [[ -n "${1:-}" && $1 == BG_* ]]; then
    bg_seq="$(__log_getvar "$1")"
    shift
  fi
  while [[ -n "${1:-}" && $1 == STYLE_* ]]; do
    style_seq+="$(__log_getvar "$1")"
    shift
  done
  printf '%b%s%b\n' "${fg_seq}${bg_seq}${style_seq}" "$*" "$COLOR_RESET"
}

# print_palette shows each named colour (foreground and background)
print_palette() {
  local fg_vars=( COLOR_BLACK COLOR_RED COLOR_GREEN COLOR_YELLOW \
                  COLOR_BLUE COLOR_MAGENTA COLOR_CYAN COLOR_WHITE )
  local bg_vars=( BG_BLACK BG_RED BG_GREEN BG_YELLOW \
                  BG_BLUE BG_MAGENTA BG_CYAN BG_WHITE )

  # 8-colour table
  for i in "${!fg_vars[@]}"; do
    local fg="${fg_vars[i]}"
    local bg="${bg_vars[i]}"
    local fg_seq bg_seq
    fg_seq="$(__log_getvar "$fg")"
    bg_seq="$(__log_getvar "$bg")"
    printf '%b%-12s%b  %b%-12s%b\n' \
      "${fg_seq}${bg_seq}" "$fg" "$COLOR_RESET" \
      "${bg_seq}${fg_seq}" "$bg" "$COLOR_RESET"
  done

  # sample useful 256-colour backgrounds when available
  if [[ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ]]; then
    echo "--- 256-colour sample (BG_256_n) ---"
    for n in 0 1 7 8 15 82 142 196 208 226; do
      local var; var=$(printf 'BG_256_%s' "$n")
      printf '%bBG_256_%-3s%b  ' "$(__log_getvar "$var")" "$n" "$COLOR_RESET"
    done
    echo
  fi
}
