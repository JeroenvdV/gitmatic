#!/usr/bin/env bash
# gitmatic: Automate Git operations across multiple repositories.
# Version: 0.2.0
#
# Copyright (C) 2025 Mateusz Okulanis
# Copyright (C) 2026 gitmatic contributors
# Originally released as AutoGit-o-Matic by Mateusz Okulanis.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

set -u

CONFIG_FILE="gitmatic.ini"
DRY_RUN=false
VERBOSE=false
LOG_FILE=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR=""
GIT_LAST_OUTPUT=""

print_usage() {
    cat <<'EOF'
Usage: gitmatic.sh [OPTIONS]

gitmatic runs git operations across many repositories:
  - [FETCH]        -> git fetch --prune --tags
  - [PULL]         -> git pull
  - [SILENT_UPDATE] -> safe local branch fast-forward without checkout

Options:
  --config FILE    Path to the configuration file (default: gitmatic.ini)
  --dry-run        Show what would run without changing repositories
  --verbose, -v    Display extra progress logs
  --log-file FILE  Append all logs to a single file
  --help           Display this help message and exit
EOF
}

get_timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

log_json_escape() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\"/\\\"}"
    text="${text//$'\n'/\\n}"
    text="${text//$'\r'/\\r}"
    text="${text//$'\t'/\\t}"
    printf '%s' "$text"
}

log_json() {
    local timestamp="$1"
    local type="$2"
    local path="$3"
    local status="$4"
    local message="$5"

    local escaped_path
    local escaped_status
    local escaped_message
    escaped_path="$(log_json_escape "$path")"
    escaped_status="$(log_json_escape "$status")"
    escaped_message="$(log_json_escape "$message")"

    if [ -n "$message" ]; then
        printf '{"timestamp":"%s","type":"%s","path":"%s","status":"%s","message":"%s"}\n' \
            "$timestamp" "$type" "$escaped_path" "$escaped_status" "$escaped_message"
    else
        printf '{"timestamp":"%s","type":"%s","path":"%s","status":"%s"}\n' \
            "$timestamp" "$type" "$escaped_path" "$escaped_status"
    fi
}

log_operation() {
    local type="$1"
    local path="$2"
    local status="$3"
    local message="${4:-}"
    local timestamp
    local line

    timestamp="$(get_timestamp)"
    line="$(log_json "$timestamp" "$type" "$path" "$status" "$message")"

    printf "%s\n" "$line"
    if [ -n "$LOG_FILE" ]; then
        printf "%s\n" "$line" >> "$LOG_FILE"
    fi
}

log_error() {
    local path="$1"
    local message="$2"
    log_operation "ERROR" "$path" "FAILED" "$message"
}

log_warning() {
    local path="$1"
    local message="$2"
    log_operation "WARN" "$path" "SKIPPED" "$message"
}

verbose_log() {
    local message="$1"
    if $VERBOSE; then
        log_operation "INFO" "" "VERBOSE" "$message"
    fi
}

ensure_log_file_directory() {
    if [ -n "$LOG_FILE" ]; then
        mkdir -p "$(dirname "$LOG_FILE")"
    fi
}

is_git_repository() {
    local path="$1"
    if [ ! -d "$path" ]; then
        return 1
    fi
    if [ ! -e "$path/.git" ]; then
        return 1
    fi
    git -C "$path" rev-parse --git-dir >/dev/null 2>&1
}

run_git_command() {
    local repo="$1"
    shift
    if GIT_LAST_OUTPUT="$(git -C "$repo" "$@" 2>&1)"; then
        return 0
    fi
    return 1
}

canonical_path() {
    local path="$1"
    if [ -d "$path" ]; then
        (cd "$path" && pwd)
    else
        printf "%s\n" "$path"
    fi
}

resolve_config_path() {
    local raw_path="$1"
    case "$raw_path" in
        /*) canonical_path "$raw_path" ;;
        *) canonical_path "$CONFIG_DIR/$raw_path" ;;
    esac
}

extract_section_paths() {
    local section="$1"
    awk -v requested_section="$section" '
        BEGIN { in_section = 0 }
        /^\[[^]]+\]/ {
            if ($0 == "[" requested_section "]") {
                in_section = 1
                next
            }
            if (in_section == 1) {
                exit
            }
        }
        in_section == 1 {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == "" || line ~ /^[#;]/) {
                next
            }
            if (line ~ /^path[[:space:]]*=/) {
                sub(/^path[[:space:]]*=[[:space:]]*/, "", line)
            }
            sub(/[[:space:]]*[#;].*$/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == "") {
                next
            }
            print line
        }
    ' "$CONFIG_FILE"
}

