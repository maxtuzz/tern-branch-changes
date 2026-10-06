--!strict
-- Builds the block's view from its state. Node ids are spelled out here
-- (`main.<key>.<key>…`) because a list's `selected` prop names its item by id.
--
-- The layout follows the pane's width (`cx.cols`), so one block serves both
-- places: a narrow sidebar (the design target: ~250-320px, around 36-45 cells)
-- and a full-width pane, where the file list keeps the left column and the
-- selected diff becomes the hero on the right.

local parse = require("./parse")
local model = require("./model")
local util = require("./util")
local link = require("./link")

local ui = tern.ui

local M = {}

-- Lists past 200 items virtualize and drop item actions; keep each list under that.
local CHUNK = 150

-- Width thresholds in cells. Below WIDE the view is one column; at or above it
-- the diff moves into its own column beside the list.
M.WIDE = 100
local ROOMY = 56

-- Status letter -> tone, shared by the row's icon tint and its status letter.
local STATUS_TONE: { [string]: string } = {
	A = "success",
	M = "warning",
	D = "error",
	R = "info",
	C = "info",
	T = "warning",
	U = "error",
	["?"] = "muted",
}

local STATUS_NAME: { [string]: string } = {
	A = "added",
	M = "modified",
	D = "deleted",
	R = "renamed",
	C = "copied",
	T = "type changed",
	U = "conflict",
	["?"] = "untracked",
}

M.STATUS_TONE = STATUS_TONE

export type Layout = {
	cols: number,
	compact: boolean, -- sidebar widths: shortest labels, fewest hints
	wide: boolean, -- the diff gets its own column
}

function M.layout(cols: number): Layout
	local c = if cols > 0 then cols else 80
	return { cols = c, compact = c < ROOMY, wide = c >= M.WIDE }
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

-- Clips a *text* node to its first line. `max.h` clips with overflow: hidden,
-- so it keeps a long branch name or path on one row. It must not go on a row
-- holding badges: a pill is taller than a line of text, and the clip would cut
-- its top and bottom edges off.
local function one_line(node: Node): Node
	return with(node, { max = { h = "1lines" } })
end

-- Keeps a node at its content width. A `row` does not wrap, but its children
-- shrink, and a squeezed text node wraps its own words ("refres/h"). Chips and
-- keycaps therefore refuse to shrink, and the view spends width by dropping
-- whole items rather than by letting any of them be squeezed.
local function fixed(node: Node): Node
	return with(node, { shrink = 0 })
end

-- Right-hand value: "+n -n" then the status letter in its tone, as Source
-- Control panels show it. The counts are toned, not marked with the `ins`/`del`
-- span tokens: those mean "text added/removed in a diff", so `del` strikes the
-- number through.
-- `↺` before the counts: a link span, because a span can carry an `href` but
-- not an `actions`, and the row's own click would win over it anyway.
local REVERT = "↺"

