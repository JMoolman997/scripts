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
  [[ "$output" == *'repeat must be a positive integer'* ]]

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
  [[ "$output" == *'repeat must not exceed 1000000'* ]]
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

  if wait "$runner_pid"; then exit_code=0; else exit_code=$?; fi
  [ "$exit_code" -eq 143 ]
  sleep 0.1
  [ ! -e "$marker" ]
}

@test "uses cwd, environment, stdin, and warmups without counting warmups" {
  printf 'input value\n' > "$BATS_TEST_TMPDIR/input"
  run bash "$runner" -C "$BATS_TEST_TMPDIR" -i input -e 'EXPERIMENT_VALUE=hello world' \
    -w 2 -r 3 -- bash -c 'read -r input; printf "%s|%s|%s\n" "$PWD" "$EXPERIMENT_VALUE" "$input"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$BATS_TEST_TMPDIR|hello world|input value"* ]]
  [[ "$output" == *'Summary: 3 succeeded, 0 failed;'* ]]
}

@test "uses the last value for duplicate environment assignments" {
  run bash "$runner" -o "$BATS_TEST_TMPDIR/jobs" \
    -e 'EXPERIMENT_VALUE=old' -e 'EXPERIMENT_VALUE=new value' -- \
    bash -c 'printf "%s\n" "$EXPERIMENT_VALUE"'

  [ "$status" -eq 0 ]
  [[ "$output" == *'new value'* ]]
  job=("$BATS_TEST_TMPDIR"/jobs/*)
  python3 - "${job[0]}/metadata.json" <<'PY'
import json, sys
with open(sys.argv[1]) as metadata:
    assert json.load(metadata)['environment'] == {'EXPERIMENT_VALUE': 'new value'}
PY
}

@test "stops after a failed warmup or measured run when requested" {
  run bash "$runner" -w 2 -r 3 -- false
  [ "$status" -eq 1 ]
  [[ "$output" != *'Run 1/3:'* ]]

  run bash "$runner" -r 3 --stop-on-error -- false
  [ "$status" -eq 1 ]
  [[ "$output" == *'Run 1/3: exit 1,'* ]]
  [[ "$output" != *'Run 2/3:'* ]]
}

@test "writes valid job JSON and preserves unusual argv" {
  run bash "$runner" -o "$BATS_TEST_TMPDIR/jobs" -l 'odd " label' \
    -- printf '%s\n' 'space quote" slash\ unicode-λ' '' $'line\nnext\tcell\001'
  [ "$status" -eq 0 ]
  [[ "$output" == *'Summary: 1 succeeded, 0 failed;'* ]]
  job=("$BATS_TEST_TMPDIR"/jobs/*)
  [ -f "${job[0]}/DONE" ]
  python3 - "${job[0]}" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
m = json.loads((p / 'metadata.json').read_text())
assert m['label'] == 'odd " label'
assert m['command'][-3:] == ['space quote" slash\\ unicode-λ', '', 'line\nnext\tcell\001']
for name in ('status.json', 'events.jsonl', 'results.jsonl'):
    for line in (p / name).read_text().splitlines():
        json.loads(line)
assert json.loads((p / 'status.json').read_text())['state'] == 'done'
results = [json.loads(line) for line in (p / 'results.jsonl').read_text().splitlines()]
assert results[-1]['type'] == 'summary' and results[-1]['runs'] == 1
events = [json.loads(line) for line in (p / 'events.jsonl').read_text().splitlines()]
assert [event['id'] for event in events] == list(range(1, len(events) + 1))
PY
}

@test "persistent failures include signal and output paths" {
  run bash "$runner" -o "$BATS_TEST_TMPDIR/jobs" -- bash -c 'kill -SEGV "$$"'
  [ "$status" -eq 1 ]
  job=("$BATS_TEST_TMPDIR"/jobs/*)
  [ -f "${job[0]}/FAILED" ]
  python3 - "${job[0]}" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
events = [json.loads(line) for line in (p / 'events.jsonl').read_text().splitlines()]
failed = next(event for event in events if event['type'] == 'run_failed')
assert failed['exit_code'] == 139 and failed['signal'] == 'SIGSEGV'
assert (p / failed['stdout']).is_file() and (p / failed['stderr']).is_file()
PY
}

@test "detached job reports failure and keeps per-run output" {
  local poll
  run bash "$runner" --detach -o "$BATS_TEST_TMPDIR/jobs" -- bash -c 'echo problem >&2; exit 7'
  [ "$status" -eq 0 ]
  job_dir=$(printf '%s\n' "$output" | sed -n 's/^job_dir=//p')
  [ -n "$job_dir" ]
  for ((poll=0; poll<100; poll++)); do
    [ -f "$job_dir/FAILED" ] && break
    sleep 0.05
  done
  [ -f "$job_dir/FAILED" ]
  [ ! -e "$job_dir/RUNNING" ]
  [[ $(<"$job_dir/stderr/run-000001.log") == problem ]]
  python3 - "$job_dir" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
assert json.loads((p / 'status.json').read_text())['state'] == 'failed'
events = [json.loads(line) for line in (p / 'events.jsonl').read_text().splitlines()]
assert any(e['type'] == 'run_failed' and e['exit_code'] == 7 for e in events)
PY
}

@test "detached cancellation stops the active child" {
  local poll
  marker="$BATS_TEST_TMPDIR/descendant-finished"
  run bash "$runner" --detach -o "$BATS_TEST_TMPDIR/jobs" -- bash -c 'sleep 2; : > "$1"' _ "$marker"
  [ "$status" -eq 0 ]
  job_dir=$(printf '%s\n' "$output" | sed -n 's/^job_dir=//p')
  for ((poll=0; poll<100; poll++)); do
    child_pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("child_pid") or "")' "$job_dir/status.json")
    [ -n "$child_pid" ] && break
    sleep 0.05
  done
  [ -n "$child_pid" ]
  kill -TERM "$(<"$job_dir/pid")"
  for ((poll=0; poll<100; poll++)); do
    [ -f "$job_dir/CANCELLED" ] && break
    sleep 0.05
  done
  [ -f "$job_dir/CANCELLED" ]
  ! kill -0 "$child_pid" 2>/dev/null
  sleep 2.1
  [ ! -e "$marker" ]
}
