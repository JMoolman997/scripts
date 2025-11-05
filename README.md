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

The repo bundles Bats so you can run the suite with:

```bash
bin/bats tests/*.bats
```

Run a single file the same way if you are working on one area:

```bash
bin/bats tests/netctl.bats
```
