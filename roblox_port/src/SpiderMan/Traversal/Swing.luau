--!strict
-- Port of crates/sm_traversal/src/swing.rs: Hero::HeroStateSwingLocal (Spider-Man.exe 4.0630, vtable exe+38ce990): the
-- swing's motion. Entry exe+ab97e0, per frame exe+ac30e0 (input exe+abcf40, integration exe+abdb30, facing exe+abd820,
-- momentum exe+ac36f0), transition check exe+aba1f0 with the release velocity of exe+ac1680 and the automatic release
-- of exe+ac2200. Field comments give the state's offsets. (The Rust's SMT_DEBUG prints are left out.)
local Math = require("./Math")
local Config = require("./Config")
local Tracker = require("./Tracker")
local V3 = Math.V3
type V3 = Math.V3
type Rows = Math.Rows
type Configs = Config.Configs
type Tracker = Tracker.Tracker

local new = V3.new
local fmax, fmin, clamp = Math.fmax, Math.fmin, Math.clamp
local remap, unlerp, lerp, approach, approach_v = Math.remap, Math.unlerp, Math.lerp, Math.approach, Math.approach_v
local atan2, acos, sin, cos, exp = Math.atan2, Math.acos, Math.sin, Math.cos, Math.exp
local spring, wrap_pi, rotate, slerp, basis = Math.spring, Math.wrap_pi, Math.rotate, Math.slerp, Math.basis
local pitch_of, angle_between, dist, flat_dist = Math.pitch_of, Math.angle_between, Math.dist, Math.flat_dist
local RAD, DEG = Math.RAD, Math.DEG
local abs, sqrt = math.abs, math.sqrt

local Swing = {}

