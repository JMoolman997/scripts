#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

#__Source_shared_functions__#
SCRIPT_PATH="${BASH_SOURCE[0]}"
# resolve symlink
while [ -L "$SCRIPT_PATH" ]; do
	SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

LOG_LIB="$SCRIPT_DIR/lib/log.sh"
if [[ ! -f "$LOG_LIB" ]]; then
	echo "[ERROR] Could not find $LOG_LIB" >&2
	exit 1
fi

# shellcheck 
. "$LOG_LIB"

info "log.sh sourced succesfully"

#__CONFIGURATION__#
PROJECT_ROOT="$(pwd)"
SRC_DIR="$PROJECT_ROOT/src"
TEST_DIR="$PROJECT_ROOT/tests"
BUILD_DIR="$PROJECT_ROOT/build"
MAKEFILE="$PROJECT_ROOT/Makefile"

: "${BINARY:=exec}"

#__HELPERS__#
usage() {
  printf '\e[94m[Usage]\e[0m %s\n\n' "$(basename "$0") <command>"
  cat <<EOF
Commands:
  scaffold   Create src/, tests/, build/, Makefile & .gitignore
  git        Initialize a Git repo, add all files, make initial commit
  all        Do both scaffold + git
  help       Show this message
EOF
}

#__Init project function__
init_scaffold() {
info "Scaffolding in: $PROJECT_ROOT"
mkdir -p "$SRC_DIR" "$TEST_DIR" "$BUILD_DIR"

if [[ -e "$MAKEFILE" ]]; then
	error "Makefile already exists at $MAKEFILE"
fi

info "Generating Makefile…"

cat > "$MAKEFILE" << 'EOF'
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

.PHONY: all clean test help

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
EOF

info $'Done! The following has been created:\n'\
$'  • '"$PROJECT_ROOT"$'\n'\
$'  • '"$SRC_DIR"$'\n'\
$'  • '"$TEST_DIR"$'\n'\
$'  • '"$BUILD_DIR"$'\n'\
$'  • '"$MAKEFILE"$'\n'

}

#__Git init function__
init_git() {
info "Writing .gitignore…"
cat > "$PROJECT_ROOT/.gitignore" <<'EOF'
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
EOF

info "Initializing git repository…"
if [ -d .git ]; then
	error "A Git repo already exists here."
fi
git init
git add .
git commit -m "Initial commit"
info "Git repo initialized – first commit created."
}

main() {
  if [ $# -lt 1 ]; then
    usage; exit 1
  fi

  case "$1" in
    scaffold) init_scaffold ;;
    git)      init_git      ;;
    all)      init_scaffold && init_git ;;
    help)     usage         ;;
    *)        error "Unknown command: $1" ;;
  esac
}

main "$@"
