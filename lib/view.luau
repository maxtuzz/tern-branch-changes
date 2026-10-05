--!strict
-- Builds the block's view from its state. Node ids are spelled out here
-- (`main.<key>.<key>…`) because a list's `selected` prop names its item by id.

local parse = require("./parse")
local model = require("./model")
local util = require("./util")

local ui = tern.ui

local M = {}

-- Lists past 200 items virtualize and drop item actions; keep each list under that.
local CHUNK = 150

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

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

-- Right-hand value: "+n −n" then the status letter in its tone, as Source Control panels show it.
local function value(f: parse.FileEntry): { Span }
	local spans: { Span } = {}
	if f.add == nil and f.del == nil then
		if f.code ~= "?" then
			table.insert(spans, ui.span("binary", "muted"))
		end
	else
		if (f.add or 0) > 0 then
			table.insert(spans, ui.span("+" .. tostring(f.add), "ins num"))
		end
		if (f.del or 0) > 0 then
			table.insert(spans, ui.span(" −" .. tostring(f.del), "del num"))
		end
	end
	table.insert(spans, ui.span("  " .. f.code, "strong " .. (STATUS_TONE[f.code] or "muted")))
	return spans
end

-- A file row: file name as the label, its folder (and rename source) dim beside it,
-- the icon tinted by status. Open rows show the name strong; the diff sits under the row.
local function file_item(f: parse.FileEntry, open: boolean): { [string]: any }
	local dir, base = util.split_path(f.path)
	local detail: { Span } = {}
	if dir ~= "" then
		table.insert(detail, ui.span(string.sub(dir, 1, -2), "muted"))
	end
	if f.orig then
		table.insert(detail, ui.span((if dir ~= "" then "  " else "") .. "from " .. f.orig, "muted"))
	end
	return {
		label = { ui.span(base, if open then "strong" else "") },
		detail = if #detail > 0 then detail else nil,
		value = value(f),
		icon = "file",
		tone = STATUS_TONE[f.code] or "muted",
		title = STATUS_NAME[f.code] or f.code,
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

-- Files of one group as lists, split after every open file to show its diff inline.
-- `parent` is the id of the node these children go under.
local function file_nodes(
	state: model.State,
	parent: string,
	kind: string,
	group: parse.Group,
	sha: string?,
	ids: { [string]: string }
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
		for i, it in items do
			titles[i] = it.title
			it.title = nil
		end
		local listing = ui.list(items)
		local children: { Node } = listing.c or {}
		local selected: string? = nil
		for i, child in children do
			local idx = start + i - 1
			local row_id = item_rows[i]
			local item_id = list_id .. ".f" .. idx
			ids[item_id] = row_id
			with(child, { key = "f" .. idx, actions = { click = "file=" .. row_id, dblclick = "diff=" .. row_id }, title = titles[i] })
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
		table.insert(items, file_item(f, d ~= nil))
		table.insert(item_rows, row_id)
		if d then
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

local function badge(text: string, tone: string, key: string): Node
	return with(ui.badge(text, tone), { key = key })
end

-- Branch name as the title, status as chips, then the base picker and the worktree path.
local function header(state: model.State): { Node }
	local snap = state.snap
	local root = state.root or state.dir
	local name = util.basename(root)
	if not snap then
		return { with(ui.text({ ui.span(name, "strong") }), { key = "head" }) }
	end
	local st = snap.status
	local branch = st.head or ("detached at " .. string.sub(st.oid or "", 1, 8))
	local nodes: { Node } = {
		with(ui.text({ ui.span(branch, "strong"), ui.span("  " .. name, "muted") }), { key = "head" }),
	}

	local chips: { Node } = {}
	local unpushed = if snap.unpushed_known then st.ahead else snap.commits_total
	if unpushed > 0 then
		table.insert(chips, badge(unpushed .. " unpushed", "warning", "ahead"))
	end
	if not snap.unpushed_known and st.oid then
		table.insert(chips, badge("no upstream", "muted", "upstream"))
	end
	if st.behind > 0 then
		table.insert(chips, badge(st.behind .. " behind", "info", "behind"))
	end
	local dirty = st.staged.total + st.unstaged.total + st.untracked.total
	table.insert(chips, if dirty > 0 then badge(dirty .. " changed", "warning", "dirty") else badge("clean", "success", "dirty"))
	if snap.total then
		local t = snap.total
		local files = t.files .. (if t.files == 1 then " file" else " files")
		table.insert(chips, badge(string.format("%s  +%d −%d", files, t.add, t.del), "neutral", "total"))
	end
	table.insert(nodes, with(ui.row(chips), { key = "chips" }))

	if #snap.bases > 0 then
		local bases: { Node } = { ui.text({ ui.span("compared to", "muted") }) }
		for i, ref in snap.bases do
			local active = ref == snap.base
			table.insert(bases, with(ui.badge(ref, if active then "accent" else "neutral"), {
				key = "b" .. i,
				actions = { click = "base=" .. ref },
			}))
		end
		table.insert(nodes, with(ui.row(bases), { key = "bases" }))
	end
	table.insert(nodes, with(ui.text({ ui.span(root, "path muted") }), { key = "meta" }))
	return nodes
end

local function uncommitted(state: model.State, snap: any, ids: { [string]: string }): Node
	local id = "main.unc"
	local sections: { Node } = {}
	local dirty = 0
	for _, g in model.GROUPS do
		local group: parse.Group = snap.status[g.key]
		dirty += group.total
		if group.total > 0 then
			local sid = id .. "." .. g.key
			local head = { ui.span(g.title, "strong"), ui.span("  " .. group.total, "muted num") }
			table.insert(sections, with(ui.section(head, file_nodes(state, sid, g.kind, group, nil, ids)), {
				key = g.key,
				collapsible = true,
			}))
		end
	end
	if dirty == 0 then
		table.insert(sections, with(ui.text({ ui.span("No uncommitted changes", "muted") }), { key = "clean" }))
	end
	local head = { ui.span("Changes", "strong"), ui.span("  " .. dirty, "muted num") }
	return with(ui.card(head, sections), { key = "unc", collapsible = true, role = "branch-changes.uncommitted" })
end

local function commit_card(state: model.State, c: parse.Commit, unpushed: boolean, ids: { [string]: string }): Node
	local key = "c" .. c.sha
	local id = "main.commits." .. key
	local open = state.open[c.sha] == true
	-- Card heads take spans only, so the sha and the unpushed tag are styled spans, not badges.
	local head: { Span } = {
		ui.span(c.subject, "strong"),
		ui.span("   "),
		ui.span(c.short, "code"),
		ui.span("   " .. c.author .. " · " .. util.age(os.time() - c.time), "muted"),
	}
	if unpushed then
		table.insert(head, ui.span("   unpushed", "warning"))
	end
	local children: { Node } = {}
	local files = state.files[c.sha]
	if files and files.err then
		children = { ui.text({ ui.span("Couldn't load files: " .. files.err, "error") }) }
	elseif files and files.group then
		children = file_nodes(state, id, "commit", files.group, c.sha, ids)
		if #children == 0 then
			children = { ui.text({ ui.span("No file changes", "muted") }) }
		end
	else
		children = { ui.text({ ui.span("Loading files…", "muted") }) }
	end
	local selected = state.sel == model.commit_row_id(c.sha)
	return with(ui.card(head, children), {
		key = key,
		collapsible = true,
		collapsed = not open,
		tone = if selected then "accent" else nil,
		role = "branch-changes.commit",
	})
end

local function commits(state: model.State, snap: any, ids: { [string]: string }): Node
	local cards: { Node } = {}
	for _, c in snap.commits do
		local unpushed = if snap.unpushed_known then snap.unpushed[c.sha] == true else true
		table.insert(cards, commit_card(state, c, unpushed, ids))
	end
	if snap.error then
		table.insert(cards, with(ui.text({ ui.span(snap.error, "warning") }), { key = "err" }))
	elseif #snap.commits == 0 then
		local note = if snap.base then "No commits ahead of " .. snap.base else "No commits on this branch yet"
		table.insert(cards, with(ui.text({ ui.span(note, "muted") }), { key = "none" }))
	end
	local hidden = snap.commits_total - #snap.commits
	if hidden > 0 then
		table.insert(cards, with(ui.text({ ui.span(hidden .. " older commits hidden (max_commits)", "muted") }), { key = "more" }))
	end
	local head: { Span } = { ui.span("Commits", "strong"), ui.span("  " .. snap.commits_total, "muted num") }
	if snap.base then
		table.insert(head, ui.span("  since " .. snap.base, "muted"))
	end
	return with(ui.section(head, cards), { key = "commits", collapsible = true })
end

local HINTS = { { "enter", "inline diff" }, { "o", "open diff" }, { "e", "edit" }, { "r", "refresh" }, { "b", "base" } }

-- A quiet footer: refresh state on the left, a few keycaps after it.
local function dock(state: model.State): Node
	local children: { Node } = {}
	if state.loading then
		table.insert(children, ui.node("spinner", { style = "dots", label = { ui.span("Refreshing", "muted") } }))
	elseif state.refreshed_at then
		table.insert(children, ui.text({ ui.span("Updated " .. os.date("%H:%M", state.refreshed_at), "muted") }))
	end
	for _, h in HINTS do
		table.insert(children, ui.node("kbd", { keys = { h[1] } }))
		table.insert(children, ui.text({ ui.span(h[2], "dim") }))
	end
	return ui.col({ ui.row(children) })
end

-- The view, and a map from list item node ids to row ids for `select` events.
function M.build(state: model.State): (BlockView, { [string]: string })
	local ids: { [string]: string } = {}
	local main: { Node } = header(state)
	for i, w in state.warnings do
		table.insert(main, with(ui.text({ ui.span(w, "warning") }), { key = "w" .. i }))
	end
	local snap = state.snap
	if state.error then
		table.insert(main, with(ui.text({ ui.span(state.error, "error") }), { key = "error" }))
	end
	if snap then
		table.insert(main, uncommitted(state, snap, ids))
		table.insert(main, commits(state, snap, ids))
	elseif not state.error then
		table.insert(main, with(ui.text({ ui.span("Loading…", "muted") }), { key = "loading" }))
	end
	return { main = with(ui.col(main), { role = "branch-changes.main" }), dock = dock(state) }, ids
end

return M
