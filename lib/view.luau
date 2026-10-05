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

local CODE_STYLE: { [string]: string } = {
	A = "success",
	M = "warning",
	D = "error",
	R = "info",
	C = "info",
	T = "warning",
	U = "error strong",
	["?"] = "muted",
}

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function counts(f: parse.FileEntry): { Span }
	if f.add == nil and f.del == nil then
		return if f.code == "?" then {} else { ui.span("bin", "muted") }
	end
	local spans: { Span } = {}
	if (f.add or 0) > 0 then
		table.insert(spans, ui.span("+" .. tostring(f.add), "ins num"))
	end
	if (f.del or 0) > 0 then
		table.insert(spans, ui.span(" −" .. tostring(f.del), "del num"))
	end
	return spans
end

local function file_item(f: parse.FileEntry, open: boolean): { [string]: any }
	local dir, base = util.split_path(f.path)
	local label: { Span } = {
		ui.span(if open then "▾ " else "▸ ", "muted"),
		ui.span(f.code .. " ", CODE_STYLE[f.code] or "muted"),
		ui.span(dir, "muted"),
		ui.span(base, if open then "strong" else ""),
	}
	return {
		label = label,
		detail = if f.orig then { ui.span("← " .. f.orig, "muted") } else nil,
		value = counts(f),
	}
end

local function diff_node(d: model.DiffState, path: string): Node
	if d.err then
		return ui.text({ ui.span("diff failed: " .. d.err, "error") })
	elseif d.text == nil then
		return ui.text({ ui.span("loading diff…", "muted") })
	elseif d.text == "" then
		return ui.text({ ui.span("no textual changes", "muted") })
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
		local listing = ui.list(items)
		local children: { Node } = listing.c or {}
		local selected: string? = nil
		for i, child in children do
			local idx = start + i - 1
			local row_id = item_rows[i]
			local item_id = list_id .. ".f" .. idx
			ids[item_id] = row_id
			with(child, { key = "f" .. idx, actions = { click = "file=" .. row_id } })
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
		table.insert(out, with(ui.text({ ui.span("… " .. hidden .. " more files not shown", "muted") }), { key = "more" }))
	end
	return out
end

local function header(state: model.State): { Node }
	local snap = state.snap
	local root = state.root or state.dir
	if not snap then
		return { with(ui.text({ ui.span("⎇ ", "muted"), ui.span(util.basename(root), "strong") }), { key = "head" }) }
	end
	local st = snap.status
	local dirty = st.staged.total + st.unstaged.total + st.untracked.total
	local spans: { Span } = {
		ui.span("⎇ ", "muted"),
		ui.span(st.head or ("detached " .. string.sub(st.oid or "", 1, 8)), "strong"),
	}
	if snap.base then
		table.insert(spans, ui.span(" vs ", "muted"))
		table.insert(spans, ui.span(snap.base, "accent"))
	end
	local unpushed = if snap.unpushed_known then st.ahead else snap.commits_total
	if unpushed > 0 then
		local note = if snap.unpushed_known then " unpushed" else " unpushed (no upstream)"
		table.insert(spans, ui.span(" · ↑" .. unpushed .. note, "warning"))
	end
	if st.behind > 0 then
		table.insert(spans, ui.span(" · ↓" .. st.behind .. " behind " .. (st.upstream or "upstream"), "info"))
	end
	table.insert(spans, ui.span(" · ●" .. dirty, if dirty > 0 then "warning" else "muted"))

	local nodes: { Node } = { with(ui.text(spans), { key = "head" }) }

	local meta: { Span } = { ui.span(root, "path muted") }
	if snap.total then
		local t = snap.total
		table.insert(meta, ui.span(string.format("  ·  %d files ", t.files), "muted"))
		table.insert(meta, ui.span("+" .. t.add, "ins num"))
		table.insert(meta, ui.span(" −" .. t.del, "del num"))
		table.insert(meta, ui.span(" since merge-base", "muted"))
	end
	table.insert(nodes, with(ui.text(meta), { key = "meta" }))

	if #snap.bases > 1 then
		local badges: { Node } = { ui.text({ ui.span("base", "muted") }) }
		for i, ref in snap.bases do
			local active = ref == snap.base
			table.insert(badges, with(ui.badge(ref, if active then "accent" else "neutral"), {
				key = "b" .. i,
				actions = { click = "base=" .. ref },
			}))
		end
		table.insert(nodes, with(ui.row(badges), { key = "bases" }))
	end
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
		table.insert(sections, with(ui.text({ ui.span("Working tree clean", "muted") }), { key = "clean" }))
	end
	local head = { ui.span("Uncommitted", "strong"), ui.span("  ●" .. dirty, if dirty > 0 then "warning" else "muted") }
	return with(ui.card(head, sections), { key = "unc", collapsible = true, role = "branch-changes.uncommitted" })
end

local function commit_card(state: model.State, c: parse.Commit, unpushed: boolean, ids: { [string]: string }): Node
	local key = "c" .. c.sha
	local id = "main.commits." .. key
	local open = state.open[c.sha] == true
	local head: { Span } = {
		ui.span(c.short, "code"),
		ui.span(" " .. c.subject .. " ", "strong"),
		ui.span(c.author .. " · " .. util.age(os.time() - c.time), "muted"),
	}
	if unpushed then
		table.insert(head, ui.span(" ↑", "warning"))
	end
	local children: { Node } = {}
	local files = state.files[c.sha]
	if files and files.err then
		children = { ui.text({ ui.span("files failed: " .. files.err, "error") }) }
	elseif files and files.group then
		children = file_nodes(state, id, "commit", files.group, c.sha, ids)
		if #children == 0 then
			children = { ui.text({ ui.span("no file changes", "muted") }) }
		end
	else
		children = { ui.text({ ui.span("loading files…", "muted") }) }
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
		table.insert(cards, with(ui.text({ ui.span("No commits on this branch yet", "muted") }), { key = "none" }))
	end
	local hidden = snap.commits_total - #snap.commits
	if hidden > 0 then
		table.insert(cards, with(ui.text({ ui.span("… " .. hidden .. " older branch commits not shown (max_commits)", "muted") }), { key = "more" }))
	end
	local range = if snap.base then snap.base .. "..HEAD" else "HEAD"
	local head = { ui.span("Commits", "strong"), ui.span("  " .. snap.commits_total .. "  " .. range, "muted") }
	return with(ui.section(head, cards), { key = "commits", collapsible = true })
end

local function dock(state: model.State): Node
	local spans: { Span } = {}
	if state.refreshed_at then
		table.insert(spans, ui.span("updated " .. os.date("%H:%M:%S", state.refreshed_at) .. "  ", "muted"))
	end
	table.insert(spans, ui.span("j/k move · enter diff · ⌥/⌘-click or o open · r refresh · b base", "dim"))
	local children: { Node } = {}
	if state.loading then
		table.insert(children, ui.node("spinner", { style = "dots", label = { ui.span("refreshing", "muted") } }))
	end
	table.insert(children, ui.text(spans))
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
		table.insert(main, with(ui.text({ ui.span("Loading branch changes…", "muted") }), { key = "loading" }))
	end
	return { main = with(ui.col(main), { role = "branch-changes.main" }), dock = dock(state) }, ids
end

return M
