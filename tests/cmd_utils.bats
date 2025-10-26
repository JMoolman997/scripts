#!/usr/bin/env bats

setup() {
  project_root="$BATS_TEST_DIRNAME/.."
  . "$project_root/lib/cmd_utils.sh"
  export -f command_exists sudo_if_needed

  TEST_TMP="$(mktemp -d)"
  export TEST_TMP
  PATH="$TEST_TMP:$PATH"
  export PATH

  cat <<'STUB' >"$TEST_TMP/sudo"
#!/usr/bin/env bash
echo "sudo invoked: $*" >&2
exit 99
STUB
  chmod +x "$TEST_TMP/sudo"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "command_exists returns success when command present" {
  run bash -c 'command_exists echo'
  [ "$status" -eq 0 ]
}

@test "command_exists returns failure when command missing" {
  run bash -c 'command_exists definitely-not-a-command'
  [ "$status" -ne 0 ]
}

@test "sudo_if_needed skips sudo when running as root" {
  run bash -c 'sudo_if_needed printf hello'
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "sudo_if_needed delegates to sudo when override provided" {
  cat <<'STUB' >"$TEST_TMP/sudo"
#!/usr/bin/env bash
printf 'sudo called with: %s\n' "$*" >"$TEST_TMP/sudo.log"
"$@"
STUB
  chmod +x "$TEST_TMP/sudo"

  run bash -c 'SC_CMD_UTILS_EUID_OVERRIDE=1000 sudo_if_needed bash -c "echo delegated"'
  [ "$status" -eq 0 ]
  [ "$output" = "delegated" ]
  run cat "$TEST_TMP/sudo.log"
  [ "$status" -eq 0 ]
  [[ "$output" =~ bash ]]
}
