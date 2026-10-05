# tern-branch-changes

A Tern block that shows what **this branch** changed: uncommitted work on top, expandable commits below, inline file diffs. Built for large monorepos where Tern's full-repo git tree is too noisy.

Companion to [tern-worktrees](https://github.com/maxtuzz/tern-worktrees) (optional; opens via `plugin.branch-changes.open`).

## Status

MVP in progress.

## Install (dev)

```bash
tern plugin link /path/to/tern-branch-changes
tern plugin reload
```

## Docs

- [DESIGN.md](./DESIGN.md)
- [docs/](./docs/) — offline Tern plugin docs
- [tern.d.luau](./tern.d.luau) — `tern plugin types .`

## License

MIT