scan_for_repositories() {
    local base_path="$1"
    if [ ! -d "$base_path" ]; then
        return 0
    fi

    if is_git_repository "$base_path"; then
        canonical_path "$base_path"
        return 0
    fi

    # A git repository root always contains a ".git" entry:
    # - normal repo: directory
    # - linked worktree: file
    find "$base_path" \( -type d -name .git -o -type f -name .git \) 2>/dev/null | \
        while IFS= read -r git_entry; do
            local repo_root
            repo_root="${git_entry%/.git}"
            if is_git_repository "$repo_root"; then
                canonical_path "$repo_root"
            fi
        done | sort -u
}

run_simple_operation() {
    local operation="$1"
    local repo="$2"
    local status
    local command_desc

    if ! is_git_repository "$repo"; then
        log_error "$repo" "Not a Git repository"
        return 1
    fi

    case "$operation" in
        FETCH)
            command_desc="git fetch --prune --tags"
            if $DRY_RUN; then
                log_operation "FETCH" "$repo" "DRY-RUN" "Would run: $command_desc"
                return 0
            fi
            if run_git_command "$repo" fetch --prune --tags; then
                status="SUCCESS"
                log_operation "FETCH" "$repo" "$status" "$GIT_LAST_OUTPUT"
                return 0
            fi
            log_error "$repo" "Fetch failed: $GIT_LAST_OUTPUT"
            return 1
            ;;
        PULL)
            command_desc="git pull"
            if $DRY_RUN; then
                log_operation "PULL" "$repo" "DRY-RUN" "Would run: $command_desc"
                return 0
            fi
            if run_git_command "$repo" pull; then
                status="SUCCESS"
                log_operation "PULL" "$repo" "$status" "$GIT_LAST_OUTPUT"
                return 0
            fi
            log_error "$repo" "Pull failed: $GIT_LAST_OUTPUT"
            return 1
            ;;
        *)
            log_error "$repo" "Unsupported operation: $operation"
            return 1
            ;;
    esac
}

