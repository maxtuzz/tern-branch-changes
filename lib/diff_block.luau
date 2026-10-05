--!strict
-- Block `branch-changes.diff`: one file's diff, full pane, in Tern's own
-- `ui.diff` renderer. Opened by the list block through a
-- `tern-branch-changes://diff?…` link (see link.luau and window.luau).
-- Args: { root, kind, path, sha?, orig? } (see link.to_args).

local git = require("./git")
local link = require("./link")
local util = require("./util")

local ui = tern.ui

local M = {}

M.KV_PANES = "diff_panes" -- pane id -> link key, read by window.luau to focus an open diff
local DEBOUNCE_MS = 500

local KIND_LABEL: { [string]: string } = {
	staged = "staged",
	unstaged = "unstaged",
	untracked = "untracked",
	commit = "commit",
}

type DiffState = {
	target: link.DiffLink?,
	text: string?,
	err: string?,
	loading: boolean,
	gen: number,
	cx: BlockCx,
	debounce: TimerHandle?,
}

local open: { [number]: DiffState } = {}

local function alive(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

local function remember(pane: number, key: string)
	pcall(function()
		local map = tern.kv.get(M.KV_PANES)
		local live: { [string]: string } = {}
		for _, p in tern.pane.list() do
			local id = tostring(p.pane)
			if type(map) == "table" and type(map[id]) == "string" then
				live[id] = map[id]
			end
		end
		live[tostring(pane)] = key
		tern.kv.set(M.KV_PANES, live)
	end)
end

local function load(state: DiffState)
	local t = state.target
	if not t then
		return
	end
	state.gen += 1
	local gen = state.gen
	state.loading = true
	git.diff(t.root, { kind = t.kind, path = t.path, orig = t.orig, sha = t.sha }, function(text, err)
		if not alive(state.cx.pane) or gen ~= state.gen then
			return
		end
		state.loading, state.text, state.err = false, text, err
		state.cx:render()
	end)
end

local function heading(t: link.DiffLink): Node
	local dir, base = util.split_path(t.path)
	local spans: { Span } = { ui.span(base, "strong") }
	if dir ~= "" then
		table.insert(spans, ui.span("  " .. string.sub(dir, 1, -2), "muted"))
	end
	if t.orig then
		table.insert(spans, ui.span("  from " .. t.orig, "muted"))
	end
	return ui.text(spans)
end

local function chips(t: link.DiffLink): Node
	local badges: { Node } = { ui.badge(KIND_LABEL[t.kind] or t.kind, if t.kind == "commit" then "neutral" else "warning") }
	if t.sha then
		table.insert(badges, ui.badge(string.sub(t.sha, 1, 8), "neutral"))
	end
	return ui.row(badges)
end

local def: BlockDef<DiffState> = {
	init = function(cx, args, _saved)
		local target = link.from_args(args)
		local state: DiffState = {
			target = target,
			text = nil,
			err = if target then nil else "Missing diff arguments: root, kind, path",
			loading = false,
			gen = 0,
			cx = cx,
			debounce = nil,
		}
		if target then
			open[cx.pane] = state
			remember(cx.pane, link.key(target))
			load(state)
		end
		return state
	end,

	title = function(state)
		local t = state.target
		if not t then
			return "File diff"
		end
		local suffix = if t.sha then " @ " .. string.sub(t.sha, 1, 7) else " (" .. t.kind .. ")"
		return util.basename(t.path) .. suffix
	end,

	view = function(state, _cx)
		local main: { Node } = {}
		local t = state.target
		if t then
			table.insert(main, heading(t))
			table.insert(main, chips(t))
		end
		if state.err then
			table.insert(main, ui.text({ ui.span("Couldn't load diff: " .. state.err, "error") }))
		elseif state.text == nil then
			table.insert(main, ui.text({ ui.span("Loading diff…", "muted") }))
		elseif state.text == "" then
			table.insert(main, ui.text({ ui.span("No changes in this file now", "muted") }))
		elseif t then
			local d = ui.diff(state.text, t.path)
			local p: { [string]: any } = d.p or {}
			p.key = "diff"
			p.role = "branch-changes.diff-full"
			d.p = p
			table.insert(main, d)
		end
		local dock: { Node } = {}
		if state.loading and state.text ~= nil then
			table.insert(dock, ui.node("spinner", { style = "dots", label = { ui.span("Refreshing", "muted") } }))
		end
		table.insert(dock, ui.node("kbd", { keys = { "r" } }))
		table.insert(dock, ui.text({ ui.span("reload", "dim") }))
		if t and t.kind ~= "commit" then
			table.insert(dock, ui.node("kbd", { keys = { "e" } }))
			table.insert(dock, ui.text({ ui.span("edit file", "dim") }))
		end
		return { main = ui.col(main), dock = ui.col({ ui.row(dock) }) }
	end,

	key = function(state, key, cx)
		if key.ctrl or key.meta then
			return false
		end
		local t = state.target
		if key.name == "r" then
			load(state)
		elseif key.name == "e" and t then
			local abs = t.root .. "/" .. t.path
			if tern.fs.exists(abs) then
				cx:open(abs)
			else
				cx:toast("info", "Deleted in the worktree", t.path)
			end
		else
			return false
		end
		return true
	end,
}

-- Reloads open working-tree diffs after a shell command under their root.
function M.on_command(cwd: string?)
	for pane, state in open do
		local t = state.target
		if not alive(pane) then
			open[pane] = nil
		elseif t and t.kind ~= "commit" and util.under(cwd, t.root) then
			if state.debounce then
				state.debounce:cancel()
			end
			state.debounce = tern.timer(DEBOUNCE_MS, function()
				state.debounce = nil
				if alive(pane) then
					load(state)
					state.cx:render()
				end
			end)
		end
	end
end

function M.define()
	tern.block.define("diff", def)
end

return M
