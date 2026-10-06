--!strict
-- `tern-branch-changes://diff?…` links. A host block has no `new_block`, only
-- `cx:open(target)`, so the list block opens a diff block by following one
-- of these links; window.luau's `tern.route.link` turns it into the block.
-- Pure: no `tern`.

local M = {}

M.SCHEME = "tern-branch-changes"
M.PREFIX = M.SCHEME .. "://diff?"
M.VIEW_PREFIX = M.SCHEME .. "://view?"
M.DISCARD_PREFIX = M.SCHEME .. "://discard?"
M.EDIT_PREFIX = M.SCHEME .. "://edit?"

export type DiffLink = {
	root: string,
	kind: string, -- "staged" | "unstaged" | "untracked" | "commit"
	path: string,
	sha: string?,
	orig: string?,
}

local KINDS = { staged = true, unstaged = true, untracked = true, commit = true }

local function encode(s: string): string
	return (string.gsub(s, "[^%w%-%._~/]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function decode(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h)
		return string.char(tonumber(h, 16) :: number)
	end))
end

function M.encode(l: DiffLink): string
	local parts = {
		"root=" .. encode(l.root),
		"kind=" .. encode(l.kind),
		"path=" .. encode(l.path),
	}
	if l.sha then
		table.insert(parts, "sha=" .. encode(l.sha))
	end
	if l.orig then
		table.insert(parts, "orig=" .. encode(l.orig))
	end
	return M.PREFIX .. table.concat(parts, "&")
end

-- The link's fields, or nil when `url` isn't a well-formed diff link.
function M.decode(url: string): DiffLink?
	if string.sub(url, 1, #M.PREFIX) ~= M.PREFIX then
		return nil
	end
	local q: { [string]: string } = {}
	for key, value in string.gmatch(string.sub(url, #M.PREFIX + 1), "([^&=]+)=([^&]*)") do
		q[key] = decode(value :: string)
	end
	local root, kind, path = q.root, q.kind, q.path
	if not root or root == "" or not path or path == "" or not kind or not KINDS[kind] then
		return nil
	end
	local k: string = kind
	local sha: string? = q.sha
	if k == "commit" and (sha == nil or not string.match(sha, "^%x+$")) then
		return nil
	end
	local out: DiffLink = {
		root = root,
		kind = k,
		path = path,
		sha = if k == "commit" then sha else nil,
		orig = if q.orig and q.orig ~= "" then q.orig else nil,
	}
	return out
end

-- Block launch args: root, kind, path, sha ("" when none), orig ("" when none).
function M.to_args(l: DiffLink): { string }
	return { l.root, l.kind, l.path, l.sha or "", l.orig or "" }
end

function M.from_args(args: { string }): DiffLink?
	local root, kind, path = args[1], args[2], args[3]
	if not root or root == "" or not path or path == "" or not kind or not KINDS[kind] then
		return nil
	end
	local k: string = kind
	local sha: string? = if args[4] and args[4] ~= "" then args[4] else nil
	if k == "commit" and sha == nil then
		return nil
	end
	local out: DiffLink = {
		root = root,
		kind = k,
		path = path,
		sha = sha,
		orig = if args[5] and args[5] ~= "" then args[5] else nil,
	}
	return out
end

-- `tern-branch-changes://view?root=…`: open the list block full width (a new tab).
function M.view_url(root: string): string
	return M.VIEW_PREFIX .. "root=" .. encode(root)
end

-- The root of a view link, or nil when `url` isn't one.
function M.decode_view(url: string): string?
	if string.sub(url, 1, #M.VIEW_PREFIX) ~= M.VIEW_PREFIX then
		return nil
	end
	local root = string.match(string.sub(url, #M.VIEW_PREFIX + 1), "^root=([^&]+)")
	if root == nil then
		return nil
	end
	local path = decode(root)
	return if path ~= "" then path else nil
end

-- `tern-branch-changes://discard?row=…`: the ↺ a file row carries. A span can
-- hold a link but not an action, and a list row's own click wins over its
-- parts, so this is how a per-row control reaches the block at all.
function M.discard_url(row_id: string): string
	return M.DISCARD_PREFIX .. "row=" .. encode(row_id)
end

function M.decode_discard(url: string): string?
	if string.sub(url, 1, #M.DISCARD_PREFIX) ~= M.DISCARD_PREFIX then
		return nil
	end
	local row = string.match(string.sub(url, #M.DISCARD_PREFIX + 1), "^row=([^&]+)")
	if row == nil then
		return nil
	end
	local id = decode(row)
	return if id ~= "" then id else nil
end

-- `tern-branch-changes://edit?path=…&line=…`: open the file for editing in
-- place of the pane the link came from, with the caret at `line`.
function M.edit_url(path: string, line: number?): string
	local url = M.EDIT_PREFIX .. "path=" .. encode(path)
	return if line then url .. "&line=" .. tostring(line) else url
end

function M.decode_edit(url: string): (string?, number?)
	if string.sub(url, 1, #M.EDIT_PREFIX) ~= M.EDIT_PREFIX then
		return nil, nil
	end
	local query = string.sub(url, #M.EDIT_PREFIX + 1)
	local path = string.match(query, "^path=([^&]+)")
	if path == nil then
		return nil, nil
	end
	local decoded = decode(path)
	if decoded == "" then
		return nil, nil
	end
	return decoded, tonumber(string.match(query, "&line=(%d+)") or "")
end

-- Identity of a diff view, for focusing an open block instead of opening another.
function M.key(l: DiffLink): string
	return table.concat({ l.root, l.kind, l.sha or "", l.path }, "\n")
end

return M
