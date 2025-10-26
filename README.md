# Scripts Toolkit

This repository hosts a collection of Bash utilities and higher level scripts used for
media management and host provisioning. The layout mirrors how the scripts are
consumed on the target systems so everything can be copied or sourced directly.

## Repository layout

- `bin/` – portable wrappers and helper binaries. The `bats` wrapper ships with the
  repo so the test suite can run without a global installation.
- `lib/` – reusable shell libraries that individual scripts source. Each file stays
  dependency-light and provides fallbacks so they can be consumed in isolation.
- `tests/` – Bats integration tests for both the libraries and higher level glue
  scripts. Test files can be run individually or as a suite.
- `*.sh` – top-level scripts that orchestrate media synchronization and host setup
  using the primitives exposed in `lib/`.

## Usage

Most scripts are intended to be sourced or executed from within the repository
root so that relative paths resolve correctly. For example, to synchronize TV
shows you can run:

```bash
./sync_shows.sh
```

Library helpers can also be sourced directly from other scripts:

```bash
source "$(pwd)/lib/download.sh"
download_file "https://example.com/tool.tar.gz"
```

## Testing

All automated tests are implemented with [Bats](https://bats-core.readthedocs.io/).
The repository includes a vendored runner so you only need Bash and standard Unix
utilities. To execute the full suite run:

```bash
bin/bats tests
```

You can also target an individual file during development:

```bash
bin/bats tests/system_info.bats
```

Each test creates its own temporary sandbox so it can run on a developer
workstation or in CI without elevated privileges.
