#!/usr/bin/env bash
#
# experiment_runner.sh
# --------------------
# Run a reusable list of experiments defined in a Bash configuration file.
#
# Design goals:
#   - Keep configuration minimal: experiment NAME COMMAND [ARGS...]
#   - Preserve command arguments exactly; no eval and no command strings.
#   - Run every experiment in a subshell so one experiment cannot change the
#     runner's working directory, variables, shell options, or environment.
#   - Continue after normal failures and child-process crashes such as SIGSEGV
#     or SIGKILL. The runner exits non-zero only after all experiments finish.
#   - Always show suite progress as [current/total].
#   - Show task/suite elapsed time and estimated time remaining in a terminal.
#   - Allow experiments to optionally report internal progress through one
#     small file-based interface; experiments that ignore it require no changes.
#
# Requirements:
#   - Bash 4.3+ (for namerefs: local -n)
#
# Usage:
#   ./experiment_runner.sh [experiments-file]
#
# If no file is supplied, ./experiments.sh is used.
#
# Example experiments.sh:
#
#   experiment baseline ./build/sim --agent baseline --episodes 100
#   experiment bdi      ./build/sim --agent bdi      --episodes 100
#   experiment mcts     env MCTS_ITERATIONS=1000 ./build/sim --agent mcts
#
# More complicated experiments can be ordinary Bash functions:
#
#   run_ablation() {
#       cd build || return
#       ./sim --agent mcts --ablation no-tree-reuse
#   }
#   experiment ablation run_ablation
#
# Optional task progress:
#   While an experiment is running, EXPERIMENT_PROGRESS_FILE contains the path
#   of a temporary file owned by the runner. An experiment that knows its own
#   progress may overwrite that file with:
#
#       COMPLETED TOTAL
#
#   For example:
#
#       printf '%d %d\n' "$episode" "$episodes" > "$EXPERIMENT_PROGRESS_FILE"
#
#   The runner uses this to display a percentage and estimate the current
#   task's remaining time. Experiments that do not write the file still get
#   elapsed-time reporting and, once prior tasks have completed, a rough ETA
#   based on the average duration of those tasks.
#
# Progress output is refreshed once per second only when stdout is a terminal,
# so redirected/CI output is not flooded with status lines.
#
# IMPORTANT:
#   Do not add `set -e`. A failed experiment is expected data here; it must not
#   terminate the runner before the remaining experiments have been attempted.

set -uo pipefail

# -----------------------------------------------------------------------------
# Global runner state
# -----------------------------------------------------------------------------

# Each experiment has a human-readable name in `experiment_names`.
# Its command is stored in a separate Bash array named experiment_cmd_N.
# This avoids `eval` and preserves spaces, quotes, and other argument boundaries.
declare -a experiment_names=()

failures=0
total=0
completed_count=0
completed_time=0
suite_start=0

# State for the currently running child. These are only used to clean up if the
# user explicitly interrupts the runner while an experiment is active.
current_child_pid=
current_status_pid=
current_progress_file=

# Live status is useful on an interactive terminal but noisy when output is
# redirected to a file or consumed by another program.
live_progress=0
[[ -t 1 ]] && live_progress=1


# -----------------------------------------------------------------------------
# Utility functions
# -----------------------------------------------------------------------------

die() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

# Format an integer number of seconds as HH:MM:SS.
format_time() {
    local seconds=$1

    ((seconds >= 0)) || seconds=0

    printf '%02d:%02d:%02d' \
        "$((seconds / 3600))" \
        "$(((seconds / 60) % 60))" \
        "$((seconds % 60))"
}

# Convert an exit status caused by a signal into a readable signal name.
# Bash normally reports a process terminated by signal N as 128 + N.
signal_name() {
    local status=$1
    local number

    ((status > 128 && status <= 192)) || return 1

    number=$((status - 128))
    kill -l "$number" 2>/dev/null || return 1
}