local function value(f: parse.FileEntry, lay: Layout, row_id: string?, armed: boolean): { Span }
	local spans: { Span } = {}
	if row_id then
		table.insert(spans, ui.link(REVERT, link.discard_url(row_id), if armed then "error strong" else "muted"))
		table.insert(spans, ui.span(" "))
	end
	if f.add == nil and f.del == nil then
		if f.code ~= "?" then
			table.insert(spans, ui.span(if lay.compact then "bin" else "binary", "muted"))
		end
	else
		if (f.add or 0) > 0 then
			table.insert(spans, ui.span("+" .. tostring(f.add), "success num"))
		end
		if (f.del or 0) > 0 then
			table.insert(spans, ui.span((if #spans > 0 then " -" else "-") .. tostring(f.del), "error num"))
		end
	end
	table.insert(spans, ui.span((if #spans > 0 then " " else "") .. f.code, "strong " .. (STATUS_TONE[f.code] or "muted")))
	return spans
end

-- A file row: file name as the label, its folder (and rename source) dim beside
-- it, the icon tinted by status. A file an agent touched since the last refresh
-- carries an accent "just now", so live work stands out in the list.
local function file_item(state: model.State, f: parse.FileEntry, row_id: string, open: boolean, lay: Layout, kind: string): { [string]: any }
	local dir, base = util.split_path(f.path)
	local detail: { Span } = {}
	if dir ~= "" then
		table.insert(detail, ui.span(string.sub(dir, 1, -2), "muted"))
	end
	if f.orig and not lay.compact then
		table.insert(detail, ui.span((if dir ~= "" then "  " else "") .. "from " .. f.orig, "muted"))
	end
	local since = model.fresh_age(state, row_id)
	if since then
		local when = if since < 60 then "just now" else util.age(since) .. " ago"
		table.insert(detail, ui.span((if #detail > 0 then "  " else "") .. when, "accent"))
	end
	local title = STATUS_NAME[f.code] or f.code
	-- Armed for discard: the row says so plainly, since the next press is final.
	if state.armed == row_id then
		local gone = if kind == "untracked" then "delete" else "discard"
		return {
			label = { ui.span(base, "strong") },
			-- Neutral wording: you may have armed this with the key or the ↺.
			detail = { ui.span("again to " .. gone, "error strong") },
			value = value(f, lay, row_id, true),
			icon = "revert",
			tone = "error",
			title = "Press x or ⌘-click ↺ again to " .. gone .. " " .. f.path .. ", or escape to leave it alone",
		}
	end
	local can_discard = kind ~= "commit"
	return {
		label = { ui.span(base, if open then "strong" else "") },
		detail = if #detail > 0 then detail else nil,
		value = value(f, lay, if can_discard then row_id else nil, false),
		icon = "file",
		tone = STATUS_TONE[f.code] or "muted",
		title = f.path .. " · " .. title .. (if can_discard then " · ⌘-click ↺ or press x to discard" else ""),
	}
end

local function diff_node(d: model.DiffState, path: string): Node
	if d.err then
		return ui.text({ ui.span("Couldn't load diff: " .. d.err, "error") })
	elseif d.text == nil then
		return ui.text({ ui.span("Loading diff…", "muted") })
	elseif d.text == "" then
		return ui.text({ ui.span("No textual changes", "muted") })
	end
	return ui.diff(d.text, path)
end

-- Files of one group as lists, split after every open file to show its diff
-- inline. In the wide layout the diff lives in the hero column instead, so the
-- rows stay unbroken. `parent` is the id of the node these children go under.
local function file_nodes(
	state: model.State,
	parent: string,
	kind: string,
	group: parse.Group,
	sha: string?,
	ids: { [string]: string },
	lay: Layout
): { Node }
	local out: { Node } = {}
	local items: { { [string]: any } } = {}
	local item_rows: { string } = {}
	local start = 1

	local function flush(stop: number)
		if #items == 0 then
			return
		end
		local key = "l" .. start
		local list_id = parent .. "." .. key
		-- `ui.list` takes only label/detail/value/icon/tone; the tooltip goes on the built item.
		local titles: { string? } = {}
		local hints: { { string }? } = {}
		for i, it in items do
			titles[i], hints[i] = it.title, it.hint
			it.title, it.hint = nil, nil
		end
		local listing = ui.list(items)
		local children: { Node } = listing.c or {}
		local selected: string? = nil
		for i, child in children do
			local idx = start + i - 1
			local row_id = item_rows[i]
			local item_id = list_id .. ".f" .. idx
			ids[item_id] = row_id
			with(child, {
				key = "f" .. idx,
				actions = { click = "file=" .. row_id, dblclick = "diff=" .. row_id },
				title = titles[i],
				hint = hints[i],
			})
			if row_id == state.sel then
				selected = item_id
			end
		end
		with(listing, { key = key, selected = selected })
		table.insert(out, listing)
		items, item_rows, start = {}, {}, stop + 1
	end

	for idx, f in group.files do
		local row_id = model.file_row_id(kind, f.path, sha)
		local d = state.diffs[row_id]
		table.insert(items, file_item(state, f, row_id, d ~= nil, lay, kind))
		table.insert(item_rows, row_id)
		if d and not lay.wide then
			flush(idx)
			table.insert(out, with(diff_node(d, f.path), { key = "d" .. idx, role = "branch-changes.diff" }))
		elseif #items >= CHUNK then
			flush(idx)
		end
	end
	flush(#group.files)
	local hidden = group.total - #group.files
	if hidden > 0 then
		table.insert(out, with(ui.text({ ui.span(hidden .. " more files hidden (max_files)", "muted") }), { key = "more" }))
	end
	return out
end

local function badge(text: string, tone: string, key: string, title: string?): Node
	return fixed(with(ui.badge(text, tone), { key = key, title = title }))
end

-- Branch line, one clipped row of status chips, and the base as a single chip
-- that cycles on click. Nothing here is allowed to wrap onto a second row.
local function header(state: model.State, lay: Layout): { Node }
	local snap = state.snap
	local root = state.root or state.dir
	local name = util.basename(root)
	if not snap then
		return { one_line(with(ui.text({ ui.span(name, "strong") }), { key = "head" })) }
	end
	local st = snap.status
	local branch = st.head or ("detached at " .. string.sub(st.oid or "", 1, 8))

	local title: { Node } = {
		one_line(with(ui.text({ ui.span(branch, "strong") }), { key = "branch", grow = 1, shrink = 1, title = root })),
	}
	if snap.base then
		local label = if lay.compact then (string.gsub(snap.base, "^origin/", "")) else snap.base
		local more = #snap.bases > 1
		table.insert(title, with(ui.badge(label, "accent"), {
			key = "base",
			shrink = 0,
			actions = { click = "base-next" },
			title = if more then "Compared to " .. snap.base .. " · click or press b for the next base" else "Compared to " .. snap.base,
		}))
	end
	local nodes: { Node } = { with(ui.row(title), { key = "head" }) }

	local chips: { Node } = {}
	local unpushed = if snap.unpushed_known then st.ahead else snap.commits_total
	if unpushed > 0 then
		local word = if snap.unpushed_known then " not pushed" else " on this branch (no upstream)"
		table.insert(chips, badge("↑" .. unpushed, "warning", "ahead", unpushed .. " commit(s)" .. word))
	end
	if st.behind > 0 then
		table.insert(chips, badge("↓" .. st.behind, "info", "behind", st.behind .. " commit(s) behind " .. (st.upstream or "upstream")))
	end
	local dirty = st.staged.total + st.unstaged.total + st.untracked.total
	if dirty > 0 then
		table.insert(chips, badge(dirty .. " changed", "warning", "dirty", dirty .. " uncommitted file(s)"))
	else
		table.insert(chips, badge("clean", "success", "dirty", "No uncommitted changes"))
	end
	if snap.total and not (lay.compact and snap.total.files == 0) then
		local t = snap.total
		local text = string.format("+%d -%d", t.add, t.del)
		if not lay.compact then
			text = t.files .. (if t.files == 1 then " file  " else " files  ") .. text
		end
		table.insert(chips, badge(text, "neutral", "total", string.format("%d file(s), +%d -%d since %s", t.files, t.add, t.del, snap.base or "the merge base")))
	end
	table.insert(nodes, with(ui.row(chips), { key = "chips" }))

	if lay.wide then
		table.insert(nodes, one_line(with(ui.text({ ui.span(root, "path muted") }), { key = "meta" })))
	end
	return nodes
end

local function uncommitted(state: model.State, snap: any, ids: { [string]: string }, lay: Layout, prefix: string): Node
	local id = prefix .. ".unc"
	local sections: { Node } = {}
	local dirty = 0
	for _, g in model.GROUPS do
		local group: parse.Group = snap.status[g.key]
		dirty += group.total
		if group.total > 0 then
			local sid = id .. "." .. g.key
			local head = { ui.span(g.title, "strong"), ui.span("  " .. group.total, "muted num") }
			table.insert(sections, with(ui.section(head, file_nodes(state, sid, g.kind, group, nil, ids, lay)), {
				key = g.key,
				collapsible = true,
			}))
		end
	end
	if dirty == 0 then
		table.insert(sections, with(ui.text({ ui.span("No uncommitted changes", "muted") }), { key = "clean" }))
	end
	local head = { ui.span("Changes", "strong"), ui.span("  " .. dirty, "muted num") }
	-- A section, like Commits: no card ring, so the two groups read as one list.
	return with(ui.section(head, sections), { key = "unc", collapsible = true, role = "branch-changes.uncommitted" })
end

-- One line per commit: subject as the label (it truncates with an ellipsis),
-- author only when it isn't this repo's user, sha and age right-aligned.
local function commit_item(state: model.State, c: parse.Commit, unpushed: boolean, lay: Layout): { [string]: any }
	local detail: { Span } = {}
	if c.author ~= state.me and not lay.compact then
		table.insert(detail, ui.span(c.author, "muted"))
	end
	-- An item's value reserves up to 40% of the row, and that width comes out of
	-- the subject. `%h` grows with the repo, so the sha is cut back to 7 and
	-- waits in the tooltip until the pane is wide enough to spend room on it.
	local sha = string.sub(c.short, 1, 7)
	local v: { Span } = {}
	if lay.wide then
		table.insert(v, ui.span(sha .. " ", "code"))
	end
	table.insert(v, ui.span(util.age(os.time() - c.time), "muted"))
	local title = c.subject .. "\n" .. sha .. " · " .. c.author .. (if unpushed then " · not pushed" else "")
	return {
		label = { ui.span(c.subject, if state.open[c.sha] then "strong" else "") },
		detail = if #detail > 0 then detail else nil,
		value = v,
		-- One icon, open or closed: a name Tern doesn't know draws nothing, and the
		-- empty slot shifts the whole row left. `commit` and `chev-r` exist; there
		-- is no down chevron, so expansion shows in the label and the files below.
		icon = "commit",
		tone = if unpushed then "warning" else "muted",
		title = title,
	}
end

-- The commit list: plain rows, no card borders. An expanded commit's files
-- follow its row, using the same file rows as the Changes section.
local function commits(state: model.State, snap: any, ids: { [string]: string }, lay: Layout, prefix: string): Node
	local parent = prefix .. ".commits"
	local out: { Node } = {}
	local items: { { [string]: any } } = {}
	local shas: { string } = {}
	local start = 1

	local function flush(stop: number)
		if #items == 0 then
			return
		end
		local key = "l" .. start
		local list_id = parent .. "." .. key
		local titles: { string? } = {}
		for i, it in items do
			titles[i] = it.title
			it.title = nil
		end
		local listing = ui.list(items)
		local children: { Node } = listing.c or {}
		local selected: string? = nil
		for i, child in children do
			local sha = shas[i]
			local item_id = list_id .. ".c" .. sha
			ids[item_id] = model.commit_row_id(sha)
			with(child, { key = "c" .. sha, actions = { click = "commit=" .. sha }, title = titles[i] })
			if model.commit_row_id(sha) == state.sel then
				selected = item_id
			end
		end
		with(listing, { key = key, selected = selected })
		table.insert(out, listing)
		items, shas, start = {}, {}, stop + 1
	end

	for idx, c in snap.commits do
		local unpushed = if snap.unpushed_known then snap.unpushed[c.sha] == true else true
		table.insert(items, commit_item(state, c, unpushed, lay))
		table.insert(shas, c.sha)
		if state.open[c.sha] then
			flush(idx)
			local files = state.files[c.sha]
			local children: { Node }
			if files and files.err then
				children = { ui.text({ ui.span("Couldn't load files: " .. files.err, "error") }) }
			elseif files and files.group then
				children = file_nodes(state, parent .. ".f" .. c.sha, "commit", files.group, c.sha, ids, lay)
				if #children == 0 then
					children = { ui.text({ ui.span("No file changes", "muted") }) }
				end
			else
				children = { ui.text({ ui.span("Loading files…", "muted") }) }
			end
			table.insert(out, with(ui.col(children), { key = "f" .. c.sha, role = "branch-changes.commit-files" }))
		elseif #items >= CHUNK then
			flush(idx)
		end
	end
	flush(#snap.commits)

	if snap.error then
		table.insert(out, with(ui.text({ ui.span(snap.error, "warning") }), { key = "err" }))
	elseif #snap.commits == 0 then
		local note = if snap.base then "No commits ahead of " .. snap.base else "No commits on this branch yet"
		table.insert(out, with(ui.text({ ui.span(note, "muted") }), { key = "none" }))
	end
	local hidden = snap.commits_total - #snap.commits
	if hidden > 0 then
		table.insert(out, with(ui.text({ ui.span(hidden .. " older commits hidden (max_commits)", "muted") }), { key = "more" }))
	end
	local head: { Span } = { ui.span("Commits", "strong"), ui.span("  " .. snap.commits_total, "muted num") }
	if snap.base and not lay.compact then
		table.insert(head, ui.span("  since " .. snap.base, "muted"))
	end
	return with(ui.section(head, out), { key = "commits", collapsible = true })
end

-- Discarding takes two presses, and the chip says which one you are on.
local function discard_chip(state: model.State, row: model.Row): Node
	if not model.discardable(row) then
		return with(ui.text({}), { key = "discard", hidden = true })
	end
	local armed = state.armed == row.id
	return with(ui.badge(if armed then "confirm discard" else "discard", if armed then "error" else "neutral"), {
		key = "discard",
		shrink = 0,
		actions = { click = "discard=" .. row.id },
		title = if armed then "Click again to throw these changes away" else "Throw away this file's uncommitted changes (x)",
	})
end

-- The hero column of the wide layout: the selected file's diff, full height.
local function hero(state: model.State): Node
	local children: { Node } = {}
	local row = model.find(model.rows(state), state.sel)
	local target = if row then row.target else nil
	if not target then
		table.insert(children, with(ui.text({ ui.span("Select a file to see its diff here", "muted") }), { key = "empty" }))
	else
		local dir, base = util.split_path(target.path)
		local head: { Span } = { ui.span(base, "strong") }
		if dir ~= "" then
			table.insert(head, ui.span("  " .. string.sub(dir, 1, -2), "muted"))
		end
		if target.sha then
			table.insert(head, ui.span("  at " .. string.sub(target.sha, 1, 7), "muted"))
		end
		table.insert(children, with(ui.row({
			one_line(with(ui.text(head), { key = "t", grow = 1, shrink = 1 })),
			with(ui.badge("open in its own pane", "neutral"), {
				key = "pop",
				shrink = 0,
				actions = { click = "diff=" .. (row :: model.Row).id },
				title = "Open this diff in a File diff block (o)",
			}),
			discard_chip(state, row :: model.Row),
		}), { key = "head" }))
		local d = state.diffs[(row :: model.Row).id]
		if d then
			table.insert(children, with(diff_node(d, target.path), { key = "diff", role = "branch-changes.diff" }))
		else
			table.insert(children, with(ui.text({ ui.span("Press enter or click the row to load this diff", "muted") }), { key = "hint" }))
		end
	end
	return with(ui.col(children), { key = "hero", role = "branch-changes.hero", grow = 1, basis = 0.58 })
end

local ALL_HINTS = {
	{ "enter", "diff" },
	{ "o", "open" },
	{ "x", "discard" },
	{ "e", "edit" },
	{ "r", "refresh" },
	{ "b", "base" },
	{ "f", "full view" },
}

-- A quiet footer. Hints are added only while they fit the pane's width, so the
-- strip never wraps a label mid-word; the row is clipped to one line as well.
local function dock(state: model.State, lay: Layout): Node
	local children: { Node } = {}
	local used = 0
	if state.loading then
		table.insert(children, fixed(ui.node("spinner", { style = "dots", label = { ui.span("Refreshing", "muted") } })))
		used += 12
	elseif state.refreshed_at then
		-- A live timer, so a sidebar left open shows how stale its picture is.
		table.insert(children, fixed(ui.node("elapsed", { age = (os.time() - state.refreshed_at) * 1000, format = "short" })))
		table.insert(children, fixed(ui.text({ ui.span("ago", "muted") })))
		used += 10
	end
	for _, h in ALL_HINTS do
		local cost = #h[1] + #h[2] + 4
		if used + cost > lay.cols - 2 then
			break
		end
		used += cost
		table.insert(children, fixed(ui.node("kbd", { keys = { h[1] } })))
		table.insert(children, fixed(ui.text({ ui.span(h[2], "dim") })))
	end
	return ui.col({ ui.row(children) })
end

-- The view, and a map from list item node ids to row ids for `select` events.
function M.build(state: model.State, cols: number?): (BlockView, { [string]: string })
	local lay = M.layout(cols or 80)
	local ids: { [string]: string } = {}
	-- Node ids are spelled out, so they have to follow the layout: in the wide
	-- view the lists sit one level deeper, under the split's left column.
	local wide = lay.wide and state.snap ~= nil
	local prefix = if wide then "main.split.list" else "main"
	local main: { Node } = header(state, lay)
	for i, w in state.warnings do
		table.insert(main, with(ui.text({ ui.span(w, "warning") }), { key = "w" .. i }))
	end
	if state.hint and not lay.compact then
		table.insert(main, one_line(with(ui.text({ ui.span(state.hint, "muted") }), { key = "hint" })))
	end
	local snap = state.snap
	if state.error then
		table.insert(main, with(ui.text({ ui.span(state.error, "error") }), { key = "error" }))
	end
	if snap then
		table.insert(main, uncommitted(state, snap, ids, lay, prefix))
		table.insert(main, commits(state, snap, ids, lay, prefix))
	elseif not state.error then
		table.insert(main, with(ui.text({ ui.span("Loading…", "muted") }), { key = "loading" }))
	end

	-- The region root is the region itself: Tern draws its children and takes its
	-- `role`, so the split has to be a child, not the root.
	local root: Node
	if wide then
		root = ui.col({
			with(ui.row({
				with(ui.col(main), { key = "list", grow = 1, shrink = 1, basis = 0.36, role = "branch-changes.list" }),
				hero(state),
			}), { key = "split", role = "branch-changes.split" }),
		})
	else
		root = ui.col(main)
	end
	return { main = with(root, { role = "branch-changes.main" }), dock = dock(state, lay) }, ids
end

return M
