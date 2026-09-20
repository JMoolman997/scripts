#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "$BATS_TEST_DIRNAME/.." && pwd -P)"
  SERVER="$REPO_ROOT/mcp/server.sh"
  PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT/tests" "$PROJECT/build"
  touch "$PROJECT/Makefile" "$PROJECT/compile_commands.json"
  printf 'original\n' >"$PROJECT/file.c"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" add Makefile compile_commands.json file.c
  git -C "$PROJECT" -c user.name='MCP Test' -c user.email=mcp@test.invalid commit -qm fixture

  cat >"$PROJECT/textconv-audit" <<'EOF'
#!/usr/bin/env bash
touch -- "$MCP_AUDIT_MARKER"
cat -- "$1"
EOF
  chmod +x "$PROJECT/textconv-audit"
  printf '*.c diff=audit\n' >"$PROJECT/.gitattributes"
  git -C "$PROJECT" config diff.audit.textconv "$PROJECT/textconv-audit"
  git -C "$PROJECT" add .gitattributes textconv-audit
  git -C "$PROJECT" -c user.name='MCP Test' -c user.email=mcp@test.invalid commit -qm textconv-fixture
  printf 'changed\n' >"$PROJECT/file.c"
}

run_server() { "$SERVER" <<<"$1"; }

request_stream() {
  {
    jq -cn '{jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:"2025-11-25",capabilities:{},clientInfo:{name:"test",version:"1"}}}'
    jq -cn '{jsonrpc:"2.0",method:"notifications/initialized"}'
    printf '%s\n' "$1"
  }
}

@test "lists inspection and fixed experiment-management tools" {
  calls="$({
    jq -cn '{jsonrpc:"2.0",id:2,method:"tools/list",params:{}}'
    jq -cn '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"system_info",arguments:{}}}'
    jq -cn --arg project "$PROJECT" '{jsonrpc:"2.0",id:4,method:"tools/call",params:{name:"project_info",arguments:{project:$project}}}'
    jq -cn --arg project "$PROJECT" '{jsonrpc:"2.0",id:5,method:"tools/call",params:{name:"git_status",arguments:{project:$project}}}'
    jq -cn --arg project "$PROJECT" '{jsonrpc:"2.0",id:6,method:"tools/call",params:{name:"git_diff",arguments:{project:$project}}}'
  })"
  run run_server "$(request_stream "$calls")"
  [ "$status" -eq 0 ]
  jq -se '.[1].result.tools | map(.name) == ["system_info","project_info","git_status","git_diff","list_experiments","verify_experiments","run_experiments","experiment_status","cancel_experiment"]' <<<"$output"
  jq -se '.[1].result.tools | map(select(.name=="run_experiments"))[0].annotations == {readOnlyHint:false,destructiveHint:true,idempotentHint:false,openWorldHint:true}' <<<"$output"
  jq -se '.[1].result.tools | map(select(.name=="cancel_experiment"))[0].annotations.destructiveHint == true' <<<"$output"
  jq -se '.[2:] | all(.result.isError == false)' <<<"$output"
  jq -se '.[5].result.structuredContent.stdout | contains("changed")' <<<"$output"
}

@test "removed execution tools are unavailable" {
  calls="$({
    jq -cn --arg project "$PROJECT" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"build_project",arguments:{project:$project}}}'
    jq -cn --arg project "$PROJECT" '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"run_tests",arguments:{project:$project}}}'
    jq -cn --arg project "$PROJECT" '{jsonrpc:"2.0",id:4,method:"tools/call",params:{name:"compile_check",arguments:{project:$project}}}'
  })"
  run run_server "$(request_stream "$calls")"
  [ "$status" -eq 0 ]
  jq -se '.[1:] | all(.result.isError and (.result.structuredContent.stderr | startswith("unknown tool:")))' <<<"$output"
}

@test "malformed JSON, invalid arguments, and NUL strings are rejected" {
  calls="$({
    printf '%s\n' '{bad json'
    jq -cn '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"project_info",arguments:{project:42}}}'
    jq -cn '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"project_info",arguments:{project:"\u0000/tmp"}}}'
    jq -cn '{jsonrpc:"2.0",id:4,method:"\u0000tools/list",params:{}}'
    jq -cn '{jsonrpc:"2.0",id:5,method:"tools/call",params:{name:"\u0000system_info",arguments:{}}}'
  })"
  run run_server "$(request_stream "$calls")"
  [ "$status" -eq 0 ]
  jq -se '.[1].error.code == -32700' <<<"$output"
  jq -se '.[2:4] | all(.result.isError)' <<<"$output"
  jq -se '.[4].error.code == -32600 and .[5].error.code == -32602' <<<"$output"
  [[ "$output" != *'Project: /tmp'* ]]
}

@test "initialized cannot bypass initialize and version negotiation is correct" {
  input="$({
    jq -cn '{jsonrpc:"2.0",method:"notifications/initialized"}'
    jq -cn '{jsonrpc:"2.0",id:1,method:"tools/list",params:{}}'
    jq -cn '{jsonrpc:"2.0",id:2,method:"initialize",params:{protocolVersion:"2099-01-01",capabilities:{},clientInfo:{name:"test",version:"1"}}}'
    jq -cn '{jsonrpc:"2.0",method:"notifications/initialized"}'
    jq -cn '{jsonrpc:"2.0",id:3,method:"tools/list",params:{}}'
  })"
  run run_server "$input"
  [ "$status" -eq 0 ]
  jq -se '.[0].error.code == -32002' <<<"$output"
  jq -se '.[1].result.protocolVersion == "2025-11-25"' <<<"$output"
  jq -se '.[2].result.tools | length == 9' <<<"$output"
}

