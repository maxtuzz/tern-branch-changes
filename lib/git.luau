--!strict
-- Async git on the host: every call goes through `tern.process.run` with
-- `--no-optional-locks` and a timeout, so a block never blocks the worker
-- and never takes the index lock away from the user's own git.

local parse = require("./parse")
local config = require("./config")

local M = {}

type Result = { status: number, stdout: string, stderr: string, timed_out: boolean }
type Callback = (Result) -> ()

M.FAST_MS = 5000
M.SLOW_MS = 20000
M.MAX_DIFF_BYTES = 512 * 1024

local ENV = { GIT_TERMINAL_PROMPT = "0", GIT_OPTIONAL_LOCKS = "0", LC_ALL = "C" }

-- Runs `git --no-optional-locks <args>` in `root`. Spawn failures arrive as a failed result.
function M.run(root: string, args: { string }, timeout_ms: number, cb: Callback)
	local argv = { "git", "--no-optional-locks", "-c", "core.quotepath=off", "-c", "color.ui=never" }
	for _, a in args do
		table.insert(argv, a)
	end
	local ok, err = pcall(function()
		tern.process.run(argv, { cwd = root, env = ENV, timeout_ms = timeout_ms }, function(r)
			cb(r)
		end)
	end)
	if not ok then
		cb({ status = -1, stdout = "", stderr = tostring(err), timed_out = false })
	end
end

-- A one-line reason for a failed result.
function M.reason(r: Result): string
	if r.timed_out then
		return "git timed out"
	end
	local line = string.match(r.stderr, "[^\n]+") or ("git exited " .. r.status)
	return (string.gsub(line, "^fatal: ", ""))
end

-- Runs `jobs` concurrently; `done` gets their results in order.
function M.all(root: string, jobs: { { args: { string }, timeout: number } }, done: ({ Result }) -> ())
	local results: { Result } = {}
	local left = #jobs
	if left == 0 then
		done(results)
		return
	end
	for i, job in jobs do
		M.run(root, job.args, job.timeout, function(r)
			results[i] = r
			left -= 1
			if left == 0 then
				done(results)
			end
		end)
	end
end

-- Resolves the worktree root containing `dir`.
function M.toplevel(dir: string, cb: (string?, string?) -> ())
	M.run(dir, { "rev-parse", "--show-toplevel" }, M.FAST_MS, function(r)
		if r.status == 0 then
			cb((string.gsub(r.stdout, "%s+$", "")), nil)
		else
			cb(nil, M.reason(r))
		end
	end)
end

-- The one call that sees the working tree. It is the dear part of a refresh in
-- a big worktree, so the poll runs it alone and hands the output to the
-- snapshot when something changed, instead of running it twice.
function M.status_args(cfg: config.Config): { string }
	return { "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=" .. cfg.untracked }
end

-- Reports how long the call took as well: the poll paces itself by it, so a
-- worktree where status is expensive is asked less often.
function M.status(root: string, cfg: config.Config, cb: (string?, number) -> ())
	local started = tern.now()
	M.run(root, M.status_args(cfg), M.SLOW_MS, function(r)
		cb(if r.status == 0 then r.stdout else nil, tern.now() - started)
	end)
end

-- Whether this worktree has git's filesystem monitor on, which is what keeps
-- `git status` cheap in a big repo.
function M.fsmonitor(root: string, cb: (boolean) -> ())
	M.run(root, { "config", "--get", "core.fsmonitor" }, M.FAST_MS, function(r)
		local value = string.match(r.stdout, "^%s*(.-)%s*$") or ""
		cb(r.status == 0 and value ~= "" and value ~= "false")
	end)
end

function M.head(root: string, cb: (string?) -> ())
	M.run(root, { "rev-parse", "-q", "--verify", "HEAD" }, M.FAST_MS, function(r)
		cb(if r.status == 0 then (string.gsub(r.stdout, "%s+$", "")) else nil)
	end)
end

export type Snapshot = {
	status: parse.Status,
	raw: string, -- the status output this snapshot was read from, for the poll
	bases: { string }, -- configured refs that exist, in order
	base: string?, -- the ref in use
	merge_base: string?,
	commits: { parse.Commit },
	commits_total: number,
	unpushed: { [string]: boolean },
	unpushed_known: boolean, -- false when there is no upstream
	total: { files: number, add: number, del: number }?,
	error: string?, -- why the commit list is missing, when it is
}

