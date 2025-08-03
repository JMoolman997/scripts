#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

#__Source_shared_functions__#
SCRIPT_PATH="${BASH_SOURCE[0]}"
# resolve symlink
while [ -L "$SCRIPT_PATH" ]; do
	SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

LOG_LIB="$SCRIPT_DIR/lib/log.sh"
if [[ ! -f "$LOG_LIB" ]]; then
	echo "[ERROR] Could not find $LOG_LIB" >&2
	exit 1
fi

# shellcheck 
. "$LOG_LIB"

info "log.sh sourced succesfully"

#__Helpers__#
usage() {
  printf '\e[94m[Usage]\e[0m %s [options] [venv_dir]\n\n' "$(basename "$0")"
  cat <<EOF
Options:
  -p PROFILE   one of {base,notebook,scientific,datascience} (default: base)
  -r FILE      install from this requirements.txt instead of profiles
  -c           recreate the venv if it already exists
  -h           show this help message
EOF
}

#–– Default values ––
PROFILE="base"
REQ_FILE=""
FORCE=0

#–– Parse flags ––
while getopts "p:r:ch" opt; do
  case $opt in
    p) PROFILE=$OPTARG ;;
    r) REQ_FILE=$OPTARG ;;
    c) FORCE=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
shift $((OPTIND-1))

#–– Determine venv location ––
VENV_DIR="${1:-venv}"

#–– Preflight checks ––
command -v python3 >/dev/null  || error "python3 not found"
python3 -m venv --help >/dev/null 2>&1 || error "python3 -m venv not supported"

#–– Create / recreate venv ––
if (( FORCE )) && [[ -d $VENV_DIR ]]; then
  info "Removing existing venv at $VENV_DIR"
  rm -rf "$VENV_DIR"
fi
info "Creating virtualenv in '$VENV_DIR'"
python3 -m venv "$VENV_DIR"

PIP="$VENV_DIR/bin/pip"

#–– Upgrade pip & friends ––
info "Upgrading pip, setuptools, wheel…"
"$PIP" install --upgrade pip setuptools wheel

#–– Install packages ––
if [[ -n "$REQ_FILE" ]]; then
  info "Installing from $REQ_FILE…"
  "$PIP" install -r "$REQ_FILE"
else
  case "$PROFILE" in
    base)
      info "Profile 'base': numpy, matplotlib, requests, flask"
      "$PIP" install numpy matplotlib requests flask ;;
    notebook)
      info "Profile 'notebook': jupyter, ipykernel, jupyterlab"
      "$PIP" install jupyter ipykernel jupyterlab ;;
    scientific)
      info "Profile 'scientific': scipy, sympy, pandas"
      "$PIP" install scipy sympy pandas ;;
    datascience)
      info "Profile 'datascience': scikit-learn, seaborn, statsmodels"
      "$PIP" install scikit-learn seaborn statsmodels ;;
    *)
      error "Unknown profile: $PROFILE" ;;
  esac
fi

#–– Final reminder ––
ACTIVATE="source \"$VENV_DIR/bin/activate\""
info "Setup complete! Activate with:"
printf "  %s\n" "$ACTIVATE"
