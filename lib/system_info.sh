# lib/system_info.sh — detect host OS and summarize hardware details
#
# The helpers in this file can be sourced by any script to expose a consistent
# interface for environmental inspection.  They intentionally provide
# overrides—`SC_SYSTEM_INFO_OS` and `SC_SYSTEM_INFO_ROOT`—so tests can emulate
# different platforms without mutating real system files.

if [[ -z "${__SYSTEM_INFO_SH_SOURCED:-}" ]]; then
  readonly __SYSTEM_INFO_SH_SOURCED=1

  __system_info_bind_logging() {
    if ! declare -F log_error >/dev/null; then
      if declare -F error >/dev/null; then
        log_error(){ error "$@"; }
      else
        log_error(){ printf '[ERROR] %s\n' "$*" >&2; }
      fi
    fi
  }

  __system_info_bind_logging
fi

: "${SC_SYSTEM_INFO_ROOT:=/}"

# Detect the host operating system. Supported values: macos, debian, arch, fedora.
detect_os() {
  if [[ -n "${SC_SYSTEM_INFO_OS:-}" ]]; then
    printf '%s\n' "$SC_SYSTEM_INFO_OS"
    return 0
  fi

  case "$OSTYPE" in
    darwin*)  printf 'macos\n' ;;
    linux*)
      if [[ -f "$SC_SYSTEM_INFO_ROOT/etc/debian_version" ]]; then
        printf 'debian\n'
      elif [[ -f "$SC_SYSTEM_INFO_ROOT/etc/arch-release" ]]; then
        printf 'arch\n'
      elif [[ -f "$SC_SYSTEM_INFO_ROOT/etc/fedora-release" ]]; then
        printf 'fedora\n'
      else
        log_error 'Unsupported Linux distro'
        return 1
      fi
      ;;
    *)
      log_error "Unsupported OS: $OSTYPE"
      return 1
      ;;
  esac
}

# Get CPU information (model + core count).
get_cpu_info() {
  local os
  os="$(detect_os)" || return 1

  if [[ "$os" == "macos" ]]; then
    sysctl -n machdep.cpu.brand_string
    printf 'Cores: %s\n' "$(sysctl -n hw.ncpu)"
  else
    local cpuinfo="$SC_SYSTEM_INFO_ROOT/proc/cpuinfo"
    local model
    model="$(grep -m1 'model name' "$cpuinfo" 2>/dev/null | cut -d: -f2- | sed 's/^ *//')"
    [[ -n "$model" ]] || model='Unknown CPU'
    printf 'Model: %s\n' "$model"

    local cores
    if command -v nproc >/dev/null 2>&1; then
      cores="$(nproc --all)"
    else
      cores="$(grep -c '^processor' "$cpuinfo" 2>/dev/null || echo 0)"
    fi
    printf 'Cores: %s\n' "$cores"
  fi
}

# Get total RAM in MB.
get_total_ram() {
  local os
  os="$(detect_os)" || return 1

  if [[ "$os" == "macos" ]]; then
    sysctl -n hw.memsize | awk '{printf "%.0f MB\n", $1 / 1024 / 1024}'
  else
    local meminfo="$SC_SYSTEM_INFO_ROOT/proc/meminfo"
    local kb
    kb="$(awk '/MemTotal:/ {print $2}' "$meminfo" 2>/dev/null)"
    if [[ -n "$kb" ]]; then
      awk -v kb="$kb" 'BEGIN { printf "%.0f MB\n", kb / 1024 }'
    else
      free -m | awk '/Mem:/ {print $2 " MB"}'
    fi
  fi
}

# Get disk usage for the root filesystem (used/total with percentage).
get_disk_info() {
  df -h / | tail -1 | awk '{print "Used: " $3 " / Total: " $2 " (" $5 " used)"}'
}

# Get the remaining free space on the root filesystem.
get_free_disk() {
  df -h / | tail -1 | awk '{print $4 " free"}'
}

# Environment info helpers.
get_current_user() { whoami; }
get_current_dir()  { pwd; }
get_path()         { printf '%s\n' "$PATH"; }
get_env_var()      { local var="${1:?var name required}"; printf '%s\n' "${!var:-unset}"; }

export -f detect_os get_cpu_info get_total_ram get_disk_info get_free_disk
export -f get_current_user get_current_dir get_path get_env_var