@test "production experiment catalog is empty and invalid selections are rejected" {
  calls="$({
    jq -cn '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"list_experiments",arguments:{}}}'
    jq -cn '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"verify_experiments",arguments:{experiments:[]}}}'
    jq -cn '{jsonrpc:"2.0",id:4,method:"tools/call",params:{name:"verify_experiments",arguments:{experiments:["unknown"]}}}'
    jq -cn '{jsonrpc:"2.0",id:5,method:"tools/call",params:{name:"run_experiments",arguments:{experiments:["same","same"]}}}'
  })"
  run run_server "$(request_stream "$calls")"
  [ "$status" -eq 0 ]
  jq -se '.[1].result.structuredContent.experiments == []' <<<"$output"
  jq -se '.[2:].result | all(.isError)' <<<"$output"
}

@test "fixed test preset verifies, starts, reports status, and preserves output" {
  export MCP_ENABLE_TEST_PRESETS=1
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  calls="$({
    jq -cn '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"list_experiments",arguments:{}}}'
    jq -cn '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"verify_experiments",arguments:{experiments:["mcp_test_fixture"]}}}'
    jq -cn '{jsonrpc:"2.0",id:4,method:"tools/call",params:{name:"run_experiments",arguments:{experiments:["mcp_test_fixture"]}}}'
  })"
  run run_server "$(request_stream "$calls")"
  [ "$status" -eq 0 ]
  jq -se '.[1].result.structuredContent.experiments[0].name == "mcp_test_fixture"' <<<"$output"
  jq -se '.[2].result.structuredContent.experiments[0].details.runtime_limit == null' <<<"$output"
  jq -se '.[3].result.isError == false and .[3].result.structuredContent.started == 1' <<<"$output"
  job_id="$(jq -sr '.[3].result.structuredContent.experiments[0].job.job_id' <<<"$output")"
  job_dir="$XDG_STATE_HOME/local-dev-tools/experiments/$job_id"
  for _ in {1..100}; do
    state="$(jq -r '.state' "$job_dir/status.json")"
    [[ $state == done ]] && break
    sleep 0.05
  done
  [ "$state" = done ]
  call="$(jq -cn --arg id "$job_id" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"experiment_status",arguments:{job_id:$id}}}')"
  run run_server "$(request_stream "$call")"
  [ "$status" -eq 0 ]
  jq -se '.[1].result.structuredContent.status.state == "done"' <<<"$output"
  [[ "$(cat "$job_dir/stdout/run-000001.log")" == *'fixture "stdout"'* ]]
  [[ "$(cat "$job_dir/stderr/run-000001.log")" == *'diagnostic on stderr'* ]]
}

@test "confirmed cancellation targets only the expected runner" {
  export MCP_ENABLE_TEST_PRESETS=1 MCP_TEST_FIXTURE_SLEEP=5
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  call="$(jq -cn '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"run_experiments",arguments:{experiments:["mcp_test_fixture"]}}}')"
  run run_server "$(request_stream "$call")"
  [ "$status" -eq 0 ]
  job_id="$(jq -sr '.[1].result.structuredContent.experiments[0].job.job_id' <<<"$output")"
  cancel="$(jq -cn --arg id "$job_id" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"cancel_experiment",arguments:{job_id:$id}}}')"
  run run_server "$(request_stream "$cancel")"
  [ "$status" -eq 0 ]
  jq -se '.[1].result.structuredContent.cancellation_requested == true' <<<"$output"
  job_dir="$XDG_STATE_HOME/local-dev-tools/experiments/$job_id"
  for _ in {1..100}; do
    state="$(jq -r '.state' "$job_dir/status.json")"
    [[ $state == cancelled ]] && break
    sleep 0.05
  done
  [ "$state" = cancelled ]
}

@test "batch launch reports partial failure without hiding started jobs" {
  export MCP_ENABLE_TEST_PRESETS=1
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  call="$(jq -cn '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"run_experiments",arguments:{experiments:["mcp_test_fixture","mcp_test_launch_failure"]}}}')"
  run run_server "$(request_stream "$call")"
  [ "$status" -eq 0 ]
  jq -se '
    .[1].result.isError and
    .[1].result.structuredContent.started == 1 and
    (.[1].result.structuredContent.stderr | contains("not rolled back")) and
    (.[1].result.structuredContent.experiments[0].job.job_id | type == "string") and
    .[1].result.structuredContent.experiments[1].exit_code == 7
  ' <<<"$output"
}

@test "git_diff does not execute configured textconv" {
  marker="$BATS_TEST_TMPDIR/textconv-ran"
  export MCP_AUDIT_MARKER="$marker"
  call="$(jq -cn --arg project "$PROJECT" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"git_diff",arguments:{project:$project}}}')"
  run run_server "$(request_stream "$call")"
  [ "$status" -eq 0 ]
  jq -se '.[1].result.isError == false' <<<"$output"
  [ ! -e "$marker" ]
}

@test "inspection timeout is reported and the server continues" {
  fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
sleep 5
EOF
  chmod +x "$fake_bin/git"
  calls="$({
    jq -cn --arg project "$PROJECT" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"git_status",arguments:{project:$project}}}'
    jq -cn '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"system_info",arguments:{}}}'
  })"
  PATH="$fake_bin:$PATH" MCP_INSPECT_TIMEOUT=1 run run_server "$(request_stream "$calls")"
  [ "$status" -eq 0 ]
  jq -se '.[1].result.isError and .[1].result.structuredContent.timed_out' <<<"$output"
  jq -se '.[2].result.isError == false' <<<"$output"
}
