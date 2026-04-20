#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AUTOGIT_SCRIPT="$ROOT_DIR/gitmatic.sh"
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

git_quiet() {
    git -c init.defaultBranch=main "$@" >/dev/null 2>&1
}

assert_contains() {
    local file="$1"
    local expected="$2"
    if ! grep -Fq "$expected" "$file"; then
        echo "ASSERTION FAILED: expected '$expected' in $file"
        exit 1
    fi
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    if [ "$expected" != "$actual" ]; then
        echo "ASSERTION FAILED: $message"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        exit 1
    fi
}

assert_json_log_contains() {
    local file="$1"
    local type="$2"
    local path="$3"
    local status="$4"
    local message="${5:-}"
    local expected

    expected="\"type\":\"$type\",\"path\":\"$path\",\"status\":\"$status\""
    if [ -n "$message" ]; then
        expected="$expected,\"message\":\"$message\""
    fi
    assert_contains "$file" "$expected"
}

new_repo_fixture() {
    local name="$1"
    local fixture_dir="$TMPDIR_ROOT/$name"
    local remote_repo="$fixture_dir/remote.git"
    local local_repo="$fixture_dir/local"
    local seed_repo="$fixture_dir/seed"

    mkdir -p "$fixture_dir"
    git_quiet init --bare "$remote_repo"
    git_quiet init "$seed_repo"
    git -C "$seed_repo" config user.name "AutoGit Test"
    git -C "$seed_repo" config user.email "autogit-test@example.com"
    printf "seed\n" > "$seed_repo/file.txt"
    git_quiet -C "$seed_repo" add file.txt
    git_quiet -C "$seed_repo" commit -m "seed commit"
    git_quiet -C "$seed_repo" branch -M main
    git_quiet -C "$seed_repo" remote add origin "$remote_repo"
    git_quiet -C "$seed_repo" push -u origin main
    git_quiet --git-dir "$remote_repo" symbolic-ref HEAD refs/heads/main
    git_quiet clone "$remote_repo" "$local_repo"
    git -C "$local_repo" config user.name "AutoGit Test"
    git -C "$local_repo" config user.email "autogit-test@example.com"
    git_quiet -C "$local_repo" checkout -b feature
    git_quiet -C "$local_repo" push -u origin feature
    git_quiet -C "$local_repo" checkout main
    git_quiet -C "$local_repo" fetch --prune --tags
}

advance_remote_branch() {
    local fixture_name="$1"
    local branch="$2"
    local content="$3"
    local fixture_dir="$TMPDIR_ROOT/$fixture_name"
    local remote_repo="$fixture_dir/remote.git"
    local updater_repo="$fixture_dir/updater-$branch"

    git_quiet clone "$remote_repo" "$updater_repo"
    git -C "$updater_repo" config user.name "AutoGit Test"
    git -C "$updater_repo" config user.email "autogit-test@example.com"
    git_quiet -C "$updater_repo" checkout "$branch"
    printf "%s\n" "$content" >> "$updater_repo/file.txt"
    git_quiet -C "$updater_repo" add file.txt
    git_quiet -C "$updater_repo" commit -m "advance $branch"
    git_quiet -C "$updater_repo" push origin "$branch"
    rm -rf "$updater_repo"
}

run_autogit_for_repo() {
    local repo_root="$1"
    local log_file="$2"
    local config_file="$3"

    cat > "$config_file" <<EOF
[SILENT_UPDATE]
path = $repo_root
EOF

    "$AUTOGIT_SCRIPT" --config "$config_file" --log-file "$log_file" >/dev/null
}

test_fast_forward_updates_non_checked_out_branch() {
    local fixture_name="ff-success"
    new_repo_fixture "$fixture_name"
    local local_repo="$TMPDIR_ROOT/$fixture_name/local"
    local before_sha
    local after_sha
    local log_file="$TMPDIR_ROOT/$fixture_name/run.log"
    local config_file="$TMPDIR_ROOT/$fixture_name/config.ini"

    before_sha="$(git -C "$local_repo" rev-parse feature)"
    advance_remote_branch "$fixture_name" feature "remote feature update"

    run_autogit_for_repo "$local_repo" "$log_file" "$config_file"
    after_sha="$(git -C "$local_repo" rev-parse feature)"

    if [ "$before_sha" = "$after_sha" ]; then
        echo "ASSERTION FAILED: feature branch did not move after fast-forward update"
        exit 1
    fi
    assert_json_log_contains "$log_file" "SILENT_UPDATE" "$local_repo:feature" "UPDATED"
}

test_checked_out_worktree_branch_is_skipped() {
    local fixture_name="worktree-skip"
    new_repo_fixture "$fixture_name"
    local local_repo="$TMPDIR_ROOT/$fixture_name/local"
    local wt_repo="$TMPDIR_ROOT/$fixture_name/worktree-feature"
    local before_sha
    local after_sha
    local log_file="$TMPDIR_ROOT/$fixture_name/run.log"
    local config_file="$TMPDIR_ROOT/$fixture_name/config.ini"

    git_quiet -C "$local_repo" worktree add "$wt_repo" feature
    before_sha="$(git -C "$local_repo" rev-parse feature)"
    advance_remote_branch "$fixture_name" feature "feature update while checked out elsewhere"

    run_autogit_for_repo "$local_repo" "$log_file" "$config_file"
    after_sha="$(git -C "$local_repo" rev-parse feature)"

    assert_equals "$before_sha" "$after_sha" "feature should remain unchanged when checked out in a worktree"
    assert_json_log_contains "$log_file" "WARN" "$local_repo:feature" "SKIPPED" "Skipped because this branch is checked out in a worktree"
}

test_diverged_branch_is_skipped() {
    local fixture_name="diverged-skip"
    new_repo_fixture "$fixture_name"
    local local_repo="$TMPDIR_ROOT/$fixture_name/local"
    local before_sha
    local after_sha
    local log_file="$TMPDIR_ROOT/$fixture_name/run.log"
    local config_file="$TMPDIR_ROOT/$fixture_name/config.ini"

    # Local commit makes branch diverge from remote.
    git_quiet -C "$local_repo" checkout feature
    printf "local diverging commit\n" >> "$local_repo/file.txt"
    git_quiet -C "$local_repo" add file.txt
    git_quiet -C "$local_repo" commit -m "local diverging commit"
    git_quiet -C "$local_repo" checkout main

    advance_remote_branch "$fixture_name" feature "remote diverging commit"
    before_sha="$(git -C "$local_repo" rev-parse feature)"

    run_autogit_for_repo "$local_repo" "$log_file" "$config_file"
    after_sha="$(git -C "$local_repo" rev-parse feature)"

    assert_equals "$before_sha" "$after_sha" "diverged feature should not be rewritten"
    assert_json_log_contains "$log_file" "WARN" "$local_repo:feature" "SKIPPED" "Skipped because fast-forward is not possible (branch diverged or ahead)"
}

main() {
    command -v git >/dev/null 2>&1 || {
        echo "git is required for tests"
        exit 1
    }

    test_fast_forward_updates_non_checked_out_branch
    test_checked_out_worktree_branch_is_skipped
    test_diverged_branch_is_skipped
    echo "All tests passed"
}

main "$@"
