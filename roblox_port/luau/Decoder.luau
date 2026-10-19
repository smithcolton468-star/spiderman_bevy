--!native
-- Reads the SpiderManData pack that roblox_port/tools/build_roblox_pack.py writes.
-- The binary layouts are described in roblox_port/FORMAT.md.
--
-- parseClip and parseMesh are pure and run in any Luau. The load functions read the packed ModuleScripts and need
-- Roblox (EncodingService for base64 and Zstd, HttpService for JSON).

local Decoder = {}

export type Channel = {
	interp: number, -- 0 = LINEAR (lerp / slerp), 1 = STEP
	times: { number }, -- key times in seconds, shared by the clip's channels that use the same set
	keys: number, -- keys stored: 1 when the channel is constant, else #times
	constant: boolean,
	width: number, -- 3 for translation and scale, 4 for rotation (x, y, z, w)
	offset: number, -- byte offset of key 1 in clip.values; keys are stored key-major as f32
}

export type JointChannels = { T: Channel?, R: Channel?, S: Channel? }

export type Clip = {
	name: string,
	duration: number,
	joints: number,
	channels: { JointChannels }, -- [skin joint index + 1]
	values: buffer,
}

export type Mesh = {
	vertexCount: number,
	vertices: buffer, -- f32 x, y, z per vertex, metres, the mesh's own space
	indexCount: number,
	indices: buffer, -- u32 per index, three per triangle, in the file's order
}

local PATHS = { "T", "R", "S" }
local TWO32 = 4294967296

function Decoder.parseClip(b: buffer): Clip
	assert(buffer.readstring(b, 0, 4) == "SMC1", "not a SpiderManData clip")
	local o = 4
	local nameLen = buffer.readu16(b, o)
	o += 2
	local name = buffer.readstring(b, o, nameLen)
	o += nameLen
	local duration = buffer.readf32(b, o)
	o += 4
	local joints = buffer.readu16(b, o)
	o += 2
	local setCount = buffer.readu16(b, o)
	o += 2
	local sets = table.create(setCount)
	for s = 1, setCount do
		local n = buffer.readu32(b, o)
		o += 4
		local t = table.create(n)
		for k = 1, n do
			t[k] = buffer.readf32(b, o)
			o += 4
		end
		sets[s] = t
	end
	local channelCount = buffer.readu32(b, o)
	o += 4
	assert(channelCount == joints * 3, "one channel slot per joint and path")
	local headerAt = o
	o += channelCount * 7
	local valueCount = buffer.readu32(b, o)
	o += 4
	-- the value words are stored as four byte planes: byte k of word i is at plane k, position i
	local p0, p1, p2, p3 = o, o + valueCount, o + 2 * valueCount, o + 3 * valueCount
	local function word(i: number): number
		return buffer.readu8(b, p0 + i)
			+ buffer.readu8(b, p1 + i) * 256
			+ buffer.readu8(b, p2 + i) * 65536
			+ buffer.readu8(b, p3 + i) * 16777216
	end
	local values = buffer.create(valueCount * 4)
	local channels = table.create(joints)
	local at = 0 -- position in the value stream, in words
	for j = 1, joints do
		local entry = {}
		for p = 1, 3 do
			local h = headerAt + ((j - 1) * 3 + (p - 1)) * 7
			local flags = buffer.readu8(b, h)
			if bit32.band(flags, 4) ~= 0 then
				local set = buffer.readu16(b, h + 1)
				local keys = buffer.readu32(b, h + 3)
				local width = if p == 2 then 4 else 3
				local constant = bit32.band(flags, 8) ~= 0
				local offset = at * 4
				if constant then
					for c = 0, width - 1 do
						buffer.writeu32(values, offset + c * 4, word(at + c))
					end
				else
					-- stored component by component, each a run of differences of the f32 bit patterns
					for c = 0, width - 1 do
						local run = at + c * keys
						local bits = 0
						for k = 0, keys - 1 do
							local w = word(run + k)
							bits = if k == 0 then w else (bits + w) % TWO32
							buffer.writeu32(values, offset + (k * width + c) * 4, bits)
						end
					end
				end
				at += width * keys
				entry[PATHS[p]] = {
					interp = bit32.band(flags, 3),
					times = sets[set + 1],
					keys = keys,
					constant = constant,
					width = width,
					offset = offset,
				}
			end
		end
		channels[j] = entry
	end
	assert(at == valueCount, "value stream fully used")
	return {
		name = name,
		duration = duration,
		joints = joints,
		channels = channels,
		values = values,
	}
