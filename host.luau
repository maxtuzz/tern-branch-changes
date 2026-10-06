--!strict
-- Block `branch-changes.view`: what this branch changed. Uncommitted work on
-- top, merge-base(base)..HEAD commits below, inline diffs on click.
-- Args: { worktree_root } (any directory inside the worktree works).
-- Also defines `branch-changes.diff` (lib/diff_block.luau), the full-pane diff
-- that `o` and double-click open.

local config = require("./lib/config")
local git = require("./lib/git")
local model = require("./lib/model")
local view = require("./lib/view")
local util = require("./lib/util")
local link = require("./lib/link")
local diff_block = require("./lib/diff_block")

local DEBOUNCE_MS = 500
-- The poll runs `git status` and refreshes when its output changed. It starts
-- at the configured pace (2 s) so an agent's edits land quickly, and after a
-- few quiet rounds backs off to IDLE_MS, so a block left open all day is cheap.
local IDLE_MS = 15000
local QUIET_ROUNDS = 6
-- The poll keeps itself to about a twentieth of one core: in a worktree where
-- `git status` takes 800 ms it runs every 16 s, not every 2 s. Measured, so it
-- needs no guess about repo size, and it tightens up by itself once the repo
-- gets git's filesystem monitor.
local DUTY = 20
local MAX_POLL_MS = 60000
local SLOW_MS = 400
local KV_PANES = "panes" -- pane id -> worktree root, read by window.luau to focus an open block

type Block = {
	state: model.State,
	cx: BlockCx,
	gen: number, -- bumps per refresh so stale results are dropped
	busy: boolean,
	again: boolean, -- a refresh was asked for while one ran
	debounce: TimerHandle?,
	fsmonitor: boolean, -- whether this worktree has git's filesystem monitor on
	seen: string?, -- the last status output, so the poll can tell what changed
	quiet: number, -- consecutive polls that found nothing, for the backoff
	tick: TimerHandle?, -- the pending poll, so waking it can re-arm at the quick pace
	ids: { [string]: string }, -- list item node id -> row id, from the last view
}

local blocks: { [number]: Block } = {}

