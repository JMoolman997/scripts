#!/usr/bin/env bash

set -u

usage() {
  cat <<'EOF'
Usage: experiment_runner.sh --repeat N -- command [args...]

Run a command N times and report elapsed time and exit status for each run.
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
[[ ${2-} =~ ^[1-9][0-9]*$ && ${#2} -le 15 ]] || usage_error 'N must be a positive integer'
repeat=$2
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

for ((run = 1; run <= repeat; run++)); do
  start=$(now_us)
  if "$@"; then
    status=0
    ((successes += 1))
  else
    status=$?
    ((failures += 1))
  fi
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
