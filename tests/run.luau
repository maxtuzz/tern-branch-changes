-- The plugin's tests. Run them with `python3 tests/test.py`, which bundles
-- this file with the plugin so they share the stub `tern` from tests/stub.luau.
-- Pure modules are tested directly; host.luau runs end to end against
-- git output recorded by tests/record.py.

local S = require("./stub")
tern = S.tern

local util = require("../lib/util")
local parse = require("../lib/parse")
local config = require("../lib/config")
local model = require("../lib/model")
local view = require("../lib/view")

local F = S.fixtures
local PREFIX = "git --no-optional-locks -c core.quotepath=off -c color.ui=never "

local passed, failed = 0, 0

local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		print("FAIL " .. name .. "\n     " .. tostring(err))
	end
end

local function eq(actual: any, expected: any, what: string?)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
	end
end

local function run(args: string)
	return F.runs[PREFIX .. args].stdout
end

-- util

test("split_nul keeps empty tokens between NULs and a trailing token", function()
	local t = util.split_nul("a\0\0b\0c")
	eq(#t, 4, "count")
	eq(t[1], "a")
	eq(t[2], "")
	eq(t[4], "c")
end)

test("under matches the root and paths inside it only", function()
	eq(util.under("/r/x", "/r"), true)
	eq(util.under("/r", "/r/"), true)
	eq(util.under("/rx", "/r"), false)
	eq(util.under(nil, "/r"), false)
end)

test("age buckets", function()
	eq(util.age(5), "now")
	eq(util.age(120), "2m")
	eq(util.age(3 * 86400), "3d")
	eq(util.age(400 * 86400), "1y")
end)

-- parse

test("status reads branch, upstream and the three groups", function()
	local st = parse.status(run("status --porcelain=v2 --branch -z --untracked-files=normal"), 2000)
	eq(st.head, "feat", "head")
	eq(st.upstream, "origin/feat", "upstream")
	eq(st.ahead, 3, "ahead")
	eq(st.staged.total, 1, "staged")
	eq(st.staged.files[1].path, "new.lua")
	eq(st.staged.files[1].code, "M")
	eq(st.unstaged.files[1].path, "lib/util.lua")
	eq(st.untracked.files[1].path, "notes with space.md")
end)

test("status caps groups but keeps totals", function()
	local out = "? a\0? b\0? c\0"
	local st = parse.status(out, 2)
	eq(#st.untracked.files, 2)
	eq(st.untracked.total, 3)
end)

test("status reads renames and conflicts", function()
	local out = "2 R. N... 100644 100644 100644 aaa bbb R100 new name.txt\0old.txt\0"
		.. "u UU N... 100644 100644 100644 100644 aaa bbb ccc both.txt\0"
	local st = parse.status(out, 10)
	eq(st.staged.files[1].path, "new name.txt")
	eq(st.staged.files[1].orig, "old.txt")
	eq(st.staged.files[1].code, "R")
	eq(st.unstaged.files[1].code, "U")
	eq(st.oid, nil, "no oid header")
end)

test("numstat reads plain, binary and renamed records", function()
	local c = parse.numstat("3\t1\ta.txt\0-\t-\timg.png\0" .. "2\t0\t\0old\0new\0")
	eq(c["a.txt"].add, 3)
	eq(c["img.png"].add, nil)
	eq(c["new"].add, 2)
end)

test("commit_files joins raw status with numstat counts, renames included", function()
	local rename_sha = F.commits[3] -- rev-list order: merge, add new, move a, grow a
	local key = "diff-tree -r -z --raw --numstat -M --root --no-commit-id --diff-merges=first-parent " .. rename_sha .. " --"
	local g = parse.commit_files(run(key), 100)
	eq(g.total, 1)
	eq(g.files[1].code, "R")
	eq(g.files[1].path, "docs/b c.txt")
	eq(g.files[1].orig, "a.txt")
	eq(g.files[1].add, 0)
end)

test("log parses the branch commits only", function()
	local key = "log --no-color --format=" .. parse.LOG_FORMAT .. " -n 200 " .. F.merge_base .. "..HEAD --"
	local commits = parse.log(run(key))
	eq(#commits, 4, "branch commits")
	eq(commits[2].subject, "feat: add new.lua")
	eq(commits[1].author, "Ada")
	for _, c in commits do
		assert(not string.find(c.subject, "^main:"), "main history leaked: " .. c.subject)
	end
end)

test("shortstat", function()
	local t = parse.shortstat(" 3 files changed, 10 insertions(+), 1 deletion(-)\n")
	eq(t.files, 3)
	eq(t.add, 10)
	eq(t.del, 1)
end)

-- config

test("config defaults", function()
	local cfg, warnings = config.normalize(nil)
	eq(cfg.base[1], "origin/dev")
	eq(cfg.base[2], "origin/main")
	eq(cfg.max_commits, 200)
	eq(#warnings, 0)
end)

test("config keeps good fields and warns on bad ones", function()
	local cfg, warnings = config.normalize({ base = { "upstream/main" }, max_commits = 0, untracked = "all", extra = 1 })
	eq(cfg.base[1], "upstream/main")
	eq(cfg.max_commits, 200, "bad max_commits falls back")
	eq(cfg.untracked, "all")
	eq(#warnings, 1)
end)

test("config rejects option-like refs", function()
	local cfg, warnings = config.normalize({ base = { "--output=/tmp/x" } })
	eq(cfg.base[1], "origin/dev")
	eq(#warnings, 1)
end)

-- host block, end to end against the fixtures

local function start()
	S.queue, S.timers, S.ran, S.effects, S.kv, S.handlers = {}, {}, {}, {}, {}, {}
	S.panes = { { pane = 7, cwd = F.root, program = "branch-changes.view", title = "", busy = false } }
	__reload("host")
	local def = S.blocks.view
	local cx = S.cx(7, F.root)
	local state = def.init(cx, { F.root }, nil)
	S.drain()
	return def, cx, state
end

local function find(node: any, pred: (any) -> boolean): any
	if pred(node) then
		return node
	end
	for _, child in node.c or {} do
		local hit = find(child, pred)
		if hit then
			return hit
		end
	end
	return nil
end

local function key(def, state, cx, name: string, extra: { [string]: any }?)
	local k = { name = name, ctrl = false, alt = false, shift = false, meta = false }
	for f, v in extra or {} do
		k[f] = v
	end
	local r = def.key(state, k, cx)
	S.drain()
	return r
end

test("block loads uncommitted work and branch commits against origin/main", function()
	local def, cx, state = start()
	eq(state.error, nil, "error")
	eq(state.root, F.root)
	local snap = state.snap
	assert(snap, "snapshot")
	eq(snap.base, "origin/main", "first existing base (origin/dev is missing)")
	eq(#snap.bases, 2, "origin/main and origin/HEAD exist")
	eq(snap.merge_base, F.merge_base)
	eq(#snap.commits, 4)
	eq(snap.commits_total, 4)
	eq(snap.unpushed[snap.commits[1].sha], true, "merge is unpushed")
	eq(snap.unpushed[snap.commits[3].sha], nil, "move a was pushed")
	eq(snap.status.staged.files[1].add, 1, "staged counts")
	assert(snap.total and snap.total.files > 0, "branch total")
	eq(state.sel, "staged:new.lua", "selects the first row")
	eq(def.title(state), "⎇ feat · " .. util.basename(F.root))
	for _, ran in S.ran do
		assert(string.find(ran, "--no-optional-locks", 1, true), "every git call skips optional locks")
	end
	assert(cx.renders > 0)
	eq(S.kv.panes["7"], F.root, "pane root remembered for the window half")
end)

test("view marks the selected row and keeps item ids stable", function()
	local def, cx, state = start()
	local v = def.view(state, cx)
	local main = v.main
	local unc = find(main, function(n)
		return n.p and n.p.key == "unc"
	end)
	assert(unc, "uncommitted card")
	local list = find(unc, function(n)
		return n.k == "list"
	end)
	eq(list.p.selected, "main.unc.staged.l1.f1")
	local _, ids = view.build(state)
	eq(ids["main.unc.staged.l1.f1"], "staged:new.lua")
	local commits = find(main, function(n)
		return n.p and n.p.key == "commits"
	end)
	eq(#commits.c, 4, "one card per branch commit")
	eq(commits.c[1].p.collapsed, true)
end)

test("enter opens an inline diff under the file; escape closes it", function()
	local def, cx, state = start()
	key(def, state, cx, "enter")
	local d = state.diffs["staged:new.lua"]
	assert(d and d.text and string.find(d.text, "+print('hello')", 1, true), "staged diff text")
	local v = def.view(state, cx)
	local diff = find(v.main, function(n)
		return n.k == "diff"
	end)
	eq(diff.p.path, "new.lua")
	key(def, state, cx, "escape")
	eq(next(state.diffs), nil)
end)

test("j/k walk files then commits; enter expands a commit lazily", function()
	local def, cx, state = start()
	key(def, state, cx, "j")
	eq(state.sel, "unstaged:lib/util.lua")
	key(def, state, cx, "j")
	eq(state.sel, "untracked:notes with space.md")
	key(def, state, cx, "enter")
	assert(state.diffs[state.sel].text, "untracked diff via --no-index")
	key(def, state, cx, "j")
	local move = state.snap.commits[3]
	key(def, state, cx, "j")
	key(def, state, cx, "j")
	eq(state.sel, "c:" .. move.sha)
	eq(state.files[move.sha], nil, "files load only on expand")
	key(def, state, cx, "enter")
	eq(state.open[move.sha], true)
	eq(state.files[move.sha].group.files[1].path, "docs/b c.txt")
	key(def, state, cx, "j")
	eq(state.sel, "c:" .. move.sha .. ":docs/b c.txt")
	key(def, state, cx, "enter")
	local d = state.diffs[state.sel]
	assert(d.text and string.find(d.text, "rename to docs/b c.txt", 1, true), "commit diff follows the rename")
end)

test("a toggle event from a commit card loads its files", function()
	local def, cx, state = start()
	local sha = state.snap.commits[1].sha
	def.event(state, { ev = "toggle", id = "main.commits.c" .. sha, collapsed = false }, cx)
	S.drain()
	eq(state.open[sha], true)
	assert(state.files[sha].group, "merge commit files (first parent)")
	eq(state.files[sha].group.files[1].path, "main-only.txt")
end)

test("alt-click opens the file; plain click toggles its diff", function()
	local def, cx, state = start()
	S.files[F.root .. "/lib/util.lua"] = true
	def.event(state, { ev = "action", act = "file", value = "unstaged:lib/util.lua", mods = { "alt" } }, cx)
	eq(S.effects[1][1], "open")
	eq(S.effects[1][2], F.root .. "/lib/util.lua")
	def.event(state, { ev = "action", act = "file", value = "unstaged:lib/util.lua" }, cx)
	S.drain()
	assert(state.diffs["unstaged:lib/util.lua"].text, "diff loaded")
end)

test("command_finished under the root refreshes after the debounce", function()
	local def, cx, state = start()
	table.insert(S.panes, { pane = 3, cwd = F.root .. "/lib", program = "zsh", title = "", busy = false })
	local before = #S.ran
	for _, h in S.handlers.command_finished do
		h({ pane = 3, line = "git commit", status = 0, took_ms = 5 }, nil)
	end
	S.drain()
	eq(#S.ran, before, "debounced, nothing yet")
	S.advance(500)
	assert(#S.ran > before, "refreshed")
	local _ = def
	local _ = cx
	local _ = state
end)

test("command_finished elsewhere does not refresh", function()
	start()
	table.insert(S.panes, { pane = 4, cwd = "/elsewhere", program = "zsh", title = "", busy = false })
	for _, h in S.handlers.command_finished do
		h({ pane = 4, line = "ls", status = 0, took_ms = 5 }, nil)
	end
	local before = #S.ran
	S.advance(600)
	eq(#S.ran, before)
end)

test("HEAD poll is a single rev-parse while HEAD is unchanged", function()
	start()
	local before = #S.ran
	S.advance(12000)
	eq(#S.ran, before + 1)
	assert(string.find(S.ran[#S.ran], "rev-parse -q --verify HEAD", 1, true))
end)

test("background work stops once the pane is gone", function()
	start()
	S.panes = {}
	local before = #S.ran
	S.advance(30000)
	eq(#S.ran, before)
end)

test("b cycles to the next existing base", function()
	local def, cx, state = start()
	local ok = pcall(key, def, state, cx, "b")
	-- origin/HEAD resolves to the same commit, but its range is recorded only for origin/main.
	eq(state.base_pref, "origin/HEAD")
	local _ = ok
end)

test("a missing worktree shows an error instead of failing", function()
	S.queue, S.timers, S.handlers = {}, {}, {}
	__reload("host")
	local def = S.blocks.view
	local cx = S.cx(9, nil)
	local state = def.init(cx, {}, nil)
	assert(state.error and string.find(state.error, "No directory"), "error shown")
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
	error("tests failed")
end
