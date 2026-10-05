--!strict
-- Block `branch-changes.view`: what this branch changed. Uncommitted work on
-- top, merge-base(base)..HEAD commits below, inline diffs on click.
-- Args: { worktree_root } (any directory inside the worktree works).

local config = require("./lib/config")
local git = require("./lib/git")
local model = require("./lib/model")
local view = require("./lib/view")
local util = require("./lib/util")

local DEBOUNCE_MS = 500
local POLL_MS = 12000
local KV_PANES = "panes" -- pane id -> worktree root, read by window.luau to focus an open block

type Block = {
	state: model.State,
	cx: BlockCx,
	gen: number, -- bumps per refresh so stale results are dropped
	busy: boolean,
	again: boolean, -- a refresh was asked for while one ran
	debounce: TimerHandle?,
	head: string?, -- HEAD the poll compares against
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

local refresh: (b: Block) -> ()

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

refresh = function(b: Block)
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
				s.snap = snap
				s.refreshed_at = os.time()
				b.head = snap.status.oid
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
	end)
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

-- Cheap HEAD poll: catches commits, checkouts and rebases made outside a Tern shell.
local function poll(b: Block)
	tern.timer(POLL_MS, function()
		if not reap(b.cx.pane) or blocks[b.cx.pane] ~= b then
			return
		end
		local root = b.state.root
		if root and not b.busy then
			git.head(root, function(head)
				if alive(b.cx.pane) and head ~= b.head then
					refresh(b)
				end
			end)
		end
		poll(b)
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

local function open_file(b: Block, row: model.Row)
	local root, target = b.state.root, row.target
	if not root or not target then
		return
	end
	local abs = root .. "/" .. target.path
	if tern.fs.exists(abs) then
		b.cx:open(abs)
	else
		b.cx:toast("info", "Not in the worktree", target.path)
	end
end

-- Enter/space and clicks on a row.
local function activate(b: Block, row: model.Row)
	if row.kind == "commit" and row.sha then
		toggle_commit(b, row.sha)
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
			head = nil,
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
			refresh(b)
			poll(b)
		end)
		return state
	end,

	title = function(state)
		local snap = state.snap
		local name = util.basename(state.root or state.dir)
		if snap and snap.status.head then
			return "⎇ " .. snap.status.head .. " · " .. name
		end
		return "Branch changes · " .. name
	end,

	view = function(state, cx)
		local v, ids = view.build(state)
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
				open_file(b, row)
			elseif row.sha then
				toggle_commit(b, row.sha)
			end
		elseif name == "y" and row then
			cx:copy(if row.target then row.target.path else row.sha or "")
		elseif name == "r" then
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
					open_file(b, row)
				else
					toggle_diff(b, row)
				end
			end
		elseif ev.ev == "action" and ev.act == "file" then
			local row = model.find(model.rows(state), ev.value)
			if row then
				state.sel = row.id
				if has_mod(ev.mods, { "alt", "meta" }) then
					open_file(b, row)
				else
					toggle_diff(b, row)
				end
			end
		elseif ev.ev == "action" and ev.act == "base" and type(ev.value) == "string" then
			state.base_pref = ev.value
			refresh(b)
		end
	end,

	save = function(state)
		return { dir = state.root or state.dir, base = state.base_pref }
	end,
}

tern.block.define("view", def)

-- Shell commands under a block's root (git commit, checkout, stash, …) refresh it.
tern.on("command_finished", function(ev, _cx)
	if next(blocks) == nil then
		return
	end
	local cwd: string? = nil
	for _, p in tern.pane.list() do
		if p.pane == ev.pane then
			cwd = p.cwd
			break
		end
	end
	reap(nil)
	for _, b in blocks do
		if util.under(cwd, b.state.root) or util.under(cwd, b.state.dir) then
			schedule(b, DEBOUNCE_MS)
		end
	end
end)
