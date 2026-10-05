-- A stand-in for the `tern` global, enough to run the plugin under the plain
-- `luau` CLI. UI builders return the documented node shapes; processes answer
-- from tests/fixtures.luau; timers and process callbacks wait in a queue that
-- `drain` runs, so tests control when async work lands.

local fixtures = require("./fixtures")

local S = {}

S.fixtures = fixtures
S.queue = {} :: { () -> () }
S.timers = {} :: { { at: number, fn: () -> (), cancelled: boolean } }
S.clock = 0
S.panes = {} :: { { pane: number, cwd: string?, program: string, title: string, busy: boolean } }
S.blocks = {} :: { [string]: any }
S.handlers = {} :: { [string]: { (...any) -> ...any } }
S.kv = {} :: { [string]: any }
S.files = {} :: { [string]: boolean }
S.ran = {} :: { string }
S.effects = {} :: { { string } }

local function node(k: string, p: { [string]: any }?, c: { any }?)
	local n: { [string]: any } = { k = k }
	if p and next(p) ~= nil then
		n.p = p
	end
	if c and #c > 0 then
		n.c = c
	end
	return n
end

local ui = {}
function ui.span(t, s)
	return { t = tostring(t), s = if s ~= "" then s else nil }
end
function ui.text(spans)
	return node("text", { spans = spans })
end
function ui.col(c)
	return node("col", { gap = "sm" }, c)
end
function ui.row(c)
	return node("row", { gap = "sm" }, c)
end
function ui.card(head, c)
	return node("card", { head = head }, c)
end
function ui.section(head, c)
	return node("section", { head = head }, c)
end
function ui.badge(t, tone)
	return node("badge", { text = t, tone = tone })
end
function ui.diff(text, path)
	return node("diff", { text = text, path = path })
end
function ui.node(k, p, c)
	return node(k, p, c)
end
function ui.list(items)
	local c = {}
	for i, it in items do
		c[i] = node("item", { label = it.label, detail = it.detail, value = it.value, icon = it.icon, tone = it.tone })
	end
	return node("list", nil, c)
end

local function queue(fn)
	table.insert(S.queue, fn)
end

local tern = {
	context = "host",
	plugin = { id = "branch-changes", name = "Branch Changes", dir = "/plugin", data = "/data" },
	ui = ui,
	log = { debug = print, info = print, warn = print, error = print },
	json = {
		null = {},
		array = function(t)
			return t or {}
		end,
		decode = function(_text)
			error("json.decode not stubbed")
		end,
	},
	now = function()
		return S.clock
	end,
	kv = {
		get = function(k)
			return S.kv[k]
		end,
		set = function(k, v)
			S.kv[k] = v
		end,
	},
	fs = {
		exists = function(path)
			return S.files[path] == true
		end,
		read = function(path)
			error("tern.fs.read " .. path .. ": not found")
		end,
	},
	pane = {
		list = function()
			return S.panes
		end,
		write = function() end,
	},
	block = {
		define = function(id, def)
			S.blocks[id] = def
		end,
	},
	on = function(name, fn)
		S.handlers[name] = S.handlers[name] or {}
		table.insert(S.handlers[name], fn)
	end,
	timer = function(ms, fn)
		local t = { at = S.clock + ms, fn = fn, cancelled = false }
		table.insert(S.timers, t)
		return {
			cancel = function(self)
				t.cancelled = true
			end,
		}
	end,
	process = {
		run = function(argv, opts, cb)
			local key = table.concat(argv, " ")
			table.insert(S.ran, key)
			local r = fixtures.runs[key]
			if r == nil then
				error("no fixture for: " .. key .. " (run python3 tests/record.py?)")
			end
			queue(function()
				cb({ status = r.status, stdout = r.stdout, stderr = r.stderr, timed_out = false })
			end)
		end,
	},
}
S.tern = tern

-- Runs queued process callbacks until none are left.
function S.drain()
	local guard = 0
	while #S.queue > 0 do
		guard += 1
		assert(guard < 10000, "queue never drained")
		local fn = table.remove(S.queue, 1) :: () -> ()
		fn()
	end
end

-- Advances the clock by `ms`, firing due timers and draining after each.
function S.advance(ms: number)
	S.clock += ms
	local fired = true
	while fired do
		fired = false
		for i, t in S.timers do
			if not t.cancelled and t.at <= S.clock then
				table.remove(S.timers, i)
				t.fn()
				S.drain()
				fired = true
				break
			end
		end
	end
end

-- A BlockCx that records renders and effects.
function S.cx(pane: number, cwd: string?)
	local cx = { pane = pane, cwd = cwd, cols = 80, rows = 40, renders = 0 }
	function cx.render(self)
		self.renders += 1
	end
	function cx.save(self) end
	function cx.exit(self) end
	function cx.toast(self, level, text, sub)
		table.insert(S.effects, { "toast", level, text, sub or "" })
	end
	function cx.open(self, target)
		table.insert(S.effects, { "open", target })
	end
	function cx.copy(self, text)
		table.insert(S.effects, { "copy", text })
	end
	return cx
end

return S
