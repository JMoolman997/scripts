#!/usr/bin/env bash
# jellyfinctl.sh - Swiss-army CLI for managing a remote Jellyfin/media server over SSH.
# Drop this in your scripts repo. Make it executable: chmod +x jellyfinctl.sh
# Optional config file: ~/.config/jellyfinctl/config (see TEMPLATE at bottom).
#
# Features:
# - SSH ControlMaster MUX for fast repeated commands
# - Quick health checks (uptime, disk, memory, CPU load)
# - Jellyfin service management (systemd or Docker)
# - Firewall & port reachability checks (UFW/ss/nc)
# - Tailscale checks (if present)
# - Run your sync scripts remotely in tmux sessions (sync_shows.sh / sync_movies.sh)
# - Safe defaults, clear output, and verbose mode
#
# Usage:
#   jellyfinctl.sh [global options] <command> [args...]
#
# GLOBAL OPTIONS:
#   -H, --host HOST         Remote host or Tailscale IP (env: JELLYFINCTL_HOST)
#   -u, --user USER         SSH user (env: JELLYFINCTL_USER)
#   -p, --port PORT         SSH port (default: 22) (env: JELLYFINCTL_PORT)
#   -i, --identity PATH     SSH identity file (env: JELLYFINCTL_IDENTITY)
#   --profile NAME          Load host/user/port from config profile
#   -v, --verbose           Verbose logging
#   -n, --dry-run           Show what would run, don't execute
#   -h, --help              Show help
#
# COMMANDS:
#   init-ssh                     Copy your public key to server (ssh-copy-id)
#   mux-open                     Start a persistent SSH master connection
#   mux-close                    Close the persistent SSH master connection
#   whoami                       Show remote user/host info
#   sysinfo                      Show remote system info (uptime, CPU, RAM, disk)
#   check                        Full health check (includes Jellyfin, ports, firewall, tailscale)
#   jf status|start|restart      Manage Jellyfin (systemd or docker)
#   jf logs [lines]              Tail last N lines of Jellyfin logs
#   port-test [HOST] [PORT]      Test TCP reachability from local and remote sides
#   ufw                          Show remote UFW status & rules
#   tailscale [status|ip]        Show Tailscale status/IP (if present)
#   tmux-run NAME CMD...         Run a long command in remote tmux session NAME
#   sync shows|movies [args...]  Run your sync scripts in tmux (pass args to scripts)
#   run CMD...                   Run arbitrary remote command
#
# Examples:
#   ./jellyfinctl.sh --profile wan check
#   ./jellyfinctl.sh -H 100.76.105.58 -u moolman840 jf status
#   ./jellyfinctl.sh --profile wan sync shows -- --dry-run
#   ./jellyfinctl.sh --profile wan tmux-run sync-shows "~/git/scripts/sync_shows.sh -P 3"
#
set -euo pipefail
IFS=$'\n\t'

LOG_LEVEL="${LOG_LEVEL:-2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/cmd_utils.sh"

VERSION="1.0.0"

# ---------- Defaults ----------
HOST="${JELLYFINCTL_HOST:-}"
USER="${JELLYFINCTL_USER:-}"
PORT="${JELLYFINCTL_PORT:-22}"
IDENTITY="${JELLYFINCTL_IDENTITY:-}"
PROFILE=""
VERBOSE=0
DRY_RUN=0

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/jellyfinctl"
CONFIG_FILE="$CONFIG_DIR/config"
SSH_CONTROL_PATH="$HOME/.ssh/cm-%r@%h:%p"

# ---------- Helpers ----------
die() { error "$@"; }
require_cmd() { command_exists "$1" || die "Missing required command: $1"; }

