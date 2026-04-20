#!/usr/bin/env python3
"""
gitmatic: Automate Git operations across multiple repositories.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import platform
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any


VERSION = "0.3.0"
DEFAULT_CONFIG_FILE = "gitmatic.toml"
SCRIPT_DIR = Path(__file__).resolve().parent


class ConfigError(Exception):
    """Raised when the TOML configuration is invalid."""


@dataclass
class Event:
    timestamp: str
    type: str
    path: str
    status: str
    message: str = ""
    code: str | None = None


@dataclass
class NotificationPolicy:
    enabled: bool = False
    backend: str = "macos"
    title: str = "gitmatic"
    unexpected_statuses: set[str] = field(default_factory=lambda: {"FAILED"})
    unexpected_codes: set[str] = field(default_factory=set)

    def is_unexpected(self, event: Event) -> bool:
        if not self.enabled:
            return False
        if event.status in self.unexpected_statuses:
            return True
        return bool(event.code and event.code in self.unexpected_codes)


@dataclass
class SshAgentConfig:
    enabled: bool = False
    key_path: Path | None = None
    cache_ttl_seconds: int = 8 * 60 * 60
    state_dir: Path | None = None
    use_keychain: bool = True


@dataclass
class OperationConfig:
    include_paths: list[Path] = field(default_factory=list)
    exclude_patterns: list[str] = field(default_factory=list)
    max_depth: int | None = None


@dataclass
class GitmaticConfig:
    config_path: Path
    config_dir: Path
    fetch: OperationConfig
    pull: OperationConfig
    silent_update: OperationConfig
    notifications: NotificationPolicy
    ssh_agent: SshAgentConfig


class Logger:
    def __init__(self, log_file: Path | None, verbose: bool, notification_policy: NotificationPolicy | None = None) -> None:
        self.log_file = log_file
        self.verbose_enabled = verbose
        self.notification_policy = notification_policy or NotificationPolicy()
        self.unexpected_events: list[Event] = []
        if self.log_file:
            self.log_file.parent.mkdir(parents=True, exist_ok=True)

    @staticmethod
    def _timestamp() -> str:
        return datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    def log(
        self,
        log_type: str,
        path: str,
        status: str,
        message: str = "",
        *,
        code: str | None = None,
        collect_unexpected: bool = True,
    ) -> Event:
        event = Event(
            timestamp=self._timestamp(),
            type=log_type,
            path=path,
            status=status,
            message=message,
            code=code,
        )
        payload: dict[str, Any] = {
            "timestamp": event.timestamp,
            "type": event.type,
            "path": event.path,
            "status": event.status,
        }
        if event.message:
            payload["message"] = event.message
        if event.code:
            payload["code"] = event.code

        line = json.dumps(payload, separators=(",", ":"))
        print(line, flush=True)
        if self.log_file:
            with self.log_file.open("a", encoding="utf-8") as handle:
                handle.write(f"{line}\n")

        if collect_unexpected and self.notification_policy.is_unexpected(event):
            self.unexpected_events.append(event)
        return event

    def error(self, path: str, message: str, *, code: str) -> None:
        self.log("ERROR", path, "FAILED", message, code=code)

    def warning(self, path: str, message: str, *, code: str) -> None:
        self.log("WARN", path, "SKIPPED", message, code=code)

    def verbose(self, message: str) -> None:
        if self.verbose_enabled:
            self.log("INFO", "", "VERBOSE", message, code="verbose", collect_unexpected=False)


class MacOSNotifier:
    def __init__(self, logger: Logger, policy: NotificationPolicy) -> None:
        self.logger = logger
        self.policy = policy

    def flush(self, events: list[Event]) -> None:
        if not self.policy.enabled or not events:
            return

        if self.policy.backend != "macos":
            self.logger.warning(
                "",
                f"Notification backend '{self.policy.backend}' is not supported",
                code="notification_backend_unsupported",
            )
            return

        if platform.system() != "Darwin":
            self.logger.verbose("Notification backend is enabled, but native notifications are only sent on macOS")
            return

        issue_count = len(events)
        path_count = len({event.path for event in events if event.path})
        summary_parts: list[str] = []
        for event in events[:3]:
            label = event.code or event.status.lower()
            location = shorten_path(event.path) if event.path else "global"
            summary_parts.append(f"{label}: {location}")

        body = "; ".join(summary_parts)
        if issue_count > 3:
            body = f"{body}; +{issue_count - 3} more"

        subtitle = f"{issue_count} unexpected issue(s)"
        if path_count:
            subtitle = f"{subtitle} across {path_count} path(s)"

        script = (
            f'display notification "{applescript_escape(body)}" '
            f'with title "{applescript_escape(self.policy.title)}" '
            f'subtitle "{applescript_escape(subtitle)}"'
        )
        result = subprocess.run(
            ["osascript", "-e", script],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            self.logger.warning(
                "",
                f"Unable to send macOS notification: {result.stderr.strip() or result.stdout.strip()}",
                code="notification_failed",
            )


class SshAgentManager:
    def __init__(self, config: SshAgentConfig, logger: Logger) -> None:
        self.config = config
        self.logger = logger
        self.env = os.environ.copy()
        self.state_file = (self.config.state_dir or default_state_dir()) / "ssh-agent-state.json"

    def prepare(self) -> dict[str, str]:
        if not self.config.enabled:
            return self.env

        if not self.config.key_path:
            if self._current_env_reachable():
                self.logger.verbose("Reusing the current SSH agent from the environment")
                self._persist_env(self._extract_agent_env(self.env))
                return self.env
            self.logger.warning(
                "",
                "ssh_agent is enabled but no key_path was configured; using the default environment without a dedicated agent",
                code="ssh_agent_no_key_path",
            )
            return self.env

        stored_env = self._load_stored_env()
        if stored_env and self._agent_reachable(stored_env):
            self.logger.verbose("Reusing the dedicated SSH agent from the previous run")
            self.env.update(stored_env)
        elif self._current_env_reachable():
            self.logger.verbose("Reusing the current SSH agent from the environment")
            self._persist_env(self._extract_agent_env(self.env))
        else:
            self.logger.verbose("Starting a dedicated SSH agent for gitmatic")
            new_env = self._start_agent()
            self.env.update(new_env)
            self._persist_env(new_env)

        if not self._desired_key_loaded():
            self._add_key()

        return self.env

    def _load_stored_env(self) -> dict[str, str] | None:
        if not self.state_file.is_file():
            return None
        try:
            data = json.loads(self.state_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            self.logger.warning(
                str(self.state_file),
                f"Unable to read cached ssh-agent state: {exc}",
                code="ssh_agent_state_read_failed",
            )
            return None
        if not isinstance(data, dict):
            return None
        sock = data.get("SSH_AUTH_SOCK")
        pid = data.get("SSH_AGENT_PID")
        if not isinstance(sock, str) or not isinstance(pid, str):
            return None
        return {"SSH_AUTH_SOCK": sock, "SSH_AGENT_PID": pid}

    def _persist_env(self, agent_env: dict[str, str]) -> None:
        try:
            self.state_file.parent.mkdir(parents=True, exist_ok=True)
            payload = {
                "SSH_AUTH_SOCK": agent_env.get("SSH_AUTH_SOCK", ""),
                "SSH_AGENT_PID": agent_env.get("SSH_AGENT_PID", ""),
                "key_path": str(self.config.key_path) if self.config.key_path else "",
            }
            self.state_file.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        except OSError as exc:
            self.logger.warning(
                str(self.state_file),
                f"Unable to persist ssh-agent state: {exc}",
                code="ssh_agent_state_write_failed",
            )

    @staticmethod
    def _extract_agent_env(env: dict[str, str]) -> dict[str, str]:
        result: dict[str, str] = {}
        for key in ("SSH_AUTH_SOCK", "SSH_AGENT_PID"):
            value = env.get(key)
            if value:
                result[key] = value
        return result

    def _current_env_reachable(self) -> bool:
        agent_env = self._extract_agent_env(self.env)
        return self._agent_reachable(agent_env)

    def _agent_reachable(self, agent_env: dict[str, str]) -> bool:
        if "SSH_AUTH_SOCK" not in agent_env or "SSH_AGENT_PID" not in agent_env:
            return False
        result = subprocess.run(
            ["ssh-add", "-l"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={**self.env, **agent_env},
            check=False,
        )
        return result.returncode in (0, 1)

    def _start_agent(self) -> dict[str, str]:
        result = subprocess.run(
            ["ssh-agent", "-s"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            self.logger.error("", f"Unable to start ssh-agent: {result.stderr.strip()}", code="ssh_agent_start_failed")
            return {}

        agent_env: dict[str, str] = {}
        for line in result.stdout.splitlines():
            if line.startswith("SSH_AUTH_SOCK="):
                agent_env["SSH_AUTH_SOCK"] = line.split(";", 1)[0].split("=", 1)[1]
            elif line.startswith("SSH_AGENT_PID="):
                agent_env["SSH_AGENT_PID"] = line.split(";", 1)[0].split("=", 1)[1]

        if "SSH_AUTH_SOCK" not in agent_env or "SSH_AGENT_PID" not in agent_env:
            self.logger.error("", "ssh-agent started but did not return a usable environment", code="ssh_agent_parse_failed")
            return {}
        return agent_env

    def _desired_key_loaded(self) -> bool:
        if not self.config.key_path:
            return True
        if not self._agent_reachable(self._extract_agent_env(self.env)):
            return False

        fingerprint = public_key_fingerprint(self.config.key_path)
        if not fingerprint:
            return False
        result = subprocess.run(
            ["ssh-add", "-l"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self.env,
            check=False,
        )
        if result.returncode == 2:
            return False
        return fingerprint in result.stdout

    def _add_key(self) -> None:
        if not self.config.key_path:
            return

        command = ["ssh-add"]
        if self.config.cache_ttl_seconds > 0:
            command.extend(["-t", str(self.config.cache_ttl_seconds)])
        if platform.system() == "Darwin" and self.config.use_keychain:
            command.append("--apple-use-keychain")
        command.append(str(self.config.key_path))

        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self.env,
            check=False,
        )
        if result.returncode != 0:
            self.logger.error(
                str(self.config.key_path),
                f"Unable to add SSH key to the agent cache: {result.stderr.strip() or result.stdout.strip()}",
                code="ssh_key_add_failed",
            )
            return

        self.logger.verbose(
            f"Loaded {self.config.key_path} into the SSH agent cache for {self.config.cache_ttl_seconds} seconds"
        )
        self._persist_env(self._extract_agent_env(self.env))


class Gitmatic:
    def __init__(self, args: argparse.Namespace, config: GitmaticConfig) -> None:
        log_file = Path(os.path.abspath(os.path.expanduser(args.log_file))).resolve() if args.log_file else None
        self.logger = Logger(log_file, args.verbose, config.notifications)
        self.args = args
        self.config = config
        self.notifier = MacOSNotifier(self.logger, config.notifications)
        self.env = SshAgentManager(config.ssh_agent, self.logger).prepare()

    def run(self) -> int:
        any_configured = False

        if self.process_operation_section("FETCH", self.config.fetch, self.run_fetch):
            any_configured = True
        if self.process_operation_section("PULL", self.config.pull, self.run_pull):
            any_configured = True
        if self.process_operation_section("SILENT_UPDATE", self.config.silent_update, self.run_silent_update):
            any_configured = True

        if not any_configured:
            self.logger.log(
                "SILENT_UPDATE",
                str(self.config.config_dir),
                "DEFAULT",
                "No operation sections configured; defaulting to SILENT_UPDATE in config directory",
                code="default_operation",
                collect_unexpected=False,
            )
            self.process_operation_path(
                "SILENT_UPDATE",
                str(self.config.config_dir),
                [],
                None,
                self.run_silent_update,
                set(),
            )

        self.notifier.flush(self.logger.unexpected_events)
        return 0

    def process_operation_section(
        self,
        section_name: str,
        operation: OperationConfig,
        handler: callable[[str], None],
    ) -> bool:
        if not operation.include_paths:
            self.logger.verbose(f"No entries configured for section [{section_name}]")
            return False

        seen_repos: set[str] = set()
        for include_path in operation.include_paths:
            self.process_operation_path(
                section_name,
                str(include_path),
                operation.exclude_patterns,
                operation.max_depth,
                handler,
                seen_repos,
            )
        return True

    def process_operation_path(
        self,
        section_name: str,
        raw_path: str,
        exclude_patterns: list[str],
        max_depth: int | None,
        handler: callable[[str], None],
        seen_repos: set[str],
    ) -> None:
        self.logger.verbose(f"[{section_name}] scanning path: {raw_path}")
        found_repos = False
        for repo in self.scan_for_repositories(Path(raw_path), exclude_patterns, max_depth):
            found_repos = True
            if repo in seen_repos:
                continue
            seen_repos.add(repo)
            handler(repo)

        if not found_repos:
            self.logger.warning(raw_path, "No repositories discovered under this path", code="no_repositories_found")

    def scan_for_repositories(
        self,
        base_path: Path,
        exclude_patterns: list[str],
        max_depth: int | None,
    ) -> list[str]:
        if not base_path.is_dir():
            return []
        normalized = strip_trailing_slashes(str(base_path))
        return list(self._scan_directory(Path(normalized), normalized, 0, exclude_patterns, max_depth))

    def _scan_directory(
        self,
        current_path: Path,
        include_root: str,
        current_depth: int,
        exclude_patterns: list[str],
        max_depth: int | None,
    ) -> list[str]:
        normalized_path = strip_trailing_slashes(str(current_path))
        if normalized_path != include_root and path_is_excluded(normalized_path, exclude_patterns):
            return []

        if current_path.joinpath(".git").exists() and self.is_git_repository(normalized_path):
            return [normalized_path]

        if max_depth is not None and current_depth >= max_depth:
            return []

        repos: list[str] = []
        try:
            children = sorted(
                (
                    entry
                    for entry in os.scandir(current_path)
                    if entry.is_dir(follow_symlinks=False) and entry.name != ".git"
                ),
                key=lambda entry: entry.path,
            )
        except OSError as exc:
            self.logger.warning(normalized_path, f"Unable to scan directory: {exc}", code="scan_failed")
            return []

        for child in children:
            repos.extend(
                self._scan_directory(
                    Path(child.path),
                    include_root,
                    current_depth + 1,
                    exclude_patterns,
                    max_depth,
                )
            )
        return repos

    def is_git_repository(self, repo: str) -> bool:
        result = self.run_command(["git", "-C", repo, "rev-parse", "--git-dir"], check=False)
        return result.returncode == 0

    def run_command(self, command: list[str], *, check: bool) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=self.env,
            check=check,
        )

    def run_fetch(self, repo: str) -> None:
        if not self.is_git_repository(repo):
            self.logger.error(repo, "Not a Git repository", code="not_a_git_repository")
            return
        command_desc = "git fetch --prune --tags"
        if self.args.dry_run:
            self.logger.log("FETCH", repo, "DRY-RUN", f"Would run: {command_desc}", code="fetch_dry_run", collect_unexpected=False)
            return
        result = self.run_command(["git", "-C", repo, "fetch", "--prune", "--tags"], check=False)
        if result.returncode == 0:
            self.logger.log("FETCH", repo, "SUCCESS", result.stdout.strip(), code="fetch_success", collect_unexpected=False)
            return
        self.logger.error(repo, f"Fetch failed: {result.stdout.strip()}", code="fetch_failed")

    def run_pull(self, repo: str) -> None:
        if not self.is_git_repository(repo):
            self.logger.error(repo, "Not a Git repository", code="not_a_git_repository")
            return
        command_desc = "git pull"
        if self.args.dry_run:
            self.logger.log("PULL", repo, "DRY-RUN", f"Would run: {command_desc}", code="pull_dry_run", collect_unexpected=False)
            return
        result = self.run_command(["git", "-C", repo, "pull"], check=False)
        if result.returncode == 0:
            self.logger.log("PULL", repo, "SUCCESS", result.stdout.strip(), code="pull_success", collect_unexpected=False)
            return
        self.logger.error(repo, f"Pull failed: {result.stdout.strip()}", code="pull_failed")

    def run_silent_update(self, repo: str) -> None:
        if not self.is_git_repository(repo):
            self.logger.error(repo, "Not a Git repository", code="not_a_git_repository")
            return

        updated_count = 0
        skipped_checked_out = 0
        warning_count = 0

        if self.args.dry_run:
            self.logger.log(
                "SILENT_UPDATE",
                repo,
                "DRY-RUN",
                "Would run: git fetch --prune --tags",
                code="silent_update_prefetch_dry_run",
                collect_unexpected=False,
            )
        else:
            result = self.run_command(["git", "-C", repo, "fetch", "--prune", "--tags"], check=False)
            if result.returncode != 0:
                self.logger.error(
                    repo,
                    f"Cannot fetch before tracking update: {result.stdout.strip()}",
                    code="prefetch_failed",
                )
                return
            self.logger.log("SILENT_UPDATE", repo, "FETCHED", result.stdout.strip(), code="prefetch_success", collect_unexpected=False)

        checked_out_branches = self.collect_checked_out_branches(repo)
        branch_map = self.list_tracking_branches(repo)

        for branch, upstream in branch_map:
            branch_path = f"{repo}:{branch}"
            if branch in checked_out_branches:
                self.logger.warning(
                    branch_path,
                    "Skipped because this branch is checked out in a worktree",
                    code="checked_out_branch_skipped",
                )
                skipped_checked_out += 1
                continue

            old_sha = self.git_output(repo, ["rev-parse", branch])
            new_sha = self.git_output(repo, ["rev-parse", upstream])
            if not old_sha or not new_sha:
                self.logger.warning(
                    branch_path,
                    "Skipped because refs could not be resolved (branch/upstream missing)",
                    code="ref_resolution_failed",
                )
                warning_count += 1
                continue

            if old_sha == new_sha:
                self.logger.log(
                    "SILENT_UPDATE",
                    branch_path,
                    "UP-TO-DATE",
                    f"Already at {upstream}",
                    code="silent_update_up_to_date",
                    collect_unexpected=False,
                )
                continue

            merge_base = self.run_command(["git", "-C", repo, "merge-base", "--is-ancestor", branch, upstream], check=False)
            if merge_base.returncode != 0:
                self.logger.warning(
                    branch_path,
                    "Skipped because fast-forward is not possible (branch diverged or ahead)",
                    code="fast_forward_blocked",
                )
                warning_count += 1
                continue

            if self.args.dry_run:
                self.logger.log(
                    "SILENT_UPDATE",
                    branch_path,
                    "DRY-RUN",
                    f"Would run: git branch -f {branch} {upstream}",
                    code="silent_update_branch_dry_run",
                    collect_unexpected=False,
                )
                updated_count += 1
                continue

            update_result = self.run_command(["git", "-C", repo, "branch", "-f", branch, upstream], check=False)
            if update_result.returncode == 0:
                self.logger.log(
                    "SILENT_UPDATE",
                    branch_path,
                    "UPDATED",
                    f"Fast-forwarded to {upstream} ({new_sha})",
                    code="silent_update_branch_updated",
                    collect_unexpected=False,
                )
                updated_count += 1
            else:
                self.logger.warning(
                    branch_path,
                    f"Skipped because branch update failed: {update_result.stdout.strip()}",
                    code="branch_update_failed",
                )
                warning_count += 1

        self.logger.log(
            "SILENT_UPDATE",
            repo,
            "SUMMARY",
            f"updated={updated_count} skipped_checked_out={skipped_checked_out} warnings={warning_count}",
            code="silent_update_summary",
            collect_unexpected=False,
        )

    def collect_checked_out_branches(self, repo: str) -> set[str]:
        result = self.run_command(["git", "-C", repo, "worktree", "list", "--porcelain"], check=False)
        if result.returncode != 0:
            return set()

        branches: set[str] = set()
        for line in result.stdout.splitlines():
            if line.startswith("branch refs/heads/"):
                branches.add(line.removeprefix("branch refs/heads/"))
        return branches

    def list_tracking_branches(self, repo: str) -> list[tuple[str, str]]:
        result = self.run_command(
            [
                "git",
                "-C",
                repo,
                "for-each-ref",
                "--format=%(refname:short)%09%(upstream:short)",
                "refs/heads",
            ],
            check=False,
        )
        if result.returncode != 0:
            return []

        branches: list[tuple[str, str]] = []
        for line in result.stdout.splitlines():
            if not line.strip():
                continue
            branch, _, upstream = line.partition("\t")
            if branch and upstream:
                branches.append((branch, upstream))
        return branches

    def git_output(self, repo: str, args: list[str]) -> str:
        result = self.run_command(["git", "-C", repo, *args], check=False)
        if result.returncode != 0:
            return ""
        return result.stdout.strip()


def shorten_path(path: str, *, max_length: int = 70) -> str:
    if len(path) <= max_length:
        return path
    return f"...{path[-(max_length - 3):]}"


def applescript_escape(text: str) -> str:
    text = text.replace("\\", "\\\\")
    text = text.replace('"', '\\"')
    return text.replace("\n", " ").replace("\r", " ")


def strip_trailing_slashes(path: str) -> str:
    if path == "/":
        return path
    return path.rstrip("/") or "/"


def has_glob_characters(text: str) -> bool:
    return any(char in text for char in ("*", "?", "["))


def path_matches_pattern(path: str, pattern: str) -> bool:
    if fnmatch.fnmatch(path, pattern):
        return True
    if has_glob_characters(pattern) and fnmatch.fnmatch(f"{path}/", pattern):
        return True
    return False


def path_is_excluded(path: str, exclude_patterns: list[str]) -> bool:
    return any(path_matches_pattern(path, pattern) for pattern in exclude_patterns)


def default_state_dir() -> Path:
    home = Path.home()
    if platform.system() == "Darwin":
        return home / "Library" / "Application Support" / "gitmatic"
    return home / ".local" / "state" / "gitmatic"


def public_key_fingerprint(key_path: Path) -> str:
    public_key = Path(f"{key_path}.pub")
    if not public_key.is_file():
        return ""
    result = subprocess.run(
        ["ssh-keygen", "-lf", str(public_key)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return ""
    return result.stdout.strip().split()[1]


def resolve_path(raw_path: str, config_dir: Path) -> Path:
    candidate = Path(os.path.expanduser(raw_path))
    if not candidate.is_absolute():
        candidate = config_dir / candidate
    return Path(os.path.abspath(candidate))


def resolve_exclude_pattern(raw_path: str, config_dir: Path) -> str:
    if has_glob_characters(raw_path):
        if raw_path.startswith("/"):
            return raw_path
        return f"*/{raw_path}"
    return strip_trailing_slashes(str(resolve_path(raw_path, config_dir)))


def normalize_string_list(value: Any, label: str) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, list) and all(isinstance(item, str) for item in value):
        return value
    raise ConfigError(f"{label} must be a string or an array of strings")


def normalize_bool(value: Any, label: str, default: bool) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    raise ConfigError(f"{label} must be a boolean")


def normalize_int(value: Any, label: str, default: int | None = None) -> int | None:
    if value is None:
        return default
    if isinstance(value, int) and value >= 0:
        return value
    raise ConfigError(f"{label} must be a non-negative integer")


def collect_tables(data: dict[str, Any], aliases: tuple[str, ...], label: str) -> list[dict[str, Any]]:
    tables: list[dict[str, Any]] = []
    for alias in aliases:
        if alias not in data:
            continue
        table = data[alias]
        if not isinstance(table, dict):
            raise ConfigError(f"[{label}] must be a TOML table")
        tables.append(table)
    return tables


def parse_operation_config(data: dict[str, Any], config_dir: Path, aliases: tuple[str, ...], label: str) -> OperationConfig:
    tables = collect_tables(data, aliases, label)
    include_paths: list[Path] = []
    exclude_patterns: list[str] = []
    max_depth: int | None = None

    for table in tables:
        include_values = normalize_string_list(table.get("include_path"), f"[{label}] include_path")
        include_values.extend(normalize_string_list(table.get("path"), f"[{label}] path"))
        for raw_path in include_values:
            if has_glob_characters(raw_path):
                raise ConfigError(f"[{label}] include_path does not support wildcards: {raw_path}")
            include_paths.append(resolve_path(raw_path, config_dir))

        exclude_values = normalize_string_list(table.get("exclude_path"), f"[{label}] exclude_path")
        exclude_patterns.extend(resolve_exclude_pattern(value, config_dir) for value in exclude_values)

        table_max_depth = normalize_int(table.get("max_depth"), f"[{label}] max_depth")
        if table_max_depth is not None:
            max_depth = table_max_depth

    return OperationConfig(include_paths=include_paths, exclude_patterns=exclude_patterns, max_depth=max_depth)


def parse_notification_policy(data: dict[str, Any]) -> NotificationPolicy:
    tables = collect_tables(data, ("notifications", "NOTIFICATIONS"), "notifications")
    if not tables:
        return NotificationPolicy()

    combined: dict[str, Any] = {}
    for table in tables:
        combined.update(table)

    enabled = normalize_bool(combined.get("enabled"), "[notifications] enabled", False)
    backend = combined.get("backend", "macos")
    if not isinstance(backend, str):
        raise ConfigError("[notifications] backend must be a string")

    title = combined.get("title", "gitmatic")
    if not isinstance(title, str):
        raise ConfigError("[notifications] title must be a string")

    if "unexpected_statuses" in combined:
        statuses = set(normalize_string_list(combined.get("unexpected_statuses"), "[notifications] unexpected_statuses"))
    else:
        statuses = {"FAILED"}

    if "unexpected_codes" in combined:
        codes = set(normalize_string_list(combined.get("unexpected_codes"), "[notifications] unexpected_codes"))
    else:
        codes = set()

    return NotificationPolicy(
        enabled=enabled,
        backend=backend,
        title=title,
        unexpected_statuses=statuses,
        unexpected_codes=codes,
    )


def parse_ssh_agent_config(data: dict[str, Any], config_dir: Path) -> SshAgentConfig:
    tables = collect_tables(data, ("ssh_agent", "SSH_AGENT"), "ssh_agent")
    if not tables:
        return SshAgentConfig()

    combined: dict[str, Any] = {}
    for table in tables:
        combined.update(table)

    enabled = normalize_bool(combined.get("enabled"), "[ssh_agent] enabled", False)
    raw_key_path = combined.get("key_path")
    if raw_key_path is not None and not isinstance(raw_key_path, str):
        raise ConfigError("[ssh_agent] key_path must be a string")
    key_path = resolve_path(raw_key_path, config_dir) if raw_key_path else None

    ttl = normalize_int(combined.get("cache_ttl_seconds"), "[ssh_agent] cache_ttl_seconds", 8 * 60 * 60)

    raw_state_dir = combined.get("state_dir")
    if raw_state_dir is not None and not isinstance(raw_state_dir, str):
        raise ConfigError("[ssh_agent] state_dir must be a string")
    state_dir = resolve_path(raw_state_dir, config_dir) if raw_state_dir else default_state_dir()

    use_keychain = normalize_bool(combined.get("use_keychain"), "[ssh_agent] use_keychain", True)

    return SshAgentConfig(
        enabled=enabled,
        key_path=key_path,
        cache_ttl_seconds=ttl or 0,
        state_dir=state_dir,
        use_keychain=use_keychain,
    )


def load_config(config_path: Path) -> GitmaticConfig:
    if config_path.suffix.lower() == ".ini":
        raise ConfigError("INI configuration is no longer supported. Convert the file to TOML and use a .toml path.")
    if not config_path.is_file():
        raise ConfigError(f"Configuration file '{config_path}' not found.")

    with config_path.open("rb") as handle:
        try:
            data = tomllib.load(handle)
        except tomllib.TOMLDecodeError as exc:
            raise ConfigError(f"Unable to parse TOML config: {exc}") from exc

    if not isinstance(data, dict):
        raise ConfigError("Top-level TOML document must be a table")

    config_dir = config_path.parent
    return GitmaticConfig(
        config_path=config_path,
        config_dir=config_dir,
        fetch=parse_operation_config(data, config_dir, ("fetch", "FETCH"), "fetch"),
        pull=parse_operation_config(data, config_dir, ("pull", "PULL"), "pull"),
        silent_update=parse_operation_config(data, config_dir, ("silent_update", "SILENT_UPDATE"), "silent_update"),
        notifications=parse_notification_policy(data),
        ssh_agent=parse_ssh_agent_config(data, config_dir),
    )


def resolve_config_path(raw_path: str) -> Path:
    candidate = Path(os.path.expanduser(raw_path))
    if not candidate.is_absolute():
        candidate = Path.cwd() / candidate
    candidate = Path(os.path.abspath(candidate))

    if candidate == Path.cwd() / DEFAULT_CONFIG_FILE and not candidate.exists():
        bundled = SCRIPT_DIR / DEFAULT_CONFIG_FILE
        if bundled.is_file():
            return bundled
    return candidate


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="gitmatic.py",
        description="Run Git operations across many repositories.",
    )
    parser.add_argument("--config", default=DEFAULT_CONFIG_FILE, help=f"Path to the TOML configuration file (default: {DEFAULT_CONFIG_FILE})")
    parser.add_argument("--dry-run", action="store_true", help="Show what would run without changing repositories")
    parser.add_argument("--verbose", "-v", action="store_true", help="Display extra progress logs")
    parser.add_argument("--log-file", help="Append all logs to a single file")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    config_path = resolve_config_path(args.config)

    try:
        config = load_config(config_path)
    except ConfigError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    runner = Gitmatic(args, config)
    return runner.run()


if __name__ == "__main__":
    sys.exit(main())
