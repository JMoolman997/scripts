# lib/cmd_utils.sh — lightweight command helpers
#
# These helpers are intentionally dependency-free so that other libraries can
# source them without bringing in heavier logging layers.  Each function is
# exported so that scripts executed via `bash -c` can re-use them.

# Return 0 when the provided command exists in PATH.
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Execute the given command via sudo only when not already running as root.
# Tests can force the non-root branch by exporting SC_CMD_UTILS_EUID_OVERRIDE.
sudo_if_needed() {
  local effective_euid="${SC_CMD_UTILS_EUID_OVERRIDE:-$EUID}"

  if [[ $effective_euid -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

export -f command_exists sudo_if_needed
