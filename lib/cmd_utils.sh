# Command utilities

command_exists() { command -v "$1" >/dev/null 2>&1; }

sudo_if_needed() { [[ $EUID -eq 0 ]] && "$@" || sudo "$@"; }

export -f command_exists sudo_if_needed