local function alive(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

-- Drops blocks whose panes are gone; returns whether `pane` is still live.
local function reap(pane: number?): boolean
	local live: { [number]: boolean } = {}
	for _, p in tern.pane.list() do
		live[p.pane] = true
	end
	for id, b in blocks do
		if not live[id] then
			if b.debounce then
				b.debounce:cancel()
			end
			blocks[id] = nil
		end
	end
	return pane ~= nil and live[pane] == true
end

local function remember_root(pane: number, root: string)
	pcall(function()
		local map = tern.kv.get(KV_PANES)
		local live: { [string]: string } = {}
		for _, p in tern.pane.list() do
			local key = tostring(p.pane)
			if type(map) == "table" and type(map[key]) == "string" then
				live[key] = map[key]
			end
		end
		live[tostring(pane)] = root
		tern.kv.set(KV_PANES, live)
	end)
end

local refresh: (b: Block, have_status: string?) -> ()

local function load_diff(b: Block, row: model.Row)
	local root, target = b.state.root, row.target
	if not root or not target then
		return
	end
	local gen = b.gen
	b.state.diffs[row.id] = { loading = true, text = nil, err = nil }
	git.diff(root, target, function(text, err)
		local d = b.state.diffs[row.id]
		if not alive(b.cx.pane) or d == nil or (target.kind ~= "commit" and gen ~= b.gen) then
			return
		end
		b.state.diffs[row.id] = { loading = false, text = text, err = err }
		b.cx:render()
	end)
end

local function load_files(b: Block, sha: string)
	local root = b.state.root
	if not root or b.state.files[sha] then
		return
	end
	b.state.files[sha] = { loading = true, group = nil, err = nil }
	git.commit_files(root, sha, b.state.cfg.max_files, function(group, err)
		if not alive(b.cx.pane) then
			return
		end
		b.state.files[sha] = { loading = false, group = group, err = err }
		b.cx:render()
	end)
end

-- Re-fetches open uncommitted diffs; commit diffs never change.
local function reload_open_diffs(b: Block)
	for _, row in model.rows(b.state) do
		local d = b.state.diffs[row.id]
		if d and row.target and row.target.kind ~= "commit" then
			load_diff(b, row)
		end
	end
end

refresh = function(b: Block, have_status: string?)
	if b.busy then
		b.again = true
		return
	end
	local root = b.state.root
	if not root then
		return
	end
	b.busy, b.again = true, false
	b.gen += 1
	local gen = b.gen
	local cfg, warnings = config.load(root)
	b.state.cfg, b.state.warnings = cfg, warnings
	b.state.loading = true
	b.cx:render()
	git.snapshot(root, cfg, b.state.base_pref, function(snap, err)
		if not alive(b.cx.pane) then
			return
		end
		b.busy = false
		if gen == b.gen then
			local s = b.state
			s.loading = false
			s.error = err
			if snap then
				local first = s.refreshed_at == nil
				-- What the poll compares against, so it doesn't refresh again
				-- for a change this snapshot already carries.
				b.seen = snap.raw
				s.snap = snap
				s.refreshed_at = os.time()
				model.note_changes(s, first)
				model.prune(s)
				if s.sel == nil then
					model.move(s, 0)
				end
				reload_open_diffs(b)
			end
			b.cx:render()
		end
		if b.again then
			refresh(b)
		end
	end, have_status)
end

local function schedule(b: Block, ms: number)
	if b.debounce then
		b.debounce:cancel()
	end
	b.debounce = tern.timer(ms, function()
		b.debounce = nil
		if reap(b.cx.pane) then
			refresh(b)
		end
	end)
end

-- Watches the worktree: one `git status` per tick, and a full refresh only when
-- its output differs from the last. `command_finished` and `r` still refresh
-- directly; this is what catches edits made by an editor or an agent, which
-- finish no shell command and leave HEAD alone.
-- Said once, quietly, and only where it would actually help: a worktree this
-- big is what git's filesystem monitor is for.
local function hint_for(b: Block): string?
	local cost = b.state.cost
	if b.fsmonitor or cost == nil or cost < SLOW_MS then
		return nil
	end
	return string.format("git status takes %.1fs here — `git config core.fsmonitor true` makes this quick", cost / 1000)
end

local poll: (b: Block) -> ()

-- Back to the quick pace now, not at the end of a 15 s nap: a command just
-- started under the root, or the user asked for a refresh.
local function wake(b: Block)
	b.quiet = 0
	if b.tick then
		b.tick:cancel()
		b.tick = nil
	end
	poll(b)
end

-- What a tick should cost us: the configured pace, stretched when status is
-- slow here, stretched again while nothing is happening.
local function pace(b: Block): number
	local floor = b.state.cfg.poll_ms
	local wait = math.max(floor, (b.state.cost or 0) * DUTY)
	if b.quiet >= QUIET_ROUNDS then
		wait = math.max(wait, IDLE_MS)
	end
	return math.min(wait, MAX_POLL_MS)
end

poll = function(b: Block)
	b.tick = tern.timer(pace(b), function()
		b.tick = nil
		if not reap(b.cx.pane) or blocks[b.cx.pane] ~= b then
			return
		end
		local root = b.state.root
		if root == nil or b.busy then
			poll(b)
			return
		end
		git.status(root, b.state.cfg, function(out, took)
			if not alive(b.cx.pane) or blocks[b.cx.pane] ~= b then
				return
			end
			-- A rolling cost, so one slow tick doesn't set the pace on its own.
			local cost = b.state.cost
			b.state.cost = if cost then cost * 0.7 + took * 0.3 else took
			b.state.hint = hint_for(b)
			if out ~= nil and out ~= b.seen then
				b.seen, b.quiet = out, 0
				refresh(b, out)
			else
				b.quiet += 1
			end
			poll(b)
		end)
	end)
end

local function toggle_diff(b: Block, row: model.Row)
	if b.state.diffs[row.id] then
		b.state.diffs[row.id] = nil
	else
		load_diff(b, row)
	end
end

local function toggle_commit(b: Block, sha: string, open: boolean?)
	local now = if open == nil then not b.state.open[sha] else open
	b.state.open[sha] = now
	if now then
		load_files(b, sha)
	end
end

-- Edits the worktree file (`e`, ⌥/⌘-click). A deleted file has nothing to edit.
local function edit_file(b: Block, row: model.Row)
	local root, target = b.state.root, row.target
	if not root or not target then
		return
	end
	local abs = root .. "/" .. target.path
	if tern.fs.exists(abs) then
		b.cx:open(abs)
	else
		b.cx:toast("info", "Deleted in the worktree", target.path .. " · press o to view its diff")
	end
end

-- Opens this worktree's view full width, in its own tab (`f`).
local function open_full(b: Block)
	local root = b.state.root
	if root then
		b.cx:open(link.view_url(root))
	end
end

-- Opens the file's diff in its own `branch-changes.diff` block (`o`, double-click).
-- A host block can't create blocks, so it follows a link window.luau routes.
local function open_diff(b: Block, row: model.Row)
	local root, target = b.state.root, row.target
	if not root or not target then
		return
	end
	b.cx:open(link.encode({
		root = root,
		kind = target.kind,
		path = target.path,
		sha = target.sha,
		orig = target.orig,
	}))
end

-- Enter/space and clicks on a row. In a wide pane the diff is the hero column,
-- so a click there loads it rather than folding it away again.
local function activate(b: Block, row: model.Row)
	if row.kind == "commit" and row.sha then
		toggle_commit(b, row.sha)
	elseif b.cx.cols >= view.WIDE then
		if not b.state.diffs[row.id] then
			load_diff(b, row)
		end
	else
		toggle_diff(b, row)
	end
end

local function cycle_base(b: Block, step: number)
	local snap = b.state.snap
	if not snap or #snap.bases < 2 then
		return
	end
	local i = table.find(snap.bases, snap.base or "") or 0
	b.state.base_pref = snap.bases[(i - 1 + step) % #snap.bases + 1]
	refresh(b)
end

local function has_mod(mods: any, names: { string }): boolean
	if type(mods) ~= "table" then
		return false
	end
	for _, m in mods do
		if table.find(names, m) then
			return true
		end
	end
	return false
end

local def: BlockDef<model.State> = {
	init = function(cx, args, saved)
		local dir = (if type(saved) == "table" then saved.dir else nil) or args[1] or cx.cwd or ""
		local base = if type(saved) == "table" and type(saved.base) == "string" then saved.base else nil
		local state = model.new(dir, nil, base)
		local b: Block = {
			state = state,
			cx = cx,
			gen = 0,
			busy = false,
			again = false,
			debounce = nil,
			fsmonitor = false,
			seen = nil,
			quiet = 0,
			tick = nil,
			ids = {},
		}
		blocks[cx.pane] = b
		if dir == "" then
			state.error = "No directory: open this block with a worktree root"
			return state
		end
		state.loading = true
		git.toplevel(dir, function(root, err)
			if not alive(cx.pane) then
				return
			end
			if not root then
				state.loading = false
				state.error = "Not a git worktree: " .. dir .. " (" .. tostring(err) .. ")"
				cx:render()
				return
			end
			state.root = root
			remember_root(cx.pane, root)
			-- `user.name` lets the commit rows leave out the author when it is you.
			git.run(root, { "config", "--get", "user.name" }, git.FAST_MS, function(r)
				if alive(cx.pane) and r.status == 0 then
					state.me = (string.gsub(r.stdout, "%s+$", ""))
					cx:render()
				end
			end)
			git.fsmonitor(root, function(on)
				if alive(cx.pane) then
					b.fsmonitor = on
				end
			end)
			refresh(b)
			poll(b)
		end)
		return state
	end,

	title = function(state)
		local snap = state.snap
		local name = util.basename(state.root or state.dir)
		if snap and snap.status.head then
			return snap.status.head .. " · " .. name
		end
		return "Branch changes · " .. name
	end,

	view = function(state, cx)
		local v, ids = view.build(state, cx.cols)
		local b = blocks[cx.pane]
		if b then
			b.ids = ids
		end
		return v
	end,

	key = function(state, key, cx)
		local b = blocks[cx.pane]
		if not b or key.ctrl or key.meta then
			return false
		end
		local rows = model.rows(state)
		local row = model.find(rows, state.sel)
		local name = key.name
		if name == "j" or name == "down" then
			model.move(state, 1)
		elseif name == "k" or name == "up" then
			model.move(state, -1)
		elseif name == "end" or key.text == "G" then
			state.sel = if #rows > 0 then rows[#rows].id else nil
		elseif name == "g" or name == "home" then
			state.sel = if rows[1] then rows[1].id else nil
		elseif (name == "enter" or name == "space") and row then
			activate(b, row)
		elseif name == "o" and row then
			if row.kind == "file" then
				open_diff(b, row)
			elseif row.sha then
				toggle_commit(b, row.sha)
			end
		elseif name == "f" then
			open_full(b)
		elseif name == "e" and row and row.kind == "file" then
			edit_file(b, row)
		elseif name == "y" and row then
			cx:copy(if row.target then row.target.path else row.sha or "")
		elseif name == "r" then
			wake(b)
			refresh(b)
		elseif name == "b" then
			cycle_base(b, if key.shift then -1 else 1)
		elseif name == "escape" then
			state.diffs = {}
		else
			return false
		end
		return true
	end,

	event = function(state, ev, cx)
		local b = blocks[cx.pane]
		if not b then
			return
		end
		if ev.ev == "toggle" then
			local sha = string.match(ev.id or "", "^main%.commits%.c(%x+)$")
			if sha then
				state.sel = model.commit_row_id(sha)
				toggle_commit(b, sha, ev.collapsed == false)
			end
		elseif ev.ev == "select" or ev.ev == "activate" then
			local row = model.find(model.rows(state), b.ids[ev.item or ""])
			if row then
				state.sel = row.id
				if ev.ev == "activate" then
					open_diff(b, row)
				else
					activate(b, row)
				end
			end
		elseif ev.ev == "action" and ev.act == "file" then
			local row = model.find(model.rows(state), ev.value)
			if row then
				state.sel = row.id
				if has_mod(ev.mods, { "alt", "meta" }) then
					edit_file(b, row)
				else
					activate(b, row)
				end
			end
		elseif ev.ev == "action" and ev.act == "diff" then
			local row = model.find(model.rows(state), ev.value)
			if row then
				state.sel = row.id
				open_diff(b, row)
			end
		elseif ev.ev == "action" and ev.act == "commit" and type(ev.value) == "string" then
			state.sel = model.commit_row_id(ev.value)
			toggle_commit(b, ev.value)
		elseif ev.ev == "action" and ev.act == "base" and type(ev.value) == "string" then
			state.base_pref = ev.value
			refresh(b)
		elseif ev.ev == "action" and ev.act == "base-next" then
			cycle_base(b, 1)
		end
	end,

	save = function(state)
		return { dir = state.root or state.dir, base = state.base_pref }
	end,
}

tern.block.define("view", def)
diff_block.define()

-- The pane's directory, when it is known.
local function pane_cwd(pane: number): string?
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return p.cwd
		end
	end
	return nil
end

-- Runs `fn` for every block watching the worktree `pane` sits in.
local function for_blocks_under(pane: number, fn: (Block) -> ())
	local cwd = pane_cwd(pane)
	if next(blocks) ~= nil then
		reap(nil)
	end
	for _, b in blocks do
		if util.under(cwd, b.state.root) or util.under(cwd, b.state.dir) then
			fn(b)
		end
	end
end

-- Shell commands under a block's root (git commit, checkout, stash, …) refresh it.
tern.on("command_finished", function(ev, _cx)
	local cwd = pane_cwd(ev.pane)
	diff_block.on_command(cwd)
	if next(blocks) == nil then
		return
	end
	for_blocks_under(ev.pane, function(b)
		schedule(b, DEBOUNCE_MS)
		wake(b)
	end)
end)

-- A command starting under the root usually means work is about to land (an
-- agent, a build, a test run), so the poll goes back to its quick pace.
tern.on("command_started", function(ev, _cx)
	if next(blocks) == nil then
		return
	end
	for_blocks_under(ev.pane, wake)
end)
