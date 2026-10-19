--!strict
-- The SpiderManData pack for the Luau CLI tests, read from the files tools/extract_pack.py writes (the same bytes
-- Decoder.payload returns in Studio: base64 joined, then Zstd). Studio code reads the pack with Decoder; both hand
-- the game the same tables.
local Json = require("./Json")

local Pack = {}
Pack.__index = Pack

local readfile: (string) -> string? = (_G :: any).readfile

function Pack.open(root: string)
	return setmetatable({ root = root }, Pack)
end

-- A text module's text ("Tuning/sandbox_air" -> its JSON text)
function Pack.text(self: any, path: string): string
	local s = readfile(self.root .. "/" .. path .. ".txt")
	assert(s, "pack: no " .. path)
	return s
end
function Pack.json(self: any, path: string): any
	return Json.decode(self:text(path))
end
-- A payload's bytes
function Pack.payload(self: any, path: string): buffer
	local s = readfile(self.root .. "/" .. path .. ".bin")
	assert(s, "pack: no payload " .. path)
	return buffer.fromstring(s)
end
function Pack.exists(self: any, path: string): boolean
	return readfile(self.root .. "/" .. path) ~= nil
end
-- The names listed under a folder (from index.txt)
function Pack.list(self: any, folder: string): { string }
	local idx = readfile(self.root .. "/index.txt") :: string
	local seen, out = {}, {}
	local prefix = folder .. "/"
	for line in string.gmatch(idx, "[^\n]+") do
		if string.sub(line, 1, #prefix) == prefix then
			local rest = string.sub(line, #prefix + 1)
			local name = string.match(rest, "^([^/]+)") :: string
			name = string.gsub(name, "%.%w+$", "") :: string
			if not seen[name] then
				seen[name] = true
				table.insert(out, name)
			end
		end
	end
	table.sort(out)
	return out
end

return Pack
