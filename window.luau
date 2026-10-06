--!strict
-- Window half: two commands and the plugin's link route.
--   `plugin.branch-changes.open` opens the sidebar block beside the focused
--   pane for that pane's worktree, or focuses the one already showing it;
--   `plugin.branch-changes.open_full` opens the same block in its own tab,
--   where it lays out full width with the diff beside the list.
-- Other plugins (tern-worktrees) may run either action by name; nothing here
-- depends on them.

local util = require("./lib/util")
local link = require("./lib/link")

local KIND = "branch-changes.view"
local KV_PANES = "panes" -- written by host.luau: pane id -> worktree root
local DIFF_KIND = "branch-changes.diff"
local KV_DIFF_PANES = "diff_panes" -- written by lib/diff_block.luau: pane id -> link key

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

-- The same block in its own tab: the pane is wide, so the view lays itself out
-- with the file list on the left and the selected diff on the right.
local function open_full(cx: WindowCx, root: string)
	local pane = cx.layout:new_tab({ block = KIND, args = { root }, cwd = root })
	if pane == nil then
		cx:toast("error", "Branch Changes isn't loaded on this host", "Run `tern plugin reload` and check `tern plugin list`.")
	end
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

-- The directory to show changes for: the focused pane's, or a file block's folder.
local function focused_dir(cx: WindowCx): (string?, number?, PaneInfo?)
	local focused = cx.session:focused()
	local info = if focused then cx.session:pane(focused) else nil
	local dir: string? = if info then info.cwd else nil
	if info and (dir == nil or dir == "") and info.path then
		-- A file block has no shell directory; use the file's folder.
		dir = if info.kind == "file" then string.match(info.path, "^(.*)/[^/]*$") else info.path
	end
	return dir, focused, info
end

-- Resolves `dir`'s worktree root, then hands it to `use`. When git can't answer
-- on this machine (a remote host), the block resolves the root itself.
local function with_root(cx: WindowCx, title: string, use: (WindowCx, number?, string) -> ())
	local dir, focused = focused_dir(cx)
	if dir == nil or dir == "" then
		cx:toast("info", title, "Focus a pane inside a git worktree first.")
		return
	end
	local at: string = dir
	tern.process.run({ "git", "-C", at, "rev-parse", "--show-toplevel" }, { timeout_ms = 3000 }, function(r, wcx)
		if wcx == nil then
			return
		end
		use(wcx, focused, if r.status == 0 then util.trim(r.stdout) else at)
	end)
end

tern.command({
	id = "open",
	title = "Show branch changes",
	icon = "git-branch",
	keys = { "ctrl+alt+shift+b" },
	run = function(cx)
		local _, _, info = focused_dir(cx)
		if info and info.block == KIND then
			return -- already looking at it
		end
		with_root(cx, "Show branch changes", open_beside)
	end,
})

tern.command({
	id = "open_full",
	title = "Branch changes (full view)",
	icon = "git-branch",
	run = function(cx)
		with_root(cx, "Branch changes (full view)", function(wcx, _focused, root)
			open_full(wcx, root)
		end)
	end,
})

-- `tern-branch-changes://diff?…`, followed by the list block's `cx:open`:
-- focus the diff block already showing that file, else open one beside.
tern.route.link(function(req, cx)
	-- `f` in the block: the same worktree, full width in a new tab.
	local root = link.decode_view(req.url)
	if root then
		open_full(cx, root)
		return { handled = true }
	end
	local target = link.decode(req.url)
	if target == nil then
		return nil
	end
	local key = link.key(target)
	local ok, map = pcall(tern.kv.get, KV_DIFF_PANES)
	local known: { [string]: string } = if ok and type(map) == "table" then map else {}
	for _, p in cx.session:panes() do
		if p.block == DIFF_KIND and known[tostring(p.pane)] == key then
			cx.layout:focus(p.pane)
			return { handled = true }
		end
	end
	return { block = DIFF_KIND, args = link.to_args(target) }
end)
