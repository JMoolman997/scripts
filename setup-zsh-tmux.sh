#!/usr/bin/env bash
# setup-zsh-tmux.sh — Bootstrap zsh + tmux environment
#
# SYNOPSIS
#   ./setup-zsh-tmux.sh [--dotfiles-dir PATH] [--dry-run] [--no-network] [--help]
#
# DESCRIPTION
# Installs (or verifies) zsh, tmux, and supporting plugins using repo-local
# helpers when available. Backs up existing dotfiles, links in managed versions,
# and optionally updates a dotfiles Git repository. Designed to be idempotent so
# it can be re-run safely on the same host.
#
# OPTIONS
#   --dotfiles-dir PATH   Override the dotfiles source directory (default:
#                         $HOME/dotfiles or DOTFILES_DIR env var)
#   --dry-run             Print actions without applying filesystem changes
#   --no-network          Skip package installs and Git clones/pulls
#   --help                Show this help/usage text
#
# ENV VARS
#   DOTFILES_DIR          Dotfiles repository (default: $HOME/dotfiles)
#   LIB_DIR               Override path to repo lib/ helpers
#   BACKUP_DIR            Destination for displaced config files (timestamped)
#   VERBOSE=1             Enable additional debug logging (fallback logger only)
#
# EXIT CODES
#   0 on success; non-zero propagated from failed commands.

set -euo pipefail
IFS=$'\n\t'

######################
# Defaults & ENV
######################
canon_path() {
  local path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path"
    return
  fi
  if command -v grealpath >/dev/null 2>&1; then
    grealpath "$path"
    return
  fi
  # Manual fallback keeps relative segments resolvable
  if [[ -d "$path" ]]; then
    (cd "$path" >/dev/null 2>&1 && pwd) || printf '%s\n' "$path"
    return
  fi
  local dir base
  dir="$(cd "$(dirname "$path")" >/dev/null 2>&1 && pwd)" || {
    printf '%s\n' "$path"
    return
  }
  base="$(basename "$path")"
  printf '%s/%s\n' "$dir" "$base"
}

