#!/bin/bash
# sync_shows.sh — TV show sync for Jellyfin (+ external subs)
#
# SYNOPSIS
# ./sync_shows.sh -h <host> [-u user] [-p port] [-l local_shows_dir] [-r remote_base_dir] [-w workers] [-n]
#
# DESCRIPTION
# Parses common TV episode filename patterns (SxxEyy, 1x01, with basic multi-episode
# tolerance), creates remote directories /Shows/<Show>/Season N, and transfers
# episodes + external subtitles. Uses SSH ControlMaster, LAN/WAN rsync profiles,
# batch mkdir, and bounded parallel transfers.
# Show names are normalized (year inference + optional aliases in
# lib/show_aliases.conf) to avoid splintered directories.
#
# OPTIONS
# -h HOST Remote host/IP (required)
# -u USER SSH username (default: $SSH_USER or moolman840)
# -p PORT SSH port (default: 2222)
# -l DIR Local shows directory (default: $HOME/Videos/Shows)
# -r DIR Remote media base path (default: /mnt/media)
# -w N Parallel transfers (default: 3)
# -n Dry-run (no changes)
#
# ENV VARS
# SSH_USER, SSH_HOST, SSH_PORT, LOCAL_SHOWS_DIR, REMOTE_BASE_PATH
# SYNC_PROFILE=lan|wan (default: wan)
# PREALLOCATE=1 COMP_LEVEL=<zstd level>
# WORKERS (parallelism)
# SSH_CIPHER=aes128-gcm@openssh.com | chacha20-poly1305@openssh.com
#
# SUBTITLES
# Copies common external subtitles next to episodes: .srt .ass .ssa .vtt .sub .idx
# Ensures VobSub pairs (.sub/.idx) stay together.
#
# EXIT CODES
# 0 success; non-zero on failure of rsync/ssh.


set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/sync_common.sh"
__sc_adapt_logging

SSH_USER="${SSH_USER:-moolman840}"
SSH_HOST="${SSH_HOST:-}"
SSH_PORT="${SSH_PORT:-2222}"
LOCAL_SHOWS_DIR="${LOCAL_SHOWS_DIR:-$HOME/Videos/Shows}"
REMOTE_BASE_PATH="${REMOTE_BASE_PATH:-/mnt/media}"
SYNC_PROFILE="${SYNC_PROFILE:-wan}"
PREALLOCATE="${PREALLOCATE:-0}"
COMP_LEVEL="${COMP_LEVEL:-6}"
WORKERS="${WORKERS:-1}"
SSH_CIPHER="${SSH_CIPHER:-aes128-gcm@openssh.com}"
DRY_RUN=0

# --- junk filter (case-insensitive, bash-safe) ----------------------------
# Bash [[ =~ ]] does not support (?i). Use lowercase normalization instead.
# Matches filenames containing: sample, trailer, extra/extras
is_junk() {
  local s="${1,,}"   # bash 4+: to-lowercase
  [[ "$s" =~ (sample|trailer|extras?) ]]
}

# normalize_show_name applies optional alias overrides and synthesizes a year
# suffix when the filename carries a 4-digit year elsewhere. This keeps series
# names consistent even when source files use mixed naming conventions.
normalize_show_name() {
  local name="$1"
  local fname="$2"
  local normalized="$name"
  local alias_file="${SHOW_ALIASES_FILE:-$SCRIPT_DIR/lib/show_aliases.conf}"

  if [[ -f "$alias_file" ]]; then
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line%"${line##*[![:space:]]}"}"
      line="${line#"${line%%[![:space:]]*}"}"
      [[ -z "$line" ]] && continue
      local lhs="${line%%=*}"
      local rhs="${line#*=}"
      lhs="$(echo "$lhs" | sed -E 's/^ +| +$//g')"
      rhs="$(echo "$rhs" | sed -E 's/^ +| +$//g')"
      if [[ "$lhs" == "$normalized" ]]; then
        normalized="$rhs"
        break
      fi
    done <"$alias_file"
  fi

  if [[ ! "$normalized" =~ \([0-9]{4}\)$ ]]; then
    if [[ "$fname" =~ [\[\(]?([12][0-9]{3})[\]\)]?([[:space:][:punct:]]|$) ]]; then
      local year="${BASH_REMATCH[1]}"
      normalized="$normalized ($year)"
    fi
  fi

  printf '%s\n' "$normalized"
}

while getopts "u:h:p:l:r:w:n" opt; do
  case "$opt" in
    u) SSH_USER="$OPTARG" ;;
    h) SSH_HOST="$OPTARG" ;;
    p) SSH_PORT="$OPTARG" ;;
    l) LOCAL_SHOWS_DIR="$OPTARG" ;;
    r) REMOTE_BASE_PATH="$OPTARG" ;;
    w) WORKERS="$OPTARG" ;;
    n) DRY_RUN=1 ;;
    *)
      log_error "Usage: $0 -h host [-u user] [-p port] [-l local_shows_dir] [-r remote_base_dir] [-w workers] [-n]"
      exit 1
      ;;
  esac
done
shift $((OPTIND - 1))

[[ "$LOCAL_SHOWS_DIR" == ~* ]] && LOCAL_SHOWS_DIR="${HOME}${LOCAL_SHOWS_DIR:1}"
[[ -z "$SSH_HOST" ]] && { log_error "SSH host required (-h or SSH_HOST)."; exit 1; }
[[ -d "$LOCAL_SHOWS_DIR" ]] || { log_error "Local dir '$LOCAL_SHOWS_DIR' not found."; exit 1; }
[[ "$WORKERS" =~ ^[0-9]+$ ]] || { log_error "Workers must be numeric (got '$WORKERS')."; exit 1; }
(( WORKERS > 0 )) || { log_error "Workers must be greater than zero."; exit 1; }

