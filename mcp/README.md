# Bash MCP server for Zed

`server.sh` is a newline-delimited JSON-RPC stdio server implemented with Bash
and jq. It supports the MCP `2025-11-25` initialization lifecycle plus `ping`,
`tools/list`, and `tools/call`. It opens no network port and has no dependency
on Ollama or another model provider.

## How the server is organized

`server.sh` is intentionally a single process with no background listener. At
startup it validates its dependencies and timeout settings, creates a private
temporary directory, and reserves the original stdout file descriptor for MCP
responses. Ordinary stdout is redirected to stderr so unexpected diagnostic
output cannot be mistaken for a protocol message.

The main loop reads one JSON object per line and processes it in these stages:

1. Parse the line and validate the JSON-RPC envelope.
2. `handle_request` enforces the MCP initialization lifecycle and dispatches the
   method.
3. `call_tool` validates each tool's arguments and selects a fixed executable or
   experiment operation.
4. `run_command` captures stdout and stderr separately, applies the configured
   startup/inspection timeout, and creates a consistent structured result.
5. `tool_response` returns that result as both MCP text content and structured
   content. Protocol responses are written only to the saved stdout descriptor.

The functions are grouped by purpose in the script:

- **Preset registry:** `preset_wrapper` maps allowlisted names to repository
  executables, while `available_experiments` supplies their public metadata.
- **Result helpers:** `send_result`, `send_error`, `validation_failure`, and
  `run_command` build the JSON-RPC and command-result envelopes.
- **Experiment validation and launch:** `valid_selection`, `verify_one`,
  `verify_batch`, and `run_batch` validate presets before starting jobs.
- **Job access:** `resolve_job` confines a job ID to the state directory,
  `job_status` reads bounded history, and `cancel_job` verifies the live process
  identity before signalling it.
- **Protocol dispatch:** `tool_response`, `call_tool`, and `handle_request`
  translate validated JSON-RPC methods into the operations above.

The server uses global `PROJECT`, `REPLY`, `STATE_ROOT_REAL`, and `JOB_DIR`
variables as return values from small validation/resolution helpers. Callers
must only read those variables after the corresponding function succeeds.

## Dependencies and Zed configuration

Runtime dependencies are Bash 4+, jq, GNU coreutils, Git, and the tools required
by an enabled experiment. Merge this into Zed's settings:

```json
{
  "context_servers": {
    "local-dev-tools": {
      "command": "/home/Moolman997/git/scripts/mcp/server.sh",
      "args": [],
      "env": {}
    }
  },
  "agent": {
    "tool_permissions": {
      "tools": {
        "mcp:local-dev-tools:run_experiments": { "default": "confirm" },
        "mcp:local-dev-tools:cancel_experiment": { "default": "confirm" }
      }
    }
  }
}
```

Open **Settings → AI → MCP Servers**, confirm `local-dev-tools` is active, and
enable it for the Agent profile. Zed's confirmation is the human authorization
boundary; an MCP argument cannot prove that a human approved an operation.

Two optional environment variables control the bounded foreground work:

- `MCP_INSPECT_TIMEOUT` is the maximum number of seconds for inspection tools
  and preset verification (default: `15`).
- `MCP_EXPERIMENT_START_TIMEOUT` is the maximum number of seconds allowed for a
  wrapper to create and report a detached job (default: `15`). It does **not**
  limit the detached experiment's runtime.

Both values must be integers from 1 through 9999. `MCP_ENABLE_TEST_PRESETS=1`
is reserved for the automated test harness and should not be set in normal use.

## Tools

- `system_info()` — read-only host information.
- `project_info(project)` — non-recursive project marker inspection.
- `git_status(project)` — concise, read-only Git status.
- `git_diff(project)` — unstaged diff with external diff and textconv disabled.
- `list_experiments()` — enabled fixed presets. Production initially returns an
  empty list.
- `verify_experiments(experiments)` — validate 1–32 unique preset names and show
  the exact wrapper-provided configuration without running it.
- `run_experiments(experiments)` — revalidate the whole batch, then start one
  detached job per preset. A launch failure does not cancel jobs already started.
  It is conservatively annotated destructive and open-world because enabled
  programs can modify files or communicate externally.
- `experiment_status(job_id)` — metadata, status, the last 100 events/results,
  and captured-output locations. It deliberately does not return unbounded logs.
- `cancel_experiment(job_id)` — best-effort termination after checking that the
  live PID is the expected runner for that job.

Experiment jobs are stored under
`${XDG_STATE_HOME:-$HOME/.local/state}/local-dev-tools/experiments`. Starting a
job creates this directory; listing and verification do not. There is no forced
experiment runtime limit by design. A confirmed batch can consume CPU, memory,
disk, and other resources until it finishes or cancellation succeeds.

## Adding an experiment

An experiment is an executable Bash wrapper with exactly two public operations:

```bash
#!/usr/bin/env bash
set -uo pipefail
repo_root=/absolute/audited/project/path

case ${1-} in
  verify)
    # Check fixed dependencies and paths, then describe the exact operation.
    jq -cn --arg cwd "$repo_root" '{
      name:"my_benchmark",
      description:"Run the fixed project benchmark.",
      command:["./build/benchmark","--size","10000"],
      cwd:$cwd,
      repeat:5,
      warmup:1,
      runtime_limit:null,
      warnings:["No forced runtime limit."]
    }'
    ;;
  run)
    (($# == 2)) || exit 2
    output_root=$2
    exec /home/Moolman997/git/scripts/experiment_runner.sh \
      --detach --format jsonl -C "$repo_root" -o "$output_root" \
      -l my-benchmark -w 1 -r 5 -- ./build/benchmark --size 10000
    ;;
  *) exit 2 ;;
esac
```

Then add its fixed name and repository-owned path to `preset_wrapper` and its
description to `available_experiments` in `server.sh`. Do not accept commands,
arguments, paths, environment assignments, repetitions, or wrapper names from
the MCP request. The intended path remains:

```text
semantic MCP tool -> validated preset name -> audited wrapper -> experiment_runner.sh
```

Verification confirms that a preset is currently configured and available. It
does not make the command harmless, impose a timeout, or represent human consent.

## Protocol and security notes

- Server stdout is reserved for MCP; diagnostics go to stderr.
- jq parses and constructs all MCP JSON.
- Every exposed operation maps to a fixed executable. There is no shell, exec,
  script-path, package-installation, sudo, or Git-mutation tool.
- Project paths use `realpath` and must already be directories.
- Job IDs have a narrow syntax and must resolve beneath the state root.
- Commands use quoted arrays. The MCP adapter contains no `eval` or `bash -c`.
- Command stdout, stderr, exit status, and timeout state remain separate.
- Cancellation is destructive and best-effort. It cannot reverse filesystem or
  external effects produced before termination, and process termination races
  remain possible even after identity checks.

## Verification

Run the focused suites first, followed by all repository tests:

```bash
bin/bats tests/experiment_runner.bats
bin/bats tests/mcp_server.bats
bin/bats tests/*.bats
```

The tests cover initialization, discovery, sequential calls, malformed input,
empty production presets, validation, detached JSON output, launch and partial
launch failure, status, captured multiline stdout/stderr, cancellation, Git
textconv suppression, and inspection timeouts. MCP-only fixtures are enabled solely by the test harness
through `MCP_ENABLE_TEST_PRESETS=1`; it is absent from the normal tool catalog.
