# gitmatic

<p align="center">
  <img src="logo.jpg" alt="gitmatic Logo" width="500"/>
</p>

<p align="center">
  <strong>Automate safe Git maintenance across multiple repositories</strong>
</p>

## What it does

gitmatic is a Bash tool that scans one or more parent directories, discovers Git repositories (including worktrees), and performs configured maintenance operations:

- `FETCH` section: `git fetch --prune --tags`
- `PULL` section: `git pull`
- `SILENT_UPDATE` section: safe local tracking-branch updates **without checkout**

## Why `SILENT_UPDATE` exists

`SILENT_UPDATE` is designed for users who want repository metadata updated in the background while they may be actively working in worktrees.

Behavior:

1. Fetch remote updates.
2. Enumerate local branches that have an upstream.
3. For each branch:
   - Skip if currently checked out in any worktree.
   - Skip if fast-forward is not possible.
   - Otherwise fast-forward local branch ref to upstream **without checkout**.

See concise mechanism docs here:
- [`docs/silent-update.md`](docs/silent-update.md)

## Installation

### macOS (automated)

Install script + config scaffold + optional launchd helper:

```bash
./scripts/install-macos.sh
```

Install a launch agent that runs every 15 minutes:

```bash
./scripts/install-launchd.sh
```

### Generic manual setup

1. Clone repository.
2. Make scripts executable:

```bash
chmod +x gitmatic.sh scripts/*.sh tests/*.sh
```

3. Copy config template:

```bash
cp gitmatic.ini.example gitmatic.ini
```

## Usage

```bash
./gitmatic.sh [OPTIONS]
```

Options:

- `--config FILE` - Path to config file (default `gitmatic.ini`)
- `--dry-run` - Print actions without changing repositories
- `--verbose` / `-v` - Extra progress output
- `--log-file FILE` - Append logs to this file
- `--help` - Show help

Examples:

```bash
./gitmatic.sh --config ./gitmatic.ini --log-file ./gitmatic.log
./gitmatic.sh --dry-run --verbose
```

## Configuration

The file is INI-like. Each operation section accepts repository paths or parent paths to scan recursively.

```ini
[SETTINGS]
log_format = TXT

[FETCH]
path = /Users/you/src

[PULL]
# use cautiously if you actively edit repos
path = /Users/you/archived-projects

[SILENT_UPDATE]
path = /Users/you/src
```

Notes:

- Relative paths are resolved relative to the configuration file location.
- The scanner includes repos where `.git` is a directory **or** a file (worktree-linked repos).
- Worktree-checked-out branches are logged as skipped in `SILENT_UPDATE`.
- If no operation sections are configured, gitmatic defaults to `SILENT_UPDATE` using the configuration file directory as the scan root.

## Scheduling

### macOS `launchd` (recommended)

Install:

```bash
./scripts/install-launchd.sh \
  --script "$HOME/.local/share/gitmatic/gitmatic.sh" \
  --config "$HOME/.local/share/gitmatic/gitmatic.ini" \
  --interval-seconds 900
```

Uninstall:

```bash
./scripts/uninstall-launchd.sh
```

### cron

Run every 15 minutes:

```cron
*/15 * * * * /absolute/path/to/gitmatic.sh --config /absolute/path/to/gitmatic.ini --log-file /absolute/path/to/gitmatic.log
```

## Tests

Lightweight, isolated tests create temporary repositories and bare remotes locally (no network):

```bash
./tests/run.sh
```

Coverage currently includes:

- fast-forward update of non-checked-out tracking branch
- skip on non-fast-forward/diverged branch
- skip when branch is checked out in another worktree

## License

GNU GPL v3.0 - see [LICENSE](LICENSE).

## Credits

- Original project and author: **AutoGit-o-Matic** by **Mateusz Okulanis** (`FPGArtktic@outlook.com`)
- This fork (`gitmatic`) keeps original attribution and license terms.
