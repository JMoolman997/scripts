#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Resolve script directory to source log.sh reliably
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

usage() {
  cat <<EOF
Usage: $0 COMMAND [options]

Commands:
  connect          Connect to remote via SSH
  ssh-setup        Setup SSH keys, copy key, test connection
  tailscale-up     Bring up tailscale daemon on remote (with optional --ssh)
  tailscale-down   Bring down tailscale daemon on remote
  tailscale-status Show tailscale status on remote
  tailscale-ip     Show tailscale IPs on remote

Options for ssh-setup:
  -r, --remote USER@HOST    Remote SSH target (required)
  -p, --port PORT           SSH port (default: 22)
  -g, --gen-key             Generate SSH key if missing
  -c, --copy-key            Copy SSH key to remote
  -t, --test                Test SSH connection

Options for tailscale-up:
  -r, --remote USER@HOST    Remote SSH target (required)
  -p, --port PORT           SSH port for remote connection (default: 22)
  --ssh                     Enable tailscale SSH feature

Options for connect:
  -r, --remote USER@HOST    Remote SSH target (required)
  -p, --port PORT           SSH port (default: 22)

Examples:
  $0 connect -r user@host -p 2222
  $0 ssh-setup -r user@host -p 2222 -g -c -t
  $0 tailscale-up -r user@host --ssh
EOF
  exit 0
}

if [[ $# -lt 1 ]]; then
  usage
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
    -h|--help) usage ;;
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
      error "Unknown option: $1"
      usage
      ;;
  esac
done

if [[ -z "$REMOTE" ]]; then
  error "Remote host is required."
  usage
fi

SSH_KEY="$HOME/.ssh/id_ed25519"
SSH_PUB="${SSH_KEY}.pub"

ssh_exec() {
  ssh -p "$PORT" "$REMOTE" "$@"
}

case "$CMD" in
  connect)
    info "Connecting to $REMOTE via SSH on port $PORT..."
    exec ssh -p "$PORT" "$REMOTE"
    ;;

  ssh-setup)
    info "Starting SSH convenience setup for $REMOTE on port $PORT"

    if $GEN_KEY; then
      if [[ ! -f "$SSH_KEY" || ! -f "$SSH_PUB" ]]; then
        info "Generating new SSH keypair..."
        ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" || { error "Failed to generate SSH keys"; exit 1; }
      else
        info "SSH keypair already exists."
      fi
    fi

    if $COPY_KEY; then
      info "Copying SSH public key to $REMOTE..."
      if ssh-copy-id -p "$PORT" -i "$SSH_PUB" "$REMOTE"; then
        info "Public key copied successfully."
      else
        error "Failed to copy public key."
        exit 1
      fi
    fi

    if $TEST_CONN; then
      info "Testing SSH connection to $REMOTE..."
      if ssh -p "$PORT" -o BatchMode=yes "$REMOTE" exit; then
        info "SSH connection succeeded!"
      else
        error "SSH connection test failed!"
        exit 1
      fi
    fi
    ;;

  tailscale-up)
    info "Bringing up tailscale on $REMOTE..."
    CMD="sudo tailscale up"
    if $TS_ENABLE_SSH; then
      CMD+=" --ssh"
    fi
    ssh_exec $CMD
    ;;

  tailscale-down)
    info "Bringing down tailscale on $REMOTE..."
    ssh_exec sudo tailscale down
    ;;

  tailscale-status)
    info "Fetching tailscale status on $REMOTE..."
    ssh_exec tailscale status
    ;;

  tailscale-ip)
    info "Fetching tailscale IPs on $REMOTE..."
    ssh_exec tailscale ip -4
    ;;

  *)
    error "Unknown command: $CMD"
    usage
    ;;
esac
