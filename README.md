# gitmatic

<p align="center">
  <img src="logo.jpg" alt="gitmatic logo" width="500"/>
</p>

<p align="center">
  <strong>Keep many Git repositories up to date without manually visiting each one.</strong>
</p>

Gitmatic is now a Python-based tool that automates Git maintenance across many repositories while staying conservative about working trees.

## What changed

- The core tool is now `gitmatic.py`, with `gitmatic.sh` kept as a tiny wrapper for convenience.
- Configuration is now **TOML only**.
- INI support has been removed.
- macOS users can optionally reuse a dedicated `ssh-agent` across scheduled runs to avoid repeated Touch ID or fingerprint prompts.
- macOS users can optionally get native notifications when selected problems occur.

## Action modes

- `silent_update`: safely fast-forward local tracking branches without checking them out
- `fetch`: run `git fetch --prune --tags`
- `pull`: run `git pull`

Most users should start with `silent_update`.

## Quick start for macOS

### 1) Install the helper

```bash
./scripts/install-macos.sh
```

This installs:

- `~/.local/share/gitmatic/gitmatic.sh`
- `~/.local/share/gitmatic/gitmatic.py`
- `~/.local/share/gitmatic/gitmatic.toml`

It does **not** automatically enable launchd scheduling.

### 2) Edit the TOML config

```bash
code ~/.local/share/gitmatic/gitmatic.toml
```

Minimal example:

```toml
[silent_update]
include_path = ["/Users/yourname/code"]
```

### 3) Optional: enable SSH key caching

If scheduled Git updates keep asking macOS to release your SSH key, configure a dedicated agent:

```toml
[ssh_agent]
enabled = true
key_path = "~/.ssh/id_ed25519"
cache_ttl_seconds = 28800
use_keychain = true
```

How this works:

- gitmatic reuses a previously started `ssh-agent` when possible
- it stores the agent socket and PID in a small state file
- it loads the configured key into that agent with a TTL
- later runs reuse the same unlocked key cache instead of starting from scratch each time

This reduces repeated key release prompts substantially when the agent remains alive and the key TTL has not expired.

### 4) Optional: enable native macOS notifications

```toml
[notifications]
enabled = true
backend = "macos"
title = "gitmatic"
unexpected_statuses = ["FAILED"]
unexpected_codes = ["prefetch_failed", "fetch_failed", "pull_failed", "ssh_key_add_failed"]
```

Notifications are aggregated per run and currently use macOS Notification Center via `osascript`.

### 5) Run it once manually

```bash
~/.local/share/gitmatic/gitmatic.sh --config ~/.local/share/gitmatic/gitmatic.toml --verbose
```

### 6) Optional: schedule it with launchd

```bash
./scripts/install-launchd.sh \
  --script "$HOME/.local/share/gitmatic/gitmatic.sh" \
  --config "$HOME/.local/share/gitmatic/gitmatic.toml"
```

This creates `~/Library/LaunchAgents/io.gitmatic.runner.plist`, runs at login, then repeats every 900 seconds by default, and logs to `~/Library/Logs/gitmatic.log`.

## Configuration

Use TOML tables named `silent_update`, `fetch`, and `pull`.

Example:

```toml
[silent_update]
include_path = ["/Users/yourname/code", "/Users/yourname/work"]
exclude_path = ["/Users/yourname/code/archive", "*node_modules*"]
max_depth = 4

[fetch]
include_path = "/Users/yourname/archive"

[notifications]
enabled = true
backend = "macos"
unexpected_statuses = ["FAILED"]
unexpected_codes = ["prefetch_failed", "ssh_key_add_failed"]
```

Rules worth knowing:

- `include_path` accepts either a string or an array of strings
- `path` still works as a compatibility alias for `include_path`
- `exclude_path` accepts either a string or an array of strings
- exact `exclude_path` values are resolved relative to the config file location
- wildcard `exclude_path` values use simple glob matching against discovered absolute paths
- `max_depth` limits how deep gitmatic descends below each include root
- when gitmatic finds a repo root, it stops descending into that repo
- nested repos are only discovered if you include them explicitly
- if a branch is checked out in any worktree, `silent_update` skips it
- if a branch cannot be fast-forwarded safely, `silent_update` skips it
- if you leave out all operation tables, gitmatic defaults to `silent_update` in the config directory

## Command-line usage

You can run either:

```bash
./gitmatic.py [OPTIONS]
./gitmatic.sh [OPTIONS]
```

Options:

- `--config FILE` - path to the TOML config file
- `--dry-run` - show what would happen without changing repositories
- `--verbose` or `-v` - print extra progress output
- `--log-file FILE` - append JSON logs to a file
- `--help` - show help

Examples:

```bash
./gitmatic.sh --config ./gitmatic.toml --dry-run --verbose
./gitmatic.py --config ./gitmatic.toml --log-file ./gitmatic.log
```

If you point `--config` at an `.ini` file, gitmatic exits with an error because INI is no longer supported.

## Logging

gitmatic writes one JSON object per log line.

When run manually:

- logs always go to stdout
- no log file is created unless you pass `--log-file`

When run through the provided macOS launchd helper:

- launchd stdout/stderr goes to `~/Library/Logs/gitmatic.log`
- gitmatic also appends its structured logs to that same file

## Platform support

- **macOS:** supported, including launchd helper scripts, reusable SSH-agent support, and native notifications
- **Linux:** the main Python tool works; use cron or another scheduler
- **Other Unix-like systems:** likely usable with Python 3.11+ and Git
- **Windows:** not documented here

## Scheduling

### macOS

```bash
./scripts/install-launchd.sh \
  --script "$HOME/.local/share/gitmatic/gitmatic.sh" \
  --config "$HOME/.local/share/gitmatic/gitmatic.toml"
```

Remove it with:

```bash
./scripts/uninstall-launchd.sh
```

### Linux or generic Unix

Example cron entry:

```cron
*/15 * * * * /absolute/path/to/gitmatic.sh --config /absolute/path/to/gitmatic.toml --log-file /absolute/path/to/gitmatic.log
```

Use absolute paths in scheduler jobs.

## Silent update details

`silent_update` is the safest background mode. For each matching repository it:

1. runs `git fetch --prune --tags`
2. checks local branches that have an upstream
3. skips branches checked out in any worktree
4. skips branches that are ahead or diverged
5. fast-forwards safe branches without checking them out

More detail lives in [`docs/silent-update.md`](docs/silent-update.md).

## Tests

Run the lightweight local tests with:

```bash
./tests/run.sh
```

The tests verify:

- safe fast-forward updates happen when allowed
- checked-out worktree branches are skipped
- diverged branches are skipped
- repository discovery rules still behave correctly
- old INI configs are rejected

## License

GNU GPL v3.0 - see [LICENSE](LICENSE).

## Credits

- Original project and author: **AutoGit-o-Matic** by **Mateusz Okulanis** (`FPGArtktic@outlook.com`)
- This fork (`gitmatic`) keeps original attribution and license terms.
