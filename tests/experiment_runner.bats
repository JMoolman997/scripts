#!/usr/bin/env bats

setup() {
  runner="$BATS_TEST_DIRNAME/../experiment_runner.sh"
}

@test "runs a command repeatedly and reports timing" {
  run bash "$runner" --repeat 3 -- bash -c 'printf "hello\n"'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^hello$')" -eq 3 ]
  [[ "$output" == *'Run 3/3: exit 0,'* ]]
  [[ "$output" == *'Summary: 3 succeeded, 0 failed; min '* ]]
}

@test "continues after failures and returns failure" {
  run bash "$runner" --repeat 3 -- bash -c 'exit 7'
  [ "$status" -ne 0 ]
  [[ "$output" == *'Run 3/3: exit 7,'* ]]
  [[ "$output" == *'Summary: 0 succeeded, 3 failed; min '* ]]
}

@test "continues after a run segfaults" {
  state="$BATS_TEST_TMPDIR/segfault-state"

  run bash "$runner" --repeat 2 -- bash -c '
    if [[ ! -e $1 ]]; then
      : > "$1"
      kill -SEGV "$$"
    fi
    printf "recovered-after-segv\n"
  ' _ "$state"

  [ "$status" -ne 0 ]
  [[ "$output" == *'Run 1/2: exit 139,'* ]]
  [[ "$output" == *'recovered-after-segv'* ]]
  [[ "$output" == *'Run 2/2: exit 0,'* ]]
  [[ "$output" == *'Summary: 1 succeeded, 1 failed;'* ]]
}

@test "continues after a run is killed like an OOM victim" {
  state="$BATS_TEST_TMPDIR/oom-state"

  # Linux's OOM killer terminates a selected process with SIGKILL. Sending the
  # same signal exercises the runner behavior without exhausting test memory.
  run bash "$runner" --repeat 2 -- bash -c '
    if [[ ! -e $1 ]]; then
      : > "$1"
      kill -KILL "$$"
    fi
    printf "recovered-after-kill\n"
  ' _ "$state"

  [ "$status" -ne 0 ]
  [[ "$output" == *'Run 1/2: exit 137,'* ]]
  [[ "$output" == *'recovered-after-kill'* ]]
  [[ "$output" == *'Run 2/2: exit 0,'* ]]
  [[ "$output" == *'Summary: 1 succeeded, 1 failed;'* ]]
}

@test "rejects invalid counts and missing commands" {
  run bash "$runner" --repeat 0 -- true
  [ "$status" -eq 2 ]
  [[ "$output" == *'N must be a positive integer'* ]]

  run bash "$runner" --repeat 2 --
  [ "$status" -eq 2 ]
  [[ "$output" == *'a command is required'* ]]
}

@test "treats repeat counts as decimal and bounds resource use" {
  run bash "$runner" --repeat 08 -- true
  [ "$status" -eq 0 ]
  [[ "$output" == *'Summary: 8 succeeded, 0 failed;'* ]]

  run bash "$runner" --repeat 1000001 -- true
  [ "$status" -eq 2 ]
  [[ "$output" == *'N must not exceed 1000000'* ]]
}

@test "preserves command arguments and standard input" {
  run bash -c 'printf "input data" | "$1" --repeat 1 -- bash -c '\''read -r value; printf "<%s>|<%s>\\n" "$value" "$1"'\'' _ "two words"' _ "$runner"
  [ "$status" -eq 0 ]
  [[ "$output" == *'<input data>|<two words>'* ]]
}

@test "terminates the active command when signalled" {
  marker="$BATS_TEST_TMPDIR/completed"
  bash "$runner" --repeat 2 -- bash -c 'sleep 2; : > "$1"' _ "$marker" &
  runner_pid=$!
  sleep 0.1
  kill -TERM "$runner_pid"

  run wait "$runner_pid"
  [ "$status" -eq 143 ]
  sleep 0.1
  [ ! -e "$marker" ]
}
