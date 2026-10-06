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

The layout follows the pane's width, so one block serves both places.

### Sidebar (the design target, ~250-320px)

```
feat/login-redirect              [dev]
↑3  ↓1  5 changed  +120 -30

Changes 5
  Staged 1
    app.ts         src       +4 -1 M
  Unstaged 2
    util.lua       lib  just now  +1 -1 M
    notes.md       docs           +2 M
  Untracked 2
    scratch.md                       ?
Commits 3
  fix login redirect      a1b2c3d 2h
  drop the retry loop     9f0e1d2 4h
12s ago  [enter] diff  [o] open
```

- **Header:** two rows that never wrap. The branch name takes the first row with the base as one chip on its right; click it (or press `b`) to cycle to the next base. The second row holds short status chips: `↑n`/`↓n` for ahead and behind, the uncommitted count, and the branch totals. Every chip carries a tooltip with the long form.
- **File rows:** the file name is the label, its folder dim beside it, the icon tinted by status (modified warning, added success, deleted error, renamed/copied info, conflict error, untracked muted). `+n -n` and the status letter are right-aligned, and the tooltip gives the full path and status.
- **Live work:** a file whose status or line counts changed since the last refresh is marked `just now` and floats to the top of its group for three minutes, so an agent's edits are visible as they land. The footer carries a live timer showing how old the picture is.
- **Commits:** one line each, no card borders: subject (truncated) with the age right-aligned. The SHA waits in the tooltip until the pane is wide, because a row's value column reserves up to 40% of the width and that comes straight out of the subject. Unpushed commits are toned. The author appears only when it isn't this repo's `user.name`. Clicking a commit expands its files as the same file rows.
- **Footer:** hints are added only while they fit the pane, so nothing wraps mid-word; a narrow sidebar simply shows fewer.

### Full view

**Branch changes (full view)** in the palette (`plugin.branch-changes.open_full`), or `f` in the sidebar block, opens the same block in its own tab. At 100 cells or wider it lays out as two columns: the list on the left, and the selected file's diff as the hero on the right, with a chip to pop that diff into its own pane.

```
feat/login-redirect  [origin/dev]        │ app.ts  src
↑3  ↓1  5 changed  14 files  +120 -30    │ ┌──────────────────────────┐
/path/to/my-worktree                     │ │ @@ -12,7 +12,9 @@        │
Changes 5                                │ │ -  const r = retry(x)    │
  Staged 1                               │ │ +  const r = await x()   │
    app.ts        src          +4 -1  M  │ └──────────────────────────┘
```

In the full view a click loads the diff into the hero instead of folding it away; in the sidebar it still toggles inline under the row.

| Key / gesture | Action |
|---|---|
| `j` / `k`, ↓ / ↑, `g` / `G` | Move the selection |
| click, `enter` / `space` | File: show its diff — inline under the row in the sidebar, in the hero column in the full view. Commit: expand it (files load lazily) |
| double-click, `o` | Open the file's diff in its own **File diff** block beside this one. If that diff is already open, focus it. Works for deleted files too |
| `e`, ⌥-click or ⌘-click | Edit the worktree file in a Tern file block. For a deleted file it explains that and suggests `o` instead |
| `y` | Copy the selected path or commit SHA |
| `r` | Refresh |
| `b` / `B`, click the base chip | Cycle the base ref |
| `f` | Open this worktree in the full view (a new tab) |
| `escape` | Close all inline diffs |

### File diff block

`branch-changes.diff` shows one file's patch full-pane with Tern's own `ui.diff` renderer. Its args are `{ root, kind, path, sha?, orig? }`, where kind is staged, unstaged, untracked or commit. Press `r` to reload; `e` edits the file when it still exists. Working-tree diffs reload on their own when a shell command finishes under the root.

A host block can't create blocks itself, so the list follows a `tern-branch-changes://diff?root=…&kind=…&path=…&sha=…` link with `cx:open`. `window.luau`'s `tern.route.link` focuses the open block for the same root, kind, SHA and path, or places a new one. It places it itself rather than letting the route do it: a route's `block` decision opens beside the pane the link came from, which halves the sidebar and leaves the diff too narrow to read. Instead it walks the tab's split tree, splits the roomiest pane that isn't one of this plugin's blocks, and falls back to a new tab.

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
- `branch-changes.css` (the manifest's `styles`) trims the 22px indent and guide line Tern gives a section body, scoped to this plugin's surfaces.
- `lib/view.luau` builds both layouts from `cx.cols`; `lib/diff_block.luau` defines the full-pane File diff block, and `lib/link.luau` encodes the links that open it.
- `window.luau` registers the command and the `tern-branch-changes://` link route. The command resolves the focused pane's worktree root, then focuses an existing block for that root or splits a new one to the right.
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

## Tern API limitations worked around

- **Width.** A block learns its size only in cells, from `cx.cols`, so the layout switches at cell thresholds (sidebar under 56, two columns at 100) rather than at pixel widths.
- **No wrap control.** A `text` node has no "don't wrap" prop. A `row` itself doesn't wrap, but its children shrink, and a squeezed text node breaks its own words, so chips and keycaps carry `shrink = 0` and the view spends width by dropping whole items. Long single-line text (the branch name, the worktree path) is clipped with `max = { h = "1lines" }`, which cuts rather than ellipsizes — and it can only go on text, since clipping a row to one line would slice the top and bottom off any badge inside it.
- **A row centres its children** (`align-items: center` in Tern's sheet), which in the full view pushed the diff column half a screen down beside a tall list. The plugin sheet sets `flex-start` on the split.
- **A region root is the region itself**: its `role` goes on the region element and its own content isn't drawn, so the split row has to be a child of a `col` root rather than the root.
- **No pane widths.** `PaneInfo` carries no size, so "which pane is roomiest" is worked out from the tab's split-tree ratios.
- **No hover state.** Plugins see clicks, not hovers, so anything "on hover" is a `title` tooltip instead; that is where the long forms of the chips and rows live.
- **No menus for a plugin's own nodes.** `actions` carries `click` and `dblclick`, so the base picker is one chip that cycles rather than a dropdown.
- **Card heads take spans only**, which is one reason commits are list rows now: a row gives real truncation and a right-aligned value, which a card head does not.
- **No folder tree yet.** Rows are flat paths (file name plus dim folder); a grouped-by-folder toggle would need a `tree` node, which doesn't carry the per-row value column.

## License

MIT