-- What the states read each frame
export type FrameInput = {
	-- left stick, x right, y forward (-1..1)
	stick: { number },
	-- the swing button (R2), 0..1
	swing_button: number,
	-- the jump button pressed within the buffer window (0.05 s): the swing's release event
	jump_pressed: boolean,
	-- the jump button held (the jumps' button thrust, exe+a87b90)
	jump_held: boolean,
	-- |right stick x| (the camera's look input)
	look: number,
}
function Swing.FrameInput(): FrameInput
	return { stick = { 0, 0 }, swing_button = 0, jump_pressed = false, jump_held = false, look = 0 }
end

export type Env = {
	-- the game clock (seconds)
	time: number,
	dt: number,
	-- the hero's rows as the state reads them (the mover's turn of the previous frame) and his position now
	hero: Rows,
	cam: Rows,
	-- the mover's velocity (its last move)
	mover_vel: V3,
	input: FrameInput,
}
function Swing.Env(): Env
	return {
		time = 0,
		dt = 0,
		hero = Math.Rows.default(),
		cam = Math.Rows.default(),
		mover_vel = V3.ZERO,
		input = Swing.FrameInput(),
	}
end

-- exe+b7e920 as ArkWeb's research harness stands in for it: the stick as a flat world direction seen from the camera
-- (the camera's side row points left), its magnitude with a radial dead zone 0.01..0.99, and its angle
function Swing.stick_world(env: Env): (V3, number, number)
	local x, y = env.input.stick[1], env.input.stick[2]
	local m = sqrt(x * x + y * y)
	local mag = clamp((m - 0.01) / (0.99 - 0.01), 0, 1)
	local angle = atan2(x, y)
	if mag <= 0.0001 then
		return V3.ZERO, mag, angle
	end
	local f = env.cam.fwd
	local s = env.cam.side
	local fl = sqrt(f.x * f.x + f.z * f.z)
	local sl = sqrt(s.x * s.x + s.z * s.z)
	local fx, fz, sx, sz = f.x / fl, f.z / fl, s.x / sl, s.z / sl
	local dx, dz = -sx * x + fx * y, -sz * x + fz * y
	local dl = sqrt(dx * dx + dz * dz)
	return new(dx / dl, 0, dz / dl), mag, angle
end
-- exe+1f2d8f0: the stick's magnitude and angle, no dead zone
function Swing.stick_raw(env: Env): (number, number)
	local x, y = env.input.stick[1], env.input.stick[2]
	return fmin(sqrt(x * x + y * y), 1), atan2(x, y)
end

-- The swing's entry data (built by the transition manager's slot 81, exe+97c470: constructor exe+ab3820, points
-- exe+ab5da0)
export type SwingEntry = {
	-- +0x24: the pivot (the hunter's anchor, pushed out from the wall)
	anchor: V3,
	-- +0x30: the web's point on the surface
	attach: V3,
	-- +0x54
	min_time: number,
	-- +0x6c flags: 1 input angle given (+0x58), 2 velocity given (+0x5c), 4 blend given (+0x68), 8 rising starts in
	-- the second phase, 0x40, 0x100 (a forward action just before)
	flags: number,
	input_angle: number,
	velocity: V3,
	blend: number,
}
function Swing.SwingEntry(anchor: V3, attach: V3): SwingEntry
	return { anchor = anchor, attach = attach, min_time = 0.2, flags = 0, input_angle = 0, velocity = V3.ZERO, blend = 0 }
end

-- The swing's processor (Hero::HeroStateSwing, the animation side) as far as the motion reads it: the anchor it slides
-- (exe+ab8410, ArkWeb's PivotDrift port)
export type SwingProcessor = { anchor: V3, pivot: V3, hold: V3, drift: number }
local Processor = {}
Swing.Processor = Processor
function Processor.new(): SwingProcessor
	-- +0x150 the anchor the swing reads each frame, +0x15c the pivot as the hunter placed it, +0x168 the hold (the
	-- web's surface point), +0x174 how far the anchor has slid (never back)
	return { anchor = V3.ZERO, pivot = V3.ZERO, hold = V3.ZERO, drift = 0 }
end
function Processor.start(self: SwingProcessor, e: SwingEntry)
	self.anchor = e.anchor
	self.pivot = e.anchor
	self.hold = e.attach
	self.drift = 0
end
-- exe+ab8410's first part: the anchor slides along a level segment at the hold's height, from the pivot toward a
-- point 1 m off the hold, by the larger of where he projects on it, (time - 2 s) * 2/3, and what it already slid
function Processor.drift(self: SwingProcessor, pos: V3, swing_time: number)
	local pv, ho = self.pivot, self.hold
	local dx, dz = pv.x - ho.x, pv.z - ho.z
	local m = fmax(abs(dx), abs(dz))
	if m > 0 then
		dx /= m
		dz /= m
		local l = 1 / sqrt(dx * dx + dz * dz)
		dx *= l
		dz *= l
	end
	local a = new(pv.x, ho.y, pv.z)
	local b = new(ho.x + dx, ho.y, ho.z + dz)
	local ab = b - a
	local l = ab:dot(ab)
	local u = if l >= 1e-8 then clamp((pos - a):dot(ab) / l, 0, 1) else 0
	local f = fmax(fmax(clamp((swing_time - 2) * 0.6666667, 0, 1), u), self.drift)
	self.drift = f
	self.anchor = new(a.x + ab.x * f, pv.y, a.z + ab.z * f)
end

-- The swing's obstacle probes (+0x120, exe+b919c0 / b90af0 / b90780): horizontal distances to what rays found, 40 m
-- when nothing. Filled by the host's ray casts; clear (all 40) by default, as in the research harness.
export type Probes = { center: { number }, side: { number }, stuck: number, blocked: number }
local Probes = {}
Swing.Probes = Probes
function Probes.new(): Probes
	-- +0x9c the fan ahead, read as c(i), i = -3..3; +0x160 the two side fans, s(i, side); +0x24c time stuck against
	-- something; +0x98 time the velocity sweep was blocked
	return { center = table.create(7, 40), side = table.create(8, 40), stuck = 0, blocked = 0 }
end
-- exe+b8fda0
function Probes.c(self: Probes, i: number): number
	return self.center[i + 3 + 1]
end
-- exe+b8fdb0
function Probes.count(self: Probes): number
	local i = 0
	while true do
		local n = i + 1
		if self.center[3 + 1] < n + n then
			break
		end
		i = n
		if n >= 4 then
			break
		end
	end
	return math.min(i, 3)
end
-- exe+b8fdf0
function Probes.s(self: Probes, i: number, flag: boolean): number
	return self.side[i + (if flag then 0 else 4) + 1]
end
-- exe+b91970: release because he is stuck
function Probes.blocked_(self: Probes): boolean
	return self.stuck > 0.05 or self.blocked > 0.1
end

-- What a frame of the swing hands the mover
export type SwingOutput = { displacement: V3, facing: V3, snap: boolean }

-- The release (exe+ac1680) handed to the transition manager's slot 82 (exe+97c9d0), which builds the swing jump
export type SwingRelease = {
	-- +0x540
	velocity: V3,
	-- +0x53c: the swing jump's rising gravity
	gravity: number,
	-- +0x538: released with the jump button (or the fast automatic release)
	jumped: boolean,
	-- the swing direction's pitch above level at release (+0x534, degrees)
	pitch: number,
	-- +0x528, +0x52c: the release animation's rate and blend
	anim_rate: number,
	anim_blend: number,
	-- +0x539: released high (above ReleaseAngleHighStart)
	high: boolean,
	-- the low or early release path (gravity 24)
	early: boolean,
}

local SwingLocal = {}
SwingLocal.__index = SwingLocal
Swing.SwingLocal = SwingLocal

-- SwingLocal::default()
local function defaults(s: any)
	-- +0xd8
	s.entry_time = 0
	s.probes = Probes.new()
	-- +0x398.. the rows the state copied this frame
	s.hero = Math.Rows.default()
	s.cam = Math.Rows.default()
	-- +0x418 the stick's world direction, +0x424 its magnitude, +0x428 its angle
	s.input_dir = V3.ZERO
	s.input_mag = 0
	s.input_angle = 0
	-- +0x42c, +0x430 (the throttle: forward stick along travel, negative pulling back), +0x434
	s.speed_input_smooth = -1
	s.speed_input = -1
	s.speed_input_hold = 0
	-- +0x438 the anchor (the processor's, each frame), +0x444 the web's surface point
	s.anchor = V3.ZERO
	s.attach = V3.ZERO
	-- +0x450
	s.min_time = 0.2
	-- +0x454.. the entry speed boost: target, base acceleration, acceleration, its growth, on
	s.boost_target = 0
	s.boost_accel_base = 0
	s.boost_accel = 0
	s.boost_accel_accel = 0
	s.boost_on = false
	-- +0x468 (the momentum stage's gravity scale at entry)
	s.gravity_scale = 1
	-- +0x46c
	s.speed_change = 1
	-- +0x470 push off obstacles (abb030), +0x47c the probes' turn scale
	s.push = V3.ZERO
	s.probe_turn_scale = 1
	-- +0x480, +0x48c the low point under a swing floor volume
	s.low_point = V3.ZERO
	s.has_low_point = false
	-- +0x490
	s.init_pull = -1
	-- +0x494.. the floor guard (abf850)
	s.floor_y = -1e30
	s.floor_rate = 0
	s.floor_vel = 0
	s.floor_acc = 0
	-- +0x4a4 the distance to the anchor at entry, +0x4a8 the sink speed
	s.rope_len0 = 0
	s.sink = 0
	-- +0x4ac, +0x4b0, +0x4b4 descending gravity: initial, final, and in the third phase
	s.grav_fall_initial = 0
	s.grav_fall_final = 0
	s.grav_fall_hold = 0
	-- +0x4b8 velocity, +0x4c4 its previous value
	s.vel = V3.ZERO
	s.prev_vel = V3.ZERO
	-- +0x4d0 the swing direction, +0x4dc the velocity along it, +0x4e8 last frame's direction
	s.dir = V3.ZERO
	s.along = V3.ZERO
	s.prev_dir = V3.ZERO
	-- +0x4f4, +0x4f8 (abc8c0)
	s.dir_spring_v = 0
	s.dir_time = 0
	-- +0x4fc, +0x500 (abb8e0)
	s.turn_v = 0
	s.turn_ramp = 0
	-- +0x504, +0x508 the facing twist spring
	s.twist_v = 0
	s.twist = 0
	-- +0x50c the entry blend toward the mover's velocity
	s.blend_in = 0
	-- +0x510, +0x514 the gravity blend and its delay
	s.gravity_blend = 1
	s.gravity_blend_delay = 0
	-- +0x518 the pivot factor (only decreases)
	s.pivot_factor = 1
	-- +0x51c terminal speed, +0x520 its minimum, +0x524 its maximum
	s.terminal = 0
	s.terminal_min = 0
	s.terminal_max = 0
	-- +0x528, +0x52c
	s.release_anim_rate = 1
	s.release_anim_blend = 0.35
	-- +0x530 the last frame's step
	s.last_dt = 0
	-- +0x534 the release pitch
	s.release_pitch = 0
	-- +0x54c his yaw rate (degrees per second)
	s.yaw_rate = 0
	-- +0x550 look input (eased), and the camera's look input this frame (camera vtable +0xa0)
	s.look = 0
	s.look_input = 0
	-- +0x554 the stick's direction at entry, +0x560 its angle
	s.entry_input_dir = V3.ZERO
	s.input_angle2 = 0
	-- +0x564, +0x568, +0x56c, +0x570
	s.entry_input_angle = 0
	s.input_agree = 0
	s.agree_peak = 0
	s.agree_timer = 0.3
	-- +0x574 0 falling into it, 1 past the bottom, 2 swinging back; +0x578 time in phase 2; +0x57c pulling back
	s.phase = 0
	s.phase_time = 0
	s.reverse = 0
	-- +0x580 the animation sub-state (stays 0 without the animation system, as in the research harness)
	s.sub_state = 0
	-- +0x5f0, +0x5f1 the release event, +0x5f3 first substep, +0x5f7 back swing, +0x5f8, +0x5f9, +0x5fa, +0x5fb
	s.b5f0 = false
	s.release_event = false
	s.first = true
	s.back_swing = false
	s.b5f8 = false
	s.b5f9 = false
	s.forward_action = false
	s.release_countdown = 2
end

export type SwingLocal = any

function SwingLocal.new(): SwingLocal
	local s = {}
	defaults(s)
	return setmetatable(s, SwingLocal)
end

function SwingLocal.clone(self: SwingLocal): SwingLocal
	local c = table.clone(self)
	c.probes = {
		center = table.clone(self.probes.center),
		side = table.clone(self.probes.side),
		stuck = self.probes.stuck,
		blocked = self.probes.blocked,
	}
	return setmetatable(c, SwingLocal)
end

-- exe+ab4450: the swing plane through the web point, his position and a direction. Returns its normal, the normal's
-- tilt (degrees, unsigned) and his angle round the swing (degrees; about 180 entering above, 90 under the point,
-- toward 0 up the far side)
local function rope_geometry(attach: V3, pos: V3, v: V3): (V3, number, number)
	local d = (attach - pos):norm()
	local k = v.x * d.x + v.y * d.y + v.z * d.z
	local p = new(v.x - d.x * k, v.y - d.y * k, v.z - d.z * k)
	local n = new(p.y * d.z - p.z * d.y, p.z * d.x - p.x * d.z, p.x * d.y - p.y * d.x):norm()
	local tilt = abs(pitch_of(n) * RAD)
	-- a level direction (b, 0, a) across the normal
	local a, b = -n.x, n.z
	local m = fmax(fmax(abs(a), 0), abs(b))
	if m > 0 then
		a *= 1 / m
		b *= 1 / m
		local l = 1 / sqrt(a * a + b * b)
		a *= l
		b *= l
	end
	local w = new(a * n.y, b * n.z - a * n.x, -(b * n.y)):norm()
	local s, u, f = basis(new(b, 0, a), w)
	local q = -d
	q = q - s * s:dot(q)
	q = q:norm()
	local qu, qf = u:dot(q), f:dot(q)
	local angle = angle_between(new(s:dot(q), qu, qf), new(0, 0, 1)) * RAD
	if qu > 0 then
		angle = if qf <= 0 then 360 - angle else -angle
	end
	return n, tilt, angle
end
Swing.rope_geometry = rope_geometry

-- exe+1c5a450: a vector of length `len` at heading `yaw` (atan2(x, z)) and elevation `pitch`
local function from_angles(yaw: number, pitch: number, len: number): V3
	local cp = cos(pitch)
	return new(sin(yaw) * len * cp, sin(pitch) * len, cos(yaw) * len * cp)
end

-- exe+1c5b5d0: from a toward b by t, direction by angle and length by lerp
local function slerp_scaled(a: V3, b: V3, t: number): V3
	local la = a:len()
	local lb = b:len()
	local an = if la >= 0.0001 then a * (1 / la) else a
	local bn = if lb >= 0.0001 then b * (1 / lb) else b
	local d = clamp(an:dot(bn), -1, 1)
	local perp = (bn - an * d):norm()
	local th = acos(d) * t
	local sn, cs = sin(th), cos(th)
	local l = (lb - la) * t + la
	return new((an.x * cs + sn * perp.x) * l, (an.y * cs + perp.y * sn) * l, (an.z * cs + perp.z * sn) * l)
end

-- exe+1c46f80: unit `from` turned toward unit `to` by one damped-spring step of the angle between them. Returns the
-- new direction and the new v.
local function vector_spring(from: V3, to: V3, v: number, a: number, b: number, c: number, dt: number): (V3, number)
	local ang = angle_between(from, to)
	local out = to
	if ang > 0.0001 then
		local axis = from:cross(to):norm()
		local step
		step, v = spring(0, ang, v, a, b, c, dt)
		out = rotate(from, axis, step)
		-- past the target: snap to it
		if out:cross(to):dot(axis) < 0 then
			v = ang / dt
			out = to
		end
	end
	return out:norm(), v
end

-- exe+2e7060: a 3x3 inverse (rows)
local function inverse3(m: { number }): { number }
	local a, b, c, d, e, f, g, h, i = m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9]
	local det = e * a * i + f * b * g + d * c * h - f * a * h - d * b * i - e * c * g
	if det == 0 then
		return table.create(9, 0)
	end
	local r = 1 / det
	return {
		(i * e - h * f) * r,
		(h * c - i * b) * r,
		(f * b - e * c) * r,
		(g * f - i * d) * r,
		(i * a - g * c) * r,
		(d * c - f * a) * r,
		(h * d - g * e) * r,
		(g * b - h * a) * r,
		(e * a - d * b) * r,
	}
end

-- exe+86c2a0: the hunter's heading for a new swing from the camera, his travel and the stick; true for a back swing
local function swing_heading(cam_flat: V3, travel: V3, input: V3): (V3, boolean)
	local t = clamp(angle_between(cam_flat, travel) * 1.909859 - 1, 0, 1)
	local mid = slerp(cam_flat, travel, t)
	local a = angle_between(input, mid) * RAD
	if a > 90 then
		if a < 135 then
			local d = input:dot(mid)
			return (input - mid * d):norm(), false
		end
		local t2 = clamp((a - 135) * 0.02857143, 0, 1) * 0.65 + 0.35
		return slerp(input, -mid, t2), true
	end
	return input, false
end
Swing.swing_heading = swing_heading

-- exe+20dc660: time in the state
function SwingLocal.age(self: SwingLocal, env: Env): number
	return Math.f64_elapsed(env.time, self.entry_time)
end

-- exe+abcf40: the frame's input, rows and throttle
function SwingLocal.read_input(self: SwingLocal, cfg: Configs, env: Env, dt: number)
	self.cam = env.cam
	self.hero = env.hero
	self.look_input = env.input.look
	self.input_mag = 0
	local dir, mag, angle = Swing.stick_world(env)
	self.input_dir = dir
	self.input_mag = mag
	self.input_angle = angle
	if self.forward_action then
		local cf = self.cam.fwd:flat_norm()
		if self.input_mag < 0.05 or cf:dot(self.input_dir) > 0.5 then
			self.forward_action = false
		else
			-- exe+b85760: the stick turned toward the camera's forward, at most 45 degrees off it
			local side = basis(cf, V3.UP)
			local a = angle_between(cf, self.input_dir)
			if a > 1.570796 then
				a = 3.141593 - a
			end
			local w = clamp(a * 0.6366197, 0, 1) * 0.7853982
			if side:dot(self.input_dir) <= 0 then
				w = -w
			end
			self.input_dir = rotate(cf, V3.UP, w)
			-- its angle in the camera's frame
			local cs, cu, cfw = self.cam.side, self.cam.up, self.cam.fwd
			local inv = inverse3({ cs.x, cs.y, cs.z, cu.x, cu.y, cu.z, cfw.x, cfw.y, cfw.z })
			local d = self.input_dir
			local lx = inv[1] * d.x + inv[4] * d.y + inv[7] * d.z
			local lz = inv[3] * d.x + inv[6] * d.y + inv[9] * d.z
			self.input_angle = atan2(lx, lz)
			self.input_angle2 = self.input_angle
		end
	end
	if self.input_mag < 0.05 then
		self.input_dir = self.cam.fwd:flat_norm()
	end
	local vf = self.vel:flat_norm()
	local d = vf.z * self.input_dir.z + vf.x * self.input_dir.x
	local m = self.input_mag
	if d >= -0.707 then
		local s = cfg.swing
		local x
		if m <= s.speed_input_mid then
			x = remap(m, s.speed_input_min, s.speed_input_mid) * s.speed_input_mid_value
		else
			local r = s.speed_input_max - s.speed_input_mid
			local t = if abs(r) > 0.0001 then clamp((m - s.speed_input_mid) / r, 0, 1) else 1
			x = (1 - s.speed_input_mid_value) * t + s.speed_input_mid_value
		end
		local smooth = self.speed_input_smooth
		if x < smooth then
			self.speed_input_hold = fmax(self.speed_input_hold - dt, 0)
			if self.speed_input_hold < 0.0001 then
				smooth = approach(smooth, x, 2, dt)
				self.speed_input_smooth = smooth
			end
		else
			self.speed_input_smooth = x
			self.speed_input_hold = 0.2
			smooth = x
		end
		self.speed_input = (fmax(d, 0) * 0.25 + 0.75) * smooth
	else
		self.speed_input = -m
		self.speed_input_smooth = -m
	end
end

-- exe+ac04f0: the velocity turned into the swing round the anchor: its heading kept, its pitch from the part across
-- the rope and the speed kept
function SwingLocal.swing_dir(self: SwingLocal, vel: V3, pos: V3, first_phase: boolean, prev: V3?): V3
	local raw = self.anchor - pos
	local d = raw:norm()
	local vn = vel:norm()
	local hz, hx = -d.x, d.z
	local m = fmax(fmax(abs(hz), 0), abs(hx))
	if m > 0 then
		hz *= 1 / m
		hx *= 1 / m
		local l = 1 / sqrt(hz * hz + hx * hx)
		hz *= l
		hx *= l
	end
	local speed = vel:len()
	local small = vel.x * vel.x + vel.z * vel.z < 0.001
	local k = vel.x * d.x + vel.y * d.y + vel.z * d.z
	local p = new(vel.x - k * d.x, vel.y - k * d.y, vel.z - k * d.z)
	local q = p.x * hx + p.z * hz
	local ax, az = hx * q, hz * q
	local p2x, p2z = p.x - ax, p.z - az
	local al = new(ax, 0, az):flat_len()
	local u = sqrt(fmax(speed * speed - al * al, 0))
	local len2 = p2x * p2x + p.y * p.y + p2z * p2z
	local wx, wy, wz
	if len2 >= 1e-15 then
		local f = u / sqrt(len2)
		wx, wy, wz = ax + p2x * f, f * p.y, az + p2z * f
	else
		wx, wy, wz = ax + u, 0, az
	end
	local yaw = if small then atan2(self.input_dir.x, self.input_dir.z) else atan2(vel.x, vel.z)
	local pitch = atan2(wy, new(wx, 0, wz):flat_len())
	local out = from_angles(yaw, pitch, vel:len())
	local dd = vn.x * d.x + vn.y * d.y + vn.z * d.z
	if dd < -0.1 then
		local a = abs(dd)
		local t
		if a < 0.3 then
			t = 1 - clamp((a - 0.1) * 4.9999995, 0, 1) * 0.39999998
		else
			t = clamp((a - 0.3) * 1.6666667, 0, 1) * 0.39999998 + 0.6
		end
		out = slerp_scaled(p, out, t)
	end
	if first_phase then
		if raw.y < 0 then
			out = new(0, -abs(vel.y), 0)
		elseif out.y > 0 then
			if 0 >= vel.y then
				local neg = -out
				if prev == nil or neg:dot(prev) > 0 then
					out = neg
				end
			else
				out = self:swing_dir(new(vel.x, -vel.y, vel.z), pos, false, nil)
			end
		end
	end
	return out
end

-- exe+ab97e0: the swing begins. `hero_pos` is where the entity is now (exe+1676930).
function SwingLocal.enter(self: SwingLocal, cfg: Configs, tr: Tracker, proc_: SwingProcessor, e: SwingEntry, env: Env)
	-- the state object persists between swings: only its velocity survives the entry's resets
	local vel = self.vel
	defaults(self)
	self.vel = vel
	self.entry_time = env.time
	Processor.start(proc_, e)
	self.attach = e.attach
	self.anchor = e.anchor
	self.min_time = e.min_time
	self.b5f9 = bit32.band(e.flags, 0x40) ~= 0
	self.forward_action = bit32.band(e.flags, 0x100) ~= 0
	self.rope_len0 = dist(self.anchor, env.hero.pos)
	self.last_dt = env.dt
	self:read_input(cfg, env, 0)
	self:entry_velocity(env)
	if bit32.band(e.flags, 2) ~= 0 then
		self.vel = e.velocity
	end
	if bit32.band(e.flags, 4) ~= 0 then
		self.blend_in = e.blend
	end
	self.prev_vel = self.vel
	if self.vel.y > 0 and bit32.band(e.flags, 8) ~= 0 then
		self.phase = 1
	end
	local d = self:swing_dir(self.vel, self.hero.pos, true, nil)
	self.dir = d:norm()
	local dd = self.dir:dot(self.dir)
	local k = if abs(dd) <= 1e-15 then 0 else self.dir:dot(self.vel) / dd
	local p = self.dir * k
	if p:dot(self.dir) < 0 then
		p = -p
	end
	self.prev_dir = self.dir
	self.along = p
	self:initial_gravity_blend()
	if self.back_swing then
		tr:hold_momentum(cfg, 0.5)
	end
	local _, tilt = rope_geometry(self.attach, self.hero.pos, self.dir)
	local g = tr.params.motion.gravity_params
	local t = remap(tilt, g.init_tilt_angle_min, g.init_tilt_angle_max)
	self.grav_fall_final = lerp(g.gravity_fall_init, g.gravity_fall_turn, t)
	self.grav_fall_initial = fmin(self.grav_fall_final * 0.33, -12)
	self.grav_fall_hold = g.gravity_fall_hold
	local sp = tr.params.motion.speed_params
	local terminal = Swing.terminal_target(sp, self.attach, self.hero.pos, self.vel)
	if self.back_swing then
		terminal *= 0.85
	end
	self.terminal = fmax(terminal, tr.terminal_floor)
	self.gravity_scale = tr.gravity_scale
	self.terminal_max = self.terminal * 3
	self.terminal_min = fmax(self.terminal * sp.terminal_velocity_min_percent, sp.terminal_velocity_min_floor)
	self.boost_target = sp.speed_boost_target
	self.boost_accel_base = sp.speed_boost_accel
	self.boost_accel = fmax(sp.speed_boost_accel * 0.15, 8)
	self.boost_accel_accel = sp.speed_boost_accel_accel
	self.boost_on = true
	self.entry_input_dir = self.input_dir
	self.input_agree = 0
	local mag, ang = Swing.stick_raw(env)
	self.input_angle2 = if mag >= 0.1 then ang else 0
	if bit32.band(e.flags, 1) ~= 0 then
		self.input_angle2 = e.input_angle
	end
	if bit32.band(e.flags, 0x100) ~= 0 then
		self.input_angle2 = self.input_angle
	end
	local vf = self.vel:flat_norm()
	self.entry_input_angle = angle_between(self.input_dir, vf) * RAD
	self.agree_timer = 0.3
	self.agree_peak = 0
	self.speed_change = 1
end

-- exe+ac00e0: his velocity on entry, turned toward the hunter's heading when slow and steering away
function SwingLocal.entry_velocity(self: SwingLocal, env: Env)
	local mv = env.mover_vel
	local hs = mv:flat_len()
	local cam_flat = self.cam.fwd:flat_norm()
	local dir0 = if hs >= 0.001 then new(mv.x, 0, mv.z):norm() else cam_flat
	local heading, back = swing_heading(cam_flat, dir0, self.input_dir)
	self.back_swing = back
	local a = clamp(angle_between(dir0, heading) * 1.909859 - 0.6666667, 0, 1)
	local sp = clamp((hs - 10) * 0.04, 0, 1)
	local inp = clamp((self.input_mag - 0.1) * 3.333333, 0, 1)
	local w
	if not self.back_swing then
		-- the hunter's own blend (+0xe97c) is 0 here
		w = a * (1 - sp) * inp
	else
		w = 1
		hs = fmin(hs, 6)
	end
	local d = slerp(dir0, heading, w)
	self.vel = new(d.x * hs, d.y * hs + mv.y, d.z * hs)
	self.blend_in = if w >= 0.0001 then 0 else 1
end

-- exe+abd610
function SwingLocal.initial_gravity_blend(self: SwingLocal)
	local dst = (self.anchor - self.hero.pos):flat_len()
	local vf = self.vel:flat_norm()
	local a = clamp(angle_between(self.input_dir, vf) * 2.291831 - 1.2, 0, 1)
	local d = 1 - clamp((dst - 8) * 0.125, 0, 1)
	local p = clamp(-pitch_of(self.dir) * 5.729578 + 2, 0, 1)
	self.gravity_blend_delay = 0.2
	self.gravity_blend = 1 - p * a * (d * 0.65 + 0.35)
end

-- exe+ac30e0: one frame. Returns the displacement and the facing for the mover.
function SwingLocal.update(self: SwingLocal, cfg: Configs, tr: Tracker, proc_: SwingProcessor, env: Env): SwingOutput
	local dt = env.dt
	self.anchor = proc_.anchor
	self:read_input(cfg, env, dt)
	local disp = self:integrate(cfg, tr, env, dt)
	local facing = self:facing(disp, dt)
	if self.blend_in < 1 then
		local mv = env.mover_vel
		local old = self.blend_in
		self.blend_in = approach(old, 1, 2, dt)
		local w = clamp((self.blend_in - old) / (1 - old), 0, 1)
		disp = new((disp.x - mv.x * dt) * w + mv.x * dt, disp.y, (disp.z - mv.z * dt) * w + mv.z * dt)
	end
	self:update_yaw_rate()
	if self.init_pull < 0 then
		self.init_pull = clamp((self.vel.y + 5) * 0.1111111, 0, 1)
	end
	self:gain_momentum(cfg, tr, env, dt)
	self.last_dt = dt
	return { displacement = disp, facing = facing, snap = false }
end

-- exe+abd820: the facing he asks for: his flat motion turned by a twist that springs toward 0.15 x his yaw rate
function SwingLocal.facing(self: SwingLocal, disp: V3, dt: number): V3
	local out = new(disp.x, 0, disp.z):norm()
	if self.sub_state == 3 then
		return self.hero.fwd
	end
	if new(disp.x, 0, disp.z):flat_len() < dt then
		out = new(self.hero.fwd.x, 0, self.hero.fwd.z):norm()
	end
	self.twist, self.twist_v = spring(self.twist, self.yaw_rate * 0.15, self.twist_v, -1, -16, 12, dt)
	return rotate(out, V3.UP, self.twist * DEG)
end

-- exe+ac2dd0: his yaw rate (degrees per second)
function SwingLocal.update_yaw_rate(self: SwingLocal)
	local a = atan2(self.prev_vel.x, self.prev_vel.z)
	local b = atan2(self.vel.x, self.vel.z)
	self.yaw_rate = wrap_pi(b - a) * RAD / self.last_dt
	if self.prev_vel:flat_len() < 0.01 then
		self.yaw_rate = 0
	end
end

-- exe+ac36f0: momentum while he swings with the stick forward
function SwingLocal.gain_momentum(self: SwingLocal, cfg: Configs, tr: Tracker, env: Env, dt: number)
	if self.back_swing or self.phase == 2 or self.speed_input < 0.6 then
		return
	end
	local _, _, angle = rope_geometry(self.attach, self.hero.pos, self.dir)
	local a = 180 - clamp(angle, 0, 180)
	local sd = cfg.swing.momentum_config.swing_data
	if #sd.rate_list == 0 then
		return
	end
	local list = sd.rate_list
	local lo, hi, t = list[1], list[1], 1
	for k = 2, #list do
		hi = list[k]
		if a < list[k].angle then
			lo = list[k - 1]
			t = unlerp(a, list[k - 1].angle, list[k].angle)
			break
		end
		lo = list[k]
	end
	local rate = (hi.rate - lo.rate) * t + lo.rate
	local tt = remap(self:age(env), sd.min_time, sd.max_time)
	local s = clamp((self.speed_input - 0.6) * 2.5, 0, 1)
	local amount = s * ((1 - sd.start_scale) * tt + sd.start_scale) * rate * dt
	tr:add_momentum(cfg, amount, sd.boost_cap, false)
	self.terminal = fmax(self.terminal, tr.terminal_floor)
end

-- exe+abdb30: four substeps round the (virtual) pivot. Returns the frame's displacement.
function SwingLocal.integrate(self: SwingLocal, cfg: Configs, tr: Tracker, env: Env, dt: number): V3
	self.prev_vel = self.vel
	-- exe+abb420: sliding along a surface he touches (none here)
	self.vel = self:phase_update(self.vel, self.prev_dir, dt)
	self.prev_dir = self.dir
	local d0 = self:swing_dir(self.vel, self.hero.pos, self.phase == 0, self.prev_dir)
	self.dir = d0:norm()
	local dd = self.dir:dot(self.dir)
	local k = if abs(dd) <= 1e-15 then 0 else self.dir:dot(self.vel) / dd
	local p_raw = self.dir * k
	local p = p_raw
	if p:dot(self.dir) < 0 then
		p = -p
	end
	self.along = p
	-- swing floor volumes (exe+8478f0, exe+b8a4f0): none here
	local pos = self.hero.pos
	local v = self.vel
	local dirv = self.along
	local ds = dt * 0.25
	local age = self:age(env)
	local last_dirv = dirv
	for i = 0, 3 do
		-- the web stretches: 72 % of the way out is allowed until 0.33 s, nothing by 1.0 s
		local t = age + i * ds
		local elastic = 0.72 - clamp((t - 0.33) * 1.4925373, 0, 1) * 0.72
		local _, tilt, angle = rope_geometry(self.attach, pos, dirv)
		-- the entry boost
		if self.boost_on then
			if self.phase == 0 then
				local speed = v:len()
				if v.y > 0 then
					speed = v:flat_len()
				end
				if (speed > self.boost_target and v.y < 0) or not (0.2 >= self.reverse) then
					self.boost_on = false
				else
					self.boost_accel = approach(self.boost_accel, self.boost_accel_base, self.boost_accel_accel, ds)
					local add = fmin(fmax(self.boost_target - speed, 0), self.boost_accel * ds)
					local l2 = dirv:dot(dirv)
					if l2 >= 1e-15 then
						v = v + dirv * (add / sqrt(l2))
					end
				end
			else
				self.boost_on = false
			end
		end
		v = self:steer_toward_swing(v, dirv, ds)
		v = self:steer(cfg, tr, v, ds)
		local d2 = self:swing_dir(v, pos, self.phase == 0, dirv)
		local d2n = d2:norm()
		local base = if d2n:dot(p_raw) >= 0 then p_raw else -p_raw
		local delta = v - base
		-- the level direction across his motion, for the pivot
		local vn = v:norm()
		local side = new(vn.z, 0, -vn.x):flat_norm()
		local pivot = self:pivot(cfg, tr, self.anchor, pos, base, side, ds, age)
		local r = pivot - pos
		local rlen = r:len()
		local rn = r:norm()
		local g = self:gravity(tr, base, angle, tilt, rlen, age)
		local bl = base:len()
		local c = bl * bl / rlen
		self.gravity_blend_delay -= ds
		if self.gravity_blend_delay <= 0 then
			self.gravity_blend = fmin(ds * 1.25 + self.gravity_blend, 1)
		end
		local b = self.gravity_blend
		local gy = rn.y * g
		local nvx = -(gy * rn.x * b) * ds + c * rn.x * ds + base.x
		local nvz = -(gy * rn.z * b) * ds + c * rn.z * ds + base.z
		local cy = c * rn.y
		local nvy = (((g - gy * rn.y) - g) * b + g) * ds + fmin(cy * b, cy) * ds + base.y
		local nv = new(nvx, nvy, nvz)
		self.speed_change = nv:len() - bl
		-- the base motion on the circle round the pivot
		local p1 = pos + nv * ds
		local to = pivot - p1
		local p1c, rcon
		if to.y >= 0 then
			local l2 = to:dot(to)
			local f = rlen / sqrt(l2)
			local o = if l2 >= 1e-15 then to * f else new(rlen, 0, 0)
			p1c, rcon = pivot - o, rlen
		else
			p1c, rcon = p1, to:len()
		end
		-- the rest of his motion may stretch the web (elastic), never pushes it
		local p3 = p1c + delta * ds
		local to3 = pivot - p3
		local r3 = to3:len()
		local rope = fmin((r3 - rcon) * elastic + rcon, r3)
		local l2 = to3:dot(to3)
		local o = if l2 >= 1e-15 then to3 * (rope / sqrt(l2)) else new(rope, 0, 0)
		local fin = pivot - o
		if to3.y > 0 then
			if self.phase ~= 2 then
				-- sinking when the web is shorter than it began, past 85 degrees
				local c1 = clamp(cos(angle * DEG) + 1, 0, 1)
				local c2 = clamp((angle - 85) * 0.2, 0, 1)
				local tt = clamp((age - 0.1) * 2.5, 0, 1)
				local ddd = (fin - self.anchor):len()
				local len0 = fmin(self.rope_len0, 20)
				local s1 = clamp((len0 - ddd - 1) * 0.1428571, 0, 1)
				self.sink = approach(self.sink, s1 * c1 * tt * 4 * c2, 12, ds)
			end
			fin = new(fin.x, fin.y - ds * self.sink, fin.z)
		end
		fin = self:push_off(fin, ds, age)
		v = nv + delta
		v = self:cap_speed(tr, v, dirv, rope, ds)
		local guarded
		guarded, v = self:floor_guard(v, pos, fin, pivot, tilt, ds)
		pos = guarded
		local d3 = self:swing_dir(v, pos, self.phase == 0, dirv):norm()
		dirv = if d3:dot(p_raw) >= 0 then p_raw else -p_raw
		last_dirv = dirv
		self.first = false
	end
	self.vel = v
	self.along = last_dirv
	self.dir = last_dirv:norm()
	return pos - self.hero.pos
end

-- exe+abc5d0: the phases and the drag of the third
function SwingLocal.phase_update(self: SwingLocal, vel: V3, prev_dir: V3, dt: number): V3
	local _, _, angle = rope_geometry(self.attach, self.hero.pos, prev_dir)
	if self.phase == 0 then
		if angle < 90 then
			self.phase = 1
		end
	elseif self.phase == 1 and vel.y < 0 and angle > 70 then
		self.phase = 2
	end
	local r = 0
	if self.input_mag > 0.01 and self.input_agree > 0.99 then
		local vf = new(vel.x, 0, vel.z):norm()
		if vf:dot(self.input_dir) < -0.707 then
			r = (1 - clamp((angle - 90) * 0.02222222, 0, 1)) * self.input_mag
		end
	end
	self.reverse = approach(self.reverse, r, 2, dt)
	if self.phase == 2 then
		self.phase_time += dt
		local f = clamp(self.phase_time * 0.1, 0, 1)
		local s = vel:len()
		s -= (sqrt(f) * f * 0.14 + 0.01) * s * dt
		return vel:with_len(fmax(s, 0))
	end
	return vel
end

-- exe+abc8c0: the velocity eased toward the swing direction
function SwingLocal.steer_toward_swing(self: SwingLocal, vel: V3, dirv: V3, dt: number): V3
	local s1 = clamp((vel:len() - 4) * 0.25, 0, 1)
	if s1 < 0.0001 then
		self.dir_time = 0
		return vel
	end
	local hs = vel:flat_len()
	local fv = clamp((hs - 25) * 0.06666667, 0, 1)
	self.dir_time += (fv + 1) * dt
	local fd = clamp((dist(self.anchor, self.hero.pos) - 24) * 0.08333334, 0, 1)
	local fd2 = (1 - fv) * fd
	local m = 1 - fd2 * 0.7
	local nd = dirv:norm()
	local speed = vel:len()
	local p = (abs(atan2(nd.y, nd:flat_len()) * -RAD) - 35) * 0.04
	p = clamp(p, 0, 1)
	local fy = clamp((vel.y + 10) * 0.06666667, 0, 1)
	m -= (1 - p) * 0.2 - fd2 * (1 - p) * 0.14
	local toward = (self.anchor - self.hero.pos):dot(vel)
	local fy1 = 1 - fy
	local hi = -4 - (fy1 + fy1)
	local lo = if toward <= 0 then -1.5 else (-1.75 - fy1 * 0.5) * m
	local t = clamp((self.dir_time - 0.3) * 3.333333, 0, 1)
	local a = ((hi - lo) * t + lo) * s1
	local c = ((1 - m) * t + m) * 6.981317
	local out
	out, self.dir_spring_v = vector_spring(vel:norm(), nd, self.dir_spring_v, a, -15, c, dt)
	local k = clamp((angle_between(nd, vel:norm()) * 1.432394) - 0.125, 0, 1)
	local sp = ((out:dot(vel)) - speed) * k + speed
	local r = out:with_len(sp)
	if self.phase == 0 and r.y > 0 and toward > 0 then
		local f = new(r.x, 0, r.z)
		local l = fmin(f:len(), hs)
		local fl2 = r.z * r.z + r.x * r.x
		if fl2 >= 1e-15 then
			local s = l / sqrt(fl2)
			r = new(r.x * s, r.y, r.z * s)
		else
			r = new(0, r.y, 0)
		end
	end
	return r
end

-- exe+abb8e0: the stick steers the swing: his velocity turned about the vertical by a damped spring
function SwingLocal.steer(self: SwingLocal, _cfg: Configs, tr: Tracker, vel: V3, dt: number): V3
	local tp = tr.params.motion.turn_params
	local d_deg = wrap_pi(self.input_angle - self.input_angle2) * RAD
	local t
	if d_deg > 70 or self.entry_input_angle < 30 then
		self.agree_timer = 0
		self.input_agree = 1
		t = 1
	elseif self.input_agree >= 1 then
		t = self.input_agree
	else
		local a = clamp((d_deg - 5) * 0.04, 0, 1)
		local e = clamp((self.entry_input_angle - 30) * 0.03333334, 0, 1)
		local peak = fmax(self.agree_peak, a)
		self.agree_peak = peak
		local e1 = 1 - e
		local pe = peak * e1
		local ramp = true
		if peak < 0.05 then
			self.agree_timer -= ((peak + e1) * 4 + pe * 16 + 1) * dt
			if self.agree_timer >= 0.0001 then
				ramp = false
			end
		else
			self.agree_timer = 0
		end
		if ramp then
			self.input_agree = fmin(self.input_agree + (peak * 8.5 + pe * 34 + e1 * 6 + 1.5) * dt, 1)
		end
		t = self.input_agree
	end
	local tgt = slerp(self.entry_input_dir, self.input_dir, t)
	local vf = vel:flat_norm()
	local left = tgt.x * vf.z - tgt.z * vf.x > 0
	if self.input_agree > 0.99 and vf.x * self.input_dir.x + vf.z * self.input_dir.z < -0.707 then
		return vel
	end
	if self.phase == 2 and self.input_mag < 0.02 then
		return vel
	end
	local ang = angle_between(vf, tgt)
	if ang < 0.0005 then
		return vel
	end
	local a1 = clamp(ang * 0.9549296, 0, 1)
	local a2 = clamp((a1 - 0.33) * 1.754386, 0, 1)
	local ramp0 = if self.first then a2 * a1 * 0.4 else self.turn_ramp
	self.turn_ramp = ramp0
	local ramp = fmin(a1 * dt * tp.turn_ramp_speed + ramp0, a1)
	self.turn_ramp = ramp
	local gain = lerp(tp.turn_gain_min, tp.turn_gain_max, ramp)
	local s_min = lerp(tp.turn_speed_min_min, tp.turn_speed_min_max, ramp)
	local s_max = lerp(tp.turn_speed_max_min, tp.turn_speed_max_max, ramp)
	local damp = lerp(tp.turn_damp_min, tp.turn_damp_max, ramp)
	-- the camera's look input
	local l = clamp((self.look_input - 0.1) * 1.666667, 0, 1)
	self.look = if l > self.look then l else approach(self.look, l, 2, dt)
	local lk = l * 0.25 + 1
	local ag = clamp(self.input_agree * 1.515152, 0, 1)
	local f = (1 - ag) * 0.22 + 1
	gain = gain * (l + 1) * f
	damp = damp * (1 - l * 0.5) / f
	s_min = s_min * lk * f
	s_max = s_max * lk * f
	local ts = tr.turn_speed_scale
	gain += (gain * ts - gain) * 0.33
	s_min *= ts
	s_max *= ts
	damp += (damp / ts - damp) * 0.33
	local _, tilt, angle = rope_geometry(self.attach, self.hero.pos, self.dir)
	local a90 = fmax(90 - angle, 0)
	local t1 = remap(tilt, tp.turn_speed_tilt_angle_min, tp.turn_speed_tilt_angle_max)
	local tsf = (1 - tp.turn_speed_tilt_scale) * (1 - t1) + tp.turn_speed_tilt_scale
	local p1 = remap(a90, tp.turn_speed_pitch_min, tp.turn_speed_pitch_max)
	local speed = ((s_max - s_min) * (1 - p1) + s_min) * tsf
	-- the probes: slower turning toward what is close
	local pr = self.probes
	local maxc = 0
	for i = -2, 2 do
		maxc = fmax(Probes.c(pr, i), maxc)
	end
	local lsum, rsum = 0, 0
	for kk = 1, 3 do
		lsum += fmax(maxc - Probes.c(pr, -kk), 0)
		rsum += fmax(maxc - Probes.c(pr, kk), 0)
	end
	local weights = { 3, 1, 0.5, 0.25 }
	local n = Probes.count(pr)
	local sw, ws = 0, 0
	for kk = 0, math.max(n, 0) - 1 do
		local w = weights[kk + 1]
		sw += w
		ws += w * clamp((Probes.s(pr, kk, left) - 4) * 0.125, 0, 1)
	end
	local avg = if n > 0 and sw >= 0.0001 then ws / sw else 0
	local near = clamp((maxc - 6) * 0.1, 0, 1)
	local sidesum = if left then lsum else rsum
	local blk = clamp(sidesum * 0.03333334 - 0.6, 0, 1) * near * 0.8
	local target_scale = (1 - blk) + blk * avg
	local rate = if target_scale > self.probe_turn_scale then 8 else 9
	self.probe_turn_scale = approach(self.probe_turn_scale, target_scale, rate, dt)
	speed *= self.probe_turn_scale
	local mag = self.input_mag
	if mag > 0.01 then
		local m
		if mag < 0.7 then
			m = (clamp(mag * 1.428571, 0, 1) + 1) * 0.33
		else
			m = clamp((mag - 0.7) * 4.545454, 0, 1) * 0.34 + 0.66
		end
		local ia = clamp((abs(self.input_angle * RAD) - 25) * 0.04, 0, 1)
		speed *= (m - 1) * ia + 1
	end
	if not left then
		ang = -ang
	end
	local maxstep = speed * DEG
	if self.first then
		local r = ang / dt * RAD
		local lo = speed * 0.5
		local range = speed * 1.25 - lo
		local f2
		if abs(range) > 0.0001 then
			f2 = clamp((abs(r) - lo) / range, 0, 1)
		elseif abs(r) < lo then
			f2 = 0
		elseif abs(r) > lo then
			f2 = 1
		else
			f2 = 0.5
		end
		local v0 = fmin(abs((1 - a2) * (1 - f2) * r * DEG), maxstep)
		self.turn_v = if ang < 0 then -v0 else v0
	end
	local x
	x, self.turn_v = spring(ang, 0, self.turn_v, gain, damp, maxstep, dt)
	local step = ang - x
	return rotate(vel, V3.UP, step)
end

local function pivot_lerp(f: number, scale: number, si: number): number
	local x = lerp(f, 1, scale)
	return (f - x) * si + x
end

-- exe+abf160: the virtual pivot: the anchor moved toward his plane of travel by the pivot factor
function SwingLocal.pivot(self: SwingLocal, cfg: Configs, tr: Tracker, anchor: V3, pos: V3, base: V3, side: V3, ds: number, age: number): V3
	local si = fmax(self.speed_input, 0)
	local s = cfg.swing
	local f0 = pivot_lerp(tr.pivot_factor[1], s.zero_input_pivot_scale_start, si)
	local f1 = pivot_lerp(tr.pivot_factor[2], s.zero_input_pivot_scale_trough, si)
	local f2 = pivot_lerp(tr.pivot_factor[3], s.zero_input_pivot_scale_final, si)
	local p = pitch_of(base) * RAD
	local f
	if p <= 0 then
		local a = clamp((abs(p) - 20) * 0.025, 0, 1)
		f = (f2 - f1) * a + f1
	else
		local a = clamp((abs(p) - 5) * 0.02222222, 0, 1)
		f = (1 - a) * (f1 - f0) + f0
	end
	if self.phase == 2 then
		f = 0
	end
	self.pivot_factor = fmin(self.pivot_factor, f)
	local tw = abs(self.turn_v * RAD)
	local at = clamp((age - 0.4) * 2.222222, 0, 1)
	local tt = clamp((tw - 45) * 0.02222222, 0, 1)
	self.pivot_factor = fmax(self.pivot_factor - at * ds * tt * 0.6, 0)
	local k = self.pivot_factor
	local ap = anchor - pos
	local d = ap:dot(side)
	return new(
		((ap.x - side.x * d) + pos.x - anchor.x) * k + anchor.x,
		((ap.y - side.y * d) + pos.y - anchor.y) * k + anchor.y,
		((ap.z - side.z * d) + pos.z - anchor.z) * k + anchor.z
	)
end

-- exe+ac0b60: the swing's gravity (negative) from the motion along the swing direction (`base`)
function SwingLocal.gravity(self: SwingLocal, tr: Tracker, base: V3, angle: number, tilt: number, rlen: number, age: number): number
	local g = tr.params.motion.gravity_params
	local speed = base:len()
	local up = pitch_of(base) * -RAD
	local t_pitch = remap(up, g.rise_pitch_angle_min, g.rise_pitch_angle_max)
	local t_tilt = remap(tilt, g.rise_tilt_angle_min, g.rise_tilt_angle_max)
	local tl = remap(speed, g.rise_low_speed_min, g.rise_low_speed_max)
	local th = remap(speed, g.rise_high_speed_min, g.rise_high_speed_max)
	local si = fmax(self.speed_input, 0)
	local low0 = (g.rise_gravity_low_max_zero - g.rise_gravity_low_min_zero) * tl + g.rise_gravity_low_min_zero
	local low = (((g.rise_gravity_low_max - g.rise_gravity_low_min) * tl + g.rise_gravity_low_min) - low0) * si + low0
	local high0 = (g.rise_gravity_high_max_zero - g.rise_gravity_high_min_zero) * th + g.rise_gravity_high_min_zero
	low += (g.rise_gravity_low_tilt - low) * t_tilt
	local high = (((g.rise_gravity_high_max - g.rise_gravity_high_min) * th + g.rise_gravity_high_min) - high0) * si
		+ high0
	local val = (((g.rise_gravity_high_tilt - high) * t_tilt + high) - low) * t_pitch + low
	if base.y >= 0 then
		if rlen >= 16 then
			local t = remap(rlen, g.rise_line_length_min, g.rise_line_length_max)
			val *= (g.rise_line_length_scale - 1) * t + 1
		else
			local t = clamp((rlen - 8) * 0.125, 0, 1)
			val -= (val + 35) * t
		end
	elseif self.phase == 2 then
		val = self.grav_fall_hold
	else
		local a = clamp((angle - 145) * 0.02857143, 0, 1)
		local t = clamp((age - 0.25) * 4, 0, 1)
		val = (self.grav_fall_final - self.grav_fall_initial) * t + self.grav_fall_initial
		val -= (val + 50) * a
	end
	local floor = fmin(val, -10)
	local out = (val - floor) * self.gravity_blend + floor
	if self.phase ~= 0 then
		if base.y > 0 and self.speed_input < 0 then
			local a = abs(self.speed_input)
			local b = -25 - a * 15
			local tgt = ((-35 - a * 15) - b) * t_pitch + b
			local cand = (tgt - out) * a + out
			if cand < out then
				out = cand
			end
		end
		if self.phase == 1 then
			out *= self.gravity_scale * (if self.b5f9 then 0.5 else 1)
		elseif self.phase == 2 then
			out = if base.y <= 0 then -14 else -22
		end
	end
	return out
end

-- exe+abb030: pushed sideways off what the probes find ahead (nothing when they are clear)
function SwingLocal.push_off(self: SwingLocal, pos: V3, ds: number, age: number): V3
	local pr = self.probes
	local c0 = Probes.c(pr, 0)
	local cl = fmax(Probes.c(pr, -1), Probes.c(pr, -2))
	local cr = fmax(Probes.c(pr, 1), Probes.c(pr, 2))
	local f = clamp((age - 0.25) * 2.439024, 0, 1)
	local sp = clamp((self.vel:len() - 4) * 0.25, 0, 1)
	local w = (sp - 1) * f + 1
	local target = V3.ZERO
	if c0 <= 20 then
		local th = c0 + 12
		local push = true
		local left = th < cl
		if left then
			if th < cr then
				local a = new(self.attach.x - pos.x, 0, self.attach.z - pos.z):norm()
				local b = new(self.vel.x, 0, self.vel.z):norm()
				left = a.x * b.z - b.x * a.z > 0
			end
		elseif cr <= th then
			push = false
		end
		if push then
			local spd = self.vel:len()
			local side = new(self.vel.z, 0, -self.vel.x):flat_norm()
			local a = clamp((c0 - 8) * 0.08333334, 0, 1)
			local b = clamp((spd - 20) * 0.1, 0, 1)
			local m = b * 0.3 + 0.6
			local mag = (1 - a) * ((b * 0.75 + 1) - m) + m
			if not left then
				mag = -mag
			end
			target = new(side.x * mag, 0, side.z * mag)
		end
	end
	self.push = approach_v(self.push, target, 16, ds)
	return new(pos.x + ds * self.push.x * w, pos.y + self.push.y * ds * w, pos.z + self.push.z * ds * w)
end

-- exe+abf580: speed limits: the terminal speed (eased by the throttle) and the line's total
function SwingLocal.cap_speed(self: SwingLocal, tr: Tracker, v: V3, dirv: V3, rope: number, ds: number): V3
	local sp = tr.params.motion.speed_params
	local speed = v:len()
	local hs = v:flat_len()
	local si = self.speed_input
	local term = self.terminal
	local cap
	if si < 0 then
		term -= abs(si) * sp.input_decel_back * ds
		term = fmax(term, sp.terminal_velocity_max_floor)
		self.terminal = term
		cap = fmax(term * sp.terminal_velocity_min_percent, sp.terminal_velocity_min_floor)
		self.terminal_max = term
		self.terminal_min = cap
	else
		local x = (term - self.terminal_min) * si + self.terminal_min
		local c = x
		if x <= hs then
			c = term
			if hs < term then
				c = fmax(hs - ds * sp.input_decel_zero, x)
			end
		end
		cap = c
	end
	local p = pitch_of(dirv)
	local tmax = (self.terminal_max - self.terminal) * fmax(si, 0) + self.terminal
	local total
	if self.phase == 0 then
		if p <= 1.492257 then
			total = fmin(cap / fmax(cos(p), 0.001), tmax)
		else
			total = tmax
		end
	elseif self.phase == 1 then
		total = tmax
	else
		total = cap
	end
	local lim = fmin(clamp(rope * 0.07142857, 0, 1) * total, sp.terminal_velocity_pure_max)
	local out = v
	if lim < speed then
		out = out * (lim / speed)
	end
	local hs2 = out:flat_len()
	if cap < hs2 then
		out = out * (cap / hs2)
	end
	return out
end

-- exe+abf850: keeps him above a floor (the lowest point of the web's first length, 2 m lower, or a swing floor
-- volume's low point), and gives a step it shortened 70 % of the lost length back horizontally. Returns the new
-- position and the (possibly changed) velocity.
function SwingLocal.floor_guard(self: SwingLocal, v: V3, old: V3, new_: V3, pivot: V3, tilt: number, ds: number): (V3, V3)
	local vx, vy, vz = v.x, v.y, v.z
	local d_piv = dist(new_, pivot)
	local floor = (self.anchor.y - self.rope_len0) - 2
	local cur = if self.floor_y == -1e30 then floor else self.floor_y
	self.floor_y = cur
	local rate_div = 0.5
	if self.has_low_point then
		local d3 = dist(self.low_point, pivot)
		local lim = fmin(d3 - 1.5, d_piv)
		if lim < d_piv - 0.001 and self.low_point.y < self.attach.y - 4 then
			floor = self.low_point.y + 2
			local a = new(vx, vy, vz):flat_len()
			rate_div = flat_dist(self.low_point, old) / ((self.terminal - a) * 0.75 + a)
		end
	end
	if floor <= cur then
		if floor < cur - 2 then
			local t = clamp((cur - floor - 4) * 0.08333334, 0, 1)
			self.floor_rate = approach(self.floor_rate, t * 8 + 2, t * 30 + 10, ds)
			self.floor_y = approach(self.floor_y, floor, self.floor_rate, ds)
			cur = self.floor_y
		end
	else
		self.floor_y = floor
		self.floor_rate = 0
		cur = floor
	end
	local ox, oy, oz = new_.x, new_.y, new_.z
	if fmax(old.y, new_.y) < cur then
		local fr = clamp((rate_div - 0.2) * 5, 0, 1)
		local need = if rate_div <= 0.01 then 0 else fmax((cur - new_.y) / rate_div, 0)
		local a = fmin(fmax(clamp(((cur - new_.y) - 1) * 0.8, 0, 1) * (1 - fr) * 4 + 1, need), 5)
		self.floor_acc = approach(self.floor_acc, a, 32, ds)
		local gap = self.floor_y - new_.y
		local y = self.floor_acc * ds + new_.y
		local up = y - oy
		if up < gap and ds * vy < 0 then
			y += fmin(gap - up, abs(ds * vy))
		end
		local fv = (y - new_.y) / ds
		if fv <= self.floor_vel then
			fv = approach(self.floor_vel, fv, 30, ds)
		end
		self.floor_vel = fv
		oy += fv * ds
	else
		local dy = new_.y - old.y
		local decay = true
		if dy < 0 then
			local c = cos(tilt * DEG)
			local fall = abs(dy)
			local fy = self.floor_y
			local f10 = 1 - clamp(((fy - new_.y) / vy - 0.1) * 2.5, 0, 1)
			if not (fy <= self.attach.y - c * d_piv) then
				local e1 = exp((f10 * 3 - 8) * ds)
				local k = fmin((1 - e1) * (old.y - fy), exp((-25 - f10 * 35) * ds) * fall)
				local fv = (fall - k) / ds
				oy += fall - k
				self.floor_vel = fv
				if vy < 0 then
					vy += fmin(abs(vy) * 0.33, fv * 0.66 * ds)
				end
				decay = false
			end
		end
		if decay and abs(self.floor_vel) > 0.0001 then
			local t = clamp((self.floor_vel - 5) * 0.1, 0, 1)
			local p = clamp(pitch_of(new(vx, vy, vz)) * -2.291831 - 0.8, 0, 1)
			local r = t * 23 + 7
			self.floor_vel = approach(self.floor_vel, 0, (30 - r) * p + r, ds)
			oy += abs(self.floor_vel) * ds
		end
		self.floor_acc = approach(self.floor_acc, 0, 32, ds)
	end
	local out = new(ox, oy, oz)
	local full = (new_ - old):len()
	local got = (out - old):len()
	if got < full - 0.0001 then
		local add = (full - got) * 0.7
		local hx, hz = out.x - old.x, out.z - old.z
		local l = new(hx, 0, hz):flat_len() + add
		local l2 = hz * hz + hx * hx
		local nx, nz
		if l2 >= 1e-15 then
			local f = l / sqrt(l2)
			nx, nz = hx * f, hz * f
		else
			nx, nz = l, 0
		end
		out = new(nx + old.x, out.y, nz + old.z)
		local hs = new(vx, vy, vz):flat_len()
		if hs >= 0.001 then
			local extra = fmin(fmax(self.terminal - hs, 0), add)
			local k = (extra + hs) / hs
			vx *= k
			vz *= k
		end
	end
	return out, new(vx, vy, vz)
end

-- exe+ac2200: the automatic release: 0 none, 1 a jump (fast), 2 a plain release (slow)
function SwingLocal.auto_release(self: SwingLocal): number
	local _, tilt, angle = rope_geometry(self.attach, self.hero.pos, self.dir)
	local d = (self.hero.pos - self.attach):norm()
	local elev = atan2(d.y, d:flat_len()) * -RAD
	local dd = dist(self.hero.pos, self.attach)
	local lim = 50 - clamp((dd - 12) * 0.125, 0, 1) * 45
	local speed = self.vel:len()
	if (elev < lim and self.vel.y > 0 and self.phase ~= 0) or (tilt <= 60 and angle <= lim) then
		return if speed <= 20 then 2 else 1
	end
	return 0
end

-- exe+aba8a0, the swing's exit, as far as the tracker goes: a release above -10 degrees after half a second of
-- swinging raises the speed blend by 0.35 (exe+861290); the release adds momentum by his angle round the swing
-- (exe+ac1430 on SwingReleaseData) unless that boost's cooldown runs (exe+861de0).
function SwingLocal.exit(self: SwingLocal, cfg: Configs, tr: Tracker, env: Env, jumped: boolean)
	if self.release_pitch > -10 and self:age(env) > 0.5 and tr.speed_blend < 1 then
		tr.speed_blend = fmin(tr.speed_blend + 0.35, 1)
	end
	-- exe+85e310
	tr.ring_next = (tr.ring_next + 1) % 32
	if self.phase == 2 or self.back_swing then
		return
	end
	local rd = cfg.swing.momentum_config.swing_release_data
	local list = rd.rate_scale_list
	if #list == 0 then
		return
	end
	local _, _, angle = rope_geometry(self.attach, self.hero.pos, self.dir)
	local a = 180 - clamp(angle, 0, 180)
	local prev, cur, t = list[1], list[1], 0
	for i = 2, #list do
		local e = list[i]
		cur = e
		if a < e.angle then
			t = remap(a, prev.angle, e.angle)
			break
		end
		prev = e
		t = 1
	end
	local scale = (cur.scale - prev.scale) * t + prev.scale
	local b = if jumped then rd.jump_data else rd.release_data
	if tr.cooldowns[3] < 0.0001 then
		tr:add_momentum(cfg, scale * b.boost, b.boost_cap, true)
		tr.cooldowns[3] = b.retrigger_delay
	end
end

-- exe+aba1f0: lets go when the button is up (after a two-frame countdown), on the jump button, when stuck or by
-- itself near the top. Returns the release.
function SwingLocal.check(self: SwingLocal, cfg: Configs, tr: Tracker, env: Env): SwingRelease?
	local up = not (env.input.swing_button >= 0.09) and not self.b5f0
	local age = self:age(env)
	local ev = age > 0.25 and self.release_event
	local auto = self:auto_release()
	local blocked = Probes.blocked_(self.probes) and not ev
	local jumped = if ev then true else auto == 1
	local button = up or auto == 2
	local high = auto == 2
	local allowed = true
	if auto == 0 and button and not jumped and not blocked then
		local c = self.release_countdown
		self.release_countdown = c - 1
		if c > 0 then
			allowed = false
		end
	end
	if age > self.min_time and (button or jumped or blocked) and allowed then
		return self:release(cfg, tr, env, jumped, blocked, high)
	end
	return nil
end

-- The release event: the jump button (buffered 0.05 s), read each frame by the swing's second callback (exe+ac3c80)
function SwingLocal.read_release_event(self: SwingLocal, env: Env)
	if env.input.jump_pressed then
		self.release_event = true
	end
end

-- exe+ac1680: the release velocity, its rising gravity and the release animation's pace
function SwingLocal.release(self: SwingLocal, cfg: Configs, tr: Tracker, env: Env, jumped: boolean, blocked: boolean, high: boolean): SwingRelease
	local mv = env.mover_vel
	local pitch = pitch_of(self.dir) * -RAD
	local out = mv
	self.release_pitch = pitch
	local s = cfg.swing
	if jumped then
		for _, z in s.jump_redirect_zones do
			local a = pitch + 90
			if z.line_angle_start <= a and a <= z.line_angle_end then
				local t = unlerp(a, z.line_angle_start, z.line_angle_end) ^ z.exit_bias
				local exit = (z.exit_angle_end - z.exit_angle_start) * t + z.exit_angle_start
				local l = mv:max_abs()
				local ax, az = mv.x, mv.z
				if l > 0 then
					local k = 1 / l
					local yk, xk, zk = mv.y * k, mv.x * k, mv.z * k
					local n = 1 / sqrt(yk * yk + xk * xk + zk * zk)
					ax = n * mv.x * k
					az = n * mv.z * k
				end
				local axis = new(az, 0, -ax)
				out = rotate(out, axis, (exit - a) * -DEG)
				pitch = exit - 90
				self.release_pitch = pitch
			end
		end
	end
	local eq = pitch == s.release_angle_high_start
	local lt = pitch < s.release_angle_high_start
	local low_final = pitch < s.release_angle_low_final
	local ge_low = s.release_angle_low_start <= pitch
	local age = self:age(env)
	local early
	if 0.5 <= age then
		early = not ge_low and not jumped
	else
		early = not ge_low
	end
	if early or blocked then
		if self.vel.y < out.y then
			out = new(out.x, (self.vel.y - out.y) * 0.25 + out.y, out.z)
		end
		self.release_anim_rate = 0.5
		self.release_anim_blend = 0.33
		return {
			velocity = out,
			gravity = 24,
			jumped = jumped,
			pitch = pitch,
			anim_rate = 0.5,
			anim_blend = 0.33,
			high = false,
			early = true,
		}
	end
	local rp = tr.params.release
	local set = rp.params_middle
	local band_high = false
	if ge_low then
		if low_final then
			set = rp.params_low
		elseif not (lt or eq) then
			band_high = true
			set = rp.params_high
		end
	else
		set = rp.params_fall
		local hs = out:flat_len()
		if s.jump_from_fall_horz_min < hs then
			local m = fmax(hs * s.jump_from_fall_horz_damp, s.jump_from_fall_horz_min)
			local f = clamp((abs(pitch) - 20) * 0.02857143, 0, 1)
			local k = (m / hs - 1) * f + 1
			out = new(out.x * k, out.y, out.z * k)
		end
	end
	local y = out.y
	if jumped then
		y = set.jump_boost + out.y
		y += if lt or eq or not self.b5f9 then 0 else 6
		out = new(out.x, y, out.z)
	end
	local sp = tr.params.motion.speed_params
	local floor
	if y <= 0 or high then
		floor = if jumped then set.vert_floor_jump else set.vert_floor_base
	else
		local hs = out:flat_len()
		local ft = unlerp(
			hs,
			(sp.terminal_velocity_horz_max - sp.terminal_velocity_horz_min) * 0.33 + sp.terminal_velocity_horz_min,
			sp.terminal_velocity_horz_max
		)
		local f19 = 1 - ft * 0.5
		local n = out:norm()
		local add = n.y * sp.release_boost_xz * f19
		add = fmin(add, fmax(self.terminal + 1 - hs, 0))
		add = fmax(add, sp.release_boost_alt_min - hs)
		local fl = new(out.x, 0, out.z):norm()
		out = new(add * fl.x + out.x, fl.y * add + out.y, fl.z * add + out.z)
		if jumped then
			local jb
			if pitch < sp.jump_boost_pitch_low_max then
				jb = unlerp(pitch, sp.jump_boost_pitch_low_min, sp.jump_boost_pitch_low_max)
			elseif sp.jump_boost_pitch_high_min < pitch then
				jb = 1 - unlerp(pitch, sp.jump_boost_pitch_high_min, sp.jump_boost_pitch_high_max)
			else
				jb = 1
			end
			local add2 = jb * sp.jump_boost_xz * f19
			local fl2 = new(out.x, 0, out.z):norm()
			out = new(add2 * fl2.x + out.x, fl2.y * add2 + out.y, fl2.z * add2 + out.z)
			floor = set.vert_floor_jump
		else
			floor = set.vert_floor_base
		end
	end
	out = new(out.x, fmax(out.y, floor), out.z)
	local gd = rp.release_gravity_data
	local t, lo, hi
	if gd.gravity_angle_mid <= pitch then
		t = remap(pitch, gd.gravity_angle_mid, gd.gravity_angle_high)
		if jumped then
			lo, hi = gd.gravity_jump_mid, gd.gravity_jump_high
		else
			lo, hi = gd.gravity_release_mid, gd.gravity_release_high
		end
	else
		t = remap(pitch, gd.gravity_angle_low, gd.gravity_angle_mid)
		if jumped then
			lo, hi = gd.gravity_jump_low, gd.gravity_jump_mid
		else
			lo, hi = gd.gravity_release_low, gd.gravity_release_mid
		end
	end
	local gravity = (hi - lo) * t + lo
	local r = fmax(out.y / gravity, 0.1)
	local rate = fmin(fmax(r * 1.25, 0.1), 2)
	self.release_anim_rate = rate
	self.release_anim_blend = if low_final or not jumped then 0.35 else fmin(rate, 1)
	return {
		velocity = out,
		gravity = gravity,
		jumped = jumped,
		pitch = pitch,
		anim_rate = self.release_anim_rate,
		anim_blend = self.release_anim_blend,
		high = band_high,
		early = false,
	}
end

-- exe+ab38e0: the swing's terminal speed from how far and high the web is and how fast he falls into it
function Swing.terminal_target(sp: any, attach: V3, pos: V3, vel: V3): number
	local d = attach - pos
	local dst = d:len()
	local flat = d:flat_len()
	local elev = atan2(d.y, flat)
	local a = clamp(elev * 2.291831 - 0.4, 0, 1)
	local fall = abs(fmin(vel.y, 0))
	local lt = clamp((dst - 22) * 0.04545455, 0, 1)
	local w = ((1 - a) + lt) * 0.75
	local mid = sp.fall_speed_threshold_mid
	local x
	if mid <= fall then
		if w < 1 then
			x = fall
		else
			x = fmax(((((sp.fall_speed_threshold_max - mid) * 0.5 + mid) - mid) * (w - 1) + mid), fall)
		end
	elseif w < 1 then
		x = fall + (mid - fall) * w
	else
		x = fmax(((((sp.fall_speed_threshold_max - mid) * 0.5 + mid) - mid) * (w - 1) + mid), fall)
	end
	local t
	if mid <= x then
		local r = sp.fall_speed_threshold_max - mid
		local tt
		if abs(r) <= 0.0001 then
			tt = if x <= mid then 0.5 else 1
		else
			tt = clamp((x - mid) / r, 0, 1)
		end
		t = (sp.terminal_velocity_horz_max - sp.terminal_velocity_horz_mid) * tt + sp.terminal_velocity_horz_mid
	else
		local tt = remap(x, sp.fall_speed_threshold_min, mid)
		t = (sp.terminal_velocity_horz_mid - sp.terminal_velocity_horz_min) * tt + sp.terminal_velocity_horz_min
	end
	return fmax(t, vel:flat_len())
end

return Swing