# Print one live status line for the current experiment.
#
# Task ETA:
#   - If the experiment reports COMPLETED/TOTAL, extrapolate from its observed
#     rate: elapsed * (TOTAL - COMPLETED) / COMPLETED.
#   - Otherwise, after at least one task has completed, estimate the current
#     task from the mean duration of previous tasks.
#
# Suite ETA:
#   - Current task ETA + mean previous-task duration for every later task.
#   - If no previous duration exists, a multi-task suite ETA is intentionally
#     shown as unknown rather than pretending all future tasks match this one.
show_status() {
    ((live_progress)) || return 0

    local index=$1 name=$2 task_start=$3 progress_file=$4
    local task_elapsed suite_elapsed
    local current task_total percent
    local task_eta=-1 suite_eta=-1 average=-1 remaining_after
    local progress_text=''
    local task_eta_text='--:--:--' suite_eta_text='--:--:--'

    task_elapsed=$((SECONDS - task_start))
    suite_elapsed=$((SECONDS - suite_start))
    remaining_after=$((total - index - 1))

    # The progress file is optional. Ignore empty, partial, malformed, or
    # out-of-range updates and continue showing elapsed time only.
    if [[ -s $progress_file ]] &&
       read -r current task_total < "$progress_file" 2>/dev/null &&
       [[ $current =~ ^[0-9]+$ && $task_total =~ ^[0-9]+$ ]] &&
       ((task_total > 0 && current <= task_total)); then

        percent=$((current * 100 / task_total))
        progress_text=$(printf ' | %d/%d (%d%%)' "$current" "$task_total" "$percent")

        if ((current > 0)); then
            task_eta=$((task_elapsed * (task_total - current) / current))
        fi
    fi

    if ((completed_count > 0)); then
        average=$((completed_time / completed_count))

        # Without internal progress, use previous tasks only as a rough estimate
        # of how long the current task may still need.
        if ((task_eta < 0)); then
            task_eta=$((average - task_elapsed))
            ((task_eta >= 0)) || task_eta=0
        fi
    fi

    if ((task_eta >= 0)); then
        task_eta_text=$(format_time "$task_eta")

        if ((remaining_after == 0)); then
            suite_eta=$task_eta
        elif ((average >= 0)); then
            suite_eta=$((task_eta + average * remaining_after))
        fi
    fi

    if ((suite_eta >= 0)); then
        suite_eta_text=$(format_time "$suite_eta")
    fi

    # \033[K clears the remainder of the previous status line if the new line
    # is shorter. The next refresh overwrites this line using carriage return.
    printf '\r\033[K[%d/%d] %s%s | task %s ETA %s | suite %s ETA %s' \
        "$((index + 1))" "$total" "$name" "$progress_text" \
        "$(format_time "$task_elapsed")" "$task_eta_text" \
        "$(format_time "$suite_elapsed")" "$suite_eta_text"
}

clear_status() {
    ((live_progress)) || return 0
    printf '\r\033[K'
}


# -----------------------------------------------------------------------------
# Experiment registration API
# -----------------------------------------------------------------------------

