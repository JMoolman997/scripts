#!/bin/bash
# lib/sync_common.sh — shared helpers for Jellyfin media sync scripts
#
# PURPOSE
# Centralize SSH multiplexing, rsync tuning (LAN/WAN profiles), robust remote shell
# construction for rsync (-e), batch remote mkdir, and diagnostics (timing and
# scan benchmarks). Both sync_movies.sh and sync_shows.sh source this file.
#
# REQUIREMENTS
# - bash 4+
# - rsync 3.1+ (3.2+ recommended for --compress-choice=zstd / --append-verify)
# - OpenSSH client with ControlMaster support
#
# EXPORTED FUNCTIONS
# __sc_adapt_logging : bind log_* to fallback if log.sh is absent
# sc_has_flag FLAG : probe rsync --help for a capability
# sc_build_ssh_opts PORT [CIPHER]
# sc_build_rsync_remote_shell : build safe "ssh ..." string for rsync -e
# sc_ensure_mux : kill stale ControlMaster, warm a fresh one
# sc_close_mux : close ControlMaster socket
# sc_build_rsync_opts PROFILE COMP_LVL PREALLOC DRYRUN
# sc_rsync_copy SRC DSTDIR : rsync one file/dir to remote DSTDIR
# sc_batch_mkdir DIRS... : create many remote dirs in one shot
# sc_time LABEL cmd ... : run and log wall time
# sc_trace_on/off : enable/disable xtrace
# sc_rsync_scan_benchmark SRC DST INCLUDES... : time a dry-run traversal
#
# ENV INFLUENCE (consumed by wrappers)
# CM_DIR, SOCK : override ControlPath directory / pattern
#
# RETURN CODES
# Functions return underlying command exit codes. Always check return codes in
# callers when appropriate.


set -euo pipefail
IFS=$'\n\t'


# --- logging glue ---------------------------------------------------------
__sc_adapt_logging() {
if ! declare -F log_info >/dev/null; then
if declare -F info >/dev/null; then log_info(){ info "$@"; }; else log_info(){ printf "[INFO] %s\n" "$*"; }; fi
if declare -F warn >/dev/null; then log_warn(){ warn "$@"; }; else log_warn(){ printf "[WARN] %s\n" "$*"; }; fi
if declare -F error >/dev/null; then log_error(){ error "$@"; }; else log_error(){ printf "[ERROR] %s\n" "$*"; }; fi
if declare -F success >/dev/null;then log_success(){ success "$@"; } else log_success(){ printf "[ OK ] %s\n" "$*"; }; fi
fi
}


# --- feature probe --------------------------------------------------------
sc_has_flag(){ rsync --help 2>&1 | grep -q -- "$1"; }


# --- SSH/rsync setup ------------------------------------------------------
sc_build_ssh_opts() {
local port="${1:?port}" cipher="${2:-aes128-gcm@openssh.com}"
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


# join ssh array safely for rsync -e
sc_build_rsync_remote_shell() {
local parts=(ssh "${SSH_OPTS[@]}")
}
