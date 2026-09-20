#!/usr/bin/env bash
# Minimal MCP 2025-11-25 stdio server for explicit local development tools.
set -uo pipefail
exec 3>&1
exec 1>&2
umask 077

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
protocol_version=2025-11-25 initialized=0 initialize_succeeded=0
: "${MCP_INSPECT_TIMEOUT:=15}" "${MCP_EXPERIMENT_START_TIMEOUT:=15}"
for value in "$MCP_INSPECT_TIMEOUT" "$MCP_EXPERIMENT_START_TIMEOUT"; do
  [[ $value =~ ^[1-9][0-9]{0,3}$ ]] || { printf 'MCP timeouts must be integers from 1 to 9999\n' >&2; exit 1; }
done
for dependency in jq timeout realpath mktemp date; do
  command -v "$dependency" >/dev/null 2>&1 || { printf 'Required command is missing: %s\n' "$dependency" >&2; exit 1; }
done
if [[ ${XDG_STATE_HOME-} == /* ]]; then state_base=$XDG_STATE_HOME
elif [[ ${HOME-} == /* ]]; then state_base=$HOME/.local/state
else printf 'HOME or absolute XDG_STATE_HOME is required\n' >&2; exit 1
fi
state_root=$state_base/local-dev-tools/experiments
work_dir="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$work_dir"' EXIT HUP INT TERM

# Closed preset mapping. Never accept an executable or wrapper path from MCP.
# Production intentionally starts empty. The fixed fixture is test-only.
preset_wrapper() {
  case $1 in
    mcp_test_fixture)
      [[ ${MCP_ENABLE_TEST_PRESETS-0} == 1 ]] || return 1
      REPLY=$root_dir/tests/fixtures/mcp-experiment ;;
    mcp_test_launch_failure)
      [[ ${MCP_ENABLE_TEST_PRESETS-0} == 1 ]] || return 1
      REPLY=$root_dir/tests/fixtures/mcp-experiment-fail ;;
    *) return 1 ;;
  esac
}
available_experiments() {
  if [[ ${MCP_ENABLE_TEST_PRESETS-0} == 1 ]]; then
    jq -cn '{experiments:[
      {name:"mcp_test_fixture",description:"Test-only fixed experiment used to verify MCP job handling.",warnings:["Executes a local fixture and has no forced runtime limit."]},
      {name:"mcp_test_launch_failure",description:"Test-only preset whose launch fails predictably.",warnings:[]}
    ]}'
  else jq -cn '{experiments:[]}'
  fi
}

tools_json="$(jq -cn '{tools:[
 {name:"system_info",description:"Collect read-only OS, CPU, RAM, and root-disk information. This makes no system changes.",inputSchema:{type:"object",properties:{},additionalProperties:false},annotations:{readOnlyHint:true,destructiveHint:false,idempotentHint:true,openWorldHint:false}},
 {name:"project_info",description:"Inspect a project top level for build markers, Git, compile databases, and test directories. Read-only and non-recursive.",inputSchema:{type:"object",properties:{project:{type:"string",description:"Path to an existing project directory."}},required:["project"],additionalProperties:false},annotations:{readOnlyHint:true,destructiveHint:false,idempotentHint:true,openWorldHint:false}},
 {name:"git_status",description:"Inspect concise Git branch and working-tree status without optional index locking. Does not intentionally modify repository state.",inputSchema:{type:"object",properties:{project:{type:"string",description:"Path to an existing Git project directory."}},required:["project"],additionalProperties:false},annotations:{readOnlyHint:true,destructiveHint:false,idempotentHint:true,openWorldHint:false}},
 {name:"git_diff",description:"Show the unstaged Git diff with external diff and text-conversion programs disabled. Does not intentionally modify repository state.",inputSchema:{type:"object",properties:{project:{type:"string",description:"Path to an existing Git project directory."}},required:["project"],additionalProperties:false},annotations:{readOnlyHint:true,destructiveHint:false,idempotentHint:true,openWorldHint:false}},
 {name:"list_experiments",description:"List fixed experiment presets enabled by the server. Does not start or validate an experiment.",inputSchema:{type:"object",properties:{},additionalProperties:false},annotations:{readOnlyHint:true,destructiveHint:false,idempotentHint:true,openWorldHint:false}},
 {name:"verify_experiments",description:"Validate a non-empty selection of fixed experiment presets and show exact audited configurations. Validation does not run experiments and is not human approval.",inputSchema:{type:"object",properties:{experiments:{type:"array",items:{type:"string",pattern:"^[a-z][a-z0-9_-]{0,63}$"},minItems:1,maxItems:32,uniqueItems:true,description:"Names returned by list_experiments."}},required:["experiments"],additionalProperties:false},annotations:{readOnlyHint:true,destructiveHint:false,idempotentHint:true,openWorldHint:false}},
 {name:"run_experiments",description:"Start a confirmed batch of fixed audited presets as detached jobs. Executes local programs that may modify files or external state and may consume unbounded CPU, memory, disk, or time because no runtime cap is forced. Validate first and obtain human approval in Zed.",inputSchema:{type:"object",properties:{experiments:{type:"array",items:{type:"string",pattern:"^[a-z][a-z0-9_-]{0,63}$"},minItems:1,maxItems:32,uniqueItems:true}},required:["experiments"],additionalProperties:false},annotations:{readOnlyHint:false,destructiveHint:true,idempotentHint:false,openWorldHint:true}},
 {name:"experiment_status",description:"Read bounded status, metadata, recent events, and recent results for one job. Does not read captured command output files or alter the job.",inputSchema:{type:"object",properties:{job_id:{type:"string",pattern:"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"}},required:["job_id"],additionalProperties:false},annotations:{readOnlyHint:true,destructiveHint:false,idempotentHint:true,openWorldHint:false}},
 {name:"cancel_experiment",description:"Request termination of one running experiment. Destructive and best-effort; cannot undo prior effects and requires human approval in Zed.",inputSchema:{type:"object",properties:{job_id:{type:"string",pattern:"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"}},required:["job_id"],additionalProperties:false},annotations:{readOnlyHint:false,destructiveHint:true,idempotentHint:false,openWorldHint:false}}
]}')" || exit 1

send_result() { jq -cn --argjson id "$1" --argjson result "$2" '{jsonrpc:"2.0",id:$id,result:$result}' >&3; }
send_error() { jq -cn --argjson id "$1" --argjson code "$2" --arg message "$3" '{jsonrpc:"2.0",id:$id,error:{code:$code,message:$message}}' >&3; }
validation_failure() { jq -cn --arg message "$1" '{success:false,exit_code:null,stdout:"",stderr:$message,timed_out:false}'; }

run_command() {
  local seconds=$1 stdout_file=$work_dir/stdout stderr_file=$work_dir/stderr rc timed_out=false start end elapsed
  shift
  start="$(date +%s.%N)"; : >"$stdout_file"; : >"$stderr_file"
  timeout --signal=TERM --kill-after=2s "${seconds}s" "$@" >"$stdout_file" 2>"$stderr_file"; rc=$?
  end="$(date +%s.%N)"
  elapsed="$(jq -nr --arg start "$start" --arg end "$end" '($end|tonumber)-($start|tonumber)')"
  if jq -en --argjson rc "$rc" --argjson elapsed "$elapsed" --argjson limit "$seconds" '($rc==124 or $rc==137) and ($elapsed>=($limit*0.99))' >/dev/null; then timed_out=true; fi
  jq -cn --argjson exit_code "$rc" --argjson timed_out "$timed_out" --rawfile stdout "$stdout_file" --rawfile stderr "$stderr_file" '{success:($exit_code==0),exit_code:$exit_code,stdout:$stdout,stderr:$stderr,timed_out:$timed_out}'
}
validate_project() { [[ -n $1 ]] && PROJECT="$(realpath -e -- "$1" 2>/dev/null)" && [[ -d $PROJECT ]]; }
valid_selection() {
  jq -e 'type=="object" and keys==["experiments"] and (.experiments|type=="array" and length>0 and length<=32) and (.experiments|all(type=="string" and test("^[a-z][a-z0-9_-]{0,63}$"))) and ((.experiments|unique|length)==(.experiments|length))' >/dev/null <<<"$1"
}
verify_one() {
  local name=$1 wrapper result details
  if ! preset_wrapper "$name" || [[ ! -x $REPLY ]]; then validation_failure "unknown or unavailable experiment preset: $name"; return; fi
  wrapper=$REPLY; result="$(run_command "$MCP_INSPECT_TIMEOUT" "$wrapper" verify)"
  if ! jq -e '.success' >/dev/null <<<"$result"; then jq -cn --arg name "$name" --argjson result "$result" '$result+{experiment:$name}'; return; fi
  if ! details="$(jq -ce --arg name "$name" 'select(type=="object" and .name==$name)' <<<"$(jq -r '.stdout' <<<"$result")" 2>/dev/null)"; then
    jq -cn --arg name "$name" --argjson result "$result" '$result+{success:false,experiment:$name,stderr:"Preset verification returned invalid JSON."}'; return
  fi
  jq -cn --arg name "$name" --argjson result "$result" --argjson details "$details" '$result+{experiment:$name,details:$details}'
}
verify_batch() {
  local arguments=$1 name item items='[]' ok=true
  while IFS= read -r name; do
    item="$(verify_one "$name")"; items="$(jq -cn --argjson a "$items" --argjson b "$item" '$a+[$b]')"
    jq -e '.success' >/dev/null <<<"$item" || ok=false
  done < <(jq -r '.experiments[]' <<<"$arguments")
  jq -cn --argjson success "$ok" --argjson experiments "$items" '{success:$success,exit_code:(if $success then 0 else null end),stdout:"",stderr:(if $success then "" else "One or more presets failed validation." end),timed_out:false,experiments:$experiments}'
}
run_batch() {
  local arguments=$1 verification name wrapper item items='[]' ok=true started=0
  verification="$(verify_batch "$arguments")"; if ! jq -e '.success' >/dev/null <<<"$verification"; then printf '%s\n' "$verification"; return; fi
  mkdir -p -- "$state_root" || { validation_failure "cannot create experiment state directory: $state_root"; return; }
  state_root="$(realpath -e -- "$state_root")" || { validation_failure 'cannot resolve experiment state directory'; return; }
  while IFS= read -r name; do
    preset_wrapper "$name" || continue; wrapper=$REPLY
    item="$(run_command "$MCP_EXPERIMENT_START_TIMEOUT" "$wrapper" run "$state_root")"
    if jq -e '.success and (.stdout|fromjson|type=="object")' >/dev/null <<<"$item"; then
      item="$(jq -cn --arg name "$name" --argjson r "$item" '$r+{experiment:$name,job:($r.stdout|fromjson)}')"; ((started+=1))
    else
      ok=false; item="$(jq -cn --arg name "$name" --argjson r "$item" '$r+{success:false,experiment:$name,stderr:(if $r.success then "Preset launch returned invalid JSON." else $r.stderr end)}')"
    fi
    items="$(jq -cn --argjson a "$items" --argjson b "$item" '$a+[$b]')"
  done < <(jq -r '.experiments[]' <<<"$arguments")
  jq -cn --argjson success "$ok" --argjson started "$started" --argjson experiments "$items" '{success:$success,exit_code:(if $success then 0 else null end),stdout:"",stderr:(if $success then "" else "One or more launches failed; already-started jobs were not rolled back." end),timed_out:false,started:$started,experiments:$experiments,warnings:["Experiments have no forced runtime cap.","Jobs may consume CPU, memory, disk, or other resources until completion or cancellation."]}'
}
resolve_job() {
  local candidate
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && -d $state_root ]] || return 1
  STATE_ROOT_REAL="$(realpath -e -- "$state_root" 2>/dev/null)" || return 1
  candidate="$(realpath -e -- "$STATE_ROOT_REAL/$1" 2>/dev/null)" || return 1
  [[ $candidate == "$STATE_ROOT_REAL"/* && -d $candidate ]] || return 1
  JOB_DIR=$candidate
}
job_status() {
  local id=$1 metadata status events results
  if ! resolve_job "$id" || [[ ! -f $JOB_DIR/metadata.json || ! -f $JOB_DIR/status.json ]]; then validation_failure "unknown experiment job: $id"; return; fi
  metadata="$(jq -ce 'select(type=="object")' "$JOB_DIR/metadata.json" 2>/dev/null)" || { validation_failure "invalid metadata for experiment job: $id"; return; }
  status="$(jq -ce 'select(type=="object")' "$JOB_DIR/status.json" 2>/dev/null)" || { validation_failure "invalid status for experiment job: $id"; return; }
  events="$(jq -sc '.[-100:]' "$JOB_DIR/events.jsonl" 2>/dev/null)" || { validation_failure "invalid events for experiment job: $id"; return; }
  results="$(jq -sc '.[-100:]' "$JOB_DIR/results.jsonl" 2>/dev/null)" || { validation_failure "invalid results for experiment job: $id"; return; }
  jq -cn --arg id "$id" --arg dir "$JOB_DIR" --argjson metadata "$metadata" --argjson status "$status" --argjson events "$events" --argjson results "$results" '{success:true,exit_code:0,stdout:"",stderr:"",timed_out:false,job_id:$id,job_dir:$dir,metadata:$metadata,status:$status,recent_events:$events,recent_results:$results,output:{stdout_dir:($dir+"/stdout"),stderr_dir:($dir+"/stderr")},truncated:{events:($events|length==100),results:($results|length==100)}}'
}
cancel_job() {
  local id=$1 status pid index worker_matches=false script_matches=false
  local -a argv=()
  if ! resolve_job "$id" || [[ ! -f $JOB_DIR/status.json ]]; then validation_failure "unknown experiment job: $id"; return; fi
  status="$(jq -ce 'select(type=="object")' "$JOB_DIR/status.json" 2>/dev/null)" || { validation_failure "invalid status for experiment job: $id"; return; }
  jq -e '.state=="starting" or .state=="running"' >/dev/null <<<"$status" || { validation_failure "experiment job is not running: $id"; return; }
  pid="$(jq -r '.runner_pid|select(type=="number" and floor==.)' <<<"$status")"
  [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]] || { validation_failure "experiment runner is no longer available: $id"; return; }
  mapfile -d '' -t argv <"/proc/$pid/cmdline" || true
  for index in "${!argv[@]}"; do
    [[ ${argv[index]} == "$root_dir/experiment_runner.sh" ]] && script_matches=true
    [[ ${argv[index]} == --worker && ${argv[index+1]-} == "$JOB_DIR" ]] && worker_matches=true
  done
  [[ $script_matches == true && $worker_matches == true ]] || { validation_failure "refusing to signal a PID that is not the expected experiment runner: $id"; return; }
  kill -TERM "$pid" 2>/dev/null || { validation_failure "experiment ended before cancellation could be requested: $id"; return; }
  jq -cn --arg id "$id" --argjson pid "$pid" '{success:true,exit_code:0,stdout:"",stderr:"",timed_out:false,job_id:$id,runner_pid:$pid,cancellation_requested:true,warnings:["Cancellation is best-effort.","Effects already produced cannot be undone."]}'
}

tool_response() { local p; p="$(jq -cn --argjson data "$2" '{content:[{type:"text",text:($data|tojson)}],structuredContent:$data,isError:($data.success|not)}')"; send_result "$1" "$p"; }
call_tool() {
  local id=$1 request=$2 name arguments project result job_id
  name="$(jq -r '.params.name' <<<"$request")"; arguments="$(jq -c '.params.arguments//{}' <<<"$request")"
  case $name in
    system_info|list_experiments)
      if ! jq -e 'type=="object" and length==0' >/dev/null <<<"$arguments"; then result="$(validation_failure "$name accepts no arguments")"
      elif [[ $name == system_info ]]; then result="$(run_command "$MCP_INSPECT_TIMEOUT" "$root_dir/tools/system-info")"
      else result="$(available_experiments | jq '.+{success:true,exit_code:0,stdout:"",stderr:"",timed_out:false}')"; fi ;;
    project_info|git_status|git_diff)
      if ! jq -e 'type=="object" and (.project|type=="string") and (.project|index("\u0000")==null) and keys==["project"]' >/dev/null <<<"$arguments"; then result="$(validation_failure "$name requires exactly one string argument: project")"
      else project="$(jq -r '.project' <<<"$arguments")"; if ! validate_project "$project"; then result="$(validation_failure "project is not an existing directory: $project")"; else case $name in project_info) name=project-info;; git_status) name=git-status;; git_diff) name=git-diff;; esac; result="$(run_command "$MCP_INSPECT_TIMEOUT" "$root_dir/tools/$name" "$PROJECT")"; fi; fi ;;
    verify_experiments|run_experiments)
      if ! valid_selection "$arguments"; then result="$(validation_failure "$name requires 1-32 unique experiment preset names")"; elif [[ $name == verify_experiments ]]; then result="$(verify_batch "$arguments")"; else result="$(run_batch "$arguments")"; fi ;;
    experiment_status|cancel_experiment)
      if ! jq -e 'type=="object" and (.job_id|type=="string") and (.job_id|test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and keys==["job_id"]' >/dev/null <<<"$arguments"; then result="$(validation_failure "$name requires exactly one valid string argument: job_id")"
      else job_id="$(jq -r '.job_id' <<<"$arguments")"; if [[ $name == experiment_status ]]; then result="$(job_status "$job_id")"; else result="$(cancel_job "$job_id")"; fi; fi ;;
    *) result="$(validation_failure "unknown tool: $name")" ;;
  esac
  tool_response "$id" "$result"
}
handle_request() {
  local request=$1 id method result
  id="$(jq -c '.id//null' <<<"$request")"; method="$(jq -r '.method//empty' <<<"$request")"
  case $method in
    initialize)
      if ((initialize_succeeded)); then send_error "$id" -32600 'Server is already initialized'; return; fi
      if ! jq -e '(.params|type=="object") and (.params.protocolVersion|type=="string") and (.params.capabilities|type=="object") and (.params.clientInfo|type=="object")' >/dev/null <<<"$request"; then send_error "$id" -32602 'Invalid initialize parameters'; return; fi
      result="$(jq -cn --arg version "$protocol_version" '{protocolVersion:$version,capabilities:{tools:{listChanged:false}},serverInfo:{name:"local-dev-tools",version:"1.1.0"},instructions:"Read-only inspection plus fixed wrapper-backed detached experiments. Execution and cancellation require client-side human approval. No arbitrary command or path is accepted."}')"; initialize_succeeded=1; send_result "$id" "$result" ;;
    ping) send_result "$id" '{}' ;;
    tools/list) if ((initialized==0)); then send_error "$id" -32002 'Server has not received notifications/initialized'; else send_result "$id" "$tools_json"; fi ;;
    tools/call)
      if ((initialized==0)); then send_error "$id" -32002 'Server has not received notifications/initialized'
      elif ! jq -e '(.params|type=="object") and (.params.name|type=="string") and (.params.name|index("\u0000")==null) and ((.params.arguments==null) or (.params.arguments|type=="object"))' >/dev/null <<<"$request"; then send_error "$id" -32602 'Invalid tools/call parameters'
      else call_tool "$id" "$request"; fi ;;
    notifications/initialized) if ((initialize_succeeded)); then initialized=1; fi ;;
    notifications/cancelled) ;;
    '') [[ $id == null ]] || send_error "$id" -32600 'Invalid Request' ;;
    *) [[ $id == null ]] || send_error "$id" -32601 "Method not found: $method" ;;
  esac
}
while IFS= read -r line || [[ -n $line ]]; do
  if ! request="$(jq -ce 'if type=="object" then . else error("not an object") end' <<<"$line" 2>/dev/null)"; then send_error null -32700 'Parse error'; continue; fi
  if ! jq -e '.jsonrpc=="2.0" and (.method|type=="string") and (.method|index("\u0000")==null) and ((has("id")|not) or (.id|type=="string" or type=="number"))' >/dev/null <<<"$request"; then id="$(jq -c 'if (.id|type=="string" or type=="number") then .id else null end' <<<"$request")"; send_error "$id" -32600 'Invalid Request'; continue; fi
  handle_request "$request"
done
