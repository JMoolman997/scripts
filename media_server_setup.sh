#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! source "$SCRIPT_DIR/lib/log.sh" 2>/dev/null; then
  error() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
  warn()  { printf '[WARN]  %s\n' "$*" >&2; }
  info()  { printf '[INFO]  %s\n' "$*" >&2; }
fi

if [[ -f "$SCRIPT_DIR/lib/system_info.sh" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/system_info.sh"
fi

usage() {
  cat <<'EOF'
Usage: media_server_setup.sh [options]

Options:
  --user NAME           Target user that should own media directories (default: current user)
  --media-dir PATH      Media root (default: /home/<user>/Videos)
  --[no-]jellyfin       Enable/disable Jellyfin install (default: enabled)
  --[no-]xfce           Enable/disable XFCE desktop install (default: enabled)
  --[no-]samba          Enable/disable Samba setup (default: enabled)
  --[no-]docker         Enable/disable Docker install (default: disabled)
  -h, --help            Show this help text

Environment overrides:
  INSTALL_JELLYFIN, INSTALL_XFCE, INSTALL_SAMBA, INSTALL_DOCKER (0/1 flags)
  MEDIA_DIR, TARGET_USER
EOF
  exit "${1:-0}"
}

bool_from_env() {
  local value="$1"
  local normalized="${value,,}"
  if [[ "$normalized" =~ ^(0|false|no)$ ]]; then
    printf '0'
  else
    printf '1'
  fi
}

INSTALL_JELLYFIN="$(bool_from_env "${INSTALL_JELLYFIN:-1}")"
INSTALL_XFCE="$(bool_from_env "${INSTALL_XFCE:-1}")"
INSTALL_SAMBA="$(bool_from_env "${INSTALL_SAMBA:-1}")"
INSTALL_DOCKER="$(bool_from_env "${INSTALL_DOCKER:-0}")"
USER_NAME="${TARGET_USER:-$USER}"
MEDIA_DIR="${MEDIA_DIR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      USER_NAME="$2"; shift 2;;
    --media-dir)
      MEDIA_DIR="$2"; shift 2;;
    --jellyfin)        INSTALL_JELLYFIN=1; shift;;
    --no-jellyfin)     INSTALL_JELLYFIN=0; shift;;
    --xfce)            INSTALL_XFCE=1; shift;;
    --no-xfce)         INSTALL_XFCE=0; shift;;
    --samba)           INSTALL_SAMBA=1; shift;;
    --no-samba)        INSTALL_SAMBA=0; shift;;
    --docker)          INSTALL_DOCKER=1; shift;;
    --no-docker)       INSTALL_DOCKER=0; shift;;
    -h|--help)         usage 0;;
    --) shift; break;;
    -*)
      error "Unknown flag: $1"
      ;;
    *)
      # Backwards compatibility: allow positional user override
      USER_NAME="$1"
      shift
      ;;
  esac
done

if [[ -z "$MEDIA_DIR" ]]; then
  MEDIA_DIR="/home/${USER_NAME}/Videos"
fi

# Expand ~ expressions safely.
if [[ "$MEDIA_DIR" == ~* ]]; then
  MEDIA_DIR="$(eval echo "$MEDIA_DIR")"
fi

[[ "$EUID" -eq 0 ]] || error "This script must be run as root"

if declare -F detect_os >/dev/null 2>&1; then
  HOST_OS="$(detect_os)"
else
  if [[ -f /etc/debian_version ]]; then
    HOST_OS="debian"
  else
    HOST_OS="unknown"
  fi
fi

[[ "$HOST_OS" == "debian" ]] || error "Only Debian-based systems are supported (APT required)."
command -v apt >/dev/null 2>&1 || error "apt not found; please run on a Debian/Ubuntu host."

info "Starting media server setup for user: $USER_NAME"

info "Updating APT packages..."
apt update && apt upgrade -y

if [[ "$INSTALL_XFCE" -eq 1 ]]; then
  info "Installing XFCE desktop environment..."
  apt install -y xfce4 lightdm
  systemctl enable lightdm
else
  warn "XFCE installation skipped"
fi

if [[ "$INSTALL_JELLYFIN" -eq 1 ]]; then
  info "Installing Jellyfin media server..."
  apt install -y apt-transport-https curl gnupg
  curl -fsSL https://repo.jellyfin.org/debian/jellyfin_team.gpg.key | gpg --dearmor -o /usr/share/keyrings/jellyfin-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/jellyfin-archive-keyring.gpg] https://repo.jellyfin.org/debian bookworm main" > /etc/apt/sources.list.d/jellyfin.list
  apt update
  apt install -y jellyfin
  systemctl enable --now jellyfin
else
  warn "Jellyfin installation skipped"
fi

if [[ "$INSTALL_SAMBA" -eq 1 ]]; then
  info "Installing Samba..."
  apt install -y samba
  tee -a /etc/samba/smb.conf > /dev/null <<EOF

[Media]
   path = $MEDIA_DIR
   browseable = yes
   read only = no
   guest ok = yes
EOF
  systemctl restart smbd
else
  warn "Samba installation skipped"
fi

if [[ "$INSTALL_DOCKER" -eq 1 ]]; then
  info "Installing Docker..."
  apt install -y ca-certificates gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
    > /etc/apt/sources.list.d/docker.list
  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  usermod -aG docker "$USER_NAME"
else
  warn "Docker installation skipped"
fi

info "Ensuring media directory exists..."
mkdir -p "$MEDIA_DIR"
chown "$USER_NAME:$USER_NAME" "$MEDIA_DIR"

info "Media server setup complete."
custom_log "Access" "$COLOR_CYAN" "Jellyfin available at http://<your-ip>:8096 if installed"
