# gitmatic

<p align="center">
  <img src="logo.jpg" alt="gitmatic logo" width="500"/>
</p>

<p align="center">
  <strong>Keep many Git repositories up to date without manually visiting each one.</strong>
</p>

Gitmatic regularly updates your local git branches from the remote. It stays out of your way and saves you time when pulling.

## Action mode choices

- `SILENT_UPDATE` (default): safely fast-forward local tracking branches without checking them out
- `FETCH`: `git fetch --prune --tags`
- `PULL`: `git pull`

## Quick start for macOS

This is the shortest path if you just want to use the tool.

### 1) Clone the repo

### 2) Run the macOS install helper

```bash
./scripts/install-macos.sh
```

What this does on your system:

- copies `gitmatic.sh` to `~/.local/share/gitmatic/`
- makes the script executable
- copies `gitmatic.ini.example` to `~/.local/share/gitmatic/gitmatic.ini` if you do not already have a config file there

What it does **not** do:

- it does **not** enable scheduling by itself
- it does **not** edit your config for you
- it does **not** install a launchd job automatically

### 3) Edit the config file

Open this file in a text editor, for example:

```bash
code ~/.local/share/gitmatic/gitmatic.ini
```

If you do not care about the details, the main thing you need to do is add the folders or repos you want gitmatic to manage. 

The safest starting point for most people is `SILENT_UPDATE`:

```ini
[SILENT_UPDATE]
path = /Users/yourname/code
```

That tells gitmatic:

- look under `/Users/yourname/code`
- find Git repositories there
- fetch updates
- fast-forward local tracking branches when it is safe
- skip branches that are currently checked out in a worktree
- skip branches that cannot be fast-forwarded cleanly

### 4) Optional: Run it once manually

```bash
~/.local/share/gitmatic/gitmatic.sh --config ~/.local/share/gitmatic/gitmatic.ini --verbose
```

What this does:

- reads your config
- scans the paths you configured
- runs the configured Git operations
- prints the results to your terminal

At this point, you have a working setup already, but it will not run automatically.

### 5) Optional: turn on automatic scheduling with launchd

If you want it to run in the background on macOS, install the launchd agent:

```bash
./scripts/install-launchd.sh \
  --script "$HOME/.local/share/gitmatic/gitmatic.sh" \
  --config "$HOME/.local/share/gitmatic/gitmatic.ini"
```

What this does on your system:

- creates `~/Library/LaunchAgents/io.gitmatic.runner.plist`
- tells macOS launchd to run gitmatic for your user account
- runs it at login and then every 900 seconds (15 minutes) by default
- sends output to `~/Library/Logs/gitmatic.log` by default
- passes `--log-file ~/Library/Logs/gitmatic.log` to gitmatic

### Which operation should I use?

Most users should start with `SILENT_UPDATE`.

Use:

- `SILENT_UPDATE` if you want safer background updating
- `FETCH` if you only want remote refs updated and do not want local branches moved
- `PULL` only if you explicitly want working trees updated with normal `git pull`

### Example config

```ini
[SILENT_UPDATE]
path = /Users/yourname/code

[FETCH]
path = /Users/yourname/archive
```

Rules worth knowing:

- each section can contain repo paths or parent directories
- parent directories are scanned recursively for Git repos
- relative paths are resolved relative to the config file location
- if a branch is checked out in any worktree, `SILENT_UPDATE` skips it
- if a branch cannot be fast-forwarded safely, `SILENT_UPDATE` skips it
- if you leave out all operation sections, gitmatic defaults to `SILENT_UPDATE` and scans the config file directory


## `./gitmatic.sh`

This is the actual tool.

If you have launchd set up, this is the thing launchd runs for you.
You can still run it yourself manually, but you do not have to.

Manual example:

```bash
./gitmatic.sh --config ./gitmatic.ini --verbose
```

### Low-level usage

You do **not** need low-level usage if you are happy with:

1. `install-macos.sh`
2. editing the config
3. optionally `install-launchd.sh`

That is the normal user flow.

Low-level usage just means running the main script directly yourself:

```bash
./gitmatic.sh [OPTIONS]
```

Options:

- `--config FILE` - config file to use
- `--dry-run` - show what would happen without changing repos
- `--verbose` or `-v` - print extra progress output
- `--log-file FILE` - append logs to a file
- `--help` - show help

Useful examples:

```bash
./gitmatic.sh --config ./gitmatic.ini --dry-run --verbose
./gitmatic.sh --config ./gitmatic.ini --log-file ./gitmatic.log
```

If you already set up launchd scheduling, manual use is mostly for:

- testing a config change immediately
- running a dry run before changing behavior
- troubleshooting

### Logging

This part was too easy to miss before, so here is the direct answer.

gitmatic writes JSON log lines.

### If you run `gitmatic.sh` manually

- output always goes to your terminal as JSON lines
- no log file is created unless you pass `--log-file`

Example:

```bash
./gitmatic.sh --config ./gitmatic.ini --log-file ./gitmatic.log
```

If the log file's parent directory does not exist, gitmatic creates it.

### If you use the macOS launchd helper

Default log file:

```text
~/Library/Logs/gitmatic.log
```

That default comes from `scripts/install-launchd.sh`.

The launchd job sends both standard output and standard error there, and also passes that same path as gitmatic's `--log-file`.

So if you use the provided macOS scheduling script, yes: there **is** a default log file directory, and it is under `~/Library/Logs/`.

## Does this work on other operating systems?

### Yes, the main tool does

`gitmatic.sh` is a Bash script and the core tool is not macOS-specific.

Today, this repository includes:

- a portable core script for Unix-like systems with standard command-line tools
- macOS-specific helper scripts for launchd installation/removal

In practice:

- **macOS:** supported, with helper scripts included
- **Linux:** the main script should work; use manual setup or cron/system scheduler of your choice
- **Other Unix-like systems:** likely usable if you have Bash, Git, `awk`, `sed`, `find`, and `sort`
- **Windows:** not documented or packaged here

## Scheduling

If you want automation, choose one scheduler.

### macOS: use launchd

Recommended on macOS:

```bash
./scripts/install-launchd.sh \
  --script "$HOME/.local/share/gitmatic/gitmatic.sh" \
  --config "$HOME/.local/share/gitmatic/gitmatic.ini"
```

Remove it with:

```bash
./scripts/uninstall-launchd.sh
```

### Linux or generic Unix: use cron

Example: run every 15 minutes

```cron
*/15 * * * * /absolute/path/to/gitmatic.sh --config /absolute/path/to/gitmatic.ini --log-file /absolute/path/to/gitmatic.log
```

Use absolute paths in scheduler jobs.

## What `SILENT_UPDATE` actually does

This is the mode most people will want for background maintenance.

For each matching repository, it:

1. runs `git fetch --prune --tags`
2. checks local branches that have an upstream
3. skips branches that are checked out in any worktree
4. skips branches that are ahead or diverged
5. fast-forwards safe branches without checking them out

That means it is designed to avoid surprising changes to working trees.

More detail lives in [`docs/silent-update.md`](docs/silent-update.md).

## Tests

Run the lightweight local tests with:

```bash
./tests/run.sh
```

These tests create temporary local repositories and verify:

- safe fast-forward updates happen when allowed
- checked-out worktree branches are skipped
- diverged branches are skipped

## License

GNU GPL v3.0 - see [LICENSE](LICENSE).

## Credits

- Original project and author: **AutoGit-o-Matic** by **Mateusz Okulanis** (`FPGArtktic@outlook.com`)
- This fork (`gitmatic`) keeps original attribution and license terms.
