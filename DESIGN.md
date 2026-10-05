# Design: tern-branch-changes

## Pitch

What this branch changed: uncommitted on top, branch commits below, diffs inline — without loading the whole repo graph.

## Decisions (locked for MVP)

- Repo: `maxtuzz/tern-branch-changes` (public, MIT)
- Host **block** (not window canvas): keys, survives restart, one instance per worktree root
- Git via async `tern.process.run` on host (`cx.git` is window-only and not branch-scoped)
- Diffs: inline `ui.diff(text, path)` — Tern has no API to open native diff at a file/commit
- Base: first existing of configured refs (Studio: `origin/dev`, then `origin/main`, else `origin/HEAD`)
- Optional coupling: worktrees plugin may call `plugin.branch-changes.open` after session create

## Manifest

```toml
schema = 1
id = "branch-changes"
name = "Branch Changes"
version = "0.1.0"
description = "Branch-scoped changes: uncommitted + expandable commits + inline diffs"
host = "host.luau"
window = "window.luau"
```

## Commands

| Action | Label |
|---|---|
| `plugin.branch-changes.open` | Show branch changes |

Prefer a key bind on `open`. Opens or focuses block for focused pane's worktree root (`cx:new_block("branch-changes.view", {root}, "beside")`).

## Block UI (`branch-changes.view`)

Args: `{ worktree_root }`

1. **Header:** `⎇ feat/foo vs origin/dev · ↑3 unpushed · ●5` + base selector
2. **Uncommitted (top):** Staged / Unstaged / Untracked, collapsible, status letter + +/- counts
3. **Commits:** one collapsible card per commit in `merge-base(base,HEAD)..HEAD` (short sha, subject, author, age, ↑ if beyond `@{u}`)
4. Expand commit → lazy `git show --numstat --format= <sha>`
5. Click file → inline `ui.diff`:
   - WT: `git diff -- p`
   - staged: `git diff --cached -- p`
   - untracked: `git diff --no-index /dev/null p`
   - in commit: `git show <sha> -- p`
6. Alt/⌘-click → `cx:open(abs_path)` (file block with gutter)
7. Keys: j/k, enter, o, r (refresh), b (cycle base)

Caps: ~200 commits, ~2000 files; show `ui.overflow`. Use `--no-optional-locks`, `-z`, porcelain v2, timeouts.

## Refresh

- Debounced ~500 ms on `command_finished` for panes under the root
- Cheap `git rev-parse HEAD` poll every 10–15 s while block pane exists
- Manual `r`

## Config (`.tern/branch-changes.json`)

```json
{
  "base": ["origin/dev", "origin/main"],
  "max_commits": 200,
  "show_branch_total": true,
  "untracked": "normal"
}
```

## MVP done-when

1. Plugin links and reloads clean
2. `Show branch changes` opens a block beside the focused pane
3. Uncommitted section accurate for the worktree
4. Commit list is `base..HEAD` only (not full repo history)
5. Expand commit → file list; click file → inline diff
6. Refresh on shell commands and manual `r`
7. Works in a large monorepo checkout without loading whole-repo tree

## Out of scope (v1.1+)

- Stage/unstage from the block
- Full-height diff sub-block
- Native Tern diff deep-link (needs Stencil API: `cx.git:open(repo, {path, rev})`)
