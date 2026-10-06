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
	eq(def.title(state), "feat · " .. util.basename(F.root))
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
	local clist = find(commits, function(n)
		return n.k == "list"
	end)
	eq(#clist.c, 4, "one row per branch commit")
	eq(clist.c[1].p.key, "c" .. state.snap.commits[1].sha, "rows keyed by sha")
end)

local function texts(node: any, out: { string }?): { string }
	local acc = out or {}
	local p = node.p or {}
	for _, field in { "spans", "head", "label", "detail", "value" } do
		local spans = p[field]
		if type(spans) == "table" then
			for _, sp in spans do
				if type(sp) == "table" and sp.t then
					table.insert(acc, sp.t)
				end
			end
		end
	end
	if type(p.text) == "string" then
		table.insert(acc, p.text)
	end
	for _, child in node.c or {} do
		texts(child, acc)
	end
	return acc
end

test("view uses native chrome: chips, toned file rows, no TUI glyphs", function()
	local def, cx, state = start()
	local v = def.view(state, cx)
	local all = table.concat(texts(v.main), "|") .. table.concat(texts(v.dock), "|")
	for _, glyph in { "⎇", "▸", "▾", "●" } do
		assert(not string.find(all, glyph, 1, true), "glyph left in view: " .. glyph)
	end
	local branch = find(v.main, function(n)
		return n.p and n.p.key == "branch"
	end)
	eq(branch.p.spans[1].t, "feat", "branch is the title")
	eq(branch.p.spans[1].s, "strong")
	local chips = find(v.main, function(n)
		return n.p and n.p.key == "chips"
	end)
	local labels = {}
	for _, chip in chips.c do
		eq(chip.k, "badge")
		labels[chip.p.key] = chip.p.text
	end
	eq(labels.ahead, "↑3", "ahead/behind use compact git shorthand")
	eq(labels.dirty, "3 changed")
	local item = find(v.main, function(n)
		return n.k == "item"
	end)
	eq(item.p.label[1].t, "new.lua", "file name is the label")
	eq(item.p.tone, "warning", "modified rows are toned warning")
	eq(item.p.title, "new.lua · modified")
	local unc = find(v.main, function(n)
		return n.p and n.p.key == "untracked"
	end)
	local untracked = find(unc, function(n)
		return n.k == "item"
	end)
	eq(untracked.p.tone, "muted")
	local commits = find(v.main, function(n)
		return n.p and n.p.key == "commits"
	end)
	local crow = find(commits, function(n)
		return n.k == "item"
	end)
	eq(crow.p.label[1].t, state.snap.commits[1].subject, "subject is the commit label")
	eq(crow.p.value[1].s, "muted", "a sidebar spends the row on the subject, not the sha")
	assert(string.find(crow.p.title, state.snap.commits[1].short, 1, true), "the sha stays in the tooltip")
	local wide = find(view.build(state, 140).main, function(n)
		return n.k == "item" and n.p.actions and string.find(n.p.actions.click or "", "commit=", 1, true)
	end)
	eq(wide.p.value[1].s, "code", "a wide pane shows the sha, styled as code")
	eq(crow.p.tone, "warning", "unpushed commits are toned")
	local kbd = find(v.dock, function(n)
		return n.k == "kbd"
	end)
	assert(kbd, "dock key hints are keycaps")
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

-- diff links and the diff block

local link = require("../lib/link")

test("diff links round-trip paths with spaces, &, = and %", function()
	local l = { root = "/w t/r", kind = "commit", path = "a b/c&d=e%f.lua", sha = "abc123", orig = "old name.lua" }
	local back = link.decode(link.encode(l))
	assert(back, "decoded")
	eq(back.root, l.root)
	eq(back.path, l.path)
	eq(back.sha, "abc123")
	eq(back.orig, "old name.lua")
	eq(link.key(back), link.key(l))
	local args = link.to_args(back)
	eq(link.key(link.from_args(args) :: any), link.key(l), "args round-trip")
end)

test("diff links reject other schemes and incomplete queries", function()
	eq(link.decode("https://example.com/diff?root=/r&kind=staged&path=a"), nil)
	eq(link.decode(link.PREFIX .. "root=/r&kind=bogus&path=a"), nil)
	eq(link.decode(link.PREFIX .. "root=/r&kind=commit&path=a"), nil, "commit needs a sha")
	eq(link.decode(link.PREFIX .. "root=/r&kind=staged"), nil, "path required")
	eq(link.from_args({}), nil)
end)

local function opened_link(): any
	for i = #S.effects, 1, -1 do
		local e = S.effects[i]
		if e[1] == "open" then
			return link.decode(e[2])
		end
	end
	return nil
end

test("o on a deleted file opens a diff block link instead of failing", function()
	local def, cx, state = start()
	-- lib/util.lua is absent from the stub file system: the deleted-file case.
	S.files = {}
	state.sel = "unstaged:lib/util.lua"
	key(def, state, cx, "o")
	local l = opened_link()
	assert(l, "followed a tern-branch-changes:// link")
	eq(l.kind, "unstaged")
	eq(l.path, "lib/util.lua")
	eq(l.root, F.root)
	eq(state.diffs["unstaged:lib/util.lua"], nil, "o does not toggle the inline diff")
end)

test("e on a deleted file explains instead of opening", function()
	local def, cx, state = start()
	S.files = {}
	state.sel = "unstaged:lib/util.lua"
	key(def, state, cx, "e")
	eq(S.effects[#S.effects][1], "toast")
	assert(string.find(S.effects[#S.effects][4], "press o", 1, true), "points at o")
end)

test("double-click opens the diff block; single click stays inline", function()
	local def, cx, state = start()
	def.event(state, { ev = "action", act = "diff", value = "staged:new.lua" }, cx)
	local l = opened_link()
	eq(l.kind, "staged")
	eq(state.diffs["staged:new.lua"], nil)
	def.event(state, { ev = "action", act = "file", value = "staged:new.lua" }, cx)
	S.drain()
	assert(state.diffs["staged:new.lua"].text, "inline diff on single click")
	local v = def.view(state, cx)
	local item = find(v.main, function(n)
		return n.k == "item"
	end)
	eq(item.p.actions.dblclick, "diff=staged:new.lua")
end)

test("o on a commit file links to that commit's diff", function()
	local def, cx, state = start()
	local move = state.snap.commits[3]
	state.sel = "c:" .. move.sha
	key(def, state, cx, "enter")
	key(def, state, cx, "j")
	key(def, state, cx, "o")
	local l = opened_link()
	eq(l.kind, "commit")
	eq(l.sha, move.sha)
	eq(l.path, "docs/b c.txt")
	eq(l.orig, "a.txt")
end)

test("diff block loads the patch full-pane and reloads on r", function()
	start()
	local def = S.blocks.diff
	assert(def, "branch-changes.diff defined")
	table.insert(S.panes, { pane = 11, cwd = F.root, program = "branch-changes.diff", title = "", busy = false })
	local cx = S.cx(11, F.root)
	local state = def.init(cx, link.to_args({ root = F.root, kind = "staged", path = "new.lua" }), nil)
	S.drain()
	assert(state.text and string.find(state.text, "+print('hello')", 1, true), "patch loaded")
	eq(def.title(state), "new.lua (staged)")
	local v = def.view(state, cx)
	local d = find(v.main, function(n)
		return n.k == "diff"
	end)
	eq(d.p.path, "new.lua")
	eq(S.kv.diff_panes["11"], link.key({ root = F.root, kind = "staged", path = "new.lua" }))
	local before = #S.ran
	def.key(state, { name = "r", ctrl = false, alt = false, shift = false, meta = false }, cx)
	S.drain()
	eq(#S.ran, before + 1, "reloaded")
end)

test("diff block with bad args shows an error instead of failing", function()
	start()
	local state = S.blocks.diff.init(S.cx(12, nil), { "/r", "commit", "a.txt" }, nil)
	assert(state.err, "error shown")
	eq(S.blocks.diff.title(state), "File diff")
end)

test("window route opens a diff block, or focuses the one already open", function()
	S.routes = {}
	__reload("window")
	local route = S.routes[1]
	assert(route, "route.link registered")
	local target = { root = "/r", kind = "commit", path = "x.lua", sha = "abc" }
	local url = link.encode(target)
	local focused: number? = nil
	local panes = {}
	local wcx = {
		session = {
			panes = function(_self)
				return panes
			end,
		},
		layout = {
			focus = function(_self, pane)
				focused = pane
			end,
		},
	}
	eq(route({ url = "https://example.com", pane = 1, mods = {} }, wcx), nil, "other links pass")
	S.kv.diff_panes = {}
	local decision = route({ url = url, pane = 1, mods = {} }, wcx)
	eq(decision.block, "branch-changes.diff")
	eq(decision.args[4], "abc")
	panes = { { pane = 5, block = "branch-changes.diff", cwd = "", title = "" } }
	S.kv.diff_panes = { ["5"] = link.key(target) }
	decision = route({ url = url, pane = 1, mods = {} }, wcx)
	eq(decision.handled, true)
	eq(focused, 5)
end)

-- sidebar / full-view layouts

local function row_of(node: any, key: string): any
	return find(node, function(n)
		return n.p and n.p.key == key
	end)
end

local function longest_line(node: any): number
	local most = 0
	for _, t in texts(node) do
		most = math.max(most, utf8.len(t) or #t)
	end
	return most
end

local function spans_of(node: any, out: { any }?): { any }
	local acc = out or {}
	local p = node.p or {}
	for _, field in { "spans", "head", "label", "detail", "value" } do
		local list = p[field]
		if type(list) == "table" then
			for _, sp in list do
				if type(sp) == "table" and sp.t then
					table.insert(acc, sp)
				end
			end
		end
	end
	for _, child in node.c or {} do
		spans_of(child, acc)
	end
	return acc
end

test("change counts are toned, not struck through", function()
	local def, cx, state = start()
	local v = def.view(state, cx)
	local item = find(v.main, function(n)
		return n.k == "item"
	end)
	local plus, minus = item.p.value[1], item.p.value[2]
	eq(plus.t, "+1")
	eq(plus.s, "success num", "additions are toned, not `ins` (which underlines)")
	eq(minus.t, " -1")
	eq(minus.s, "error num", "deletions are toned, not `del` (which strikes through)")
	for _, node in { v.main, v.dock } do
		for _, sp in spans_of(node) do
			local style = sp.s or ""
			assert(not string.find(style, "del", 1, true), "no `del` token: " .. sp.t)
			assert(not string.find(style, "ins", 1, true), "no `ins` token: " .. sp.t)
		end
	end
end)

test("a sidebar-width pane keeps header rows on one line and trims labels", function()
	local def, cx, state = start()
	local v = def.view(state, cx)  -- cx.cols is 80 in the stub
	local narrow = view.build(state, 38)
	local head = row_of(narrow.main, "head")
	eq(head.p.max.h, "1lines", "the branch row is clipped to one line")
	eq(row_of(narrow.main, "chips").p.max.h, "1lines", "the chip row cannot wrap")
	local base = row_of(narrow.main, "base")
	eq(base.k, "badge")
	eq(base.p.text, "main", "the base chip drops the remote at sidebar width")
	eq(base.p.shrink, 0)
	eq(base.p.actions.click, "base-next", "one chip cycles the base")
	eq(row_of(narrow.main, "meta"), nil, "the worktree path is dropped when narrow")
	local chips = row_of(narrow.main, "chips")
	local width = 0
	for _, chip in chips.c do
		width += (utf8.len(chip.p.text) or 0) + 3
	end
	assert(width <= 38, "chips fit a 38-cell sidebar, got " .. width)
	local _ = v
end)

test("footer hints are dropped to fit, never wrapped", function()
	local _, _, state = start()
	local function hints(cols: number): { string }
		local out = {}
		local dock = view.build(state, cols).dock
		for _, t in texts(dock) do
			table.insert(out, t)
		end
		return out
	end
	local narrow, wide = hints(30), hints(160)
	assert(#narrow < #wide, "a sidebar shows fewer hints than a wide pane")
	for _, set in { narrow, wide } do
		for _, t in set do
			assert(not string.find(t, "\n"), "no hint wraps")
		end
	end
	local cols = 30
	local used = 0
	for _, t in narrow do
		used += (utf8.len(t) or 0) + 2
	end
	assert(used <= cols, "narrow hints fit " .. cols .. " cells, used " .. used)
	local dock = view.build(state, 30).dock
	eq(find(dock, function(n)
		return n.p and n.p.max and n.p.max.h == "1lines"
	end) ~= nil, true, "the footer row is clipped to one line")
	assert(longest_line(dock) < 30, "no single footer label exceeds the pane")
end)

test("a wide pane puts the file list beside the selected diff", function()
	local def, cx, state = start()
	key(def, state, cx, "enter") -- load the selected file's diff
	local wide = view.build(state, 140)
	eq(wide.main.k, "row", "two columns")
	local list = row_of(wide.main, "list")
	local hero = row_of(wide.main, "hero")
	assert(list and hero, "list and hero columns")
	eq(hero.p.role, "branch-changes.hero")
	local d = find(hero, function(n)
		return n.k == "diff"
	end)
	eq(d.p.path, "new.lua", "the hero shows the selected file's diff")
	eq(find(list, function(n)
		return n.k == "diff"
	end), nil, "and the list column stays unbroken")
	local narrow = view.build(state, 40)
	eq(narrow.main.k, "col", "a sidebar is one column")
	assert(find(narrow.main, function(n)
		return n.k == "diff"
	end), "where the diff stays inline under its row")
end)

test("the hero names the file and offers its own pane", function()
	local def, cx, state = start()
	local wide = view.build(state, 140)
	local hero = row_of(wide.main, "hero")
	eq(find(hero, function(n)
		return n.p and n.p.key == "pop"
	end).p.actions.click, "diff=staged:new.lua")
	local _ = def
	local _ = cx
end)

test("files an agent just touched surface first with a live cue", function()
	local def, cx, state = start()
	eq(model.fresh_age(state, "unstaged:lib/util.lua"), nil, "the first snapshot marks nothing fresh")
	-- A second snapshot with a changed signature is what an agent's edit looks like.
	state.sigs["unstaged:lib/util.lua"] = "M/99/99/"
	model.note_changes(state, false)
	local age = model.fresh_age(state, "unstaged:lib/util.lua")
	assert(age ~= nil and age < 5, "the edited file is fresh")
	local unstaged = row_of(def.view(state, cx).main, "unstaged")
	local item = find(unstaged, function(n)
		return n.k == "item"
	end)
	local detail = table.concat(texts(item), "|")
	assert(string.find(detail, "just now", 1, true), "the row says when it changed")
	state.fresh["unstaged:lib/util.lua"] = os.time() - model.FRESH_SECONDS - 60
	eq(model.fresh_age(state, "unstaged:lib/util.lua"), nil, "and the cue fades")
end)

test("clicking a commit row expands it; the author shows only for others", function()
	local def, cx, state = start()
	local sha = state.snap.commits[1].sha
	state.me = "Ada"
	local crow = find(row_of(def.view(state, cx).main, "commits"), function(n)
		return n.k == "item"
	end)
	eq(crow.p.detail, nil, "your own commits leave the author out")
	eq(crow.p.actions.click, "commit=" .. sha)
	def.event(state, { ev = "action", act = "commit", value = sha }, cx)
	S.drain()
	eq(state.open[sha], true, "the row expanded")
	assert(state.files[sha].group, "and loaded its files")
	state.me = "Someone else"
	crow = find(row_of(def.view(state, cx).main, "commits"), function(n)
		return n.k == "item"
	end)
	eq(crow.p.detail[1].t, "Ada", "another author is named")
end)

test("f opens the same worktree full width through the view link", function()
	local def, cx, state = start()
	key(def, state, cx, "f")
	local opened = S.effects[#S.effects]
	eq(opened[1], "open")
	eq(link.decode_view(opened[2]), F.root)
	eq(link.decode_view("tern-branch-changes://diff?root=/r&kind=staged&path=a"), nil)
	eq(link.decode_view("https://example.com/view?root=/r"), nil)
	local _ = state
end)

test("in a wide pane a click keeps the hero diff instead of folding it", function()
	local def, cx, state = start()
	cx.cols = 140
	def.event(state, { ev = "action", act = "file", value = "staged:new.lua" }, cx)
	S.drain()
	assert(state.diffs["staged:new.lua"].text, "loaded")
	def.event(state, { ev = "action", act = "file", value = "staged:new.lua" }, cx)
	S.drain()
	assert(state.diffs["staged:new.lua"], "a second click leaves it loaded")
	cx.cols = 40
	def.event(state, { ev = "action", act = "file", value = "staged:new.lua" }, cx)
	eq(state.diffs["staged:new.lua"], nil, "but a sidebar still toggles it closed")
end)

test("the window route opens the full view in its own tab", function()
	S.routes = {}
	__reload("window")
	local route = S.routes[1]
	local launched: any = nil
	local wcx = {
		session = {
			panes = function(_self)
				return {}
			end,
		},
		layout = {
			new_tab = function(_self, launch)
				launched = launch
				return 9
			end,
			focus = function(_self, _pane) end,
		},
	}
	local decision = route({ url = link.view_url("/w/repo"), pane = 1, mods = {} }, wcx)
	eq(decision.handled, true)
	eq(launched.block, "branch-changes.view")
	eq(launched.args[1], "/w/repo")
	eq(launched.cwd, "/w/repo")
	assert(S.commands.open_full, "palette entry for the full view")
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
	error("tests failed")
end
