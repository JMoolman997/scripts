#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Load logging library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/log.sh"

# ---- CONFIG ---- #
USER_NAME="${1:-$USER}"
MEDIA_DIR="/home/${USER_NAME}/Videos"
INSTALL_JELLYFIN=true
INSTALL_XFCE=true
INSTALL_SAMBA=true
INSTALL_DOCKER=false

# ---- SYSTEM CHECK ---- #
info "Starting media server setup for user: $USER_NAME"
[[ "$EUID" -ne 0 ]] && error "This script must be run as root"

# ---- PACKAGE UPDATE ---- #
info "Updating APT packages..."
apt update && apt upgrade -y

# ---- DESKTOP ---- #
if $INSTALL_XFCE; then
  info "Installing XFCE desktop environment..."
  apt install -y xfce4 lightdm
  systemctl enable lightdm
else
  warn "XFCE installation skipped"
fi

# ---- JELLYFIN ---- #
if $INSTALL_JELLYFIN; then
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

# ---- SAMBA ---- #
if $INSTALL_SAMBA; then
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

# ---- DOCKER ---- #
if $INSTALL_DOCKER; then
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

# ---- USER SETUP ---- #
info "Ensuring media directory exists..."
mkdir -p "$MEDIA_DIR"
chown "$USER_NAME:$USER_NAME" "$MEDIA_DIR"

# ---- DONE ---- #
info "Media server setup complete."
custom_log "Access" "$COLOR_CYAN" "Jellyfin available at http://<your-ip>:8096 if installed"
