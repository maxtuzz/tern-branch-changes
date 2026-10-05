--!strict
-- Window half: `plugin.branch-changes.open` ("Show branch changes") opens the
-- branch-changes block beside the focused pane for that pane's worktree, or
-- focuses the one already showing it. Other plugins (tern-worktrees) may run
-- the action by name; nothing here depends on them.

local util = require("./lib/util")

local KIND = "branch-changes.view"
local KV_PANES = "panes" -- written by host.luau: pane id -> worktree root

local function same_dir(a: string?, b: string?): boolean
	if a == nil or b == nil or a == "" or b == "" then
		return false
	end
	return (string.gsub(a, "/+$", "")) == (string.gsub(b, "/+$", ""))
end

local function known_roots(): { [string]: string }
	local ok, map = pcall(tern.kv.get, KV_PANES)
	return if ok and type(map) == "table" then map else {}
end

-- An open branch-changes block for `root` in this window, if any.
local function existing(cx: WindowCx, root: string): number?
	local roots = known_roots()
	for _, p in cx.session:panes() do
		if p.block == KIND and (same_dir(p.cwd, root) or same_dir(roots[tostring(p.pane)], root)) then
			return p.pane
		end
	end
	return nil
end

local function open_beside(cx: WindowCx, focused: number?, root: string)
	local found = existing(cx, root)
	if found then
		cx.layout:focus(found)
		return
	end
	local pane: number? = nil
	if focused then
		pane = cx.layout:split(focused, "right", { block = KIND, args = { root }, cwd = root })
	end
	if pane == nil then
		pane = cx:new_block(KIND, { root }, "beside")
	end
	if pane == nil then
		cx:toast("error", "Branch Changes isn't loaded on this host", "Run `tern plugin reload` and check `tern plugin list`.")
	end
end

tern.command({
	id = "open",
	title = "Show branch changes",
	icon = "git-branch",
	keys = { "ctrl+alt+shift+b" },
	run = function(cx)
		local focused = cx.session:focused()
		local info = if focused then cx.session:pane(focused) else nil
		if info and info.block == KIND then
			return -- already looking at it
		end
		local dir: string? = if info then info.cwd else nil
		if info and (dir == nil or dir == "") and info.path then
			-- A file block has no shell directory; use the file's folder.
			dir = if info.kind == "file" then string.match(info.path, "^(.*)/[^/]*$") else info.path
		end
		if dir == nil or dir == "" then
			cx:toast("info", "Show branch changes", "Focus a pane inside a git worktree first.")
			return
		end
		-- Resolve the worktree root here so an existing block is found by root.
		-- When git can't answer on this machine (a remote host), the block resolves it.
		tern.process.run({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, { timeout_ms = 3000 }, function(r, wcx)
			if wcx == nil then
				return
			end
			local root = if r.status == 0 then util.trim(r.stdout) else dir
			open_beside(wcx, focused, root)
		end)
	end,
})
