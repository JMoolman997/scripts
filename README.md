# Scripts Toolkit

Collection of Bash helpers for media sync and host setup. Clone the repo and run the
scripts from its root so the relative paths work.

## Scripts

| Script | What it does | Quick use |
| ------ | ------------- | --------- |
| `sync_shows.sh` | Pull TV show libraries with `rsync`. | `./sync_shows.sh` |
| `sync_movies.sh` | Pull movie libraries with `rsync`. | `./sync_movies.sh` |
| `jellyfinctl.sh` | Manage Jellyfin (start/stop/restart/status). | `./jellyfinctl.sh restart` |
| `media_server_setup.sh` | Install Jellyfin, dependencies, and service files. | `./media_server_setup.sh` |
| `netctl.sh` | Set up SSH keys, check connectivity, toggle Tailscale. | `./netctl.sh login user@host` |
| `c_setup.sh` | Bootstrap a minimal C project (dirs, Makefile, git optional). | `./c_setup.sh my_app` |
| `py_venv_setup.sh` | Create a local Python venv with common tooling. | `./py_venv_setup.sh` |
| `setup-zsh-tmux.sh` | Install dotfiles and plugins for zsh+tmux. | `./setup-zsh-tmux.sh` |

## Libraries

Reusable functions live in `lib/`. Source them if you only need a helper:

```bash
source lib/download.sh
```

## Tests

```bash
source "$(pwd)/lib/download.sh"
download_file "https://example.com/tool.tar.gz"
```

### Top-level helpers

- `netctl.sh` — drives common SSH and Tailscale workflows for a remote host.
  The helper can generate/copy SSH keys, validate a login, and toggle
  `tailscale up/down` with optional SSH support.
- `c_setup.sh` — scaffolds a minimal C project by creating `src/`, `tests/`, and
  `build/` directories, generating a starter Makefile, and optionally
  initialising a git repository.

## Testing

All automated tests are implemented with [Bats](https://bats-core.readthedocs.io/).
The repository includes a vendored runner so you only need Bash and standard Unix
utilities. To execute the full suite run:

```bash
bin/bats tests/*.bats
```

Some environments also support `bin/bats tests`, but invoking the globbed test
files explicitly guarantees every suite is executed.

You can also target an individual file during development:

```bash
bin/bats tests/netctl.bats
```