ssh_base_args=(-o ControlMaster=auto -o ControlPersist=600 -o "ControlPath=$SSH_CONTROL_PATH" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
build_ssh_cmd() {
  local dest="$USER@$HOST"
  local args=("${ssh_base_args[@]}")
  [[ -n "$PORT" ]] && args+=(-p "$PORT")
  [[ -n "$IDENTITY" ]] && args+=(-i "$IDENTITY")
  printf "ssh %s %q" "$(printf "%q " "${args[@]}")" "$dest"
}

remote_run() {
  local sshcmd; sshcmd=$(build_ssh_cmd)
  if (( DRY_RUN )); then
    debug "(dry-run) $sshcmd $*"
    return 0
  fi
  # shellcheck disable=SC2029
  eval "$sshcmd" -- "$@"
}

remote_run_quiet() {
  local sshcmd; sshcmd=$(build_ssh_cmd)
  if (( DRY_RUN )); then
    debug "(dry-run) $sshcmd $*"
    return 0
  fi
  # shellcheck disable=SC2029
  eval "$sshcmd" -- "$@" >/dev/null 2>&1
}

check_conn() {
  local sshcmd; sshcmd=$(build_ssh_cmd)
  if (( DRY_RUN )); then
    debug "(dry-run) $sshcmd true"
    return 0
  fi
  # shellcheck disable=SC2029
  if ! eval "$sshcmd" -- true >/dev/null 2>&1; then
    die "SSH connection failed to $USER@$HOST (port $PORT). Try: ./jellyfinctl.sh init-ssh"
  fi
}

ensure_target() {
  [[ -n "$HOST" ]] || die "No host set. Use -H/--host or --profile, or set JELLYFINCTL_HOST."
  [[ -n "$USER" ]] || die "No user set. Use -u/--user or --profile, or set JELLYFINCTL_USER."
}

# ---------- Config handling ----------
load_profile() {
  local name="$1"
  [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
  # Simple INI-like parser: [profile]; key=value
  local in_section=0 line key val
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      [[ "${BASH_REMATCH[1]}" == "$name" ]] && in_section=1 || in_section=0
      continue
    fi
    (( in_section )) || continue
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
      case "$key" in
        host|HOST) HOST="$val" ;;
        user|USER) USER="$val" ;;
        port|PORT) PORT="$val" ;;
        identity|IDENTITY) IDENTITY="$val" ;;
      esac
    fi
  done < "$CONFIG_FILE"
  [[ -n "$HOST" && -n "$USER" ]] || die "Profile '$name' incomplete (need host & user)."
  debug "Loaded profile '$name' -> $USER@$HOST:$PORT"
}

# ---------- Arg parsing ----------
print_help() {
  sed -n '1,120p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--host) HOST="$2"; shift 2;;
    -u|--user) USER="$2"; shift 2;;
    -p|--port) PORT="$2"; shift 2;;
    -i|--identity) IDENTITY="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    -v|--verbose) VERBOSE=1; shift;;
    -n|--dry-run) DRY_RUN=1; shift;;
    -h|--help) print_help; exit 0;;
    --version) echo "jellyfinctl $VERSION"; exit 0;;
    *) break;;
  esac
done

(( VERBOSE )) && LOG_LEVEL=3

CMD="${1:-}"; shift || true

[[ -n "$PROFILE" ]] && load_profile "$PROFILE"
ensure_target

require_cmd ssh
require_cmd awk
require_cmd grep
require_cmd sed

# ---------- Command implementations ----------
cmd_init_ssh() {
  require_cmd ssh-copy-id
  local dest="$USER@$HOST"
  local args=()
  [[ -n "$PORT" ]] && args+=(-p "$PORT")
  [[ -n "$IDENTITY" ]] && args+=(-i "$IDENTITY")
  info "Copying local public key to $dest ..."
  if (( DRY_RUN )); then
    debug "(dry-run) ssh-copy-id ${args[*]} $dest"
  else
    ssh-copy-id "${args[@]}" "$dest"
  fi
}

cmd_mux_open() {
  info "Opening persistent SSH master connection to $USER@$HOST:$PORT ..."
  local args=("${ssh_base_args[@]}")
  [[ -n "$PORT" ]] && args+=(-p "$PORT")
  [[ -n "$IDENTITY" ]] && args+=(-i "$IDENTITY")
  if (( DRY_RUN )); then
    debug "(dry-run) ssh -N -f ${args[*]} $USER@$HOST"
  else
    ssh -N -f "${args[@]}" "$USER@$HOST" || true
  fi
}