# Register one experiment.
#
# Usage:
#   experiment NAME COMMAND [ARG ...]
#
# Examples:
#   experiment baseline ./sim --agent baseline
#   experiment mcts env MCTS_ITERATIONS=1000 ./sim --agent mcts
#
# Commands are stored as Bash arrays rather than strings. This means arguments
# such as "file with spaces.txt" remain one argument and no `eval` is required.
experiment() {
    (($# >= 2)) || die 'experiment requires NAME and COMMAND'

    local index=${#experiment_names[@]}
    local array_name="experiment_cmd_${index}"

    experiment_names+=("$1")
    shift

    # Create a global array for this command, then access it through a nameref.
    declare -g -a "$array_name"
    local -n command_ref="$array_name"
    command_ref=("$@")
}


# -----------------------------------------------------------------------------
# Experiment execution
# -----------------------------------------------------------------------------

run_one() {
    local index=$1
    local name=${experiment_names[index]}
    local array_name="experiment_cmd_${index}"
    local status signal task_start task_elapsed
    local -n command_ref="$array_name"

    printf '\n[%d/%d] %s\n' "$((index + 1))" "$total" "$name"

    # A temporary progress file is created for every experiment. Writing to it
    # is entirely optional; the runner still tracks elapsed time without it.
    current_progress_file=$(mktemp "${TMPDIR:-/tmp}/experiment-runner.XXXXXX") || \
        die 'could not create progress file'

    task_start=$SECONDS

    # Run asynchronously so a small status helper can refresh the terminal while
    # the parent waits directly for the experiment. The command still runs in a
    # subshell, preserving isolation from cd/export/unset/shell-option changes.
    (
        export EXPERIMENT_PROGRESS_FILE="$current_progress_file"
        export EXPERIMENT_NAME="$name"
        export EXPERIMENT_INDEX="$((index + 1))"
        export EXPERIMENT_TOTAL="$total"

        "${command_ref[@]}"
    ) &
    current_child_pid=$!

    # Only interactive terminals need the refresh helper. Keeping the actual
    # `wait` in the parent avoids adding polling delay to short experiments.
    if ((live_progress)); then
        (
            while kill -0 "$current_child_pid" 2>/dev/null; do
                show_status "$index" "$name" "$task_start" "$current_progress_file"
                sleep 1
            done
        ) &
        current_status_pid=$!
    fi

    # `wait` supplies the experiment's real exit status, including signal-based
    # statuses such as 139 (SIGSEGV) and 137 (SIGKILL).
    if wait "$current_child_pid"; then
        status=0
    else
        status=$?
    fi

    # Stop the display helper immediately after the experiment completes.
    if [[ -n $current_status_pid ]]; then
        kill "$current_status_pid" 2>/dev/null || true
        wait "$current_status_pid" 2>/dev/null || true
        current_status_pid=
    fi

    task_elapsed=$((SECONDS - task_start))
    completed_time=$((completed_time + task_elapsed))
    completed_count=$((completed_count + 1))

    clear_status
    rm -f -- "$current_progress_file"
    current_progress_file=
    current_child_pid=

    if ((status == 0)); then
        printf '[%d/%d] %s: OK (%s)\n' \
            "$((index + 1))" "$total" "$name" "$(format_time "$task_elapsed")"
        return 0
    fi

    # A status greater than 128 usually means the process terminated because of
    # a signal. For example, SIGSEGV is normally 139 and SIGKILL is normally 137.
    if signal=$(signal_name "$status"); then
        printf '[%d/%d] %s: FAILED (%s, exit %d, %s)\n' \
            "$((index + 1))" "$total" "$name" "$signal" "$status" \
            "$(format_time "$task_elapsed")" >&2
    else
        printf '[%d/%d] %s: FAILED (exit %d, %s)\n' \
            "$((index + 1))" "$total" "$name" "$status" \
            "$(format_time "$task_elapsed")" >&2
    fi

    ((failures += 1))

    # Deliberately return success to the outer loop. The failure has already
    # been recorded and should not prevent the next experiment from running.
    return 0
}


# -----------------------------------------------------------------------------
# Runner interruption handling
# -----------------------------------------------------------------------------

# Experiment failures are recoverable; an explicit interruption of the runner
# is not. When possible, terminate the currently running experiment and remove
# its temporary progress file before exiting.
handle_interrupt() {
    local code=$1 message=$2

    if [[ -n $current_status_pid ]]; then
        kill "$current_status_pid" 2>/dev/null || true
        wait "$current_status_pid" 2>/dev/null || true
    fi

    clear_status

    if [[ -n $current_child_pid ]]; then
        kill -TERM "$current_child_pid" 2>/dev/null || true
        wait "$current_child_pid" 2>/dev/null || true
    fi

    if [[ -n $current_progress_file ]]; then
        rm -f -- "$current_progress_file"
    fi

    printf '\nexperiment runner %s\n' "$message" >&2
    exit "$code"
}

trap 'handle_interrupt 130 interrupted' INT
trap 'handle_interrupt 143 terminated' TERM


# -----------------------------------------------------------------------------
# Load the experiment list
# -----------------------------------------------------------------------------

config=${1:-experiments.sh}

# Resolve the configuration file before sourcing it so behavior does not depend
# on Bash's PATH/source search rules.
if [[ $config != /* ]]; then
    config="$PWD/$config"
fi

[[ -f $config && -r $config ]] || die "cannot read experiment file: $config"

# The configuration is intentionally Bash. It can define shared arrays, helper
# functions, loops, and generated experiment matrices without another config
# language or parser.
source "$config"

total=${#experiment_names[@]}
((total > 0)) || die "no experiments defined in: $config"


# -----------------------------------------------------------------------------
# Run the complete suite
# -----------------------------------------------------------------------------

suite_start=$SECONDS
printf 'Running %d experiment(s) from %s\n' "$total" "$config"

for index in "${!experiment_names[@]}"; do
    run_one "$index"
done


# -----------------------------------------------------------------------------
# Final summary and process status
# -----------------------------------------------------------------------------

successes=$((total - failures))
suite_elapsed=$((SECONDS - suite_start))

printf '\nSummary: %d/%d succeeded, %d failed; elapsed %s\n' \
    "$successes" "$total" "$failures" "$(format_time "$suite_elapsed")"

# The suite only returns failure after every experiment has had a chance to run.
if ((failures == 0)); then
    exit 0
else
    exit 1
fi
