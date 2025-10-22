#!/bin/bash
# sync_movies.sh — Fast movie sync for Jellyfin (+ external subs)
#
# Usage:
#   ./sync_movies.sh -h <host> [-u user] [-p port] [-l local_movies_dir] [-r remote_base_dir] [-n]
#
# Defaults (env or flags):
#   SSH_USER=${SSH_USER:-moolman840}
#   SSH_HOST=${SSH_HOST:-}             # required
#   SSH_PORT=${SSH_PORT:-2222}
#   LOCAL_MOVIES_DIR=${LOCAL_MOVIES_DIR:-$HOME/Videos/Movies}
#   REMOTE_BASE_PATH=${REMOTE_BASE_PATH:-/mnt/media}
#   SYNC_PROFILE=${SYNC_PROFILE:-wan}  # wan|lan
#   PREALLOCATE=${PREALLOCATE:-0}      # 1 to enable --preallocate
#   COMP_LEVEL=${COMP_LEVEL:-6}        # zstd level when SYNC_PROFILE=wan
#   DRY_RUN via -n flag
#
# Tip: cache your key passphrase first:
#   eval "$(ssh-agent -s)"; ssh-add ~/.ssh/id_ed25519

set -euo pipefail
IFS=$'\n\t'

# --- logging ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# load your logger
source "$SCRIPT_DIR/lib/log.sh" 2>/dev/null || true
# adapters/fallbacks if names differ or log.sh missing
if ! declare -F log_info >/dev/null; then
  if declare -F info >/dev/null;   then log_info(){ info "$@"; };   else log_info(){ printf "[INFO] %s\n" "$*"; }; fi
  if declare -F warn >/dev/null;   then log_warn(){ warn "$@"; };   else log_warn(){ printf "[WARN] %s\n" "$*"; }; fi
  if declare -F error >/dev/null;  then log_error(){ error "$@"; }; else log_error(){ printf "[ERROR] %s\n" "$*"; }; fi
  if declare -F success >/dev/null;then log_success(){ success "$@"; } else log_success(){ printf "[ OK ] %s\n" "$*"; }; fi
fi

# --- config ---------------------------------------------------------------
SSH_USER="${SSH_USER:-moolman840}"
SSH_HOST="${SSH_HOST:-}"
SSH_PORT="${SSH_PORT:-2222}"
LOCAL_MOVIES_DIR="${LOCAL_MOVIES_DIR:-$HOME/Videos/Movies}"
REMOTE_BASE_PATH="${REMOTE_BASE_PATH:-/mnt/media}"
SYNC_PROFILE="${SYNC_PROFILE:-wan}"   # wan|lan
PREALLOCATE="${PREALLOCATE:-0}"
COMP_LEVEL="${COMP_LEVEL:-6}"
DRY_RUN=0

while getopts "u:h:p:l:r:n" opt; do
  case "$opt" in
    u) SSH_USER="$OPTARG" ;;
    h) SSH_HOST="$OPTARG" ;;
    p) SSH_PORT="$OPTARG" ;;
    l) LOCAL_MOVIES_DIR="$OPTARG" ;;
    r) REMOTE_BASE_PATH="$OPTARG" ;;
    n) DRY_RUN=1 ;;
    *) log_error "Usage: $0 -h host [-u user] [-p port] [-l local_movies_dir] [-r remote_base_dir] [-n]"; exit 1 ;;
  esac
done

[[ "$LOCAL_MOVIES_DIR" == ~* ]] && LOCAL_MOVIES_DIR="${HOME}${LOCAL_MOVIES_DIR:1}"
[[ -z "$SSH_HOST" ]] && { log_error "SSH host required (-h or SSH_HOST)."; exit 1; }
[[ -d "$LOCAL_MOVIES_DIR" ]] || { log_error "Local dir '$LOCAL_MOVIES_DIR' not found."; exit 1; }

REMOTE_MOVIES_DIR="${REMOTE_BASE_PATH%/}/Movies"

# --- connection reuse & tuning (ARRAYS to avoid quoting bugs) -------------
# Use a short hashed ControlPath to avoid UNIX path length limits
CM_DIR="$HOME/.ssh/cm"
mkdir -p "$CM_DIR"
SOCK="$CM_DIR/%C"
SSH_OPTS=(
  -p "$SSH_PORT"
  -o ControlMaster=auto
  -o ControlPersist=300
  -o ControlPath="$SOCK"
  -o Ciphers=aes128-gcm@openssh.com
)
# Warm up a master connection (ignore failure)
ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$SSH_USER@$SSH_HOST" true || true

# rsync feature detection (best-effort)
has_flag(){ rsync --help 2>&1 | grep -q -- "$1"; }

RSYNC_BASE_OPTS=(-avh --ignore-existing --protect-args --progress --partial --partial-dir=.rsync-partial)
if [[ "$SYNC_PROFILE" == "lan" ]]; then
  RSYNC_TUNE_OPTS=(--no-compress --whole-file)
else
  if has_flag 'compress-choice'; then
    RSYNC_TUNE_OPTS=(--compress --compress-choice=zstd --compress-level="$COMP_LEVEL")
  else
    RSYNC_TUNE_OPTS=(--compress)
  fi
fi
[[ "$PREALLOCATE" == "1" ]] && RSYNC_TUNE_OPTS+=(--preallocate)
[[ "$DRY_RUN" == "1"    ]] && RSYNC_BASE_OPTS+=(-n)

# Build a single rsync -e command string from SSH_OPTS (avoid IFS newlines)
build_ssh_cmd() {
  local parts=(ssh "${SSH_OPTS[@]}")
  # join with spaces regardless of IFS
  printf '%s' "${parts[0]}"
  local i
  for (( i=1; i<${#parts[@]}; i++ )); do
    printf ' %s' "${parts[i]}"
  done
}
RSYNC_SSH=(-e "$(build_ssh_cmd)")
RSYNC_OPTS=("${RSYNC_BASE_OPTS[@]}" "${RSYNC_TUNE_OPTS[@]}" "${RSYNC_SSH[@]}")

log_info "Profile: $SYNC_PROFILE | Dry-run: $DRY_RUN | Preallocate: $PREALLOCATE"
log_info "Local:   $LOCAL_MOVIES_DIR"
log_info "Remote:  $SSH_USER@$SSH_HOST:$REMOTE_MOVIES_DIR"

# ensure remote base exists
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "mkdir -p \"$REMOTE_MOVIES_DIR\""

# --- single-shot rsync (videos + subs) -----------------------------------
INCLUDES=(
  --include='*/'
  --include='*.mp4' --include='*.mkv' --include='*.avi' --include='*.mov' --include='*.wmv'
  --include='*.srt' --include='*.ass' --include='*.ssa' --include='*.vtt' --include='*.sub' --include='*.idx'
  --exclude='*'
)

log_info "Starting rsync..."
if has_flag 'info=PROGRESS2'; then
  RSYNC_OPTS+=(--info=progress2)
fi

rsync "${RSYNC_OPTS[@]}" "${INCLUDES[@]}" -- \
  "$LOCAL_MOVIES_DIR"/ "$SSH_USER@$SSH_HOST:$REMOTE_MOVIES_DIR"/

# Optional: close the master connection cleanly
ssh -O exit -o ControlPath="$SOCK" "$SSH_USER@$SSH_HOST" 2>/dev/null || true

log_success "Movie sync complete."

