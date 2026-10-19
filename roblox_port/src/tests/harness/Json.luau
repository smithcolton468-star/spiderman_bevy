--!strict
-- A JSON decoder for the Luau CLI tests (Studio uses HttpService:JSONDecode). Numbers go through tonumber, which is
-- strtod: correctly rounded, like Roblox's decoder. null decodes to nil, as JSONDecode does.
local Json = {}

local byte, sub, find = string.byte, string.sub, string.find

local function decode(s: string): any
	local i = 1
	local function ws()
		local _, e = find(s, "^[ \n\r\t]*", i)
		i = (e :: number) + 1
	end
	local value: () -> any
	local function str(): string
		-- at the opening quote
		i += 1
		local parts = {}
		while true do
			local a, b = find(s, '["\\]', i)
			assert(a, "unterminated string")
			table.insert(parts, sub(s, i, a - 1))
			if sub(s, a, a) == '"' then
				i = a + 1
				break
			end
			local c = sub(s, a + 1, a + 1)
			if c == "u" then
				local cp = tonumber(sub(s, a + 2, a + 5), 16) :: number
				i = a + 6
				if cp >= 0xD800 and cp <= 0xDBFF and sub(s, i, i + 1) == "\\u" then
					local lo = tonumber(sub(s, i + 2, i + 5), 16) :: number
					cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
					i += 6
				end
				table.insert(parts, utf8.char(cp))
			else
				local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
				table.insert(parts, map[c] or c)
				i = a + 2
			end
		end
		return table.concat(parts)
	end
	function value(): any
		ws()
		local c = byte(s, i)
		if c == 123 then -- {
			i += 1
			local t = {}
			ws()
			if byte(s, i) == 125 then
				i += 1
				return t
			end
			while true do
				ws()
				local k = str()
				ws()
				assert(byte(s, i) == 58, "expected :")
				i += 1
				t[k] = value()
				ws()
				local d = byte(s, i)
				i += 1
				if d == 125 then
					return t
				end
				assert(d == 44, "expected , in object")
			end
		elseif c == 91 then -- [
			i += 1
			local t = {}
			ws()
			if byte(s, i) == 93 then
				i += 1
				return t
			end
			local n = 0
			while true do
				n += 1
				t[n] = value()
				ws()
				local d = byte(s, i)
				i += 1
				if d == 93 then
					return t
				end
				assert(d == 44, "expected , in array")
			end
		elseif c == 34 then
			return str()
		elseif sub(s, i, i + 3) == "true" then
			i += 4
			return true
		elseif sub(s, i, i + 4) == "false" then
			i += 5
			return false
		elseif sub(s, i, i + 3) == "null" then
			i += 4
			return nil
		else
			local a, b = find(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", i)
			assert(a, "bad JSON at " .. i)
			local v = tonumber(sub(s, a, b))
			i = (b :: number) + 1
			return v
		end
	end
	local v = value()
	return v
end
Json.decode = decode

return Json
