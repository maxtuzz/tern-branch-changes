--!strict
-- `tern-branch-changes://diff?…` links. A host block has no `new_block`, only
-- `cx:open(target)`, so the list block opens a diff block by following one
-- of these links; window.luau's `tern.route.link` turns it into the block.
-- Pure: no `tern`.

local M = {}

M.SCHEME = "tern-branch-changes"
M.PREFIX = M.SCHEME .. "://diff?"

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

-- Identity of a diff view, for focusing an open block instead of opening another.
function M.key(l: DiffLink): string
	return table.concat({ l.root, l.kind, l.sha or "", l.path }, "\n")
end

return M
