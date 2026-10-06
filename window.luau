--!strict
-- Window half: two commands and the plugin's link route.
--   `plugin.branch-changes.open` opens the sidebar block beside the focused
--   pane for that pane's worktree, or focuses the one already showing it;
--   `plugin.branch-changes.open_full` (and `f` in the block) zooms that same
--   block, which makes it wide enough to lay out with the diff beside the list.
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

-- Shows the block for `root`: the one already open, else a new split beside the
-- focused pane. There is only ever one per worktree, so the full view is the
-- same pane zoomed, not a second copy with its own selection and open diffs.
local function open_beside(cx: WindowCx, focused: number?, root: string): number?
	local found = existing(cx, root)
	if found then
		cx.layout:focus(found)
		return found
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
	return pane
end

-- The full view is Tern's own zoom: the pane fills its tab, so the block sees a
-- wide `cx.cols` and lays out with the diff beside the list. `toggle` is what
-- `f` does, so pressing it again puts the pane back.
local function zoom(cx: WindowCx, pane: number, toggle: boolean)
	cx.layout:focus(pane)
	local tab = cx.session:tab_of(pane)
	local layout = if tab then cx.session:layout(tab) else nil
	local zoomed = layout ~= nil and layout.zoomed == true
	if toggle or not zoomed then
		cx:command("zoom")
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
		with_root(cx, "Branch changes (full view)", function(wcx, focused, root)
			local pane = open_beside(wcx, focused, root)
			if pane then
				zoom(wcx, pane, false)
			end
		end)
	end,
})

-- Width share of every tiled pane in `tree`, as a fraction of the tab.
local function shares(tree: any, width: number, out: { [number]: number })
	if tree == nil then
		return
	end
	if tree.pane then
		out[tree.pane] = width
		return
	end
	local ratio = if type(tree.ratio) == "number" then tree.ratio else 0.5
	local first = if tree.split == "right" then width * ratio else width
	local second = if tree.split == "right" then width * (1 - ratio) else width
	shares(tree[1], first, out)
	shares(tree[2], second, out)
end

-- The roomiest pane that isn't one of this plugin's own blocks. Splitting the
-- block the link came from would halve a sidebar, which leaves the diff too
-- narrow to read; the main editor or shell is the better neighbour.
local function widest_other(cx: WindowCx, from: number?): number?
	local tab = if from then cx.session:tab_of(from) else nil
	local layout = if tab then cx.session:layout(tab) else nil
	if layout == nil then
		return nil
	end
	local width: { [number]: number } = {}
	shares(layout.root, 1, width)
	local best: number? = nil
	local best_width = 0
	for pane, w in width do
		local info = cx.session:pane(pane)
		local mine = info ~= nil and (info.block == KIND or info.block == DIFF_KIND)
		if not mine and w > best_width then
			best, best_width = pane, w
		end
	end
	return best
end

-- Opens a diff block where there is room for it: beside the roomiest other
-- pane, else in its own tab rather than slicing the sidebar in half.
local function open_diff(cx: WindowCx, from: number?, target: link.DiffLink)
	local launch = { block = DIFF_KIND, args = link.to_args(target), cwd = target.root }
	local neighbour = widest_other(cx, from)
	local pane = if neighbour then cx.layout:split(neighbour, "right", launch) else nil
	if pane == nil then
		pane = cx.layout:new_tab(launch)
	end
	if pane == nil then
		cx:toast("error", "Branch Changes isn't loaded on this host", "Run `tern plugin reload` and check `tern plugin list`.")
	end
end

-- `tern-branch-changes://diff?…`, followed by the list block's `cx:open`:
-- focus the diff block already showing that file, else open one where it fits.
tern.route.link(function(req, cx)
	-- `f` in the block: zoom this pane, or put it back when it is already zoomed.
	local root = link.decode_view(req.url)
	if root then
		local pane = req.pane or existing(cx, root)
		if pane then
			zoom(cx, pane, true)
		end
		return { handled = true }
	end
	-- `e` or the edit chip in a diff block: put the file in that pane's place,
	-- at the line the diff starts on. `cx.docs` is desktop-only, so a plain open
	-- stands in for it elsewhere.
	local path, line = link.decode_edit(req.url)
	if path then
		if req.pane then
			cx.layout:focus(req.pane)
		end
		local ok = pcall(function()
			cx.docs:open(path, { how = "replace", line = line })
		end)
		if not ok then
			cx:open(path, "replace")
		end
		return { handled = true }
	end
	-- The ↺ in a file row. Spans can only carry links, so the window hands the
	-- action back to the block's own `event` with the row it named.
	local row = link.decode_discard(req.url)
	if row then
		if req.pane then
			cx.session:event(req.pane, { ev = "action", act = "discard", value = row })
		end
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
	open_diff(cx, req.pane, target)
	return { handled = true }
end)