local function base_candidates(cfg: config.Config): { string }
	local refs = table.clone(cfg.base)
	if not table.find(refs, "origin/HEAD") then
		table.insert(refs, "origin/HEAD")
	end
	return refs
end

-- Commits in merge-base(base, HEAD)..HEAD, capped, plus their totals.
local function load_commits(root: string, cfg: config.Config, snap: Snapshot, done: (Snapshot) -> ())
	local base = snap.base :: string
	M.run(root, { "merge-base", base, "HEAD" }, M.FAST_MS, function(mb)
		if mb.status ~= 0 then
			snap.error = "no merge base with " .. base
			done(snap)
			return
		end
		local merge_base = (string.gsub(mb.stdout, "%s+$", ""))
		snap.merge_base = merge_base
		local range = merge_base .. "..HEAD"
		local cap = tostring(cfg.max_commits)
		local jobs = {
			{ args = { "log", "--no-color", "--format=" .. parse.LOG_FORMAT, "-n", cap, range, "--" }, timeout = M.SLOW_MS },
			{ args = { "rev-list", "--count", range, "--" }, timeout = M.SLOW_MS },
		}
		local upstream = snap.status.upstream
		if upstream then
			table.insert(jobs, { args = { "rev-list", "-n", cap, upstream .. "..HEAD", "--" }, timeout = M.SLOW_MS })
		end
		if cfg.show_branch_total then
			table.insert(jobs, { args = { "diff", "--shortstat", merge_base, "HEAD", "--" }, timeout = M.SLOW_MS })
		end
		M.all(root, jobs, function(rs)
			if rs[1].status ~= 0 then
				snap.error = M.reason(rs[1])
				done(snap)
				return
			end
			snap.commits = parse.log(rs[1].stdout)
			snap.commits_total = tonumber(string.match(rs[2].stdout, "%d+")) or #snap.commits
			local next = 3
			if upstream then
				snap.unpushed_known = rs[next].status == 0
				snap.unpushed = parse.sha_set(rs[next].stdout)
				next += 1
			end
			if cfg.show_branch_total and rs[next] and rs[next].status == 0 then
				snap.total = parse.shortstat(rs[next].stdout)
			end
			done(snap)
		end)
	end)
end

-- Everything the block shows above the per-commit file lists.
-- `want_base` is the user's chosen base, used when it still exists.
-- `have_status` is a status output the caller already fetched this cycle.
function M.snapshot(root: string, cfg: config.Config, want_base: string?, done: (Snapshot?, string?) -> (), have_status: string?)
	local candidates = base_candidates(cfg)
	local jobs: { { args: { string }, timeout: number } } = {}
	if not have_status then
		table.insert(jobs, { args = M.status_args(cfg), timeout = M.SLOW_MS })
	end
	table.insert(jobs, { args = { "diff", "--numstat", "-z", "--" }, timeout = M.SLOW_MS })
	table.insert(jobs, { args = { "diff", "--cached", "--numstat", "-z", "-M", "--" }, timeout = M.SLOW_MS })
	-- Results come back in order; the status job is absent when the poll fetched it.
	local at = if have_status then 0 else 1
	for _, ref in candidates do
		table.insert(jobs, { args = { "rev-parse", "-q", "--verify", "--end-of-options", ref .. "^{commit}" }, timeout = M.FAST_MS })
	end
	M.all(root, jobs, function(rs)
		if not have_status and rs[1].status ~= 0 then
			done(nil, M.reason(rs[1]))
			return
		end
		local status = parse.status(have_status or rs[1].stdout, cfg.max_files)
		parse.apply_counts(status.unstaged, parse.numstat(rs[at + 1].stdout))
		parse.apply_counts(status.staged, parse.numstat(rs[at + 2].stdout))

		local bases: { string } = {}
		for i, ref in candidates do
			if rs[at + 2 + i].status == 0 then
				table.insert(bases, ref)
			end
		end
		local base = if want_base and table.find(bases, want_base) then want_base else bases[1]
		local snap: Snapshot = {
			status = status,
			raw = have_status or rs[1].stdout,
			bases = bases,
			base = base,
			merge_base = nil,
			commits = {},
			commits_total = 0,
			unpushed = {},
			unpushed_known = false,
			total = nil,
			error = nil,
		}
		if status.oid == nil then
			snap.error = "no commits yet"
			done(snap, nil)
		elseif base == nil then
			snap.error = "none of the base refs exist: " .. table.concat(candidates, ", ")
			done(snap, nil)
		else
			load_commits(root, cfg, snap, function(s)
				done(s, nil)
			end)
		end
	end)
