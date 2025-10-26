# lib/pkg_utils.sh — thin wrappers around common package managers
#
# Each helper intentionally keeps logic minimal so that scripts can compose
# additional flags as needed.  Commands are exported to simplify re-use in
# subshells executed via `bash -c`.

install_with_brew()   { brew install "$@"; }
install_with_apt()    { sudo apt update && sudo apt install -y "$@"; }
install_with_pacman() { sudo pacman -Syu --noconfirm "$@"; }
install_with_dnf()    { sudo dnf install -y "$@"; }

export -f install_with_brew install_with_apt install_with_pacman install_with_dnf
