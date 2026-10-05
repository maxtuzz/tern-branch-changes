--!strict
-- Parsers for git's machine-readable output. Pure functions: no `tern`.

local util = require("./util")

local M = {}

export type FileEntry = {
	path: string,
	orig: string?, -- source path of a rename or copy
	code: string, -- one status letter: A M D R C T U ?
	add: number?, -- lines added, nil for binary or unknown
	del: number?,
}

export type Group = {
	files: { FileEntry },
	total: number, -- entries seen, including those past the cap
}

export type Status = {
	oid: string?, -- nil before the first commit
	head: string?, -- branch name, nil when detached
	upstream: string?,
	ahead: number,
	behind: number,
	staged: Group,
	unstaged: Group,
	untracked: Group,
}

export type Commit = {
	sha: string,
	short: string,
	author: string,
	time: number, -- committer time, unix seconds
	subject: string,
}

local function group(): Group
	return { files = {}, total = 0 }
end

local function push(g: Group, entry: FileEntry, cap: number)
	g.total += 1
	if #g.files < cap then
		table.insert(g.files, entry)
	end
end

-- `git status --porcelain=v2 --branch -z`.
function M.status(out: string, cap: number): Status
	local st: Status = {
		oid = nil,
		head = nil,
		upstream = nil,
		ahead = 0,
		behind = 0,
		staged = group(),
		unstaged = group(),
		untracked = group(),
	}
	local tokens = util.split_nul(out)
	local i = 1
	while i <= #tokens do
		local t = tokens[i]
		local kind = string.sub(t, 1, 2)
		if kind == "# " then
			local key, value = string.match(t, "^# branch%.(%S+) (.*)$")
			local v: string = value or ""
			if key == "oid" then
				st.oid = if v == "(initial)" then nil else v
			elseif key == "head" then
				st.head = if v == "(detached)" then nil else v
			elseif key == "upstream" then
				st.upstream = v
			elseif key == "ab" then
				local a, b = string.match(v, "^%+(%d+) %-(%d+)$")
				st.ahead, st.behind = tonumber(a) or 0, tonumber(b) or 0
			end
		elseif kind == "1 " or kind == "2 " then
			local xy, path
			local orig: string? = nil
			if kind == "1 " then
				xy, path = string.match(t, "^1 (..) %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
			else
				xy, path = string.match(t, "^2 (..) %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
				i += 1
				orig = tokens[i]
			end
			if xy and path then
				local x, y = string.sub(xy, 1, 1), string.sub(xy, 2, 2)
				if x ~= "." then
					push(st.staged, { path = path, orig = orig, code = x }, cap)
				end
				if y ~= "." then
					-- The worktree side of a staged rename is the new path alone.
					push(st.unstaged, { path = path, code = y }, cap)
				end
			end
		elseif kind == "u " then
			local path = string.match(t, "^u .. %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
			if path then
				push(st.unstaged, { path = path, code = "U" }, cap)
			end
		elseif kind == "? " then
			push(st.untracked, { path = string.sub(t, 3), code = "?" }, cap)
		end
		i += 1
	end
	return st
end

export type Counts = { [string]: { add: number?, del: number? } }

-- Reads one `--numstat -z` record starting at tokens[i]; returns path, counts and next index.
local function numstat_at(tokens: { string }, i: number): (string?, number?, number?, number)
	local a, d, path = string.match(tokens[i], "^([%d%-]+)\t([%d%-]+)\t(.*)$")
	if not a then
		return nil, nil, nil, i + 1
	end
	local next = i + 1
	if path == "" then
		-- A rename: the old and new paths follow as their own tokens.
		path = tokens[i + 2]
		next = i + 3
	end
	return path, tonumber(a), tonumber(d), next
end

-- `git diff --numstat -z`, keyed by (new) path.
function M.numstat(out: string): Counts
	local counts: Counts = {}
	local tokens = util.split_nul(out)
	local i = 1
	while i <= #tokens do
		local path, add, del, next = numstat_at(tokens, i)
		if path then
			counts[path] = { add = add, del = del }
		end
		i = next
	end
	return counts
end

-- Fills `add`/`del` of the entries in `g` from `counts`.
function M.apply_counts(g: Group, counts: Counts)
	for _, f in g.files do
		local c = counts[f.path]
		if c then
			f.add, f.del = c.add, c.del
		end
	end
end

-- `git diff-tree -r -z --raw --numstat`: raw records (status) then numstat (counts).
function M.commit_files(out: string, cap: number): Group
	local g = group()
	local by_path: { [string]: FileEntry } = {}
	local tokens = util.split_nul(out)
	local i = 1
	while i <= #tokens do
		local t = tokens[i]
		if string.sub(t, 1, 1) == ":" then
			local code = string.match(t, "(%u)%d*$") or "M"
			local entry: FileEntry
			if code == "R" or code == "C" then
				entry = { path = tokens[i + 2] or "", orig = tokens[i + 1], code = code }
				i += 3
			else
				entry = { path = tokens[i + 1] or "", code = code }
				i += 2
			end
			by_path[entry.path] = entry
			push(g, entry, cap)
		else
			local path, add, del, next = numstat_at(tokens, i)
			local entry = if path then by_path[path] else nil
			if entry then
				entry.add, entry.del = add, del
			end
			i = next
		end
	end
	return g
end

M.LOG_FORMAT = "%x1e%H%x1f%h%x1f%an%x1f%ct%x1f%s"

-- `git log --format=<LOG_FORMAT>`.
function M.log(out: string): { Commit }
	local commits = {}
	for record in string.gmatch(out, "\30([^\30]*)") do
		local sha, short, author, time, subject =
			string.match(record, "^(%x+)\31(%x+)\31([^\31]*)\31(%d+)\31([^\n]*)")
		if sha and short and author and time and subject then
			table.insert(commits, {
				sha = sha,
				short = short,
				author = author,
				time = tonumber(time) or 0,
				subject = subject,
			})
		end
	end
	return commits
end

-- `git diff --shortstat`: " 3 files changed, 10 insertions(+), 2 deletions(-)".
function M.shortstat(out: string): { files: number, add: number, del: number }
	return {
		files = tonumber(string.match(out, "(%d+) files? changed")) or 0,
		add = tonumber(string.match(out, "(%d+) insertions?")) or 0,
		del = tonumber(string.match(out, "(%d+) deletions?")) or 0,
	}
end

-- Newline-separated SHAs (`git rev-list`) as a set.
function M.sha_set(out: string): { [string]: boolean }
	local set = {}
	for sha in string.gmatch(out, "%x+") do
		set[sha] = true
	end
	return set
end

return M