end

-- Files changed by commit `sha` (first parent for merges).
function M.commit_files(root: string, sha: string, cap: number, done: (parse.Group?, string?) -> ())
	local args = { "diff-tree", "-r", "-z", "--raw", "--numstat", "-M", "--root", "--no-commit-id", "--diff-merges=first-parent", sha, "--" }
	M.run(root, args, M.SLOW_MS, function(r)
		if r.status ~= 0 then
			done(nil, M.reason(r))
		else
			done(parse.commit_files(r.stdout, cap), nil)
		end
	end)
end

-- Throwing uncommitted work away. Unstaged edits are not recoverable from git
-- afterwards, so every caller of this confirms first.
export type DiffTarget = {
	kind: string, -- "staged" | "unstaged" | "untracked" | "commit"
	path: string,
	orig: string?,
	sha: string?,
}

local function diff_args(t: DiffTarget): { string }
	local paths: { string } = { t.path }
	if t.orig then
		paths = { t.orig, t.path }
	end
	local args: { string }
	if t.kind == "staged" then
		args = { "diff", "--no-color", "--cached", "-M", "--" }
	elseif t.kind == "untracked" then
		return { "diff", "--no-color", "--no-index", "--", "/dev/null", t.path }
	elseif t.kind == "commit" then
		args = { "show", "--no-color", "--format=", "-M", "--diff-merges=first-parent", t.sha :: string, "--" }
	else
		args = { "diff", "--no-color", "--" }
	end
	for _, p in paths do
		table.insert(args, p)
	end
	return args
end

-- What `discard` would run, or nil when there is nothing to throw away (a file
-- inside a commit is history, not working state).
function M.discard_args(t: DiffTarget): { string }?
	local paths: { string } = { t.path }
	if t.orig then
		paths = { t.orig, t.path }
	end
	local args: { string }
	if t.kind == "staged" then
		-- Both sides: the staged copy and the file in the worktree.
		args = { "restore", "--staged", "--worktree", "--" }
	elseif t.kind == "unstaged" then
		args = { "restore", "--" }
	elseif t.kind == "untracked" then
		-- Deletes the file. `-d` as well when the entry is a directory.
		args = if string.sub(t.path, -1) == "/" then { "clean", "-f", "-d", "--" } else { "clean", "-f", "--" }
	else
		return nil
	end
	for _, p in paths do
		table.insert(args, p)
	end
	return args
end

-- A one-line description of what discarding does, for the confirmation.
function M.discard_label(t: DiffTarget): string
	if t.kind == "untracked" then
		return "delete " .. t.path
	elseif t.kind == "staged" then
		return "discard staged and working changes to " .. t.path
	end
	return "discard changes to " .. t.path
end

function M.discard(root: string, t: DiffTarget, done: (string?) -> ())
	local args = M.discard_args(t)
	if args == nil then
		done("nothing to discard there")
		return
	end
	M.run(root, args, M.SLOW_MS, function(r)
		done(if r.status == 0 then nil else M.reason(r))
	end)
end

-- The unified diff for one file, truncated past MAX_DIFF_BYTES.
function M.diff(root: string, t: DiffTarget, done: (string?, string?) -> ())
	M.run(root, diff_args(t), M.SLOW_MS, function(r)
		-- `diff --no-index` exits 1 when the files differ.
		local ok = r.status == 0 or (t.kind == "untracked" and r.status == 1)
		if not ok then
			done(nil, M.reason(r))
			return
		end
		local text = r.stdout
		if #text > M.MAX_DIFF_BYTES then
			local cut = string.find(text, "\n", M.MAX_DIFF_BYTES, true) or M.MAX_DIFF_BYTES
			text = string.sub(text, 1, cut) .. "\n… diff truncated at " .. (M.MAX_DIFF_BYTES // 1024) .. " KiB\n"
		end
		done(text, nil)
	end)
end

return M
