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
- **Discarding:** the selected row shows an `x` keycap. Pressing it arms the row (red, with a `trash` icon and what will happen); pressing it again runs `git restore` — or `git clean` for an untracked file. This cannot be undone from git, which is why it takes two presses and never a single click.
- **Live work:** a file whose status or line counts changed since the last refresh is marked `just now` and floats to the top of its group for three minutes, so an agent's edits are visible as they land. The footer carries a live timer showing how old the picture is.
- **Commits:** one line each, no card borders: subject (truncated) with the age right-aligned. The icon stays the same whether a commit is expanded or not, because an icon name Tern doesn't know draws nothing and the empty slot shifts the row. The SHA waits in the tooltip until the pane is wide, because a row's value column reserves up to 40% of the width and that comes straight out of the subject. Unpushed commits are toned. The author appears only when it isn't this repo's `user.name`. Clicking a commit expands its files as the same file rows.
- **Footer:** hints are added only while they fit the pane, so nothing wraps mid-word; a narrow sidebar simply shows fewer.

### Full view

**Branch changes (full view)** in the palette (`plugin.branch-changes.open_full`), or `f` in the block, zooms the pane with Tern's own zoom so it fills its tab. Press `f` again to put it back. There is only ever one block per worktree, so the full view is that same pane with more room, keeping your selection and open diffs — not a second copy. At 100 cells or wider it lays out as two columns: the list on the left, and the selected file's diff as the hero on the right, with a chip to pop that diff into its own pane.

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
| `x`, the **discard** chip in the full view | Throw away a file's uncommitted changes. Two steps: the first press arms the row, which turns red and says what it will do; the second does it, and `escape` or moving away stands down. Staged files lose the staged copy and the working one, an untracked file is deleted, and a file inside a commit offers nothing |
| `y` | Copy the selected path or commit SHA |
| `r` | Refresh |
| `b` / `B`, click the base chip | Cycle the base ref |
| `f` | Zoom the pane to the full view, and back again |
| `escape` | Close all inline diffs |

### File diff block

`branch-changes.diff` shows one file's patch full-pane with Tern's own `ui.diff` renderer. Its args are `{ root, kind, path, sha?, orig? }`, where kind is staged, unstaged, untracked or commit. Press `r` to reload; `e` edits the file when it still exists. Working-tree diffs reload on their own when a shell command finishes under the root.

A host block can't create blocks itself, so the list follows a `tern-branch-changes://diff?root=…&kind=…&path=…&sha=…` link with `cx:open`. `window.luau`'s `tern.route.link` focuses the open block for the same root, kind, SHA and path, or places a new one. It places it itself rather than letting the route do it: a route's `block` decision opens beside the pane the link came from, which halves the sidebar and leaves the diff too narrow to read. Instead it walks the tab's split tree, splits the roomiest pane that isn't one of this plugin's blocks, and falls back to a new tab.

The block refreshes on its own:

- **A working-tree poll.** Every `poll_ms` (2 s by default) it runs one `git status` and refreshes only when the output differs from the last. This is what catches edits an editor or an agent writes directly, which finish no shell command and leave HEAD alone. The status output is handed to the refresh, so a cycle runs `git status` once, not twice.
- **Paced by what it costs.** Each probe is timed, and the poll keeps itself to roughly a twentieth of one core: where `git status` takes 10 ms it runs at the configured 2 s, and where it takes 800 ms it runs every 16 s instead, capped at a minute. Nothing to tune by repo size, and it tightens up by itself once status gets cheap.
- **Backoff.** After six quiet rounds the poll drops to 15 s, so a block left open all day is nearly free. A command starting under the worktree (`command_started`) wakes it back to the quick pace at once — an agent about to write files is exactly when you want it watching.
- **Shell commands.** 500 ms after a command finishes under the worktree (`command_finished`, debounced).
- **`r`.**

When status is slow and the worktree has no fsmonitor, the block says so once, quietly, under the header. Turning it on is your call — the plugin never writes to your repo's config.

Tern has no filesystem-change event (`tern.on` takes `spawn`, `command_started`, `command_finished`, `cwd`, `title` and `pane_exited`), and `tern.process.run` only reports a process when it exits, so a plugin can't stream a watcher like `fswatch`. Polling `git status` is the available answer. **In a large monorepo, turn on git's fsmonitor** — `git config core.fsmonitor true` (or watchman) — which makes each poll a question to a daemon instead of a walk of the worktree, so a 2 s poll stays cheap. Otherwise raise `poll_ms`.

## Config

Optional `.tern/branch-changes.json` in the worktree root. It's re-read on every refresh. Bad fields fall back to their defaults and show a warning line in the block.

```json
{
  "base": ["origin/dev", "origin/main"],
  "max_commits": 200,
  "max_files": 2000,
  "poll_ms": 2000,
  "show_branch_total": true,
  "untracked": "normal"
}
```

| Key | Default | Meaning |
|---|---|---|
| `base` | `["origin/dev", "origin/main"]` | Candidate base refs. The first one that exists is used; `origin/HEAD` is always tried last |
| `max_commits` | `200` | Cap on listed branch commits (1–1000); the rest show as "… N older" |
| `max_files` | `2000` | Cap per file group and per commit (1–10000) |
| `poll_ms` | `2000` | How often the worktree is checked for edits, in ms (250–60000). Backs off to 15 s while nothing changes |
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
- **A list row has one icon slot and no children**, so a per-row revert button isn't possible; the row advertises the key with a keycap (`hint`) instead, and the full view's hero gets a real chip. `actions` carries `click`, `dblclick` and `menu`, but the menu payload's shape isn't in these docs, so no right-click menu is built.
- **A small icon set.** There is `chev-r` but no down chevron, so a row can't show open/closed state by swapping chevrons; unknown names silently draw nothing.
- **No hover state.** Plugins see clicks, not hovers, so anything "on hover" is a `title` tooltip instead; that is where the long forms of the chips and rows live.
- **No menus for a plugin's own nodes.** `actions` carries `click` and `dblclick`, so the base picker is one chip that cycles rather than a dropdown.
- **Card heads take spans only**, which is one reason commits are list rows now: a row gives real truncation and a right-aligned value, which a card head does not.
- **No folder tree yet.** Rows are flat paths (file name plus dim folder); a grouped-by-folder toggle would need a `tree` node, which doesn't carry the per-row value column.

## License

MIT
