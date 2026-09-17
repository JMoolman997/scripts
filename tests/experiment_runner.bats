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

@test "rejects invalid counts and missing commands" {
  run bash "$runner" --repeat 0 -- true
  [ "$status" -eq 2 ]
  [[ "$output" == *'N must be a positive integer'* ]]

  run bash "$runner" --repeat 2 --
  [ "$status" -eq 2 ]
  [[ "$output" == *'a command is required'* ]]
}
