# tern-branch-changes

A Tern block that shows what **this branch** changed: uncommitted work on top, expandable commits below, inline file diffs. Built for large monorepos where Tern's full-repo git tree is too noisy.

Companion to [tern-worktrees](https://github.com/maxtuzz/tern-worktrees) (optional; it can open this block via `plugin.branch-changes.open`).

## Install (dev)

```bash
tern plugin link /path/to/tern-branch-changes
tern plugin reload        # exits 1 if a plugin failed
tern plugin list          # branch-changes … ready
```

After editing the Luau, run `tern plugin reload` again: open blocks restart with their saved root and base.

## Use

Focus any pane inside a git worktree, then run **Show branch changes** from the palette (`plugin.branch-changes.open`, default chord `ctrl+alt+shift+b`). The block opens beside the focused pane. If a block for that worktree is already open, the command focuses it instead.

```
⎇ feat/foo vs origin/dev · ↑3 unpushed · ●5
/path/to/worktree  ·  14 files +120 −30 since merge-base
base [origin/dev] [origin/main] [origin/HEAD]

Uncommitted ●5
  Staged 1      ▸ M src/app.ts           +4 −1
  Unstaged 2    ▸ M lib/util.lua         +1 −1
  Untracked 2   ▸ ? notes.md
Commits 3  origin/dev..HEAD
  ▸ a1b2c3d fix login redirect  Ada · 2h ↑
  ▸ …
```

| Key / gesture | Action |
|---|---|
| `j` / `k`, ↓ / ↑, `g` / `G` | Move the selection |
| `enter` / `space`, click | File: toggle its inline diff. Commit: expand it (files load lazily) |
| `o`, ⌥-click or ⌘-click, double-click | Open the file in a Tern file block |
| `y` | Copy the selected path or commit SHA |
| `r` | Refresh |
| `b` / `B`, click a base badge | Cycle the base ref |
| `escape` | Close all open diffs |

The block refreshes on its own:

- 500 ms after any shell command finishes in a pane under the worktree (`command_finished`, debounced)
- when `git rev-parse HEAD` changes, checked every 12 s (catches commits made outside Tern shells)
- on `r`

## Config

Optional `.tern/branch-changes.json` in the worktree root. It's re-read on every refresh. Bad fields fall back to their defaults and show a warning line in the block.

```json
{
  "base": ["origin/dev", "origin/main"],
  "max_commits": 200,
  "max_files": 2000,
  "show_branch_total": true,
  "untracked": "normal"
}
```

| Key | Default | Meaning |
|---|---|---|
| `base` | `["origin/dev", "origin/main"]` | Candidate base refs. The first one that exists is used; `origin/HEAD` is always tried last |
| `max_commits` | `200` | Cap on listed branch commits (1–1000); the rest show as "… N older" |
| `max_files` | `2000` | Cap per file group and per commit (1–10000) |
| `show_branch_total` | `true` | Show `git diff --shortstat <merge-base> HEAD` in the header |
| `untracked` | `"normal"` | `git status --untracked-files=` mode: `normal`, `all` or `no` |

## How it differs from Tern's native git block

| | Tern git block | Branch Changes |
|---|---|---|
| Scope | Whole repository: status plus full history graph | Only this branch: `merge-base(base, HEAD)..HEAD` and uncommitted work |
| Cost in a monorepo | Loads the repo-wide tree and graph | `git status`, one capped `git log`, plus one `diff-tree` per commit you expand |
| Diffs | Native diff view | Inline `ui.diff` under the file (Tern has no API to deep-link its native diff) |
| Where it runs | Window | Host block: survives window close and restart, and every window attached to the session shows it |
| Staging | Yes | Read-only (planned for v1.1) |

## How it works

- `host.luau` defines the block. All git runs on the host through async `tern.process.run` with `--no-optional-locks`, `GIT_OPTIONAL_LOCKS=0`, `-z` porcelain output and timeouts. The block never takes the index lock away from your own git. (`cx.git` is window-only, so it can't be used here.)
- `window.luau` registers the command. It resolves the focused pane's worktree root, then focuses an existing block for that root or splits a new one to the right.
- `lib/` holds the parsers (`parse`), config validation (`config`), git calls (`git`), state and keyboard rows (`model`) and the view (`view`).

Programs it runs: `git` only.

## Development

```bash
python3 tests/test.py     # needs `luau` (brew install luau)
python3 tests/record.py   # re-record git fixtures after changing git argv
```

The tests run the real `host.luau` against a stub `tern` (`tests/stub.luau`) and git output recorded from a sample repo. For editor type-checking, run `tern plugin types .` to write `tern.d.luau` for luau-lsp.

## Docs

- [DESIGN.md](./DESIGN.md)
- [docs/](./docs/): offline Tern plugin docs
- [tern.d.luau](./tern.d.luau)

## License

MIT
