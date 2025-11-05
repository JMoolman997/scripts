#!/usr/bin/env bash
# netctl.sh — SSH and Tailscale convenience wrapper for remote hosts
#
# SYNOPSIS
#   ./netctl.sh COMMAND [options]
#
# DESCRIPTION
#   Provides a thin wrapper around common remote connectivity workflows. It can
#   bootstrap SSH keys, copy them to a remote host, validate connectivity, and
#   issue basic Tailscale lifecycle commands.
#
# COMMANDS
#   connect        Open an interactive SSH session.
#   ssh-setup      Generate keys, copy them to the remote, and test the login.
#   tailscale-up   Invoke `tailscale up` on the remote (optionally enabling SSH).
#   tailscale-down Stop the Tailscale daemon on the remote host.
#   tailscale-status
#                  Show `tailscale status` for the remote host.
#   tailscale-ip   Print the remote host's IPv4 address from Tailscale.
#
# ENVIRONMENT
#   LOG_LEVEL      Controls verbosity when sourcing lib/log.sh (default: INFO).

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! source "$SCRIPT_DIR/lib/log.sh" 2>/dev/null; then
  error() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
  warn()  { printf '[WARN]  %s\n' "$*" >&2; }
  info()  { printf '[INFO]  %s\n' "$*" >&2; }
fi

if ! declare -F log_info >/dev/null; then
  log_info() { info "$@"; }
fi
if ! declare -F log_warn >/dev/null; then
  log_warn() { warn "$@"; }
fi
if ! declare -F log_error >/dev/null; then
  log_error() { error "$@"; }
fi

usage() {
  local exit_code="${1:-0}"
  cat <<EOF
Usage: $(basename "$0") COMMAND [options]

Commands:
  connect            Connect to remote via SSH
  ssh-setup          Generate keys, copy them to the remote, and test login
  tailscale-up       Bring up Tailscale on the remote (pass --ssh to enable)
  tailscale-down     Stop the remote Tailscale daemon
  tailscale-status   Show Tailscale status on the remote host
  tailscale-ip       Show the remote host's IPv4 Tailscale address

Global options:
  -r, --remote USER@HOST    Remote SSH target (required)
  -p, --port PORT           SSH port (default: 22)

Additional options:
  ssh-setup
      -g, --gen-key         Generate an ed25519 keypair if missing
      -c, --copy-key        Copy the public key to the remote host
      -t, --test            Test SSH connectivity once keys are in place
  tailscale-up
      --ssh                 Enable the Tailscale SSH feature when bringing up

Examples:
  $(basename "$0") connect -r user@host -p 2222
  $(basename "$0") ssh-setup -r user@host -g -c -t
  $(basename "$0") tailscale-up -r user@host --ssh
EOF
  exit "$exit_code"
}

if [[ $# -lt 1 ]]; then
  usage 1
fi

CMD="$1"
shift

REMOTE=""
PORT=22
GEN_KEY=false
COPY_KEY=false
TEST_CONN=false
TS_ENABLE_SSH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage 0
      ;;
    -r|--remote)
      REMOTE="$2"
      shift 2
      ;;
    -p|--port)
      PORT="$2"
      shift 2
      ;;
    -g|--gen-key)
      GEN_KEY=true
      shift
      ;;
    -c|--copy-key)
      COPY_KEY=true
      shift
      ;;
    -t|--test)
      TEST_CONN=true
      shift
      ;;
    --ssh)
      TS_ENABLE_SSH=true
      shift
      ;;
    *)
      log_warn "Unknown option: $1 (see --help)"
      usage 1
      ;;
  esac
done

if [[ -z "$REMOTE" ]]; then
  log_error "Remote host is required (use --remote or -r)."
  exit 1
fi

SSH_KEY="$HOME/.ssh/id_ed25519"
SSH_PUB="${SSH_KEY}.pub"

ssh_exec() {
  ssh -p "$PORT" "$REMOTE" "$@"
}

case "$CMD" in
  connect)
    log_info "Connecting to $REMOTE via SSH on port $PORT..."
    exec ssh -p "$PORT" "$REMOTE"
    ;;

  ssh-setup)
    log_info "Starting SSH convenience setup for $REMOTE on port $PORT"

    if $GEN_KEY; then
      if [[ ! -f "$SSH_KEY" || ! -f "$SSH_PUB" ]]; then
        log_info "Generating new SSH keypair..."
        if ! ssh-keygen -t ed25519 -f "$SSH_KEY" -N ""; then
          log_error "Failed to generate SSH keys"
          exit 1
        fi
      else
        log_info "SSH keypair already exists."
      fi
    fi

    if $COPY_KEY; then
      log_info "Copying SSH public key to $REMOTE..."
      if ssh-copy-id -p "$PORT" -i "$SSH_PUB" "$REMOTE"; then
        log_info "Public key copied successfully."
      else
        log_error "Failed to copy public key."
        exit 1
      fi
    fi

    if $TEST_CONN; then
      log_info "Testing SSH connection to $REMOTE..."
      if ssh -p "$PORT" -o BatchMode=yes "$REMOTE" exit; then
        log_info "SSH connection succeeded!"
      else
        log_error "SSH connection test failed!"
        exit 1
      fi
    fi
    ;;

  tailscale-up)
    log_info "Bringing up Tailscale on $REMOTE..."
    ts_cmd=(sudo tailscale up)
    if $TS_ENABLE_SSH; then
      ts_cmd+=(--ssh)
    fi
    ssh_exec "${ts_cmd[@]}"
    ;;

  tailscale-down)
    log_info "Bringing down Tailscale on $REMOTE..."
    ssh_exec sudo tailscale down
    ;;

  tailscale-status)
    log_info "Fetching Tailscale status on $REMOTE..."
    ssh_exec tailscale status
    ;;

  tailscale-ip)
    log_info "Fetching Tailscale IPv4 address on $REMOTE..."
    ssh_exec tailscale ip -4
    ;;

  *)
    log_error "Unknown command: $CMD"
    exit 1
    ;;
esac
