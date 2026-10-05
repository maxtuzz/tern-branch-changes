--!strict
-- Small string and time helpers shared by both halves.

local M = {}

function M.trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") or "")
end

-- Splits NUL-separated output (`git ... -z`), dropping the trailing empty token.
function M.split_nul(s: string): { string }
	local out = {}
	for token in string.gmatch(s, "([^%z]*)%z") do
		table.insert(out, token)
	end
	local tail = string.match(s, "([^%z]+)$")
	if tail then
		table.insert(out, tail)
	end
	return out
end

-- Whether `path` is `root` or lies inside it.
function M.under(path: string?, root: string?): boolean
	if path == nil or root == nil or root == "" then
		return false
	end
	local p = (string.gsub(path, "/+$", ""))
	local r = (string.gsub(root, "/+$", ""))
	return p == r or string.sub(p, 1, #r + 1) == r .. "/"
end

function M.basename(path: string): string
	return string.match(path, "([^/]+)/*$") or path
end

-- Splits "a/b/c.txt" into "a/b/" and "c.txt".
function M.split_path(path: string): (string, string)
	local dir, base = string.match(path, "^(.*/)([^/]+)$")
	if dir and base then
		return dir, base
	end
	return "", path
end

-- A compact age ("now", "5m", "3h", "2d", "4w", "3mo", "2y") for `seconds` ago.
function M.age(seconds: number): string
	local s = math.max(0, seconds)
	if s < 60 then
		return "now"
	elseif s < 3600 then
		return math.floor(s / 60) .. "m"
	elseif s < 86400 then
		return math.floor(s / 3600) .. "h"
	elseif s < 86400 * 14 then
		return math.floor(s / 86400) .. "d"
	elseif s < 86400 * 60 then
		return math.floor(s / (86400 * 7)) .. "w"
	elseif s < 86400 * 365 then
		return math.floor(s / (86400 * 30)) .. "mo"
	end
	return math.floor(s / (86400 * 365)) .. "y"
end

function M.contains(list: { string }?, value: string): boolean
	if list == nil then
		return false
	end
	for _, v in list do
		if v == value then
			return true
		end
	end
	return false
end

return M
