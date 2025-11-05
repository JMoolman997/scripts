#!/usr/bin/env bash
# c_setup.sh — bootstrap a minimal C project skeleton with optional git init
#
# SYNOPSIS
#   ./c_setup.sh COMMAND
#
# DESCRIPTION
#   Creates a conventional `src/`, `tests/`, and `build/` directory structure,
#   writes a starter Makefile, and can optionally initialise a git repository.
#   The script prefers the logging helpers from lib/log.sh but will fall back to
#   plain stderr messages when the library is unavailable.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! source "$SCRIPT_DIR/lib/log.sh" 2>/dev/null; then
  error() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
  warn()  { printf '[WARN]  %s\n' "$*" >&2; }
  info()  { printf '[INFO]  %s\n' "$*" >&2; }
fi

if ! declare -F log_info >/dev/null; then
  log_info() { info "$@"; }
fi
if ! declare -F log_warn >/dev/null; then
  log_warn() { warn "$@"; }
fi
if ! declare -F log_error >/dev/null; then
  log_error() { error "$@"; }
fi

PROJECT_ROOT="$(pwd)"
SRC_DIR="$PROJECT_ROOT/src"
TEST_DIR="$PROJECT_ROOT/tests"
BUILD_DIR="$PROJECT_ROOT/build"
MAKEFILE="$PROJECT_ROOT/Makefile"

: "${BINARY:=exec}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  scaffold   Create src/, tests/, build/, Makefile, and .gitignore
  git        Initialise a git repo, add files, and make the first commit
  all        Run both scaffold and git commands in sequence
  help       Show this message
EOF
}

init_scaffold() {
  log_info "Scaffolding project directories under $PROJECT_ROOT"
  mkdir -p "$SRC_DIR" "$TEST_DIR" "$BUILD_DIR"

  if [[ -e "$MAKEFILE" ]]; then
    log_error "Makefile already exists at $MAKEFILE"
    exit 1
  fi

  log_info "Generating Makefile..."
  cat >"$MAKEFILE" <<'MAKEEOF'
#—————————————————————————————————————————————
# Project Makefile – basic C build
#—————————————————————————————————————————————

CC      := gcc
CFLAGS  := -Wall -Wextra -Wpedantic -Werror -std=c11 -O2
SRC_DIR := src
OBJ_DIR := build
BINARY  := ${BINARY}

SOURCES := $(wildcard $(SRC_DIR)/*.c)
OBJS    := $(patsubst $(SRC_DIR)/%.c,$(OBJ_DIR)/%.o,$(SOURCES))

.PHONY: all clean help

all: $(OBJ_DIR)/$(BINARY)

$(OBJ_DIR)/$(BINARY): $(OBJS)
	@echo "[LD] $@"
	$(CC) $(CFLAGS) -o $@ $^

$(OBJ_DIR)/%.o: $(SRC_DIR)/%.c | $(OBJ_DIR)
	@echo "[CC] $<"
	$(CC) $(CFLAGS) -c -o $@ $<

$(OBJ_DIR):
	mkdir -p $(OBJ_DIR)

clean:
	@echo "[CLEAN] removing build artifacts"
	rm -rf $(OBJ_DIR)/*

help:
	@echo "Usage: make [target]"
	@echo
	@echo "Targets:"
	@echo "  all    Build the '$(BINARY)' executable"
	@echo "  clean  Remove build artifacts in '$(OBJ_DIR)'"
	@echo "  help   Show this help message"
MAKEEOF

  log_info $'Created project layout:\n'\
$'  • '"$SRC_DIR"$'\n'\
$'  • '"$TEST_DIR"$'\n'\
$'  • '"$BUILD_DIR"$'\n'\
$'  • '"$MAKEFILE"$'\n'
}

init_git() {
  if [[ -d .git ]]; then
    log_error "A git repository already exists at $PROJECT_ROOT"
    exit 1
  fi

  if ! command -v git >/dev/null 2>&1; then
    log_error "git command not found"
    exit 1
  fi

  log_info "Writing .gitignore..."
  cat >"$PROJECT_ROOT/.gitignore" <<'GITEOF'
# build artifacts
build/

# object files
*.o

# executables
app

# editor swap/temp
*~
*.swp

# macOS
.DS_Store

# logs
*.log
GITEOF

  log_info "Initialising git repository..."
  git init
  git add .
  git commit -m "Initial commit"
  log_info "Git repo initialised – first commit created."
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  case "$1" in
    scaffold)
      init_scaffold
      ;;
    git)
      init_git
      ;;
    all)
      init_scaffold
      init_git
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      log_error "Unknown command: $1"
      usage
      exit 1
      ;;
  esac
}

main "$@"
