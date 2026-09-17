#!/usr/bin/env bash

set -u

# Keep parsing and decimal output independent of the caller's locale.
export LC_ALL=C

readonly MAX_REPEAT=1000000

usage() {
  cat <<'EOF'
Usage: experiment_runner.sh --repeat N -- command [args...]

Run a command N times and report elapsed time and exit status for each run.
Failed runs, including runs killed by signals such as SIGSEGV or SIGKILL, do
not stop later runs.
N must be between 1 and 1,000,000. The runner exits non-zero if any run fails.
EOF
}

usage_error() {
  printf 'Error: %s\n' "$1" >&2
  usage >&2
  exit 2
}

if [[ ${1-} == --help || ${1-} == -h ]]; then
  usage
  exit 0
fi

[[ ${1-} == --repeat ]] || usage_error 'expected --repeat N'
[[ ${2-} =~ ^[1-9][0-9]*$ ]] || usage_error 'N must be a positive integer'

# The 10# prefix prevents values such as 08 from being interpreted as octal by
# Bash arithmetic. Check the string length first so arithmetic never receives a
# value that could overflow the shell's signed integer type.
(( ${#2} <= ${#MAX_REPEAT} )) || usage_error "N must not exceed $MAX_REPEAT"
repeat=$((10#$2))
(( repeat <= MAX_REPEAT )) || usage_error "N must not exceed $MAX_REPEAT"
shift 2
[[ ${1-} == -- ]] || usage_error 'expected -- before the command'
shift
(( $# > 0 )) || usage_error 'a command is required'

if (( BASH_VERSINFO[0] >= 5 )) && [[ -n ${EPOCHREALTIME-} ]]; then
  now_us() { printf '%s\n' "${EPOCHREALTIME/./}"; }
else
  now_us() { printf '%s\n' "$((SECONDS * 1000000))"; }
  printf 'Note: this Bash version provides whole-second timing only.\n' >&2
fi

format_us() {
  printf '%d.%06d' "$(( $1 / 1000000 ))" "$(( $1 % 1000000 ))"
}

successes=0
failures=0
total=0
minimum=-1
maximum=0
child_pid=

forward_signal() {
  local signal=$1 exit_status=$2

  # Do not leave a running experiment behind when the runner is interrupted.
  trap - HUP INT TERM
  if [[ -n $child_pid ]]; then
    kill -s "$signal" "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  exit "$exit_status"
}

trap 'forward_signal HUP 129' HUP
trap 'forward_signal INT 130' INT
trap 'forward_signal TERM 143' TERM

for ((run = 1; run <= repeat; run++)); do
  start=$(now_us)
  # Running asynchronously lets Bash process our traps immediately instead of
  # postponing them until a long-running command has finished. Explicitly keep
  # stdin attached, since non-interactive Bash otherwise redirects it for an
  # asynchronous command when job control is disabled.
  "$@" <&0 &
  child_pid=$!
  # wait returns 128 + signal for a signalled child (for example, 139 for
  # SIGSEGV and 137 for the SIGKILL commonly used by the OOM killer). Treat
  # those statuses like any other per-run failure so the loop continues.
  if wait "$child_pid"; then
    status=0
    ((successes += 1))
  else
    status=$?
    ((failures += 1))
  fi
  child_pid=
  end=$(now_us)
  elapsed=$((end - start))
  ((elapsed < 0)) && elapsed=0
  ((total += elapsed))
  if ((minimum < 0 || elapsed < minimum)); then minimum=$elapsed; fi
  if ((elapsed > maximum)); then maximum=$elapsed; fi
  printf 'Run %d/%d: exit %d, %s s\n' "$run" "$repeat" "$status" "$(format_us "$elapsed")"
done

printf 'Summary: %d succeeded, %d failed; min %s s, avg %s s, max %s s\n' \
  "$successes" "$failures" "$(format_us "$minimum")" \
  "$(format_us "$((total / repeat))")" "$(format_us "$maximum")"

((failures == 0))
