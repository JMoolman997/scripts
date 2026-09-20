#!/usr/bin/env bash
set -u
# Separate each asynchronous run into its own process group, so cancellation
# reaches descendants started by shell scripts as well as the immediate child.
set -m
export LC_ALL=C
readonly MAX_REPEAT=1000000

usage() {
  cat <<'EOF'
Usage: experiment_runner.sh [options] -- command [args...]
  -r, --repeat N       Measured runs (default 1, maximum 1000000)
  -w, --warmup N       Warm-up runs (default 0)
  -C, --cwd DIR        Command working directory
  -e, --env KEY=VALUE  Add an environment variable (repeatable)
  -i, --stdin FILE     Use FILE as stdin for every run
  -o, --output-dir DIR Store job files under DIR
  -l, --label NAME     Job label
      --format text|jsonl  Foreground report format
      --detach         Start in background and print job paths
      --stop-on-error  Stop after first measured failure
  -h, --help           Show this help
EOF
}
usage_error() { printf 'Error: %s\n' "$1" >&2; usage >&2; exit 2; }
error() { printf 'Error: %s\n' "$1" >&2; exit 2; }
timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
if (( BASH_VERSINFO[0] >= 5 )) && [[ -n ${EPOCHREALTIME-} ]]; then
  # EPOCHREALTIME is seconds with exactly six fractional digits. Removing the
  # decimal point gives an integer microsecond timestamp without external tools.
  now_us() { printf '%s\n' "${EPOCHREALTIME/./}"; }
else
  # Older Bash versions only expose whole seconds, so timing remains valid but
  # has one-second resolution.
  now_us() { printf '%s\n' "$((SECONDS * 1000000))"; }
fi
format_us() { printf '%d.%06d' "$(( $1 / 1000000 ))" "$(( $1 % 1000000 ))"; }

