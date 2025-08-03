#!/bin/bash
# sync_shows.sh - Organize and sync TV show episodes from local to remote using rsync.
#
# Usage: sync_shows.sh [options]
# Options:
#   -u <user>       SSH username (default: moolman840)
#   -h <host>       SSH host (e.g., 100.76.105.58)
#   -p <port>       SSH port (default: 2222)
#   -l <path>       Local source directory (path to local media or shows folder)
#   -r <path>       Remote base path (default: /mnt/media)
#
# Examples:
#   SSH_HOST=100.76.105.58 LOCAL_SOURCE="/home/user/Media" REMOTE_BASE_PATH="/mnt/media" ./sync_shows.sh
#   ./sync_shows.sh -h 100.76.105.58 -u moolman840 -l "/home/user/Media/Shows" -r "/mnt/media"
#
# This script scans the local "Shows" directory for episode files and uploads them to the remote server under "$REMOTE_BASE_PATH/Shows".
# Files are organized on the remote by show name and season. For example, "Show.Name.S01E02.mkv" will be placed in "$REMOTE_BASE_PATH/Shows/Show Name/Season 1/".
# The script recognizes common TV naming patterns (e.g., "Show.Name.S01E02", "Show Name - S1E2", "Show_Name.1x02").
# Files with unrecognized naming formats are skipped and reported. Existing files on the remote are also skipped to avoid duplicates.
# All operations are verbose, and each skipped or transferred file is logged.

# Configurable variables (with defaults, override via env or flags):
SSH_USER="${SSH_USER:-moolman840}"
SSH_HOST="${SSH_HOST:-}"            # SSH host is required (no default).
SSH_PORT="${SSH_PORT:-2222}"
LOCAL_SOURCE="${LOCAL_SOURCE:-$HOME/Videos}"
REMOTE_BASE_PATH="${REMOTE_BASE_PATH:-/mnt/media}"

# Parse command-line options
opt_l_used=0
while getopts "u:h:p:l:r:" opt; do
  case "$opt" in
    u) SSH_USER="$OPTARG" ;;
    h) SSH_HOST="$OPTARG" ;;
    p) SSH_PORT="$OPTARG" ;;
    l) LOCAL_SOURCE="$OPTARG"; opt_l_used=1 ;;
    r) REMOTE_BASE_PATH="$OPTARG" ;;
    *) echo "Usage: $0 [-u user] [-h host] [-p port] [-l local_path] [-r remote_path]"; exit 1 ;;
  esac
done

# Determine the local Shows directory path
if [ $opt_l_used -eq 1 ]; then
  LOCAL_SHOWS_DIR="$LOCAL_SOURCE"
else
  LOCAL_SHOWS_DIR="${LOCAL_SOURCE%/}/Shows"
fi

# Verify required parameters
if [ -z "$SSH_HOST" ]; then
  echo "Error: SSH_HOST is not specified."
  exit 1
fi
if [ ! -d "$LOCAL_SHOWS_DIR" ]; then
  echo "Error: Local directory '$LOCAL_SHOWS_DIR' does not exist."
  exit 1
fi

# Ensure the remote Shows base directory exists
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "mkdir -p '$REMOTE_BASE_PATH/Shows'" || {
  echo "Error: Unable to create remote directory $REMOTE_BASE_PATH/Shows"
  exit 1
}

# Find all files in the local Shows directory (recursively), and sort them
mapfile -t files < <(find "$LOCAL_SHOWS_DIR" -type f -printf "%P\n" | sort)

# Use an associative array to track which remote directories have been created (to avoid redundant mkdir calls)
declare -A CREATED_DIRS

# Loop through each show file
for file in "${files[@]}"; do
  filename="$(basename "$file")"
  # Parse show name, season, and episode from the filename using regex
  season_num="" episode_num="" showname_raw=""
  if [[ "$filename" =~ ^(.+?)[-._[:space:]]+[Ss]([0-9]+)[-._[:space:]]*[Ee]([0-9]+) ]]; then
    # Matches patterns like "Show.Name.S01E02" or "Show Name - S1E2"
    showname_raw="${BASH_REMATCH[1]}"
    season_num="${BASH_REMATCH[2]}"
    episode_num="${BASH_REMATCH[3]}"
  elif [[ "$filename" =~ ^(.+?)[-._[:space:]]+([0-9]+)[xX]([0-9]+) ]]; then
    # Matches patterns like "Show_Name.1x02"
    showname_raw="${BASH_REMATCH[1]}"
    season_num="${BASH_REMATCH[2]}"
    episode_num="${BASH_REMATCH[3]}"
  else
    echo "Skipping '$filename' (unrecognized format)."
    continue
  fi

  # Clean up the show name: replace dots, underscores, and hyphens with spaces
  showname="${showname_raw//./ }"
  showname="${showname//_/ }"
  showname="${showname//-/ }"
  # Trim any extra spaces
  showname="$(echo "$showname" | sed -e 's/  */ /g' -e 's/^ *//; s/ *$//')"

  # Convert season number to an integer (remove any leading zeros)
  season=$((10#$season_num))
  # Define the remote directory for this show's season
  remote_dir="$REMOTE_BASE_PATH/Shows/$showname/Season $season"

  # Create the remote show/season directory if not already created in this run
  if [ -z "${CREATED_DIRS["$showname Season $season"]}" ]; then
    ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "mkdir -p '$remote_dir'" || {
      echo "Error: failed to create remote directory '$remote_dir'."
      exit 1
    }
    CREATED_DIRS["$showname Season $season"]=1
  fi

  # Check if the file already exists on the remote server
  remote_file="$remote_dir/$filename"
  ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash -c "$(printf 'test -e %q' "$remote_file")"
  rc=$?
  if [ $rc -eq 0 ]; then
    echo "Skipping '$filename' (already exists on remote)."
    continue
  elif [ $rc -ne 1 ]; then
    echo "Error: failed to check remote file '$remote_file' (SSH error code $rc). Aborting."
    exit 1
  fi

  # File does not exist remotely, proceed to transfer it
  local_path="$LOCAL_SHOWS_DIR/$file"
  rsync -avh --progress --ignore-existing --protect-args -e "ssh -p $SSH_PORT" "$local_path" "$SSH_USER@$SSH_HOST:$remote_dir/"
  if [ $? -ne 0 ]; then
    echo "Error: rsync failed for file '$filename'. Aborting sync."
    exit 1
  fi
done

echo "Show sync completed."