resolve_source() {
  if ! command -v readlink >/dev/null 2>&1; then
    printf '%s\n' "$1"
    return
  fi
  local source_path="$1" dir target
  while [[ -L "$source_path" ]]; do
    dir="$(cd "$(dirname "$source_path")" >/dev/null 2>&1 && pwd)"
    target="$(readlink "$source_path")" || break
    if [[ "$target" != /* ]]; then
      source_path="$dir/$target"
    else
      source_path="$target"
    fi
  done
  printf '%s\n' "$source_path"
}

SCRIPT_SOURCE="$(resolve_source "${BASH_SOURCE[0]:-$0}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
LIB_DIR="${LIB_DIR:-$SCRIPT_DIR/lib}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/dotfiles_backup/$(date +%Y%m%d_%H%M%S)}"
DRY_RUN=0
NO_NETWORK=0

######################
# Parse CLI
######################
usage() {
  cat <<EOF
Usage: $0 [--dotfiles-dir PATH] [--dry-run] [--no-network] [--help]

Options:
  --dotfiles-dir PATH   Location of your dotfiles (default: $DOTFILES_DIR)
  --dry-run             Print actions but don't execute (safe check)
  --no-network          Skip cloning / network installs (useful offline)
  --help                Show this help
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dotfiles-dir) DOTFILES_DIR="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --no-network) NO_NETWORK=1; shift;;
    --help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

######################
# Helpers (log fallback)
######################
# try to source lib log first; otherwise define minimal logger
if [[ -f "$LIB_DIR/log.sh" ]]; then
  # shellcheck source=/dev/null
  source "$LIB_DIR/log.sh"
fi

if ! declare -F log_info >/dev/null; then
  if declare -F info >/dev/null; then
    log_info(){ info "$@"; }
  else
    log_info(){ printf '\033[1;34m→ %s\033[0m\n' "$*"; }
  fi
fi
if ! declare -F log_warn >/dev/null; then
  if declare -F warn >/dev/null; then
    log_warn(){ warn "$@"; }
  else
    log_warn(){ printf '\033[1;33m! %s\033[0m\n' "$*"; }
  fi
fi
if ! declare -F log_error >/dev/null; then
  if declare -F error >/dev/null; then
    log_error(){ error "$@"; }
  else
    log_error(){ printf '\033[1;31m✖ %s\033[0m\n' "$*"; }
  fi
fi
if ! declare -F log_debug >/dev/null; then
  if declare -F debug >/dev/null; then
    log_debug(){ debug "$@"; }
  else
    log_debug(){ [[ "${VERBOSE:-}" == "1" ]] && printf '  debug: %s\n' "$*"; }
  fi
fi

######################
# Source optional libs (pkg_utils, file_utils, system_info)
######################
if [[ -f "$LIB_DIR/pkg_utils.sh" ]]; then
  # shellcheck source=/dev/null
  source "$LIB_DIR/pkg_utils.sh"
  log_info "Loaded pkg utilities from $LIB_DIR/pkg_utils.sh"
fi

if [[ -f "$LIB_DIR/file_utils.sh" ]]; then
  # shellcheck source=/dev/null
  source "$LIB_DIR/file_utils.sh"
  log_info "Loaded file utilities from $LIB_DIR/file_utils.sh"
fi

if [[ -f "$LIB_DIR/system_info.sh" ]]; then
  # shellcheck source=/dev/null
  source "$LIB_DIR/system_info.sh"
  log_info "Loaded system info helper from $LIB_DIR/system_info.sh"
fi

######################
# Small portable helpers (used if lib versions absent)
######################
safe_mkdir() {
  local dir="$1"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "DRY RUN: mkdir -p \"$dir\""
  else
    mkdir -p "$dir"
  fi
}

now_ts(){ date +%Y%m%d_%H%M%S; }

# safe symlink: if target exists and is not a symlink, move to backup and create symlink
safe_link() {
  local src="$1" dst="$2" backup_target resolved_src resolved_dst
  if [[ ! -e "$src" ]]; then
    log_warn "Source missing for link: $src"
    return 0
  fi

  if [[ -e "$dst" && ! -L "$dst" ]]; then
    log_warn "Backing up existing $dst -> $BACKUP_DIR/$(basename "$dst")"
    safe_mkdir "$BACKUP_DIR"
    backup_target="$BACKUP_DIR/$(basename "$dst")"
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "DRY RUN: mv \"$dst\" \"$backup_target\""
    else
      mv "$dst" "$backup_target"
    fi
  fi
  if [[ -L "$dst" ]]; then
    # already a symlink; verify it points to src
    resolved_src="$(canon_path "$src")"
    resolved_dst="$(canon_path "$(resolve_source "$dst")")"
    if [[ -n "$resolved_src" && -n "$resolved_dst" && "$resolved_src" == "$resolved_dst" ]]; then
      log_info "Symlink already correct: $dst -> $src"
      return 0
    fi
    log_info "Replacing stale symlink $dst -> $src"
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "DRY RUN: rm -f \"$dst\""
    else
      rm -f "$dst"
    fi
  fi
  safe_mkdir "$(dirname "$dst")"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "DRY RUN: ln -s \"$src\" \"$dst\""
  else
    ln -s "$src" "$dst"
    log_info "Linked: $dst -> $src"
  fi
}

# run or echo when dry-run
run_cmd() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "DRY RUN: $*"
  else
    log_info "RUN: $*"
    eval "$@"
  fi
}

######################
# OS detection & package installation (tries pkg_utils if available)
######################
detect_pkg_manager() {
  if command -v apt >/dev/null 2>&1; then
    PKG_MANAGER=apt
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER=pacman
  elif command -v brew >/dev/null 2>&1; then
    PKG_MANAGER=brew
  else
    PKG_MANAGER=unknown
  fi
  export PKG_MANAGER
  log_info "Detected package manager: $PKG_MANAGER"
}

install_packages() {
  local pkgs=(zsh tmux fzf)
  if [[ $NO_NETWORK -eq 1 ]]; then
    log_info "NO_NETWORK enabled: skipping package install for ${pkgs[*]}"
    return 0
  fi
  # If pkg_utils provides install_packages or pkg_install function, use it
  if declare -f pkg_utils::install >/dev/null 2>&1; then
    log_info "Using pkg_utils::install to install: ${pkgs[*]}"
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "DRY RUN: pkg_utils::install ${pkgs[*]}"
    else
      pkg_utils::install "${pkgs[@]}"
    fi
    return 0
  fi

  # Fallback per-manager
  case "$PKG_MANAGER" in
    apt)
      run_cmd "sudo apt update && sudo apt install -y ${pkgs[*]}"
      ;;
    pacman)
      run_cmd "sudo pacman -Syu --noconfirm ${pkgs[*]}"
      ;;
    brew)
      for p in "${pkgs[@]}"; do run_cmd "brew install $p"; done
      ;;
    *)
      log_warn "Unknown package manager. Please install: ${pkgs[*]} manually."
      ;;
  esac
}

######################
# Backup existing config files
######################
backup_configs() {
  local files=( "$HOME/.zshrc" "$HOME/.tmux.conf" "$HOME/.zshenv" "$HOME/.config/tmux" )
  safe_mkdir "$BACKUP_DIR"
  for f in "${files[@]}"; do
    if [[ -e "$f" && ! -L "$f" ]]; then
      log_info "Backing up $f -> $BACKUP_DIR/$(basename "$f")"
      if [[ $DRY_RUN -eq 1 ]]; then
        log_info "DRY RUN: mv '$f' '$BACKUP_DIR/$(basename "$f")'"
      else
        mv "$f" "$BACKUP_DIR/$(basename "$f")"
      fi
    fi
  done
}

######################
# Clone or update dotfiles repo (if it's a repo path); otherwise assume DOTFILES_DIR already present
######################
update_dotfiles_dir() {
  if [[ $NO_NETWORK -eq 1 ]]; then
    log_info "NO_NETWORK enabled: skipping dotfiles repo update"
    return
  fi
  if [[ -d "$DOTFILES_DIR/.git" ]]; then
    log_info "Updating dotfiles repo at $DOTFILES_DIR"
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "DRY RUN: git -C '$DOTFILES_DIR' pull --ff-only"
    else
      git -C "$DOTFILES_DIR" pull --ff-only || true
    fi
  else
    log_info "No git repo found at $DOTFILES_DIR — skipping update (if you want cloning, pass a git URL into DOTFILES_DIR or clone manually)"
  fi
}

######################
# Zsh setup
######################
setup_zsh() {
  log_info "Setting up zsh"
  # ensure zsh installed
  if ! command -v zsh >/dev/null 2>&1; then
    if [[ $NO_NETWORK -eq 1 ]]; then
      log_warn "zsh not found and --no-network specified; install it manually."
    else
      log_info "zsh not found — installing"
      install_packages
    fi
  fi

  # OH-MY-ZSH: clone to ~/.oh-my-zsh if network allowed and not present
  if [[ $NO_NETWORK -eq 0 ]]; then
    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
      if [[ $DRY_RUN -eq 1 ]]; then
        log_info "DRY RUN: git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git ~/.oh-my-zsh"
      else
        log_info "Cloning Oh My Zsh"
        git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"
      fi
    else
      log_info "Updating Oh My Zsh"
      if [[ $DRY_RUN -eq 0 ]]; then git -C "$HOME/.oh-my-zsh" pull --ff-only || true; fi
    fi
  else
    log_info "NO_NETWORK: skipping Oh My Zsh clone/update"
  fi

  # prefer dotfiles zsh config if present
  if [[ -f "$DOTFILES_DIR/zsh/.zshrc" ]]; then
    safe_link "$DOTFILES_DIR/zsh/.zshrc" "$HOME/.zshrc"
  else
    # generate minimal .zshrc that sources oh-my-zsh if present
    if [[ ! -f "$HOME/.zshrc" || -L "$HOME/.zshrc" ]]; then
      local tmp="$HOME/.zshrc"
      log_info "Generating minimal $tmp"
      if [[ $DRY_RUN -eq 1 ]]; then
        log_info "DRY RUN: write minimal zshrc to $tmp"
      else
        cat > "$tmp" <<'EOF'
# Minimal auto-generated .zshrc
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git)
[ -s "$ZSH/oh-my-zsh.sh" ] && source "$ZSH/oh-my-zsh.sh"
EOF
      fi
    fi
  fi

  # set default shell to zsh for current user if not already
  if [[ "$(basename "$SHELL")" != "zsh" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "DRY RUN: chsh -s $(command -v zsh)"
    else
      if chsh -s "$(command -v zsh)" "$(whoami)" >/dev/null 2>&1; then
        log_info "Changed default shell to zsh"
      else
        log_warn "Unable to change shell automatically; you may need to run: chsh -s $(command -v zsh)"
      fi
    fi
  fi
}

######################
# Tmux setup
######################
setup_tmux() {
  log_info "Setting up tmux"
  if ! command -v tmux >/dev/null 2>&1; then
    if [[ $NO_NETWORK -eq 1 ]]; then
      log_warn "tmux not found and --no-network specified; install it manually."
    else
      log_info "tmux not found — installing"
      install_packages
    fi
  fi

  if [[ -f "$DOTFILES_DIR/tmux/.tmux.conf" ]]; then
    safe_link "$DOTFILES_DIR/tmux/.tmux.conf" "$HOME/.tmux.conf"
  else
    # minimal tmux.conf
    if [[ ! -f "$HOME/.tmux.conf" ]]; then
      if [[ $DRY_RUN -eq 1 ]]; then
        log_info "DRY RUN: create minimal ~/.tmux.conf"
      else
        cat > "$HOME/.tmux.conf" <<'EOF'
# Minimal tmux config
set -g mouse on
set -g history-limit 10000
EOF
        log_info "Wrote minimal ~/.tmux.conf"
      fi
    fi
  fi

  # Install TPM (tmux plugin manager)
  if [[ $NO_NETWORK -eq 0 ]]; then
    if [[ ! -d "$HOME/.tmux/plugins/tpm" ]]; then
      if [[ $DRY_RUN -eq 1 ]]; then
        log_info "DRY RUN: git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm"
      else
        git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
      fi
    else
      log_info "TPM already present; updating"
      if [[ $DRY_RUN -eq 0 ]]; then git -C "$HOME/.tmux/plugins/tpm" pull --ff-only || true; fi
    fi

    # offer to auto-install plugins (this requires running tmux command to trigger TPM)
    if [[ $DRY_RUN -eq 0 ]]; then
      if tmux list-sessions >/dev/null 2>&1; then
        log_info "Running TPM plugin install (inside tmux session)"
        "$HOME/.tmux/plugins/tpm/bin/install_plugins" || true
      else
        log_info "To install tmux plugins now: start tmux and run: prefix + I (capital i) or run: ~/.tmux/plugins/tpm/bin/install_plugins"
      fi
    else
      log_info "DRY RUN: would suggest running TPM installer after starting tmux"
    fi
  else
    log_info "NO_NETWORK: skipping TPM clone/update"
  fi
}

######################
# Main
######################
main() {
  log_info "Starting zsh+tmux bootstrap"
  detect_pkg_manager
  backup_configs
  update_dotfiles_dir

  if [[ $NO_NETWORK -eq 0 ]]; then
    log_info "Network allowed: cloning/updating components as needed"
  else
    log_info "NO_NETWORK enabled: skipping network actions (clones/remote installs)"
  fi

  if [[ $NO_NETWORK -eq 0 ]]; then
    install_packages
  else
    log_info "NO_NETWORK enabled: skipping bulk package install step"
  fi
  setup_zsh
  setup_tmux

  log_info "Bootstrap complete."
  log_info "Backups (if any) stored in: $BACKUP_DIR"
  log_info "Make sure to open a NEW shell or re-login to start using zsh"
}

main "$@"