cmd_mux_close() {
  info "Closing SSH master connection (if any) ..."
  local args=(-O exit -o "ControlPath=$SSH_CONTROL_PATH")
  [[ -n "$PORT" ]] && args+=(-p "$PORT")
  [[ -n "$IDENTITY" ]] && args+=(-i "$IDENTITY")
  if (( DRY_RUN )); then
    debug "(dry-run) ssh ${args[*]} $USER@$HOST"
  else
    ssh "${args[@]}" "$USER@$HOST" || true
  fi
}

cmd_whoami() {
  check_conn
  remote_run 'echo "User: $(id -un)"; echo "Host: $(hostname)"; echo "OS: $(grep -m1 PRETTY_NAME /etc/os-release | cut -d= -f2-)"; echo "Kernel: $(uname -r)"'
}

cmd_sysinfo() {
  check_conn
  remote_run '
    echo "== Uptime =="
    uptime || true
    echo
    echo "== CPU Load =="
    cat /proc/loadavg 2>/dev/null || true
    echo
    echo "== Memory =="
    free -h 2>/dev/null || true
    echo
    echo "== Disk =="
    df -hT / 2>/dev/null || true
    echo
    echo "== IPs =="
    ip -4 addr show | awk "/inet /{print \$2, \$NF}" || true
  '
}

_remote_has() { remote_run_quiet "command -v $1"; }

jf_guess_mode() {
  if remote_run_quiet 'systemctl list-units --type=service 2>/dev/null | grep -qi jellyfin'; then
    echo "systemd"
  elif remote_run_quiet 'docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^jellyfin$"'; then
    echo "docker"
  else
    echo "unknown"
  fi
}

cmd_jf_status() {
  check_conn
  local mode; mode=$(jf_guess_mode)
  case "$mode" in
    systemd)
      remote_run 'systemctl status jellyfin --no-pager || true; echo; echo "Listening sockets:"; ss -tulnp 2>/dev/null | grep -i jellyfin || true'
      ;;
    docker)
      remote_run 'docker ps --filter "name=jellyfin" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"; echo; docker logs --tail 50 jellyfin 2>/dev/null || true'
      ;;
    *)
      warn "Jellyfin not found via systemd or docker. Checking ports ..."
      remote_run 'ss -tulnp | grep -E ":8096|:8920" || echo "No listener on 8096/8920"'
      ;;
  esac
}

cmd_jf_start() {
  check_conn
  local mode; mode=$(jf_guess_mode)
  case "$mode" in
    systemd) remote_run 'sudo systemctl start jellyfin' ;;
    docker)  remote_run 'docker start jellyfin' ;;
    *) die "Jellyfin not installed (systemd/docker not found).";;
  esac
}

cmd_jf_restart() {
  check_conn
  local mode; mode=$(jf_guess_mode)
  case "$mode" in
    systemd) remote_run 'sudo systemctl restart jellyfin' ;;
    docker)  remote_run 'docker restart jellyfin' ;;
    *) die "Jellyfin not installed (systemd/docker not found).";;
  esac
}

cmd_jf_logs() {
  check_conn
  local lines="${1:-100}"
  local mode; mode=$(jf_guess_mode)
  case "$mode" in
    systemd) remote_run "journalctl -u jellyfin -n $lines --no-pager" ;;
    docker)  remote_run "docker logs --tail $lines jellyfin" ;;
    *) die "Jellyfin not installed (systemd/docker not found).";;
  esac
}

cmd_ufw() {
  check_conn
  remote_run 'if command -v ufw >/dev/null 2>&1; then sudo ufw status verbose; else echo "UFW not installed"; fi'
}

cmd_tailscale() {
  check_conn
  local sub="${1:-status}"; shift || true
  case "$sub" in
    status) remote_run 'if command -v tailscale >/dev/null 2>&1; then tailscale status; else echo "tailscale not installed"; fi' ;;
    ip)     remote_run 'if command -v tailscale >/dev/null 2>&1; then tailscale ip -4; else echo "tailscale not installed"; fi' ;;
    *) die "tailscale subcommand must be one of: status, ip";;
  esac
}