REMOTE_SHOWS_DIR="${REMOTE_BASE_PATH%/}/Shows"
SUB_EXTS=(srt ass ssa vtt sub idx)
EXCLUDES_REGEX='(?i)(sample|trailer|extras?)'

sc_build_ssh_opts "$SSH_PORT" "$SSH_CIPHER"
sc_build_rsync_opts "$SYNC_PROFILE" "$COMP_LEVEL" "$PREALLOCATE" "$DRY_RUN"
sc_ensure_mux

log_info "Profile: $SYNC_PROFILE | Workers: $WORKERS | Dry-run: $DRY_RUN | Preallocate: $PREALLOCATE"
log_info "Local:  $LOCAL_SHOWS_DIR"
log_info "Remote: $SSH_USER@$SSH_HOST:$REMOTE_SHOWS_DIR"

find_errors="$(mktemp)"
videos_manifest="$(mktemp)"
sort_manifest="${videos_manifest}.sorted"
dirs_manifest="$(mktemp)"
dirs_sorted="${dirs_manifest}.sorted"
# Temporary manifests capture candidate videos and destination directories; the
# trap ensures we always clean them up on exit.
trap 'rm -f "$find_errors" "$videos_manifest" "$sort_manifest" "$dirs_manifest" "$dirs_sorted"' EXIT

# Allow find to encounter unreadable directories without aborting the script.
set +e
find "$LOCAL_SHOWS_DIR" -type f \
  \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.wmv" \) \
  >"$videos_manifest" 2>"$find_errors"
find_status=$?
set -e

set +e
sort "$videos_manifest" >"$sort_manifest"
sort_status=$?
set -e
if (( sort_status == 0 )); then
  mv "$sort_manifest" "$videos_manifest"
else
  log_warn "Sort command failed (exit $sort_status); continuing unsorted."
  rm -f "$sort_manifest"
fi

mapfile -t videos <"$videos_manifest"

if [[ -s "$find_errors" ]]; then
  while IFS= read -r err_line; do
    log_warn "find: $err_line"
  done <"$find_errors"
fi
rm -f "$find_errors"

if (( find_status != 0 )); then
  log_warn "Continuing despite find errors (exit $find_status)."
fi

if [[ ${#videos[@]} -eq 0 ]]; then
  log_warn "No TV episode files found in $LOCAL_SHOWS_DIR"
else
  log_info "Discovered ${#videos[@]} candidate video files"
fi

queue=() # entries stored as SRC|DEST_DIR for lightweight tuple handling
parse_ok=0
parse_skip=0

for vid in "${videos[@]}"; do
  fname="$(basename "$vid")"
  rel="${vid#$LOCAL_SHOWS_DIR/}"

  if is_junk "$fname"; then
    log_warn "Skip junk: $rel"
    ((++parse_skip))
    continue
fi


  show_raw=""
  season=""
  ep=""

  if [[ "$fname" =~ ^(.+?)[._[:space:]-]+[sS]([0-9]+)[._[:space:]-]*[eE]([0-9]+)([eE][0-9]+)* ]]; then
    show_raw="${BASH_REMATCH[1]}"
    season="${BASH_REMATCH[2]}"
    ep="${BASH_REMATCH[3]}"
  elif [[ "$fname" =~ ^(.+?)[._[:space:]-]+([0-9]+)[xX]([0-9]+)(-[0-9]+)? ]]; then
    show_raw="${BASH_REMATCH[1]}"
    season="${BASH_REMATCH[2]}"
    ep="${BASH_REMATCH[3]}"
  else
    log_warn "Skip (unrecognized pattern): $rel"
    ((++parse_skip))
    continue
  fi

  show_clean="$(echo "$show_raw" | tr '._-' ' ' | sed -E 's/ +/ /g; s/^ +| +$//g')"
  show_clean="$(normalize_show_name "$show_clean" "$fname")"
  season_num=$((10#$season))
  dest_dir="$REMOTE_SHOWS_DIR/$show_clean/Season $season_num"
  printf '%s\n' "$dest_dir" >>"$dirs_manifest"
  queue+=("$vid|$dest_dir")

  base_noext="${vid%.*}"
  for ext in "${SUB_EXTS[@]}"; do
    for sub in "$base_noext".$ext*; do
      [[ -f "$sub" ]] || continue
      queue+=("$sub|$dest_dir")
      case "$sub" in
        *.idx)
          twin="${sub%.idx}.sub"
          [[ -f "$twin" ]] && queue+=("$twin|$dest_dir")
          ;;
        *.sub)
          twin="${sub%.sub}.idx"
          [[ -f "$twin" ]] && queue+=("$twin|$dest_dir")
          ;;
      esac
    done
  done

  ((++parse_ok))
done

log_info "Parsed: $parse_ok episodes | Skipped: $parse_skip"

if [[ -s "$dirs_manifest" ]]; then
  sort -u "$dirs_manifest" >"$dirs_sorted"
  mapfile -t dir_list <"$dirs_sorted"
  sc_batch_mkdir "${dir_list[@]}"
fi

# Named semaphore helper keeps a max of WORKERS parallel rsync processes without
# requiring external tools.
sem() {
  while (( $(jobs -rp | wc -l) >= WORKERS )); do
    wait -n || true
  done
  "$@" &
}

transfer_one() {
  local src="$1"
  local dst="$2"
  sc_rsync_copy "$src" "$dst" || log_warn "rsync failed: $(basename "$src") -> $dst"
}

log_info "Transferring ${#queue[@]} items with $WORKERS workers..."
for item in "${queue[@]}"; do
  src="${item%%|*}"
  dst="${item#*|}"
  sem transfer_one "$src" "$dst"
done
wait || true

sc_close_mux
log_success "Show sync complete."
