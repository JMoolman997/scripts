# Shared, read-only project detection for the public development tools.

project_dir() {
  local requested="${1:?project path required}"
  local resolved
  resolved="$(realpath -e -- "$requested")" || {
    printf 'Project path does not exist: %s\n' "$requested" >&2
    return 64
  }
  [[ -d "$resolved" ]] || {
    printf 'Project path is not a directory: %s\n' "$resolved" >&2
    return 64
  }
  printf '%s\n' "$resolved"
}

find_cmake_build() {
  local project="$1" dir
  for dir in build cmake-build-debug cmake-build-release out/build; do
    [[ -f "$project/$dir/CMakeCache.txt" ]] && { printf '%s\n' "$dir"; return 0; }
  done
  return 1
}

find_meson_build() {
  local project="$1" dir
  for dir in build builddir; do
    [[ -f "$project/$dir/meson-private/coredata.dat" ]] && { printf '%s\n' "$dir"; return 0; }
  done
  return 1
}
