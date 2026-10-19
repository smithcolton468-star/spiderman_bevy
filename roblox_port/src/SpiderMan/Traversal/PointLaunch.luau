--!strict
-- Port of crates/sm_traversal/src/point_launch.rs: Hero::HeroStateZipToPointLaunchLocal (Spider-Man.exe 4.0630, vtable
-- exe+38d5dd0): how a zip to a point ends in a point launch. The state's frame (exe+b1d640), its transition check
-- (exe+b19fb0) and the checks ahead of the launch (exe+b1d250, exe+b1be00):
--   - the press: the jump button (buffered 0.1 s, exe+909320) starts a clock (+0x250) that runs until the launch;
--   - the direction (at the zip's end): the stick's way when within MaxExitAngle (35 degrees) of the zip's; the zip's
--     turned MaxExitAngle toward the stick up to 120 degrees off; pulled back further, the zip's, with the stick's
--     amount negative (the "back" exit);
--   - the launch: speed, height and time to the top from PointLaunchConfig's exit data (zero, toward full by the
--     stick's amount, or toward back), plus their bonuses scaled by the boost: 1 - remap(clock, BoostWindowMin,
--     BoostWindowMax), at least BoostMinApply. The vertical speed and the gravity reach that height in that time;
--     GravityFall after the top. Into HeroStateJump, kind 0x2a.
--   - clearing what is ahead: casts from the point along the launch at 2 to 9 m up, under the ceiling, find a wall in
--     the way; the launch then rises enough to clear its top by 1.25 m (slower if need be), or, with no top in reach,
--     goes lower and slower so it doesn't hit it.
local Math = require("./Math")
local Air = require("./Air")
local V3 = Math.V3
type V3 = Math.V3

local new = V3.new
local fmin, fmax, clamp, unlerp = Math.fmin, Math.fmax, Math.clamp, Math.unlerp
local RAD, DEG = Math.RAD, Math.DEG

local PointLaunch = {}

-- The jump press the state reads is buffered this long (exe+909320's window in exe+b1d640)
PointLaunch.PRESS_BUFFER = 0.1

-- Which exit data a launch reads (exe+b19fb0)
PointLaunch.Exit = { Point = "Point", PerchToPerch = "PerchToPerch", AutoVault = "AutoVault" }

-- exe+b1d640 at the end of the zip: the launch's direction (+0x1fc) and the stick's signed amount (+0x208).
-- `zip`: the zip's flat direction (+0x1f0); `prev`: the direction kept from the frame before (the zip's, on the first);
-- `stick`: the stick's flat direction in the world and its amount (exe+b7e920).
function PointLaunch.exit_direction(cfg: any, zip: V3, prev: V3, stick: V3, amount: number): (V3, number)
	if amount <= 0.05 then
		return prev, amount
	end
	-- the angle from the zip's way to the stick's, about up (positive: to his left)
	local side, _, fwd = Math.basis(zip, V3.UP)
	local a = Math.atan2(side:dot(stick), fwd:dot(stick)) * RAD
	if math.abs(a) < cfg.max_exit_angle then
		return stick, amount
	elseif math.abs(a) < 120 then
		local s = if a < 0 then -DEG else DEG
		return Math.rotate(zip, V3.UP, cfg.max_exit_angle * s), amount
	else
		return prev, -amount
	end
end

-- exe+b19fb0: the boost for a press `clock` seconds before the launch
function PointLaunch.boost(cfg: any, clock: number): number
	return fmax(1 - unlerp(clock, cfg.boost_window_min, cfg.boost_window_max), cfg.boost_min_apply)
end

-- What exe+b1d250's casts found ahead of the point. They start from the point at 2 to 9 m up and go 16 m along the
-- launch's direction (0.25 m spheres), below the ceiling a cast straight up finds (0.3 m sphere, to 21 m).
export type Probes = {
	-- +0x164..: the flat distance to what blocks each height in turn from 2 m up (1e30 past the last)
	blocked: { number },
	-- +0x184: the nearest of them
	nearest: number,
	-- +0x188: 1e30 when nothing blocks at 2 m; 0 when every height under the ceiling is blocked; else the first clear
	-- height above the blocked ones
	clear: number,
}

function PointLaunch.CLEAR(): Probes
	return { blocked = table.create(8, 1e30), nearest = 1e30, clear = 1e30 }
end

-- Heights of the casts above the point (k = 0..7)
function PointLaunch.height(k: number): number
	return 2 + k
end

-- exe+b1d250's reading: `ceiling`, the height above the point of what the cast up hit; `hit(k)`, the flat distance
-- from the point to what the cast at `height(k)` hit
function PointLaunch.read(ceiling: number?, hit: (number) -> number?): Probes
	local p = PointLaunch.CLEAR()
	local ceil_ = ceiling or 1e30
	for k = 0, 7 do
		if PointLaunch.height(k) > ceil_ then
			break
		end
		local d = hit(k)
		if d == nil then
			if p.clear == 0 then
				p.clear = PointLaunch.height(k)
			end
			break
		else
			p.blocked[k + 1] = d
			p.nearest = fmin(p.nearest, d)
			p.clear = 0
		end
	end
	return p
