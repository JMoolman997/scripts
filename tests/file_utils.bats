#!/usr/bin/env bats

setup() {
  project_root="$BATS_TEST_DIRNAME/.."
  . "$project_root/lib/file_utils.sh"
  export -f backup_file symlink

  TEST_TMP="$(mktemp -d)"
  export TEST_TMP
  PATH="$TEST_TMP:$PATH"
  export PATH

  HOME="$TEST_TMP/home"
  mkdir -p "$HOME"
  export HOME

  cat <<'STUB' >"$TEST_TMP/date"
#!/usr/bin/env bash
echo "20240101-000000"
STUB
  chmod +x "$TEST_TMP/date"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "backup_file creates timestamped copy" {
  src="$TEST_TMP/sample.txt"
  echo "content" >"$src"
  run bash -c 'backup_file "'$src'"'
  [ "$status" -eq 0 ]
  backup_dir="$HOME/.backup-20240101-000000"
  [ -d "$backup_dir" ]
  [ -f "$backup_dir/$(basename "$src")" ]
}

@test "symlink backs up destination before linking" {
  src="$TEST_TMP/source.txt"
  dest="$TEST_TMP/destination.txt"
  echo "data" >"$src"
  echo "old" >"$dest"

  run bash -c 'symlink "'$src'" "'$dest'"'
  [ "$status" -eq 0 ]

  backup_dir="$HOME/.backup-20240101-000000"
  [ -f "$backup_dir/$(basename "$dest")" ]
  [ -L "$dest" ]
  [ "$(readlink "$dest")" = "$src" ]
}