collect_checked_out_branches() {
    local repo="$1"
    git -C "$repo" worktree list --porcelain 2>/dev/null | \
        while IFS= read -r line; do
            case "$line" in
                branch\ refs/heads/*)
                    printf "%s\n" "${line#branch refs/heads/}"
                    ;;
            esac
        done | sort -u
}

branch_is_checked_out_anywhere() {
    local branch="$1"
    local checked_out="$2"
    local checked_branch
    while IFS= read -r checked_branch; do
        [ -z "$checked_branch" ] && continue
        if [ "$checked_branch" = "$branch" ]; then
            return 0
        fi
    done <<EOF
$checked_out
EOF
    return 1
}

update_tracking_branches_without_checkout() {
    local repo="$1"
    local checked_out_list=""
    local branch_line
    local branch
    local upstream
    local old_sha
    local new_sha
    local updated_count=0
    local skipped_count=0
    local warning_count=0

    if ! is_git_repository "$repo"; then
        log_error "$repo" "Not a Git repository"
        return 1
    fi

    # Always refresh remotes first so local fast-forward decisions use fresh data.
    if $DRY_RUN; then
        log_operation "SILENT_UPDATE" "$repo" "DRY-RUN" "Would run: git fetch --prune --tags"
    else
        if run_git_command "$repo" fetch --prune --tags; then
            log_operation "SILENT_UPDATE" "$repo" "FETCHED" "$GIT_LAST_OUTPUT"
        else
            log_error "$repo" "Cannot fetch before tracking update: $GIT_LAST_OUTPUT"
            return 1
        fi
    fi

    while IFS= read -r branch; do
        [ -z "$branch" ] && continue
        if [ -z "$checked_out_list" ]; then
            checked_out_list="$branch"
        else
            checked_out_list="${checked_out_list}
$branch"
        fi
    done <<EOF
$(collect_checked_out_branches "$repo")
EOF

    while IFS=$'\t' read -r branch upstream; do
        [ -z "${branch:-}" ] && continue
        [ -z "${upstream:-}" ] && continue

        [ -z "$branch" ] && continue
        [ -z "$upstream" ] && continue

        # Safety rule:
        # Never move a branch ref if that branch is currently checked out in any
        # worktree. This avoids surprising users who are actively working there.
        if branch_is_checked_out_anywhere "$branch" "$checked_out_list"; then
            log_warning "$repo:$branch" "Skipped because this branch is checked out in a worktree"
            skipped_count=$((skipped_count + 1))
            continue
        fi

        old_sha="$(git -C "$repo" rev-parse "$branch" 2>/dev/null || true)"
        new_sha="$(git -C "$repo" rev-parse "$upstream" 2>/dev/null || true)"
        if [ -z "$old_sha" ] || [ -z "$new_sha" ]; then
            log_warning "$repo:$branch" "Skipped because refs could not be resolved (branch/upstream missing)"
            warning_count=$((warning_count + 1))
            continue
        fi

        if [ "$old_sha" = "$new_sha" ]; then
            log_operation "SILENT_UPDATE" "$repo:$branch" "UP-TO-DATE" "Already at $upstream"
            continue
        fi

        # We only move refs by fast-forward, never by reset/rewrite.
        # `merge-base --is-ancestor A B` means A can be fast-forwarded to B.
        if ! git -C "$repo" merge-base --is-ancestor "$branch" "$upstream" >/dev/null 2>&1; then
            log_warning "$repo:$branch" "Skipped because fast-forward is not possible (branch diverged or ahead)"
            warning_count=$((warning_count + 1))
            continue
        fi

        # Highest-level safe ref update command:
        # `git branch -f branch upstream` moves the branch pointer without checkout.
        # We deliberately avoid checkout/merge to keep worktrees untouched.
        if $DRY_RUN; then
            log_operation "SILENT_UPDATE" "$repo:$branch" "DRY-RUN" "Would run: git branch -f $branch $upstream"
            updated_count=$((updated_count + 1))
            continue
        fi

        if run_git_command "$repo" branch -f "$branch" "$upstream"; then
            log_operation "SILENT_UPDATE" "$repo:$branch" "UPDATED" "Fast-forwarded to $upstream (${new_sha})"
            updated_count=$((updated_count + 1))
        else
            log_warning "$repo:$branch" "Skipped because branch update failed: $GIT_LAST_OUTPUT"
            warning_count=$((warning_count + 1))
        fi
    done <<EOF
$(git -C "$repo" for-each-ref --format='%(refname:short)%09%(upstream:short)' refs/heads)
EOF

    log_operation "SILENT_UPDATE" "$repo" "SUMMARY" \
        "updated=$updated_count skipped_checked_out=$skipped_count warnings=$warning_count"
}

process_repo_with_operation() {
    local operation="$1"
    local repo="$2"
    case "$operation" in
        FETCH|PULL)
            run_simple_operation "$operation" "$repo"
            ;;
        SILENT_UPDATE)
            update_tracking_branches_without_checkout "$repo"
            ;;
        *)
            log_error "$repo" "Unsupported operation: $operation"
            ;;
    esac
}

process_operation_path() {
    local section="$1"
    local operation="$2"
    local path="$3"
    local repos
    local repo

    verbose_log "[$section] scanning path: $path"
    repos="$(scan_for_repositories "$path")"
    if [ -z "$repos" ]; then
        log_warning "$path" "No repositories discovered under this path"
        return 0
    fi

    while IFS= read -r repo; do
        [ -z "$repo" ] && continue
        process_repo_with_operation "$operation" "$repo"
    done <<EOF
$repos
EOF
}

process_operation_section() {
    local section="$1"
    local operation="$2"
    local found_any_paths=0
    local raw_path
    local path

    while IFS= read -r raw_path; do
        [ -z "$raw_path" ] && continue
        found_any_paths=1
        path="$(resolve_config_path "$raw_path")"
        process_operation_path "$section" "$operation" "$path"
    done <<EOF
$(extract_section_paths "$section")
EOF

    if [ "$found_any_paths" -eq 0 ]; then
        verbose_log "No entries configured for section [$section]"
        return 1
    fi
    return 0
}

process_silent_update_section() {
    local found_any_paths=0
    local raw_path
    local path

    while IFS= read -r raw_path; do
        [ -z "$raw_path" ] && continue
        found_any_paths=1
        path="$(resolve_config_path "$raw_path")"
        process_operation_path "SILENT_UPDATE" "SILENT_UPDATE" "$path"
    done <<EOF
$(extract_section_paths "SILENT_UPDATE")
EOF

    if [ "$found_any_paths" -eq 0 ]; then
        verbose_log "No entries configured for section [SILENT_UPDATE]"
        return 1
    fi
    return 0
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --config)
                if [ "$#" -lt 2 ]; then
                    echo "Error: --config requires a value"
                    exit 1
                fi
                CONFIG_FILE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --log-file)
                if [ "$#" -lt 2 ]; then
                    echo "Error: --log-file requires a value"
                    exit 1
                fi
                LOG_FILE="$2"
                shift 2
                ;;
            --help)
                print_usage
                exit 0
                ;;
            *)
                echo "Error: Unknown option $1"
                print_usage
                exit 1
                ;;
        esac
    done
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ] && [ -f "$SCRIPT_DIR/$CONFIG_FILE" ]; then
        CONFIG_FILE="$SCRIPT_DIR/$CONFIG_FILE"
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Configuration file '$CONFIG_FILE' not found."
        exit 1
    fi

    CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
}

main() {
    parse_args "$@"
    load_config
    ensure_log_file_directory

    local any_configured=0

    process_operation_section "FETCH" "FETCH" && any_configured=1 || true
    process_operation_section "PULL" "PULL" && any_configured=1 || true
    process_silent_update_section && any_configured=1 || true

    if [ "$any_configured" -eq 0 ]; then
        log_operation "SILENT_UPDATE" "$CONFIG_DIR" "DEFAULT" \
            "No operation sections configured; defaulting to SILENT_UPDATE in config directory"
        process_operation_path "SILENT_UPDATE" "SILENT_UPDATE" "$CONFIG_DIR"
    fi
}

main "$@"