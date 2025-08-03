#!/bin/bash
# sync_movies.sh - Sync new movie files from a local directory to a remote server using rsync.
#
# Usage: sync_movies.sh [options]
# Options:
#   -u <user>       SSH username (default: moolman840)
#   -h <host>       SSH host (e.g., 100.76.105.58)
#   -p <port>       SSH port (default: 2222)
#   -l <path>       Local source directory (path to local media or movies folder)
#   -r <path>       Remote base path (default: /mnt/media)
#
# Example:
#   ./sync_movies.sh -h 100.76.105.58 -u moolman840 -l "$HOME/Videos/Movies" -r "/mnt/media"
#
# Tip: Use 'ssh-agent' and 'ssh-add' before running this script to avoid repeated passphrase prompts:
#   eval "$(ssh-agent -s)"
#   ssh-add ~/.ssh/id_ed25519

# Configurable variables (with defaults that can be overridden by env or args):
SSH_USER="${SSH_USER:-moolman840}"
SSH_HOST="${SSH_HOST:-}"
SSH_PORT="${SSH_PORT:-2222}"
LOCAL_SOURCE="${LOCAL_SOURCE:-$HOME/Videos}"
REMOTE_BASE_PATH="${REMOTE_BASE_PATH:-/mnt/media}"

# Parse command-line options to override defaults
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

# Expand tilde to home dir if present
if [[ "$LOCAL_SOURCE" == ~* ]]; then
  LOCAL_SOURCE="${HOME}${LOCAL_SOURCE:1}"
fi

# Determine the local Movies directory path
if [ $opt_l_used -eq 1 ]; then
  LOCAL_MOVIES_DIR="$LOCAL_SOURCE"
else
  LOCAL_MOVIES_DIR="${LOCAL_SOURCE%/}/Movies"
fi

# Verify required parameters
if [ -z "$SSH_HOST" ]; then
  echo "Error: SSH_HOST is not specified."
  exit 1
fi
if [ ! -d "$LOCAL_MOVIES_DIR" ]; then
  echo "Error: Local directory '$LOCAL_MOVIES_DIR' does not exist."
  exit 1
fi

# Ensure the remote Movies directory exists on the server
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "mkdir -p '$REMOTE_BASE_PATH/Movies'" || {
  echo "Error: Unable to create remote directory $REMOTE_BASE_PATH/Movies"
  exit 1
}

# Find all files in the local Movies directory (relative paths)
mapfile -t files < <(find "$LOCAL_MOVIES_DIR" -type f -printf "%P\n" | sort)

# Loop through each movie file
for file in "${files[@]}"; do
  filename="$(basename "$file")"
  remote_file="$REMOTE_BASE_PATH/Movies/$filename"

  # Properly quote remote file for test
  ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash -c "$(printf 'test -e %q' "$remote_file")"
  rc=$?
  if [ $rc -eq 0 ]; then
    echo "Skipping '$filename' (already exists on remote)."
    continue
  elif [ $rc -ne 1 ]; then
    echo "Error: failed to check remote file '$remote_file' (SSH error code $rc). Aborting."
    exit 1
  fi

  local_path="$LOCAL_MOVIES_DIR/$file"
  echo "Syncing: $filename"
  rsync -avh --progress --ignore-existing --protect-args -e "ssh -p $SSH_PORT" "$local_path" "$SSH_USER@$SSH_HOST:$REMOTE_BASE_PATH/Movies/"
  if [ $? -ne 0 ]; then
    echo "Error: rsync failed for file '$filename'."
    exit 1
  fi
done

echo "Movie sync completed."
