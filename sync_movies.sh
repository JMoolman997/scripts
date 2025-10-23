#!/bin/bash
# sync_movies.sh — Fast movie sync for Jellyfin (+ external subs)
#
# SYNOPSIS
# ./sync_movies.sh -h <host> [-u user] [-p port] [-l local_movies_dir] [-r remote_base_dir] [-n]
#
# DESCRIPTION
# One-shot rsync that syncs movie files and common external subtitles to
# a remote Jellyfin library path over SSH. Uses ControlMaster multiplexing,
# LAN/WAN profiles, and safe remote shell construction to reduce overhead.
#
# OPTIONS
# -h HOST Remote host/IP (required)
# -u USER SSH username (default: $SSH_USER or moolman840)
# -p PORT SSH port (default: 2222)
# -l DIR Local movies directory (default: $HOME/Videos/Movies)
# -r DIR Remote media base path (default: /mnt/media)
# -n Dry-run (no changes)
#
# ENV VARS
# SSH_USER, SSH_HOST, SSH_PORT, LOCAL_MOVIES_DIR, REMOTE_BASE_PATH
# SYNC_PROFILE=lan|wan (default: wan)
# PREALLOCATE=1 (enable --preallocate)
# COMP_LEVEL=<zstd level> (default: 6)
# SSH_CIPHER=aes128-gcm@openssh.com | chacha20-poly1305@openssh.com
#
# EXAMPLES
# SYNC_PROFILE=lan ./sync_movies.sh -h 100.76.105.58
# PREALLOCATE=1 COMP_LEVEL=10 ./sync_movies.sh -h 100.76.105.58
#
# EXIT CODES
# 0 success, non-zero on error (propagated from rsync/ssh)


set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/sync_common.sh"
__sc_adapt_logging

SSH_USER="${SSH_USER:-moolman840}"
SSH_HOST="${SSH_HOST:-}"
SSH_PORT="${SSH_PORT:-2222}"
LOCAL_MOVIES_DIR="${LOCAL_MOVIES_DIR:-$HOME/Videos/Movies}"
REMOTE_BASE_PATH="${REMOTE_BASE_PATH:-/mnt/media}"
SYNC_PROFILE="${SYNC_PROFILE:-wan}"
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
    *)
      echo "Usage: $0 -h host [-u user] [-p port] [-l local_movies_dir] [-r remote_base_dir] [-n]"
      exit 1
      ;;
  esac
done

[[ "$LOCAL_MOVIES_DIR" == ~* ]] && LOCAL_MOVIES_DIR="${HOME}${LOCAL_MOVIES_DIR:1}"
[[ -z "$SSH_HOST" ]] && { log_error "SSH host required (-h or SSH_HOST)."; exit 1; }
[[ -d "$LOCAL_MOVIES_DIR" ]] || { log_error "Local dir '$LOCAL_MOVIES_DIR' not found."; exit 1; }

REMOTE_MOVIES_DIR="${REMOTE_BASE_PATH%/}/Movies"

# Setup and warm ControlMaster
sc_build_ssh_opts "$SSH_PORT" "${SSH_CIPHER:-aes128-gcm@openssh.com}"
sc_ensure_mux
sc_build_rsync_opts "$SYNC_PROFILE" "$COMP_LEVEL" "$PREALLOCATE" "$DRY_RUN"

log_info "Profile: $SYNC_PROFILE | Dry-run: $DRY_RUN | Preallocate: $PREALLOCATE"
log_info "Local:  $LOCAL_MOVIES_DIR"
log_info "Remote: $SSH_USER@$SSH_HOST:$REMOTE_MOVIES_DIR"

ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "mkdir -p \"$REMOTE_MOVIES_DIR\""

INCLUDES=(
  --include='*/'
  --include='*.mp4' --include='*.mkv' --include='*.avi' --include='*.mov' --include='*.wmv'
  --include='*.srt' --include='*.ass' --include='*.ssa' --include='*.vtt' --include='*.sub' --include='*.idx'
  --exclude='*'
)

# Benchmark the scanner (dry-run)
sc_rsync_scan_benchmark "$LOCAL_MOVIES_DIR" "$REMOTE_MOVIES_DIR" "${INCLUDES[@]}"

log_info "Starting rsync..."
sc_time "Transfer" rsync "${RSYNC_OPTS[@]}" "${INCLUDES[@]}" -- \
  "$LOCAL_MOVIES_DIR"/ "$SSH_USER@$SSH_HOST:$REMOTE_MOVIES_DIR"/

sc_close_mux
log_success "Movie sync complete."