end

function Decoder.parseMesh(b: buffer): Mesh
	assert(buffer.readstring(b, 0, 4) == "SMM1", "not a SpiderManData mesh")
	local vertexCount = buffer.readu32(b, 4)
	local vertices = buffer.create(vertexCount * 12)
	buffer.copy(vertices, 0, b, 8, vertexCount * 12)
	local o = 8 + vertexCount * 12
	local indexCount = buffer.readu32(b, o)
	local indices = buffer.create(indexCount * 4)
	buffer.copy(indices, 0, b, o + 4, indexCount * 4)
	return { vertexCount = vertexCount, vertices = vertices, indexCount = indexCount, indices = indices }
end

-- Roblox side ---------------------------------------------------------------------------------------------------

local function source(module: Instance): string
	return (require :: any)(module)
end

-- A JSON ModuleScript (it returns the text) decoded with HttpService (no HTTP access is needed for JSONDecode)
function Decoder.json(module: Instance): any
	return game:GetService("HttpService"):JSONDecode(source(module))
end

-- A payload folder: ModuleScripts "001", "002", ... that each return part of one base64 text, then Zstd
function Decoder.payload(folder: Instance, compression: string): buffer
	local EncodingService = game:GetService("EncodingService")
	local parts = folder:GetChildren()
	table.sort(parts, function(a, b)
		return a.Name < b.Name
	end)
	local decoded = table.create(#parts)
	local total = 0
	for i, part in parts do
		-- each part is a whole number of base64 quads, so the parts decode on their own
		local bin = EncodingService:Base64Decode(buffer.fromstring(source(part)))
		decoded[i] = bin
		total += buffer.len(bin)
	end
	local joined = buffer.create(total)
	local o = 0
	for _, bin in decoded do
		buffer.copy(joined, o, bin)
		o += buffer.len(bin)
	end
	if compression == "zstd" then
		return EncodingService:DecompressBuffer(joined, Enum.CompressionAlgorithm.Zstd)
	end
	assert(compression == "none", "unknown compression " .. compression)
	return joined
end

-- Every clip in the pack, by name. `root` is the SpiderManData folder.
function Decoder.loadClips(root: Instance): { [string]: Clip }
	local info = Decoder.json(root:FindFirstChild("PackInfo") :: Instance)
	local clips = {}
	for _, folder in (root:FindFirstChild("Clips") :: Instance):GetChildren() do
		local clip = Decoder.parseClip(Decoder.payload(folder, info.compression))
		assert(clip.name == folder.Name, "clip folder and payload agree")
		clips[clip.name] = clip
	end
	return clips
end

-- The collision models (by id) and the index that says which glTF primitive each one is
function Decoder.loadCollision(root: Instance): ({ [string]: Mesh }, any)
	local info = Decoder.json(root:FindFirstChild("PackInfo") :: Instance)
	local collision = root:FindFirstChild("Collision") :: Instance
	local index = Decoder.json(collision:FindFirstChild("Index") :: Instance)
	local meshes = {}
	for _, folder in (collision:FindFirstChild("Models") :: Instance):GetChildren() do
		meshes[folder.Name] = Decoder.parseMesh(Decoder.payload(folder, info.compression))
	end
	return meshes, index
end

return Decoder
