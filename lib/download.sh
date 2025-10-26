# lib/download.sh — helpers for fetching artifacts (curl, git, zip)
#
# The functions in this file prefer to degrade gracefully when the richer
# logging helpers from lib/log.sh are not present.  They surface errors via the
# shell's exit status so callers running with `set -e` will abort automatically.

if [[ -z "${__DOWNLOAD_SH_SOURCED:-}" ]]; then
  readonly __DOWNLOAD_SH_SOURCED=1

  __download_bind_logging() {
    if ! declare -F log_info >/dev/null; then
      if declare -F info >/dev/null; then
        log_info(){ info "$@"; }
      else
        log_info(){ printf '[INFO] %s\n' "$*"; }
      fi
    fi

    if ! declare -F log_error >/dev/null; then
      if declare -F error >/dev/null; then
        log_error(){ error "$@"; }
      else
        log_error(){ printf '[ERROR] %s\n' "$*" >&2; }
      fi
    fi
  }

  __download_bind_logging
fi

# Download a file with curl into the current directory (or a custom destination).
download_file() {
  local url="${1:?url required}"
  local dest="${2:-$(basename "$url")}"

  if curl -fL -o "$dest" "$url"; then
    log_info "Downloaded $url → $dest"
  else
    log_error "Download failed: $url"
    return 1
  fi
}

# Clone a git repository (or pull when the target already exists).
git_clone_or_pull() {
  local repo="${1:?repo required}"
  local dir="${2:?target directory required}"

  if [[ -d "$dir/.git" ]]; then
    if git -C "$dir" pull --ff-only; then
      log_info "Updated $dir from $repo"
    else
      log_error "Git pull failed in $dir"
      return 1
    fi
  else
    if git clone "$repo" "$dir"; then
      log_info "Cloned $repo → $dir"
    else
      log_error "Git clone failed: $repo"
      return 1
    fi
  fi
}

# Download a ZIP archive and extract it into the requested directory.
download_and_unzip() {
  local url="${1:?url required}"
  local dir="${2:?target directory required}"
  local zip="${url##*/}"

  mkdir -p "$dir"
  download_file "$url" "$zip" || return 1

  if unzip -o "$zip" -d "$dir" >/dev/null; then
    rm -f "$zip"
    log_info "Unzipped $url → $dir"
  else
    log_error "Unzip failed: $zip"
    rm -f "$zip"
    return 1
  fi
}

export -f download_file git_clone_or_pull download_and_unzip
