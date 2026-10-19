-- Check 3: the Luau sm_traversal port against the game's own code, as crates/sm_traversal/tests/oracle_paths.rs does
-- it: each of the 11 OracleFixtures scenarios run closed loop from its starting conditions alone; every frame within
-- the scenario's tolerance of the game's path, in the same state, facing within 0.5 degrees.
-- Run: luau oracle_paths.luau -a <extracted pack dir> [trace dir]
local Pack = require("./harness/Pack")
local Config = require("../SpiderMan/Traversal/Config")
local Replay = require("../SpiderMan/Traversal/Replay")
local Math = require("../SpiderMan/Traversal/Math")
local V3 = Math.V3

local args = { ... }
local pack = Pack.open(args[1])
local traceDir = args[2]
local cfg = Config.embedded(function(name)
	return pack:json("Tuning/" .. name)
end)

local allOk = true
local rows = {}
for _, name in pack:list("OracleFixtures") do
	local sc = Replay.parse(pack:text("OracleFixtures/" .. name .. "/Scenario"))
	local game = pack:json("OracleFixtures/" .. name .. "/Game")
	local check = pack:json("OracleFixtures/" .. name .. "/Check")
	local t0 = os.clock()
	local path = Replay.run(sc, cfg)
	local ms = (os.clock() - t0) * 1000
	assert(#path == #game.mode, name .. ": frame count")
	local maxErr, maxFacing, modeBad, posBad, facingBad = 0, 0, 0, 0, 0
	local firstBad
	local lines = {}
	for k, p in path do
		local gp = game.pos[k]
		local g = V3.new(gp[1], gp[2], gp[3])
		local e = (p.pos - g):len()
		maxErr = math.max(maxErr, e)
		if not (e < check.position_tolerance_m) then
			posBad += 1
			firstBad = firstBad or k - 1
		end
		if p.mode ~= game.mode[k] then
			modeBad += 1
			firstBad = firstBad or k - 1
		end
		local gf = V3.new(game.fwd[k][1], 0, game.fwd[k][2]):norm()
		local df = math.deg(Math.angle_between(p.fwd:norm(), gf))
		maxFacing = math.max(maxFacing, df)
		if not (df < check.facing_tolerance_deg) then
			facingBad += 1
			firstBad = firstBad or k - 1
		end
		if traceDir then
			table.insert(lines, string.format("%d %d %.9g %.9g %.9g %.9g %.9g", k - 1, p.mode, p.pos.x, p.pos.y, p.pos.z, p.fwd.x, p.fwd.z))
		end
	end
	if traceDir then
		writefile(traceDir .. "/" .. name .. ".luau.txt", table.concat(lines, "\n") .. "\n")
	end
	local ok = modeBad == 0 and posBad == 0 and facingBad == 0
	allOk = allOk and ok
	table.insert(rows, string.format("%-13s %4d frames  max error %.5f m (tol %.2f)  max facing %.4f deg  mode mismatches %d  %s  (%.0f ms)%s",
		name, #path, maxErr, check.position_tolerance_m, maxFacing, modeBad, ok and "PASS" or "FAIL", ms,
		firstBad and ("  first bad frame " .. firstBad) or ""))
end
for _, r in rows do
	print(r)
end
print(allOk and "ALL 11 SCENARIOS PASS" or "SOME SCENARIOS FAIL")