json_string() {
  # LC_ALL=C (set above) makes Bash iterate over bytes. Printable UTF-8 bytes
  # can therefore pass through unchanged while JSON control bytes are escaped.
  local value=$1 char code out='"' i
  for ((i=0; i<${#value}; i++)); do
    char=${value:i:1}
    case $char in
      '"') out+='\"' ;;
      $'\\') out+='\\' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      *) printf -v code '%d' "'$char"
         if ((code < 32 || code == 127)); then printf -v char '\u%04x' "$code"; fi
         out+=$char ;;
    esac
  done
  printf '%s"' "$out"
}
parse_count() {
  local value=$1 limit=$2 name=$3
  [[ $value =~ ^[0-9]+$ ]] || usage_error "$name must be a non-negative integer"
  # Check length before arithmetic so an enormous user value cannot overflow
  # Bash's signed integer parser. 10# also prevents 08 being treated as octal.
  (( ${#value} <= ${#limit} )) || usage_error "$name must not exceed $limit"
  REPLY=$((10#$value))
  ((REPLY <= limit)) || usage_error "$name must not exceed $limit"
}
set_environment() {
  # `env A=old A=new command` uses the final value. Coalescing here preserves
  # that behavior and also prevents duplicate keys in metadata.json.
  local assignment=$1 key=${1%%=*} index
  for index in "${!env_args[@]}"; do
    if [[ ${env_args[index]%%=*} == "$key" ]]; then
      env_args[index]=$assignment
      return
    fi
  done
  env_args+=("$assignment")
}

repeat=1 warmup=0 cwd=$PWD stdin_file= output_root= label=experiment
display_format=text detach=0 stop_on_error=0 worker=0 job_dir=
env_args=()
# --worker is an internal second-pass mode used by --detach. The foreground
# process creates the job directory, then the worker parses the original public
# arguments again and writes results into that already-created directory.
if [[ ${1-} == --worker ]]; then
  worker=1 job_dir=${2-}
  [[ -n $job_dir ]] || exit 2
  shift 2
fi
original_args=("$@")
while (($#)); do
  case $1 in
    -h|--help) usage; exit 0 ;;
    -r|--repeat) (($# >= 2)) || usage_error 'missing repeat count'
      parse_count "$2" "$MAX_REPEAT" repeat; repeat=$REPLY
      ((repeat > 0)) || usage_error 'repeat must be a positive integer'; shift 2 ;;
    -w|--warmup) (($# >= 2)) || usage_error 'missing warmup count'
      parse_count "$2" "$MAX_REPEAT" warmup; warmup=$REPLY; shift 2 ;;
    -C|--cwd) (($# >= 2)) || usage_error 'missing working directory'; cwd=$2; shift 2 ;;
    -e|--env) (($# >= 2)) || usage_error 'missing environment assignment'
      [[ $2 =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || usage_error 'environment must be KEY=VALUE'
      set_environment "$2"; shift 2 ;;
    -i|--stdin) (($# >= 2)) || usage_error 'missing stdin file'; stdin_file=$2; shift 2 ;;
    -o|--output-dir) (($# >= 2)) || usage_error 'missing output directory'; output_root=$2; shift 2 ;;
    -l|--label) (($# >= 2)) || usage_error 'missing label'; label=$2; shift 2 ;;
    --format) (($# >= 2)) || usage_error 'missing format'
      [[ $2 == text || $2 == jsonl ]] || usage_error 'format must be text or jsonl'
      display_format=$2; shift 2 ;;
    --detach) detach=1; shift ;;
    --stop-on-error) stop_on_error=1; shift ;;
    --) shift; break ;;
    *) usage_error "unknown option: $1" ;;
  esac
done
(($#)) || usage_error 'a command is required after --'
command=("$@")
[[ -d $cwd ]] || error "working directory does not exist: $cwd"
cwd=$(cd -- "$cwd" && pwd -P) || error "cannot enter working directory: $cwd"
if [[ -n $stdin_file ]]; then
  [[ $stdin_file == /* ]] || stdin_file=$cwd/$stdin_file
  [[ -f $stdin_file && -r $stdin_file ]] || error "cannot read stdin file: $stdin_file"
fi
safe_label=${label//[^A-Za-z0-9_-]/-}
safe_label=${safe_label:0:48}
[[ -n $safe_label ]] || safe_label=experiment
if ((detach && !worker)); then [[ -n $output_root ]] || output_root=$cwd/.agent/experiments; fi
if [[ -n $output_root && $output_root != /* ]]; then output_root=$PWD/$output_root; fi

create_job_dir() {
  mkdir -p -- "$output_root" || error "cannot create output directory: $output_root"
  output_root=$(cd -- "$output_root" && pwd -P) || exit 2
  local stamp attempt
  stamp=$(date -u '+%Y%m%d-%H%M%S')
  for ((attempt=0; attempt<100; attempt++)); do
    job_id="$stamp-$safe_label-$$-$attempt"
    job_dir=$output_root/$job_id
    if mkdir -- "$job_dir" 2>/dev/null; then
      mkdir -- "$job_dir/stdout" "$job_dir/stderr" || exit 2
      return
    fi
  done
  error 'could not create a unique job directory'
}
if ((worker)); then
  [[ -d $job_dir ]] || error "job directory missing: $job_dir"
  job_id=${job_dir##*/}
elif [[ -n $output_root ]]; then create_job_dir; fi
persistent=0
[[ -n $job_dir ]] && persistent=1

write_metadata() {
  local item first=1 key value
  {
    printf '{"job_id":%s,"label":%s,"cwd":%s,"command":[' \
      "$(json_string "$job_id")" "$(json_string "$label")" "$(json_string "$cwd")"
    for item in "${command[@]}"; do
      ((first)) || printf ','; first=0; json_string "$item"
    done
    printf '],"repeat":%d,"warmup":%d,"environment":{' "$repeat" "$warmup"
    first=1
    for item in "${env_args[@]}"; do
      key=${item%%=*}; value=${item#*=}
      ((first)) || printf ','; first=0
      printf '%s:%s' "$(json_string "$key")" "$(json_string "$value")"
    done
    printf '},"stdin_file":'
    if [[ -n $stdin_file ]]; then json_string "$stdin_file"; else printf 'null'; fi
    printf ',"started_at":%s,"runner_pid":%d}\n' "$(json_string "$started_at")" "$$"
  } > "$job_dir/metadata.json"
}
write_status() {
  ((persistent)) || return 0
  # USR1 heartbeat traps may run while another status update is in progress.
  # Avoid a nested write, and use rename below so readers never see partial JSON.
  ((status_writing)) && return 0
  status_writing=1
  local current_time temp
  current_time=$(timestamp)
  temp=$job_dir/status.json.$$.tmp
  {
    printf '{"job_id":%s,"state":%s,"phase":%s,"current_run":%d,"repeat":%d,"completed_runs":%d,"successes":%d,"failures":%d,"started_at":%s,"current_run_started_at":' \
      "$(json_string "$job_id")" "$(json_string "$state")" "$(json_string "$phase")" \
      "$current_run" "$repeat" "$completed" "$successes" "$failures" "$(json_string "$started_at")"
    if [[ -n $current_run_started_at ]]; then json_string "$current_run_started_at"; else printf 'null'; fi
    printf ',"last_heartbeat":%s,"runner_pid":%d,"child_pid":' "$(json_string "$current_time")" "$$"
    if [[ -n $child_pid ]]; then printf '%d' "$child_pid"; else printf 'null'; fi
    if [[ -n $finished_at ]]; then printf ',"finished_at":%s' "$(json_string "$finished_at")"; fi
    printf '}\n'
  } > "$temp"
  mv -f -- "$temp" "$job_dir/status.json"
  status_writing=0
}
event_id=0
status_writing=0
append_event() {
  ((persistent)) || return 0
  local type=$1 severity=$2 extra=${3-}
  ((event_id += 1))
  printf '{"id":%d,"timestamp":%s,"type":%s,"severity":%s%s}\n' \
    "$event_id" "$(json_string "$(timestamp)")" "$(json_string "$type")" \
    "$(json_string "$severity")" "$extra" >> "$job_dir/events.jsonl"
}
signal_name() {
  local code=$1 name
  ((code > 128 && code <= 192)) || return 0
  name=$(kill -l "$((code - 128))" 2>/dev/null) || return 0
  [[ $name == SIG* ]] || name=SIG$name
  printf '%s' "$name"
}

heartbeat_pid= child_pid= state=starting phase=warmup current_run=0 completed=0
successes=0 failures=0 total=0 minimum=-1 maximum=0
current_run_started_at= finished_at= started_at=$(timestamp)
heartbeat_tick=0
on_heartbeat() { heartbeat_tick=1; write_status; }
start_heartbeat() {
  ((persistent)) || return 0
  # The timer runs in a subshell, but Bash keeps $$ equal to the parent shell's
  # PID there. USR1 consequently wakes the runner, not the timer process.
  (
    trap 'kill "$sleep_pid" 2>/dev/null || true; wait "$sleep_pid" 2>/dev/null || true; exit' TERM HUP INT
    while :; do
      sleep 30 & sleep_pid=$!
      wait "$sleep_pid" || exit
      kill -USR1 "$$" 2>/dev/null || break
    done
  ) &
  heartbeat_pid=$!
}
stop_heartbeat() {
  if [[ -n $heartbeat_pid ]]; then
    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true
    heartbeat_pid=
  fi
}
set_sentinel() {
  ((persistent)) || return 0
  rm -f -- "$job_dir/RUNNING"
  printf 'successes=%d\nfailures=%d\nlast_event_id=%d\n' \
    "$successes" "$failures" "$event_id" > "$job_dir/${state^^}"
}
finish_job() {
  state=$1 phase=finished current_run_started_at= child_pid=
  finished_at=$(timestamp)
  stop_heartbeat
  if ((persistent)); then
    if [[ $state == done ]]; then
      append_event job_completed info ",\"successes\":$successes,\"failures\":$failures"
    else
      append_event job_completed error ",\"successes\":$successes,\"failures\":$failures"
    fi
    write_status
    set_sentinel
  fi
}
handle_signal() {
  local signal=$1 code=$2
  trap - HUP INT TERM
  append_event cancellation_requested warning ",\"signal\":$(json_string "SIG$signal")"
  if [[ -n $child_pid ]]; then
    # Monitor mode gives each asynchronous command its own process group whose
    # ID is child_pid. Signal the group to include descendants, with a direct
    # child signal as a fallback on shells/platforms without that grouping.
    kill -s "$signal" -- "-$child_pid" 2>/dev/null || kill -s "$signal" "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  stop_heartbeat
  state=cancelled phase=finished child_pid= current_run_started_at= finished_at=$(timestamp)
  append_event job_cancelled warning
  write_status
  set_sentinel
  exit "$code"
}
trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM
trap 'on_heartbeat' USR1

execute_one() {
  local kind=$1 number=$2 start end elapsed status extra name out_path err_path
  phase=$kind current_run=$number current_run_started_at=$(timestamp)
  if [[ $kind == measured ]]; then
    out_path=$(printf 'stdout/run-%06d.log' "$number")
    err_path=$(printf 'stderr/run-%06d.log' "$number")
    append_event run_started info ",\"run\":$number"
  else
    out_path=$(printf 'stdout/warmup-%06d.log' "$number")
    err_path=$(printf 'stderr/warmup-%06d.log' "$number")
    append_event warmup_started info ",\"run\":$number"
  fi
  start=$(now_us)
  # Keep command construction in one place; the branches below only select
  # input and output destinations. A backgrounded shell function runs in a
  # subshell; exec replaces that subshell with the command, making $! the PID
  # that status reporting and cancellation should track.
  run_command() { cd -- "$cwd" && exec env "${env_args[@]}" "${command[@]}"; }
  if ((persistent)); then
    if [[ -n $stdin_file ]]; then
      run_command < "$stdin_file" > "$job_dir/$out_path" 2> "$job_dir/$err_path" &
    else
      run_command <&0 > "$job_dir/$out_path" 2> "$job_dir/$err_path" &
    fi
  elif [[ -n $stdin_file ]]; then
    if [[ $display_format == jsonl ]]; then
      # Reserve stdout for valid JSONL records; command output remains visible
      # on stderr in machine-readable mode.
      run_command < "$stdin_file" 1>&2 &
    else
      run_command < "$stdin_file" &
    fi
  else
    if [[ $display_format == jsonl ]]; then
      run_command <&0 1>&2 &
    else
      run_command <&0 &
    fi
  fi
  child_pid=$!
  state=running
  write_status
  start_heartbeat
  while :; do
    heartbeat_tick=0
    if wait "$child_pid"; then status=0; break
    else status=$?; fi
    # A USR1 heartbeat interrupts Bash's wait. Retry only in that case; any
    # other nonzero status is the command's real exit status.
    ((heartbeat_tick)) || break
  done
  stop_heartbeat
  child_pid= current_run_started_at=
  end=$(now_us); elapsed=$((end - start)); ((elapsed >= 0)) || elapsed=0
  if ((persistent && !detach)); then
    if [[ $display_format == jsonl ]]; then cat -- "$job_dir/$out_path" >&2
    else cat -- "$job_dir/$out_path"; fi
    cat -- "$job_dir/$err_path" >&2
  fi
  if [[ $kind == measured ]]; then
    ((completed += 1))
    ((total += elapsed))
    if ((minimum < 0 || elapsed < minimum)); then minimum=$elapsed; fi
    if ((elapsed > maximum)); then maximum=$elapsed; fi
    if ((status == 0)); then ((successes += 1)); else ((failures += 1)); fi
    if ((persistent)); then
      printf '{"run":%d,"exit_code":%d,"elapsed_us":%d,"stdout":%s,"stderr":%s}\n' \
        "$number" "$status" "$elapsed" "$(json_string "$out_path")" "$(json_string "$err_path")" >> "$job_dir/results.jsonl"
      extra=",\"run\":$number,\"exit_code\":$status,\"elapsed_us\":$elapsed,\"stdout\":$(json_string "$out_path"),\"stderr\":$(json_string "$err_path")"
      if ((status)); then
        name=$(signal_name "$status")
        [[ -z $name ]] || extra+=",\"signal\":$(json_string "$name")"
        append_event run_failed error "$extra"
      else append_event run_completed info "$extra"; fi
    fi
    if ((!detach)); then
      if [[ $display_format == jsonl ]]; then
        printf '{"type":"run","run":%d,"exit_code":%d,"elapsed_us":%d}\n' "$number" "$status" "$elapsed"
      else
        printf 'Run %d/%d: exit %d, %s s\n' "$number" "$repeat" "$status" "$(format_us "$elapsed")"
      fi
    fi
  elif ((persistent)); then
    extra=",\"run\":$number,\"exit_code\":$status,\"elapsed_us\":$elapsed,\"stdout\":$(json_string "$out_path"),\"stderr\":$(json_string "$err_path")"
    if ((status)); then append_event warmup_failed error "$extra"
    else append_event warmup_completed info "$extra"; fi
  fi
  write_status
  return "$status"
}

if ((detach && !worker)); then
  # Resolve the script before leaving the foreground process so the worker does
  # not depend on PATH or on the caller retaining its current directory.
  script_path=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")
  : > "$job_dir/runner.stdout"
  : > "$job_dir/runner.stderr"
  nohup "$script_path" --worker "$job_dir" "${original_args[@]}" \
    < /dev/null > "$job_dir/runner.stdout" 2> "$job_dir/runner.stderr" &
  worker_pid=$!
  # Do not report a detached job until the worker has produced its first atomic
  # status file. This turns immediate startup failures into caller-visible errors.
  for ((attempt=0; attempt<100; attempt++)); do
    [[ -f $job_dir/status.json ]] && break
    if ! kill -0 "$worker_pid" 2>/dev/null; then
      printf 'Error: worker failed to start; see %s\n' "$job_dir/runner.stderr" >&2
      exit 2
    fi
    sleep 0.05
  done
  [[ -f $job_dir/status.json ]] || error "worker did not initialize; see $job_dir/runner.stderr"
  if [[ $display_format == jsonl ]]; then
    command -v jq >/dev/null 2>&1 || error 'jq is required for detached JSON output'
    jq -cn \
      --arg job_id "$job_id" \
      --argjson pid "$worker_pid" \
      --arg job_dir "$job_dir" \
      --arg status "$job_dir/status.json" \
      --arg events "$job_dir/events.jsonl" \
      '{job_id:$job_id,pid:$pid,job_dir:$job_dir,status:$status,events:$events}'
  else
    printf 'job_id=%s\npid=%d\njob_dir=%s\nstatus=%s\nevents=%s\n' \
      "$job_id" "$worker_pid" "$job_dir" "$job_dir/status.json" "$job_dir/events.jsonl"
  fi
  exit 0
fi

if ((persistent)); then
  : > "$job_dir/events.jsonl"
  : > "$job_dir/results.jsonl"
  printf '%d\n' "$$" > "$job_dir/pid"
  : > "$job_dir/RUNNING"
  write_metadata
  write_status
  append_event job_started info
fi
for ((run=1; run<=warmup; run++)); do
  if execute_one warmup "$run"; then :; else finish_job failed; exit 1; fi
done
for ((run=1; run<=repeat; run++)); do
  if execute_one measured "$run"; then :; else
    ((stop_on_error)) && break
  fi
done
if ((persistent)); then
  printf '{"type":"summary","runs":%d,"successes":%d,"failures":%d,"min_us":%d,"avg_us":%d,"max_us":%d}\n' \
    "$completed" "$successes" "$failures" "$minimum" "$((completed ? total / completed : 0))" "$maximum" >> "$job_dir/results.jsonl"
fi
if ((!detach)); then
  if [[ $display_format == jsonl ]]; then
    printf '{"type":"summary","runs":%d,"successes":%d,"failures":%d,"min_us":%d,"avg_us":%d,"max_us":%d}\n' \
      "$completed" "$successes" "$failures" "$minimum" "$((completed ? total / completed : 0))" "$maximum"
  else
    printf 'Summary: %d succeeded, %d failed; min %s s, avg %s s, max %s s\n' \
      "$successes" "$failures" "$(format_us "$minimum")" \
      "$(format_us "$((completed ? total / completed : 0))")" "$(format_us "$maximum")"
  fi
fi
if ((failures)); then finish_job failed; exit 1
else finish_job done; exit 0; fi
