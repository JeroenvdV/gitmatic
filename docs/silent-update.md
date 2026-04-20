# Silent update mode (`[silent_update]`)

## What this mode does

`[silent_update]` updates **local branches that track an upstream branch** (for example `main` tracking `origin/main`) **without checking out those branches**.

It is designed for background automation where you may be actively working in one or more worktrees.

## Why this is safe

The implementation intentionally uses high-level Git commands and strict checks:

1. `git fetch --prune --tags`
   Refreshes remote-tracking refs first (`origin/*`) so decisions use current data.

2. `git for-each-ref ... refs/heads`
   Lists local branches and their configured upstreams.

3. `git worktree list --porcelain`
   Detects branches currently checked out in any worktree.

4. `git merge-base --is-ancestor <local> <upstream>`
   Verifies a fast-forward is possible (no history rewrite).

5. `git branch -f <local> <upstream>`
   Moves the local branch ref to upstream **without checkout**.

No `checkout`, `switch`, or merge into the working tree is performed.

## Worktree behavior

If a local branch is currently checked out in any worktree, it is **skipped**.

This avoids surprising behavior for users actively editing in that worktree.
Every skip is logged with `WARN` and includes the repo+branch.

## When branches are skipped

A branch is skipped if:

- It is checked out in any worktree.
- It has no upstream configured.
- Fast-forward is not possible (diverged or ahead).
- Branch/upstream refs cannot be resolved.

In all of these cases the repository remains unchanged for that branch.

## Practical note

Use `[silent_update]` for "background keep-local-branches-current" behavior.
Use `[pull]` only when you explicitly want working-tree updates on the currently checked-out branch.
