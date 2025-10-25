# OS, hardware, and environment detection

# Detect OS (macos, debian, arch, fedora)
detect_os() {
    case "$OSTYPE" in
        darwin*)  echo "macos" ;;
        linux*)
            if   [ -f /etc/debian_version ]; then echo "debian"
            elif [ -f /etc/arch-release   ]; then echo "arch"
            elif [ -f /etc/fedora-release ]; then echo "fedora"
            else error "Unsupported Linux distro"  # Requires logging.sh if sourced alone
            fi ;;
        *) error "Unsupported OS: $OSTYPE" ;;
    esac
}

# Get CPU info (cores, model)
get_cpu_info() {
    local os=$(detect_os)
    if [[ $os == "macos" ]]; then
        sysctl -n machdep.cpu.brand_string
        echo "Cores: $(sysctl -n hw.ncpu)"
    else
        echo "Model: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
        echo "Cores: $(nproc --all 2>/dev/null || grep -c '^processor' /proc/cpuinfo)"
    fi
}

# Get total RAM in MB
get_total_ram() {
    local os=$(detect_os)
    if [[ $os == "macos" ]]; then
        sysctl -n hw.memsize | awk '{print $1 / 1024 / 1024 " MB"}'
    else
        free -m | awk '/Mem:/ {print $2 " MB"}'
    fi
}

# Get disk usage (root partition: used/total in GB, % used)
get_disk_info() {
    df -h / | tail -1 | awk '{print "Used: " $3 " / Total: " $2 " (" $5 " used)"}'
}

# Get free disk space in GB (root)
get_free_disk() {
    df -h / | tail -1 | awk '{print $4 " free"}'
}

# Environment info
get_current_user() { whoami; }
get_current_dir()  { pwd; }
get_path()         { echo "$PATH"; }
get_env_var()      { local var="$1"; echo "${!var:-unset}"; }  # e.g., get_env_var HOME

export -f detect_os get_cpu_info get_total_ram get_disk_info get_free_disk
export -f get_current_user get_current_dir get_path get_env_var