end

-- A launch: what HeroStateJump is asked for
export type Launch = {
	-- the launch velocity (the horizontal part, and the vertical speed)
	velocity: V3,
	-- gravity until the top, and after it (GravityFall)
	gravity: number,
	gravity_fall: number,
	-- the boost (0 without a timed press)
	boost: number,
	-- +0x264: 2 when the boost reached BoostMaxFXPerc (the full effect), 1 with a press, 0 without
	fx: number,
	-- the launch had to go lower (its animation switches from 0xd1f08899 to 0xf5f636ff)
	lowered: boolean,
}

function PointLaunch.entry(l: Launch): Air.AirEntry
	return Air.point_launch(l.velocity, l.gravity, l.gravity_fall)
end

-- exe+a2f110: v at length `l` (along x when v is zero)
local scaled = Air.scaled

-- exe+b1be00: the launch against what is ahead (the launch's gravity changes only when it has to go lower). Returns
-- the new velocity, gravity and lowered flag.
local function clear_ahead(p: Probes, v: V3, g: number, lowered: boolean): (V3, number, boolean)
	if p.clear == 0 then
		-- a wall with no top in reach: arrive at it no sooner than 0.9 of the way to the top, lower if it is near
		local vy = v.y
		local t = vy / g
		local reach = p.nearest / v:flat_len()
		if reach < t * 0.6 and not lowered then
			local h = (vy * t - t * t * g * 0.5) * 0.925
			t *= 0.85
			lowered = true
			local vy2 = (h + h) * (1 / t)
			v = new(v.x, vy2, v.z)
			g = (1 / t) * vy2
		end
		local s = fmin((1.111111 / t) * reach, 1)
		return new(v.x * s, v.y, v.z * s), g, lowered
	end
	-- a wall with a top: rise to clear it by 1.25 m, slower if it is close
	for _, d in p.blocked do
		if d == 1e30 then
			return v, g, lowered
		end
		local vy = v.y
		local peak = vy / g
		local speed = v:flat_len()
		local half = g * 0.5
		local need = p.clear + 1.25
		local t = d / speed
		if need - 0.1 < vy * t - t * half * t or peak < t then
			return v, g, lowered
		end
		local k = clamp(t / peak, 0, 1)
		k = clamp(k * 1.515152, 0, 1)
		local speed2 = speed * (k * 0.97 + 0.03)
		local t2 = d / speed2
		local vy2 = fmin(fmax((t2 * half * t2 + need) / t2, vy), 50)
		local h = new(v.x, 0, v.z):norm()
		v = new(h.x * speed2, vy2, h.z * speed2)
		if Math.pitch_of(v) * -RAD > 55 then
			lowered = true
		end
	end
	return v, g, lowered
end

-- exe+b19fb0: the launch in direction `dir` (flat) with the stick's signed `amount`, `press` the clock since the jump
-- press (nil: launched without one), `probes` what is ahead of the point
function PointLaunch.launch(cfg: any, exit: string, dir: V3, amount: number, press: number?, probes: Probes): Launch
	local a, b, f
	if exit == "PerchToPerch" then
		a, b, f = cfg.perch_to_perch_point_launch, cfg.perch_to_perch_point_launch, amount
	elseif exit == "AutoVault" then
		a, b, f = cfg.auto_vault, cfg.auto_vault, amount
	elseif amount < 0 then
		a, b, f = cfg.exit_data_zero, cfg.exit_data_back, math.abs(amount)
	else
		a, b, f = cfg.exit_data_zero, cfg.exit_data_full, amount
	end
	local function l(x: number, y: number): number
		return (y - x) * f + x
	end
	local speed = l(a.launch_speed, b.launch_speed)
	local height = l(a.jump_height, b.jump_height)
	local time = l(a.time_to_peak, b.time_to_peak)
	local bst, fx = 0, 0
	if press ~= nil and exit ~= "AutoVault" then
		bst = PointLaunch.boost(cfg, press)
		speed += l(a.launch_speed_bonus, b.launch_speed_bonus) * bst
		time += l(a.time_to_peak_bonus, b.time_to_peak_bonus) * bst
		fx = if cfg.boost_max_fx_perc <= bst then 2 else 1
		height += l(a.jump_height_bonus, b.jump_height_bonus) * bst
	end
	local vy = (height + height) * (1 / time)
	local gravity = (1 / time) * vy
	local v = scaled(dir, speed)
	v = new(v.x, vy, v.z)
	local lowered = false
	if exit ~= "AutoVault" then
		v, gravity, lowered = clear_ahead(probes, v, gravity, lowered)
	end
	return {
		velocity = v,
		gravity = gravity,
		gravity_fall = cfg.gravity_fall,
		boost = bst,
		fx = fx,
		lowered = lowered,
	}
end

return PointLaunch
