# Downloading utilities (git, curl)

# Download file with curl (to current dir)
download_file() {
    local url="$1" dest="${2:-$(basename "$url")}"
    curl -fLO -o "$dest" "$url" || error "Download failed: $url"
    log "Downloaded $url → $dest"
}

# Git clone or pull (update if exists)
git_clone_or_pull() {
    local repo="$1" dir="$2"
    if [[ -d "$dir" ]]; then
        git -C "$dir" pull || error "Git pull failed in $dir"
        log "Updated $dir from $repo"
    else
        git clone "$repo" "$dir" || error "Git clone failed: $repo"
        log "Cloned $repo → $dir"
    fi
}

# Download and extract zip (e.g., for fonts/tools)
download_and_unzip() {
    local url="$1" dir="$2"
    local zip="${url##*/}"
    download_file "$url" "$zip"
    unzip -o "$zip" -d "$dir" || error "Unzip failed: $zip"
    rm -f "$zip"
    log "Unzipped $url → $dir"
}

export -f download_file git_clone_or_pull download_and_unzip
