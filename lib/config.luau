--!strict
-- `.tern/branch-changes.json` in the worktree root, validated field by field.
-- A bad field falls back to its default and adds a warning; it never fails the block.

local M = {}

export type Config = {
	base: { string },
	max_commits: number,
	max_files: number,
	show_branch_total: boolean,
	untracked: string, -- "normal" | "all" | "no"
}

M.PATH = ".tern/branch-changes.json"
M.MAX_BYTES = 64 * 1024

function M.defaults(): Config
	return {
		base = { "origin/dev", "origin/main" },
		max_commits = 200,
		max_files = 2000,
		show_branch_total = true,
		untracked = "normal",
	}
end

local function int_in(v: any, lo: number, hi: number): number?
	if type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi then
		return v
	end
	return nil
end

-- Validates a decoded JSON value; returns the config and any warnings.
function M.normalize(raw: any): (Config, { string })
	local cfg = M.defaults()
	local warnings: { string } = {}
	if raw == nil then
		return cfg, warnings
	end
	if type(raw) ~= "table" then
		return cfg, { "config must be a JSON object" }
	end
	local function warn(field: string, expected: string)
		table.insert(warnings, string.format("%s: expected %s; using the default", field, expected))
	end

	if raw.base ~= nil then
		local refs: { string } = {}
		local ok = type(raw.base) == "table"
		if ok then
			for _, ref in raw.base do
				if type(ref) ~= "string" or ref == "" or string.sub(ref, 1, 1) == "-" then
					ok = false
					break
				end
				table.insert(refs, ref)
			end
		end
		if ok and #refs > 0 then
			cfg.base = refs
		else
			warn("base", "a non-empty list of ref names")
		end
	end
	if raw.max_commits ~= nil then
		local n = int_in(raw.max_commits, 1, 1000)
		if n then
			cfg.max_commits = n
		else
			warn("max_commits", "an integer 1-1000")
		end
	end
	if raw.max_files ~= nil then
		local n = int_in(raw.max_files, 1, 10000)
		if n then
			cfg.max_files = n
		else
			warn("max_files", "an integer 1-10000")
		end
	end
	if raw.show_branch_total ~= nil then
		if type(raw.show_branch_total) == "boolean" then
			cfg.show_branch_total = raw.show_branch_total
		else
			warn("show_branch_total", "true or false")
		end
	end
	if raw.untracked ~= nil then
		if raw.untracked == "normal" or raw.untracked == "all" or raw.untracked == "no" then
			cfg.untracked = raw.untracked
		else
			warn("untracked", '"normal", "all" or "no"')
		end
	end
	return cfg, warnings
end

-- Reads and validates the config for `root` (host only: uses `tern.fs`).
function M.load(root: string): (Config, { string })
	local path = root .. "/" .. M.PATH
	if not tern.fs.exists(path) then
		return M.defaults(), {}
	end
	local ok, text = pcall(tern.fs.read, path, M.MAX_BYTES)
	if not ok then
		return M.defaults(), { M.PATH .. ": " .. tostring(text) }
	end
	local decoded, value = pcall(tern.json.decode, text)
	if not decoded then
		return M.defaults(), { M.PATH .. ": " .. tostring(value) }
	end
	local cfg, warnings = M.normalize(value)
	for i, w in warnings do
		warnings[i] = M.PATH .. ": " .. w
	end
	return cfg, warnings
end

return M
