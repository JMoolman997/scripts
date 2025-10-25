# File operations

backup_file() {
    local file="$1"
    local bdir="$HOME/.backup-$(date +%Y%m%d-%H%M%S)"
    [[ -f "$file" || -L "$file" ]] || return 0
    mkdir -p "$bdir"
    cp -a "$file" "$bdir/"
    log "Backed up $file → $bdir"
}

symlink() {
    local src="$1" dest="$2"
    backup_file "$dest"
    ln -sf "$src" "$dest"
    log "Linked $dest → $src"
}

export -f backup_file symlink