cmd_port_test() {
  local h="${1:-$HOST}"
  local p="${2:-8096}"
  info "Local test: nc -vz $h $p"
  if (( DRY_RUN )); then
    debug "(dry-run) nc -vz $h $p"
  else
    if command_exists nc; then
      nc -vz "$h" "$p" || true
    else
      warn "nc not available locally; skipping local test."
    fi
  fi
  echo
  info "Remote listening sockets:"
  remote_run "ss -tulnp | grep -E \":$p\" || echo \"No listener on :$p\""
}

cmd_check() {
  check_conn
  echo "== WHOAMI =="
  cmd_whoami
  echo
  echo "== SYSINFO =="
  cmd_sysinfo
  echo
  echo "== FIREWALL (UFW) =="
  cmd_ufw
  echo
  echo "== TAILSCALE =="
  cmd_tailscale status || true
  echo
  echo "== JELLYFIN =="
  cmd_jf_status
  echo
  echo "== PORT 8096 TEST =="
  cmd_port_test "$HOST" 8096
}

cmd_tmux_run() {
  check_conn
  local name="$1"; shift || die "Usage: tmux-run NAME CMD..."
  local cmd="$*"
  remote_run "tmux has-session -t \"$name\" 2>/dev/null && tmux kill-session -t \"$name\" 2>/dev/null || true; tmux new-session -d -s \"$name\" \"$cmd\"; tmux ls | grep -E \"^$name\" || true"
  echo "Started tmux session '$name' running: $cmd"
  echo "Attach with: ssh $USER@$HOST -p $PORT -t tmux attach -t $name"
}

find_remote_script() {
  local script_name="$1"
  # Common locations for user's repo/scripts
  local paths=(
    "~/git/scripts/$script_name"
    "~/scripts/$script_name"
    "~/$script_name"
    "/usr/local/bin/$script_name"
  )
  for p in "${paths[@]}"; do
    if remote_run_quiet "[ -x $p ]"; then
      echo "$p"; return 0
    fi
  done
  return 1
}

cmd_sync() {
  check_conn
  local what="${1:-}"; shift || die "Usage: sync shows|movies [args...]"
  local extra_args="$*"
  local script=""
  case "$what" in
    shows)  script=$(find_remote_script "sync_shows.sh")  || die "sync_shows.sh not found/executable on remote." ;;
    movies) script=$(find_remote_script "sync_movies.sh") || die "sync_movies.sh not found/executable on remote." ;;
    *) die "Usage: sync shows|movies [args...]" ;;
  esac
  local session="sync-$what"
  cmd_tmux_run "$session" "$script $extra_args"
}

cmd_run() {
  check_conn
  [[ $# -ge 1 ]] || die "Usage: run CMD..."
  remote_run "$*"
}

# ---------- Dispatch ----------
case "$CMD" in
  init-ssh)        cmd_init_ssh ;;
  mux-open)        cmd_mux_open ;;
  mux-close)       cmd_mux_close ;;
  whoami)          cmd_whoami ;;
  sysinfo)         cmd_sysinfo ;;
  check)           cmd_check ;;
  jf)
    sub="${1:-}"; shift || true
    case "$sub" in
      status)  cmd_jf_status ;;
      start)   cmd_jf_start ;;
      restart) cmd_jf_restart ;;
      logs)    cmd_jf_logs "${1:-100}" ;;
      *) die "Usage: jf {status|start|restart|logs [N]}" ;;
    esac
    ;;
  ufw)             cmd_ufw ;;
  tailscale)       cmd_tailscale "$@" ;;
  port-test)       cmd_port_test "$@" ;;
  tmux-run)        cmd_tmux_run "$@" ;;
  sync)            cmd_sync "$@" ;;
  run)             cmd_run "$@" ;;
  ""|-h|--help|help) print_help ;;
  *) die "Unknown command: $CMD. Use --help to see available commands." ;;
esac

exit 0

# ---------- TEMPLATE CONFIG (~/.config/jellyfinctl/config) ----------
# [wan]
# host=100.76.105.58
# user=moolman840
# port=22
# identity=~/.ssh/id_ed25519
#
# [lan]
# host=192.168.1.50
# user=moolman840
# port=22
# identity=~/.ssh/id_ed25519
