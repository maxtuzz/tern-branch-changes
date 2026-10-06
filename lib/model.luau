--!strict
-- Block state and the flat list of rows the keyboard walks.

local parse = require("./parse")
local git = require("./git")
local config = require("./config")

local M = {}

export type DiffState = { loading: boolean, text: string?, err: string? }
export type CommitFiles = { loading: boolean, group: parse.Group?, err: string? }

export type State = {
	dir: string, -- the directory the block was opened for
	root: string?, -- its worktree root, once resolved
	cfg: config.Config,
	warnings: { string },
	base_pref: string?, -- the base the user picked with `b` or a click
	snap: git.Snapshot?,
	error: string?, -- why there is no snapshot
	loading: boolean,
	refreshed_at: number?, -- os.time() of the last snapshot
	open: { [string]: boolean }, -- expanded commits, by sha
	files: { [string]: CommitFiles }, -- loaded commit file lists, by sha
	diffs: { [string]: DiffState }, -- open diffs, by row id
	sel: string?, -- selected row id
	me: string?, -- this repo's user.name, so commits by others stand out
	cost: number?, -- how long `git status` takes here, in ms
	hint: string?, -- a standing suggestion, such as turning fsmonitor on
	sigs: { [string]: string }, -- uncommitted row id -> its last seen status/counts
	fresh: { [string]: number }, -- uncommitted row id -> os.time() it last changed
}

export type Row = {
	id: string,
	kind: string, -- "file" | "commit"
	sha: string?,
	target: git.DiffTarget?,
}

function M.new(dir: string, root: string?, base_pref: string?): State
	return {
		dir = dir,
		root = root,
		cfg = config.defaults(),
		warnings = {},
		base_pref = base_pref,
		snap = nil,
		error = nil,
		loading = false,
		refreshed_at = nil,
		open = {},
		files = {},
		diffs = {},
		sel = nil,
		me = nil,
		cost = nil,
		hint = nil,
		sigs = {},
		fresh = {},
	}
end

-- Uncommitted groups in display order: key, title, diff kind.
M.GROUPS = {
	{ key = "staged", title = "Staged", kind = "staged" },
	{ key = "unstaged", title = "Unstaged", kind = "unstaged" },
	{ key = "untracked", title = "Untracked", kind = "untracked" },
}

function M.file_row_id(kind: string, path: string, sha: string?): string
	if sha then
		return "c:" .. sha .. ":" .. path
	end
	return kind .. ":" .. path
end

function M.commit_row_id(sha: string): string
	return "c:" .. sha
end

local function file_row(kind: string, f: parse.FileEntry, sha: string?): Row
	return {
		id = M.file_row_id(kind, f.path, sha),
		kind = "file",
		sha = sha,
		target = { kind = kind, path = f.path, orig = f.orig, sha = sha },
	}
end

-- Every selectable row, top to bottom, as the view shows them.
function M.rows(state: State): { Row }
	local rows: { Row } = {}
	local snap = state.snap
	if not snap then
		return rows
	end
	local status = snap.status :: any
	for _, g in M.GROUPS do
		local group: parse.Group = status[g.key]
		for _, f in group.files do
			table.insert(rows, file_row(g.kind, f, nil))
		end
	end
	for _, c in snap.commits do
		table.insert(rows, { id = M.commit_row_id(c.sha), kind = "commit", sha = c.sha, target = nil })
		local loaded = state.files[c.sha]
		if state.open[c.sha] and loaded and loaded.group then
			for _, f in loaded.group.files do
				table.insert(rows, file_row("commit", f, c.sha))
			end
		end
	end
	return rows
end

function M.find(rows: { Row }, id: string?): (Row?, number?)
	if id == nil then
		return nil, nil
	end
	for i, row in rows do
		if row.id == id then
			return row, i
		end
	end
	return nil, nil
end

-- Moves the selection by `delta` rows, clamped; starts at the top when nothing is selected.
function M.move(state: State, delta: number)
	local rows = M.rows(state)
	if #rows == 0 then
		state.sel = nil
		return
	end
	local _, i = M.find(rows, state.sel)
	local next = if i then math.clamp(i + delta, 1, #rows) else 1
	state.sel = rows[next].id
end

-- How many seconds ago this file last changed, while that is still recent.
-- Drives the "just now" cue that makes an agent's live edits visible.
M.FRESH_SECONDS = 180

function M.fresh_age(state: State, row_id: string): number?
	local at = state.fresh[row_id]
	if at == nil then
		return nil
	end
	local since = os.time() - at
	return if since <= M.FRESH_SECONDS then math.max(since, 0) else nil
end

local function signature(f: parse.FileEntry): string
	return table.concat({ f.code, tostring(f.add or -1), tostring(f.del or -1), f.orig or "" }, "/")
end

-- Notes which uncommitted files changed since the last snapshot and floats the
-- freshest to the top of their group. The first snapshot only records, so a
-- block that just opened doesn't mark everything as new.
function M.note_changes(state: State, first: boolean)
	local snap = state.snap
	if not snap then
		return
	end
	local now = os.time()
	local seen: { [string]: boolean } = {}
	for _, g in M.GROUPS do
		local group: parse.Group = (snap.status :: any)[g.key]
		for _, f in group.files do
			local id = M.file_row_id(g.kind, f.path, nil)
			local sig = signature(f)
			seen[id] = true
			if not first and state.sigs[id] ~= sig then
				state.fresh[id] = now
			end
			state.sigs[id] = sig
		end
		table.sort(group.files, function(a: parse.FileEntry, b: parse.FileEntry): boolean
			local fa = state.fresh[M.file_row_id(g.kind, a.path, nil)] or 0
			local fb = state.fresh[M.file_row_id(g.kind, b.path, nil)] or 0
			if fa ~= fb then
				return fa > fb
			end
			return a.path < b.path
		end)
	end
	for id in state.sigs do
		if not seen[id] then
			state.sigs[id] = nil
			state.fresh[id] = nil
		end
	end
end

-- Drops cached state that no longer matches the snapshot after a refresh.
function M.prune(state: State)
	local snap = state.snap
	if not snap then
		return
	end
	local shas: { [string]: boolean } = {}
	for _, c in snap.commits do
		shas[c.sha] = true
	end
	for sha in state.files do
		if not shas[sha] then
			state.files[sha] = nil
			state.open[sha] = nil
		end
	end
	local rows = M.rows(state)
	local live: { [string]: boolean } = {}
	for _, row in rows do
		live[row.id] = true
	end
	for id in state.diffs do
		if not live[id] then
			state.diffs[id] = nil
		end
	end
	if state.sel and not live[state.sel] then
		state.sel = if #rows > 0 then rows[1].id else nil
	end
end

return M
