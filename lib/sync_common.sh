#!/bin/bash
# lib/sync_common.sh — shared helpers for Jellyfin media sync scripts
#
# PURPOSE
# Centralize SSH multiplexing, rsync tuning (LAN/WAN profiles), robust remote shell
# construction for rsync (-e), batch remote mkdir, and diagnostics. Both
# sync_movies.sh and sync_shows.sh source this file.
#
# REQUIREMENTS
# - bash 4+
# - rsync 3.1+ (3.2+ recommended for --compress-choice=zstd / --append-verify)
# - OpenSSH client with ControlMaster support

set -euo pipefail
IFS=$'\n\t'

# --- logging glue ---------------------------------------------------------
__sc_adapt_logging() {
  if ! declare -F log_info >/dev/null; then
    if declare -F info >/dev/null; then
      log_info(){ info "$@"; }
    else
      log_info(){ printf "[INFO] %s\n" "$*"; }
    fi

    if declare -F warn >/dev/null; then
      log_warn(){ warn "$@"; }
    else
      log_warn(){ printf "[WARN] %s\n" "$*"; }
    fi

    if declare -F error >/dev/null; then
      log_error(){ error "$@"; }
    else
      log_error(){ printf "[ERROR] %s\n" "$*"; }
    fi

    if declare -F success >/dev/null; then
      log_success(){ success "$@"; }
    else
      log_success(){ printf "[ OK ] %s\n" "$*"; }
    fi
  fi
}

# --- feature probe --------------------------------------------------------
sc_has_flag() {
  rsync --help 2>&1 | grep -q -- "$1"
}

# --- SSH / rsync setup ----------------------------------------------------
sc_build_ssh_opts() {
  local port="${1:?port}"
  local cipher="${2:-aes128-gcm@openssh.com}"

  CM_DIR="${CM_DIR:-$HOME/.ssh/cm}"
  mkdir -p "$CM_DIR"
  SOCK="${SOCK:-$CM_DIR/%C}"

  SSH_OPTS=(
    -p "$port"
    -o ControlMaster=auto
    -o ControlPersist=300
    -o ControlPath="$SOCK"
    -o ConnectTimeout=10
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
    -o Ciphers="$cipher"
  )
}

sc_build_rsync_remote_shell() {
  local parts=(ssh "${SSH_OPTS[@]}")
  local shell="${parts[0]}"

  local i
  for (( i=1; i<${#parts[@]}; i++ )); do
    shell+=" ${parts[i]}"
  done

  printf '%s' "$shell"
}

sc_ensure_mux() {
  # defensive: kill any stale master first
  ssh -O exit -o ControlPath="$SOCK" "$SSH_USER@$SSH_HOST" >/dev/null 2>&1 || true

  # check existing master
  if ssh "${SSH_OPTS[@]}" -O check "$SSH_USER@$SSH_HOST" >/dev/null 2>&1; then
    log_info "SSH mux: reusing existing master connection"
    return
  fi

  # prune old orphan sockets
  find "$CM_DIR" -maxdepth 1 -type s -mmin +120 -delete 2>/dev/null || true
  log_warn "SSH mux: starting a fresh master connection"

  ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$SSH_USER@$SSH_HOST" true >/dev/null 2>&1 || true
}

sc_close_mux() {
  ssh -O exit -o ControlPath="$SOCK" "$SSH_USER@$SSH_HOST" 2>/dev/null || true
}

sc_build_rsync_opts() {
  local profile="${1:-wan}"
  local comp_lvl="${2:-6}"
  local prealloc="${3:-0}"
  local dryrun="${4:-0}"

  RSYNC_BASE_OPTS=(
    -avh
    --ignore-existing
    --protect-args
    --progress
    --partial
  )

  if [[ "$profile" == "lan" ]]; then
    RSYNC_TUNE_OPTS=(--no-compress --whole-file)
  else
    if sc_has_flag 'compress-choice'; then
      RSYNC_TUNE_OPTS=(--compress --compress-choice=zstd --compress-level="$comp_lvl")
    else
      RSYNC_TUNE_OPTS=(--compress)
    fi

    # avoid compressing already compressed media/content
    RSYNC_TUNE_OPTS+=(--skip-compress=3gp/7z/avi/bz2,deb,dmg,flac,gz,iso,jpg,jpeg,m4a,m4v,mkv,mov,mp3,mp4,mpeg,mpg,ogg,png,rar,rpm,tbz,tgz,webm,wma,wmv,xz,zip)
  fi

  local use_append=0
  if sc_has_flag --append-verify; then
    RSYNC_TUNE_OPTS+=(--append-verify)
    use_append=1
  fi

  [[ "$prealloc" == "1" ]] && RSYNC_TUNE_OPTS+=(--preallocate)
  [[ "$dryrun" == "1" ]] && RSYNC_BASE_OPTS+=(-n)
  (( use_append )) || RSYNC_BASE_OPTS+=(--partial-dir=.rsync-partial)

  local remote_shell
  remote_shell="$(sc_build_rsync_remote_shell)"

  RSYNC_SSH=(-e "$remote_shell")
  RSYNC_OPTS=("${RSYNC_BASE_OPTS[@]}" "${RSYNC_TUNE_OPTS[@]}" "${RSYNC_SSH[@]}")
}

# --- convenience wrappers -------------------------------------------------
sc_rsync_copy() { # usage: sc_rsync_copy SRC DST_DIR
  rsync "${RSYNC_OPTS[@]}" -- "$1" "$SSH_USER@$SSH_HOST:$2/"
}

sc_batch_mkdir() { # usage: sc_batch_mkdir DIR1 DIR2 ...
  [[ $# -eq 0 ]] && return 0

  {
    for dir in "$@"; do
      printf '%s\0' "$dir"
    done
  } | ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "xargs -0 -I% mkdir -p '%'"
}

# --- diagnostics ----------------------------------------------------------
sc_time() { # usage: sc_time "label" cmd args...
  local label="$1"
  shift

  local start end rc
  start=$(date +%s)
  "$@"
  rc=$?
  end=$(date +%s)

  log_info "$label: $(( end - start ))s (rc=$rc)"
  return $rc
}

sc_trace_on()  { set -x; }
sc_trace_off() { set +x; }

sc_rsync_scan_benchmark() { # usage: sc_rsync_scan_benchmark SRC DST EXTRA_INCLUDES...
  local src="$1"
  local dst="$2"
  shift 2

  sc_time "Scan(dry-run)" rsync -n "${RSYNC_OPTS[@]}" "$@" -- \
    "$src"/ "$SSH_USER@$SSH_HOST:$dst"/ >/dev/null
}
