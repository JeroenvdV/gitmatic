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

assert_not_contains() {
    local file="$1"
    local unexpected="$2"
    if grep -Fq "$unexpected" "$file"; then
        echo "ASSERTION FAILED: did not expect '$unexpected' in $file"
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

new_plain_repo() {
    local repo_path="$1"

    mkdir -p "$repo_path"
    git_quiet init "$repo_path"
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
[silent_update]
path = "$repo_root"
EOF

    "$AUTOGIT_SCRIPT" --config "$config_file" --log-file "$log_file" >/dev/null
}

run_autogit_with_config() {
    local config_file="$1"
    local log_file="$2"
    shift 2

    "$AUTOGIT_SCRIPT" --config "$config_file" --log-file "$log_file" "$@" >/dev/null
}

test_fast_forward_updates_non_checked_out_branch() {
    local fixture_name="ff-success"
    new_repo_fixture "$fixture_name"
    local local_repo="$TMPDIR_ROOT/$fixture_name/local"
    local before_sha
    local after_sha
    local log_file="$TMPDIR_ROOT/$fixture_name/run.log"
    local config_file="$TMPDIR_ROOT/$fixture_name/config.toml"

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
    local config_file="$TMPDIR_ROOT/$fixture_name/config.toml"

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
    local config_file="$TMPDIR_ROOT/$fixture_name/config.toml"

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

test_discovery_supports_multiple_includes_excludes_and_max_depth() {
    local fixture_name="discovery-rules"
    local fixture_dir="$TMPDIR_ROOT/$fixture_name"
    local primary_root="$fixture_dir/root-one"
    local secondary_root="$fixture_dir/root-two"
    local included_repo="$primary_root/included-repo"
    local excluded_parent="$primary_root/excluded-group"
    local excluded_repo="$excluded_parent/excluded-repo"
    local explicit_repo="$excluded_parent/explicit-repo"
    local deep_repo="$primary_root/deep-parent/deep-repo"
    local wildcard_repo="$primary_root/team-skipme/project-repo"
    local secondary_repo="$secondary_root/another-repo"
    local log_file="$fixture_dir/run.log"
    local config_file="$fixture_dir/config.toml"

    new_plain_repo "$included_repo"
    mkdir -p "$excluded_parent"
    new_plain_repo "$excluded_repo"
    new_plain_repo "$explicit_repo"
    new_plain_repo "$deep_repo"
    new_plain_repo "$wildcard_repo"
    new_plain_repo "$secondary_repo"

    cat > "$config_file" <<EOF
[fetch]
include_path = ["$primary_root", "$secondary_root", "$explicit_repo"]
exclude_path = ["$excluded_parent", "*skipme*"]
max_depth = 1
EOF

    run_autogit_with_config "$config_file" "$log_file" --dry-run

    assert_json_log_contains "$log_file" "FETCH" "$included_repo" "DRY-RUN"
    assert_json_log_contains "$log_file" "FETCH" "$secondary_repo" "DRY-RUN"
    assert_json_log_contains "$log_file" "FETCH" "$explicit_repo" "DRY-RUN"
    assert_not_contains "$log_file" "\"path\":\"$excluded_repo\""
    assert_not_contains "$log_file" "\"path\":\"$deep_repo\""
    assert_not_contains "$log_file" "\"path\":\"$wildcard_repo\""
}

test_discovery_stops_descending_after_repo_root() {
    local fixture_name="nested-repo-prune"
    local fixture_dir="$TMPDIR_ROOT/$fixture_name"
    local scan_root="$fixture_dir/scan-root"
    local parent_repo="$scan_root/parent-repo"
    local nested_repo="$parent_repo/nested-repo"
    local log_file="$fixture_dir/run.log"
    local config_file="$fixture_dir/config.toml"

    new_plain_repo "$parent_repo"
    new_plain_repo "$nested_repo"

    cat > "$config_file" <<EOF
[fetch]
include_path = "$scan_root"
EOF

    run_autogit_with_config "$config_file" "$log_file" --dry-run

    assert_json_log_contains "$log_file" "FETCH" "$parent_repo" "DRY-RUN"
    assert_not_contains "$log_file" "\"path\":\"$nested_repo\""
}

test_discovery_detects_linked_worktrees() {
    local fixture_name="worktree-discovery"
    local scan_root="$TMPDIR_ROOT/$fixture_name"
    local local_repo="$scan_root/local"
    local worktree_repo="$scan_root/worktree-feature"
    local log_file="$scan_root/run.log"
    local config_file="$scan_root/config.toml"

    new_repo_fixture "$fixture_name"
    git_quiet -C "$local_repo" worktree add "$worktree_repo" feature

    cat > "$config_file" <<EOF
[fetch]
include_path = "$scan_root"
EOF

    run_autogit_with_config "$config_file" "$log_file" --dry-run

    assert_json_log_contains "$log_file" "FETCH" "$local_repo" "DRY-RUN"
    assert_json_log_contains "$log_file" "FETCH" "$worktree_repo" "DRY-RUN"
}

test_ini_configs_are_rejected() {
    local fixture_name="ini-rejected"
    local fixture_dir="$TMPDIR_ROOT/$fixture_name"
    local config_file="$fixture_dir/config.ini"
    local output_file="$fixture_dir/output.log"

    mkdir -p "$fixture_dir"
    cat > "$config_file" <<'EOF'
[SILENT_UPDATE]
path = /tmp/example
EOF

    if "$AUTOGIT_SCRIPT" --config "$config_file" >"$output_file" 2>&1; then
        echo "ASSERTION FAILED: INI config should be rejected"
        exit 1
    fi

    assert_contains "$output_file" "INI configuration is no longer supported"
}

main() {
    command -v git >/dev/null 2>&1 || {
        echo "git is required for tests"
        exit 1
    }

    test_fast_forward_updates_non_checked_out_branch
    test_checked_out_worktree_branch_is_skipped
    test_diverged_branch_is_skipped
    test_discovery_supports_multiple_includes_excludes_and_max_depth
    test_discovery_stops_descending_after_repo_root
    test_discovery_detects_linked_worktrees
    test_ini_configs_are_rejected
    echo "All tests passed"
}

main "$@"
