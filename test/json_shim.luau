--!nonstrict
-- Minimal `tern.json.decode` stand-in for the Luau CLI (which has no `tern`).
-- Just enough JSON for the fixtures: objects, arrays, strings, numbers, booleans.

local M = {}

local null = {}
M.null = null

function M.decode(text)
	local pos = 1
	local function fail(msg)
		error(msg .. " at " .. pos, 0)
	end
	local function skip()
		pos = string.find(text, "[^ \t\r\n]", pos) or (#text + 1)
	end
	local value
	local function str()
		pos += 1
		local out = {}
		while true do
			local c = string.sub(text, pos, pos)
			if c == "" then fail("unterminated string") end
			if c == '"' then pos += 1 break end
			if c == "\\" then
				local e = string.sub(text, pos + 1, pos + 1)
				local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f", ["/"] = "/", ["\\"] = "\\", ['"'] = '"' }
				if e == "u" then
					table.insert(out, utf8.char(tonumber(string.sub(text, pos + 2, pos + 5), 16)))
					pos += 6
				elseif map[e] then
					table.insert(out, map[e])
					pos += 2
				else
					fail("bad escape")
				end
			else
				table.insert(out, c)
				pos += 1
			end
		end
		return table.concat(out)
	end
	function value()
		skip()
		local c = string.sub(text, pos, pos)
		if c == "{" then
			pos += 1
			local obj = {}
			skip()
			if string.sub(text, pos, pos) == "}" then pos += 1 return obj end
			while true do
				skip()
				if string.sub(text, pos, pos) ~= '"' then fail("expected key") end
				local k = str()
				skip()
				if string.sub(text, pos, pos) ~= ":" then fail("expected ':'") end
				pos += 1
				obj[k] = value()
				skip()
				local d = string.sub(text, pos, pos)
				pos += 1
				if d == "}" then return obj end
				if d ~= "," then fail("expected ',' or '}'") end
			end
		elseif c == "[" then
			pos += 1
			local arr = {}
			skip()
			if string.sub(text, pos, pos) == "]" then pos += 1 return arr end
			while true do
				table.insert(arr, value())
				skip()
				local d = string.sub(text, pos, pos)
				pos += 1
				if d == "]" then return arr end
				if d ~= "," then fail("expected ',' or ']'") end
			end
		elseif c == '"' then
			return str()
		elseif string.sub(text, pos, pos + 3) == "true" then
			pos += 4 return true
		elseif string.sub(text, pos, pos + 4) == "false" then
			pos += 5 return false
		elseif string.sub(text, pos, pos + 3) == "null" then
			pos += 4 return null
		end
		local num = string.match(text, "^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
		if num and num ~= "" then
			pos += #num
			return tonumber(num)
		end
		fail("unexpected character '" .. c .. "'")
	end
	local v = value()
	skip()
	if pos <= #text then fail("trailing data") end
	return v
end

return M
