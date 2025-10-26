# lib/file_utils.sh — idempotent file helpers
#
# These utilities provide safe backups before overwriting files and create
# symlinks with minimal surprises.  They only rely on optional logging helpers
# and otherwise fall back to simple printf statements.

if [[ -z "${__FILE_UTILS_SH_SOURCED:-}" ]]; then
  readonly __FILE_UTILS_SH_SOURCED=1

  __file_utils_bind_logging() {
    if ! declare -F log_info >/dev/null; then
      if declare -F info >/dev/null; then
        log_info(){ info "$@"; }
      else
        log_info(){ printf '[INFO] %s\n' "$*"; }
      fi
    fi
  }

  __file_utils_bind_logging
fi

# Create a timestamped backup of a file (or symlink) if it exists.
backup_file() {
  local file="${1:?path required}"
  local bdir="$HOME/.backup-$(date +%Y%m%d-%H%M%S)"

  [[ -f "$file" || -L "$file" ]] || return 0

  mkdir -p "$bdir"
  cp -a "$file" "$bdir/"
  log_info "Backed up $file → $bdir"
}

# Create/refresh a symbolic link after backing up the destination.
symlink() {
  local src="${1:?source required}"
  local dest="${2:?destination required}"

  backup_file "$dest"
  ln -sfn "$src" "$dest"
  log_info "Linked $dest → $src"
}

export -f backup_file symlink
