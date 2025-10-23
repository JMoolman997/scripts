# lib/sync_common.sh
set -euo pipefail
IFS=$'\n\t'

# -- logging glue (works even if log.sh missing) ---------------------------
__sc_adapt_logging() {
  if ! declare -F log_info >/dev/null; then
    if declare -F info >/dev/null;   then log_info(){ info "$@"; };   else log_info(){ printf "[INFO] %s\n" "$*"; }; fi
    if declare -F warn >/dev/null;   then log_warn(){ warn "$@"; };   else log_warn(){ printf "[WARN] %s\n" "$*"; }; fi
    if declare -F error >/dev/null;  then log_error(){ error "$@"; }; else log_error(){ printf "[ERROR] %s\n" "$*"; }; fi
    if declare -F success >/dev/null;then log_success(){ success "$@"; } else log_success(){ printf "[ OK ] %s\n" "$*"; }; fi
  fi
}

# -- feature probe ---------------------------------------------------------
sc_has_flag(){ rsync --help 2>&1 | grep -q -- "$1"; }

# -- SSH/rsync setup -------------------------------------------------------
sc_build_ssh_opts() {
  local port="${1:?}" cipher="${2:-aes128-gcm@openssh.com}"
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

# avoid IFS pitfalls when passing ssh to rsync -e
sc_build_rsync_remote_shell() {
  local parts=(ssh "${SSH_OPTS[@]}")
  printf '%s' "${parts[0]}"
  local i; for (( i=1; i<${#parts[@]}; i++ )); do printf ' %s' "${parts[i]}"; done
}

sc_ensure_mux() {
  # defensive: try to kill a stale master first
  ssh -O exit -o ControlPath="$SOCK" "$SSH_USER@$SSH_HOST" >/dev/null 2>&1 || true

  if ssh "${SSH_OPTS[@]}" -O check "$SSH_USER@$SSH_HOST" >/dev/null 2>&1; then
    log_info "SSH mux: reusing existing master connection"
    return
  fi
  find "$CM_DIR" -maxdepth 1 -type s -mmin +120 -delete 2>/dev/null || true
  log_warn "SSH mux: starting a fresh master connection"
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$SSH_USER@$SSH_HOST" true >/dev/null 2>&1 || true
}

sc_close_mux() {
  ssh -O exit -o ControlPath="$SOCK" "$SSH_USER@$SSH_HOST" 2>/dev/null || true
}

# -- rsync profiles and options -------------------------------------------
sc_build_rsync_opts() {
  local profile="${1:-wan}" comp_lvl="${2:-6}" prealloc="${3:-0}" dryrun="${4:-0}"
  RSYNC_BASE_OPTS=(-avh --ignore-existing --protect-args --progress --partial --partial-dir=.rsync-partial)
  if [[ "$profile" == "lan" ]]; then
    RSYNC_TUNE_OPTS=(--no-compress --whole-file)
  else
    if sc_has_flag 'compress-choice'; then
      RSYNC_TUNE_OPTS=(--compress --compress-choice=zstd --compress-level="$comp_lvl")
    else
      RSYNC_TUNE_OPTS=(--compress)
    fi
    # skip compressing already-compressed media
    RSYNC_TUNE_OPTS+=(--skip-compress=3gp/7z/avi/bz2,deb,dmg,flac,gz,iso,jpg,jpeg,m4a,m4v,mkv,mov,mp3,mp4,mpeg,mpg,ogg,png,rar,rpm,tbz,tgz,webm,wma,wmv,xz,zip)
  fi
  [[ "$prealloc" == "1" ]] && RSYNC_TUNE_OPTS+=(--preallocate)
  [[ "$dryrun" == "1"   ]] && RSYNC_BASE_OPTS+=(-n)
  sc_has_flag --append-verify && RSYNC_TUNE_OPTS+=(--append-verify)

  local remote_shell; remote_shell="$(sc_build_rsync_remote_shell)"
  RSYNC_SSH=(-e "$remote_shell")
  RSYNC_OPTS=("${RSYNC_BASE_OPTS[@]}" "${RSYNC_TUNE_OPTS[@]}" "${RSYNC_SSH[@]}")
}

# convenience wrappers
sc_rsync_copy() {  # usage: sc_rsync_copy SRC DST_DIR
  rsync "${RSYNC_OPTS[@]}" -- "$1" "$SSH_USER@$SSH_HOST:$2/"
}

sc_batch_mkdir() { # usage: sc_batch_mkdir DIR1 DIR2 ...
  [[ $# -eq 0 ]] && return 0
  { for d in "$@"; do printf '%s\0' "$d"; done; } |
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "xargs -0 -I% mkdir -p '%'"
}

# -- diagnostics -----------------------------------------------------------
sc_time() {  # usage: sc_time "label" cmd args...
  local lbl="$1"; shift
  local t0=$(date +%s); "$@"; local rc=$?; local t1=$(date +%s)
  log_info "$lbl: $((t1 - t0))s (rc=$rc)"; return $rc
}

sc_trace_on()  { set -x; }
sc_trace_off() { set +x; }

# optional dry-run scan benchmark
sc_rsync_scan_benchmark() { # usage: sc_rsync_scan_benchmark SRC DST EXTRA_INCLUDES...
  local src="$1" dst="$2"; shift 2
  sc_time "Scan(dry-run)" rsync -n "${RSYNC_OPTS[@]}" "$@" -- "$src"/ "$SSH_USER@$SSH_HOST:$dst"/ >/dev/null
}

