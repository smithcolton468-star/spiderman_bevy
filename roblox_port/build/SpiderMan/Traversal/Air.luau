--!strict
local __F = function(x: any): any if type(x) == "number" then return vector.create(x, 0, 0).x end return x end -- f32ify: f32 rounding (vector arithmetic rounds in its own metamethods)
-- Port of crates/sm_traversal/src/air.rs: Hero::HeroStateSwingJumpLocal (Spider-Man.exe 4.0630, vtable exe+38d4b58) and
-- Hero::HeroStateFallLocal (vtable exe+38c9220): what follows a swing. Both share the jump state's layout (the fall
-- adds +0x300..). Entry exe+a86490 (the fall's exe+a70080 on top of it); per frame exe+a8d5b0 -> exe+a88ec0 with its
-- virtuals (speed data exe+a87a70, target speed exe+a8b140, drag exe+a8b1d0, displacement exe+a8b520 with the
-- steering exe+a8c7f0 and the vertical exe+a8c3c0, facing exe+a8beb0), then the fall's gravity (exe+a706a0) and
-- momentum (exe+a71a40). The swing jump hands over to the fall on exe+a87f10 / exe+a885c0 through the transition
-- manager's TryFall (exe+96e580).
--
-- The launches enter the same class as HeroStateJump: the point launch (kind 0x2a) and the jump off a perch (0x1d),
-- whose motion and speed data slots 18 and 19 pick by kind; the perch's jump has the button thrust (slot 22).
local Math = require("./Math")
local Config = require("./Config")
local Tracker = require("./Tracker")
local Swing = require("./Swing")
local V3 = Math.V3
type V3 = Math.V3
type Configs = Config.Configs
type Tracker = Tracker.Tracker
type Env = Swing.Env
type SwingRelease = Swing.SwingRelease

local new = V3.new
local fmax, fmin, clamp = Math.fmax, Math.fmin, Math.clamp
local remap, unlerp, lerp, approach, approach_v = Math.remap, Math.unlerp, Math.lerp, Math.approach, Math.approach_v
local exp, rotate, angle_between = Math.exp, Math.rotate, Math.angle_between
local abs, sqrt = math.abs, math.sqrt

local Air = {}

-- Jump kinds (+0x2c0, +0x2c4)
Air.KIND_FALL = 0x0b
Air.KIND_DIVE = 0x0c
Air.KIND_SWING_JUMP = 0x11
-- the jump off a perch (A while perched)
Air.KIND_PERCH_JUMP = 0x1d
-- the point launch at the end of a zip to a point (exe+b19fb0, HeroStateJump)
Air.KIND_POINT_LAUNCH = 0x2a
-- the second kind's default: none
Air.KIND_NONE = 0x35
local KIND_FALL, KIND_DIVE, KIND_SWING_JUMP = Air.KIND_FALL, Air.KIND_DIVE, Air.KIND_SWING_JUMP
local KIND_PERCH_JUMP, KIND_POINT_LAUNCH, KIND_NONE = Air.KIND_PERCH_JUMP, Air.KIND_POINT_LAUNCH, Air.KIND_NONE

-- The jump data a transition hands the state (defaults: exe+a7d820)
export type AirEntry = {
	-- +0x34: the horizontal direction
	dir: V3,
	-- +0x40: extra velocity on top of the motion (it decays)
	vel: V3,
	-- +0x4c: a facing to hold (zero: none)
	facing: V3,
	-- +0x58, +0x5c
	vy: number,
	h_speed: number,
	-- +0x60: gravity while rising; +0x64: after the apex (10000 or more: the same)
	gravity: number,
	gravity_after: number,
	-- +0x6c: time spent falling already
	fall_time: number,
	-- +0x70
	max_height: number,
	-- +0x74: the input magnitude to start with
	input: number,
	-- +0x78: a speed boost's duration
	boost_time: number,
	-- +0x7c: the apex gravity switch waits until this much time in the state
	gravity_switch_time: number,
	-- +0x81, +0x82, +0x83
	kind: number,
	kind2: number,
	flags: number,
}

-- AirEntry::default(), with fields overridden from `t`
function Air.AirEntry(t: { [string]: any }?): AirEntry
	local e: any = {
		dir = V3.ZERO,
		vel = V3.ZERO,
		facing = V3.ZERO,
		vy = 0,
		h_speed = 0,
		gravity = 0,
		gravity_after = 1.0000000150474662e+30,
		fall_time = 0,
		max_height = -1.0000000150474662e+30,
		input = 0,
		boost_time = 0,
		gravity_switch_time = -1,
		kind = 0,
		kind2 = KIND_NONE,
		flags = 0,
	}
	if t then
		for k, v in t do
			e[k] = v
		end
	end
	return e
end

-- exe+97c9d0 (the transition manager's slot 82): the swing jump from the swing's release. The direction is the release
-- velocity's, flattened (exe+a7d8c0 takes out the mover's up); the gravity after the apex is the tracker's fall gravity
-- (exe+ac1680's last output, exe+85fbb0).
function Air.swing_jump(r: SwingRelease, tr: Tracker): AirEntry
	local v = r.velocity
	local d = v:flat_norm()
	local dir = if abs(d.x) > 0.0099999997764825821 or abs(d.z) > 0.0099999997764825821 then d:norm() else d
	return Air.AirEntry({
		dir = dir,
		vy = v.y,
		h_speed = v:flat_len(),
		gravity = r.gravity,
		gravity_after = tr.fall_gravity,
		kind = KIND_SWING_JUMP,
	})
end

-- exe+b19fb0's request of HeroStateJump at the end of a zip to a point: the launch velocity `v` (horizontal part and
-- vertical speed), gravity `gravity` until the top, `gravity_fall` after it (PointLaunchConfig.GravityFall), the input
-- at full (+0x74 = 1), kind 0x2a. The direction and horizontal speed are `v`'s flat part's (exe+a7d8c0).
function Air.point_launch(v: V3, gravity: number, gravity_fall: number): AirEntry
	local h = new(v.x, 0, v.z)
	return Air.AirEntry({
		dir = h:norm(),
		vy = v.y,
		h_speed = h:len(),
		gravity = gravity,
		gravity_after = gravity_fall,
		input = 1,
		kind = KIND_POINT_LAUNCH,
	})
end

-- What the air states read besides the frame's Env
export type AirInput = {
	-- The animation component's "playing" bit (+0x98 bit 0): the swing jump hands over to the fall once its animation
	-- stops. nil: while rising (as tools/native_oracle stands in for it).
	anim_playing: boolean?,
	-- The animation's time (exe+15c09c0), against the state's animation timings (+0x1f8.., -1 without)
	anim_phase: number,
	-- The fall's dive input (its processor's +0x394, 0..1) and the dive button's buffered event (0xce39bb4c)
	dive_input: number,
	dive_button: boolean,
	-- The mover's height above the ground (+0x6b8); a dive needs 16 m
	height: number,
	-- The mover's time in the air (+0x6b4, negative while airborne)
	air_time: number,
}

-- The globals the air states share (exe+6deecc0..6deecd0): the air clock (+0xc, the time since the swing jump or a
-- fall that didn't follow one began), the facing blend (+0x10) and a vector the fall keeps (+0x0)
export type AirShared = { v: V3, clock: number, facing_blend: number }
function Air.AirShared(): AirShared
	return { v = V3.ZERO, clock = 0, facing_blend = 0 }
end

-- What a frame of the air states hands the mover
export type AirOutput = { displacement: V3, facing: V3, snap: boolean, input: number }

local AirLocal = {}
AirLocal.__index = AirLocal
Air.AirLocal = AirLocal
export type AirLocal = any

-- exe+a85f70 (and the fall's constructor on top)
function AirLocal.new(fall: boolean): AirLocal
	return setmetatable({
		-- the fall's virtuals (exe+38c9220) instead of the swing jump's
		fall = fall,
		-- +0xd8
		entry_time = 0,
		-- +0x124: the entry direction
		dir = V3.ZERO,
		-- +0x130
		facing = V3.ZERO,
		-- +0x13c: the horizontal velocity the state started from (the steering compares the input with it)
		carry = V3.ZERO,
		-- +0x154: extra velocity (decays at +0x224 per second); +0x160 last frame's
		vel = V3.ZERO,
		prev_vel = V3.ZERO,
		-- +0x16c: a facing to hold
		hold_facing = V3.ZERO,
		-- +0x184: the horizontal velocity moved last frame
		last_vel = V3.ZERO,
		-- +0x1d0: the shared vector, kept by a fall that follows a jump
		saved = V3.ZERO,
		-- +0x1dc: the input magnitude to start with
		entry_input = 0,
		-- +0x1e0, +0x1e4: gravity now and after the apex
		gravity = 0,
		gravity_after = 0,
		-- +0x1e8: time spent falling
		fall_time = 0,
		-- +0x1ec, +0x1f0
		vy_prev = 0,
		vy = 0,
		-- +0x1f4: the tracker's terminal velocity
		terminal = 0,
		-- +0x1f8, +0x208, +0x20c, +0x210, +0x214, +0x21c: animation timings (-1 without)
		anim_end = -1,
		anim_fall_a = -1,
		anim_dive = -1,
		anim_dive_ok = -1,
		anim_fall_b = -1,
		anim_land = -1,
		-- +0x1fc
		gravity_switch_time = -1,
		-- +0x204: an animation-driven jump when >= 0
		anim_duration = -1,
		-- +0x224
		vel_decay = -0.10000000149011612,
		-- +0x228: on the tracker's fall gravity
		tracker_gravity = false,
		-- +0x250, +0x254, +0x258: the button thrust (acceleration, gravity, this frame's time)
		thrust_accel = 0,
		thrust_gravity = 0,
		thrust_time = 0,
		-- +0x25c: the horizontal speed allowed, lowered by the drag
		speed = 0,
		-- +0x264, +0x268: the run speed and its acceleration
		run_speed = 0,
		run_accel = 0,
		-- +0x26c, +0x274
		max_height = 0,
		h_speed = 0,
		-- +0x2c0, +0x2c4
		kind = 0,
		kind2 = KIND_NONE,
		-- +0x2c8: held by the processor (its +0x3bc time) unless +0x2c9
		early = false,
		no_early = false,
		-- +0x2ca: past the first frame
		started = false,
		-- +0x2cb.. entry flags
		b2cb = false,
		b2cc = false,
		thrust_done = false,
		b2d1 = false,
		anim_read = false,
		fall_anim_done = false,
		b2d4 = false,
		b2d5 = false,
		b2d6 = false,
		b2d7 = false,
		b2d8 = false,
		-- +0x2da: diving
		dive = false,
		b2db = false,
		b2dc = true,
		-- +0x2e0: how long the button thrust has run; +0x2f8: the button held for it
		thrust_clock = 0,
		thrust_held = true,
		-- +0x2e4, +0x2e8, +0x2ec: the entry's speed boost (target speed, time left, rate)
		boost_speed = 0,
		boost_time = 0,
		boost_rate = 0,
		-- +0x2f0: how long the stick has been held (starts at 5 the first time)
		input_time = -1,
		-- +0x2f4
		input_out = 0,
		-- +0x2f9: the side the facing turns to near 180 degrees
		turn_side = false,
		-- +0x2fc: the facing's blend toward the input
		facing_blend = 0,
		-- HeroStateFallLocal +0x300: the dive input; +0x304 time diving, +0x308 time falling; +0x30c diving, +0x30d
		-- the dive drag, +0x30e, +0x310 (no dive button check), +0x311
		dive_input = 0,
		dive_time = 0,
		fall_clock = 0,
		diving = false,
		dive_drag = false,
		b30e = false,
		b310 = false,
		b311 = false,
	}, AirLocal)
end

function AirLocal.clone(self: AirLocal): AirLocal
	return setmetatable(table.clone(self), AirLocal)
end

-- exe+20dc660: time in the state
function AirLocal.age(self: AirLocal, env: Env): number
	return Math.f64_elapsed(env.time, self.entry_time)
end

-- exe+a87910's (and exe+868f00's) motion data for a kind: HeroTraversalConfig.JumpConfigs, as far as the kinds this
-- port enters go (the rest read SingleJumpConfig, the default)
local function motion_data(cfg: Configs, kind: number): any
	local j = cfg.traversal.jump_configs
	if kind == KIND_SWING_JUMP then
		return j.swing_jump_config.standard_data
	elseif kind == KIND_POINT_LAUNCH then
		return j.zip_point_launch_jump_config.standard_data
	elseif kind == KIND_PERCH_JUMP then
		return j.perch_jump_config.standard_data
	end
	return j.single_jump_config.standard_data
end
Air.motion_data = motion_data
-- exe+a879d0's (and exe+869360's) speed data for a kind
local function speed_data(cfg: Configs, kind: number): any
	local j = cfg.traversal.jump_configs
	if kind == KIND_SWING_JUMP or kind == 0x12 or kind == KIND_POINT_LAUNCH then
		return j.swing_jump_speed.standard_data
	elseif kind == KIND_DIVE then
		return j.dive_jump_speed.standard_data
	elseif kind == KIND_PERCH_JUMP then
		return j.perch_jump_speed.standard_data
	end
	return j.ground_jump_speed.standard_data
end
Air.speed_data = speed_data

-- The kind slots 18 and 19 pick their data by: a fall (0x0b, 0x34) reads its second kind's, unless it has none
function AirLocal.data_kind(self: AirLocal): number
	if (self.kind == KIND_FALL or self.kind == 0x34) and self.kind2 ~= KIND_NONE then
		return self.kind2
	end
	return self.kind
end
-- Slot 18 (exe+a87910): the motion data by kind
function AirLocal.motion(self: AirLocal, cfg: Configs): any
	return motion_data(cfg, self:data_kind())
end
-- Slot 19 (exe+a879d0): the speed data by kind
function AirLocal.speed_data(self: AirLocal, cfg: Configs): any
	return speed_data(cfg, self:data_kind())
end
-- exe+869300: the motion data's drag profile by name
function AirLocal.drag_profile(self: AirLocal, cfg: Configs): any
	return cfg:drag_profile(self:motion(cfg).drag_profile_name)
end
-- Slot 42 (exe+a8ae50): steering once the motion data's NoInputTime has passed on the air clock
function AirLocal.steering(self: AirLocal, cfg: Configs, sh: AirShared): boolean
	return self:motion(cfg).no_input_time <= sh.clock
end
function AirLocal.fall_from_jump(self: AirLocal): boolean
	return (self.kind == KIND_FALL or self.kind == KIND_DIVE) and self.kind2 ~= KIND_NONE
end

local function nonzero(v: V3, eps: number): boolean
	return abs(v.x) > eps or abs(v.y) > eps or abs(v.z) > eps
end

-- exe+a86490 (+ exe+a70080 for the fall)
function AirLocal.enter(self: AirLocal, e: AirEntry, tr: Tracker, env: Env, sh: AirShared)
	local flags = e.flags
	self.entry_time = env.time
	self.b2cb = bit32.band(bit32.bnot(bit32.rshift(flags, 1)), 1) ~= 0
	self.b2d1 = bit32.band(flags, 1) ~= 0
	self.b2cc = bit32.band(bit32.bnot(bit32.rshift(flags, 2)), 1) ~= 0
	self.b2d6 = bit32.band(bit32.rshift(flags, 6), 1) ~= 0
	self.b2d7 = bit32.rshift(flags, 7) ~= 0
	self.b2d8 = false
	self.started = false
	self.anim_duration = -1
	self.vel = e.vel
	self.prev_vel = e.vel
	self.max_height = fmax(env.hero.pos.y, e.max_height)
	local d = e.dir
	self.dir = if nonzero(d, 9.9999997473787516e-05) then d:norm() else env.hero.fwd
	self.facing = self.dir
	local f = e.facing
	if nonzero(f, 9.9999997473787516e-05) then
		self.facing = f
		self.hold_facing = f
	end
	self.entry_input = e.input
	self.kind = e.kind
	self.kind2 = e.kind2
	self.h_speed = e.h_speed
	self.vy = e.vy
	self.gravity = e.gravity
	self.gravity_after = if e.gravity_after >= 10000 then e.gravity else e.gravity_after
	self.gravity_switch_time = e.gravity_switch_time
	self.speed = self.h_speed
	self.run_speed = self.h_speed
	self.run_accel = 0
	self.b2d4 = false
	self.b2d5 = bit32.band(bit32.rshift(flags, 5), 1) ~= 0
	if (self.kind == KIND_FALL or self.kind == KIND_DIVE or self.kind == 0x34) and self.kind2 ~= KIND_NONE then
		self.facing_blend = sh.facing_blend
		self.saved = sh.v
	else
		sh.clock = 0
		sh.v = V3.ZERO
	end
	self.terminal = tr.terminal
	self.boost_time = e.boost_time
	self.boost_speed = e.h_speed
	-- (0 / 0 when there is no boost: NaN, as in the Rust; it is read only while a boost runs)
	self.boost_rate = __F(fmax(__F(self.boost_speed - env.mover_vel:flat_len()), 0) / self.boost_time)
	if not self.fall then
		return
	end
	-- exe+a70080
	self.diving = false
	self.dive_drag = false
	self.b30e = true
	self.dive_input = 1.0000000150474662e+30
	self.dive_time = 0
	self.fall_clock = 0
	self.b311 = false
	if self.kind == KIND_DIVE then
		self.dive_drag = true
		self.diving = true
		self.b2dc = false
	end
	self.b310 = false
	if self.kind2 ~= KIND_NONE then
		self.started = true
		self.carry = env.mover_vel
	end
end

-- The state's exit as far as the tracker goes: the fall's (exe+a701a0) moves the momentum ring on (exe+85e310); the
-- swing jump's (exe+a86270) leaves nothing modelled here
function AirLocal.exit(self: AirLocal, tr: Tracker)
	if self.fall then
		tr.ring_next = __F((__F(tr.ring_next + 1)) % 32)
	end
end

-- exe+a8d5b0: one frame. `tr` is the tracker after its own update this frame.
function AirLocal.update(self: AirLocal, cfg: Configs, tr: Tracker, env: Env, inp: AirInput, sh: AirShared): AirOutput
	-- the processor's hold (its +0x3bc; none after a swing)
	self.early = not self.no_early and self:age(env) < 0
	-- slot 36 (exe+a88b60): the animation's timings, once
	if not self.anim_read then
		self.anim_read = true
	end
	sh.clock = __F(sh.clock + (env.dt))
	local out = self:motion_frame(cfg, tr, env, sh)
	if self.fall then
		self:fall_gravity(tr, env, inp)
		self:fall_momentum(cfg, tr, env)
	else
		self:jump_dive(env, inp)
	end
	return out
end

-- exe+a2f110: v at length `l` (along x when v is zero)
local function scaled(v: V3, l: number): V3
	local d = v:dot(v)
	if d >= 1.0000000036274937e-15 then
		return __F(v * (__F(l / __F(sqrt(d)))))
	end
	return new(l, 0, 0)
end
Air.scaled = scaled

-- the kinds with a button thrust: bit `kind` of the u64 0x781e_2700_0009 (kinds 0..0x2e), built from the constant's
-- two 32-bit words
local THRUST_KINDS: { [number]: boolean } = {}
do
	local lo, hi = 0x27000009, 0x0000781e
	for b = 0, 31 do
		if bit32.band(bit32.rshift(lo, b), 1) ~= 0 then
			THRUST_KINDS[b] = true
		end
		if bit32.band(bit32.rshift(hi, b), 1) ~= 0 then
			THRUST_KINDS[__F(b + 32)] = true
		end
	end
end
Air.THRUST_KINDS = THRUST_KINDS

-- exe+a88ec0
function AirLocal.motion_frame(self: AirLocal, cfg: Configs, tr: Tracker, env: Env, sh: AirShared): AirOutput
	local dt = env.dt
	local hero = env.hero
	self.max_height = fmax(self.max_height, hero.pos.y)
	-- slot 45 (exe+a8afa0): the mover's velocity; the extra velocity decays and comes off it
	local base = env.mover_vel
	self.prev_vel = self.vel
	local e = __F(exp(__F(self.vel_decay * dt)))
	self.vel = __F(self.vel + __F((__F(V3.ZERO - self.vel)) * (__F(1 - e))))
	base = __F(base - self.prev_vel)
	-- slot 22 (exe+a87b90): the button thrust. For the kinds that have one (the perch's jump among them), while the
	-- jump button is held (or the entry asked for it, +0x2d6) and he rises, for ButtonThrustTimeMax at most
	self.thrust_accel = 0
	self.thrust_gravity = 0
	self.thrust_time = 0
	if not self.thrust_done and not self.early then
		if self.vy < -9.9999997473787516e-05 then
			self.thrust_done = true
		elseif self.kind <= 0x2e and THRUST_KINDS[self.kind] then
			self.thrust_held = env.input.jump_held
			if not self.thrust_held and not self.b2d6 then
				self.thrust_done = true
			else
				local md = self:motion(cfg)
				local over = fmax(__F(self.thrust_clock - md.button_thrust_time_max), 0)
				self.thrust_accel = md.button_thrust_accel
				self.thrust_gravity = md.button_thrust_accel_grav
				self.thrust_clock = __F(self.thrust_clock + (dt))
				self.thrust_done = md.button_thrust_time_max <= self.thrust_clock
				self.thrust_time = fmax(__F(dt - over), 0)
			end
		end
	end
	self.vy_prev = self.vy
	-- slot 20 (exe+a87a70): the speeds
	local sd = self:speed_data(cfg)
	self.run_speed = fmax(self.run_speed, sd.run_speed_alt_min)
	if self.run_speed < sd.run_speed_max_min then
		if sh.clock > sd.max_accel_delay then
			if sd.max_accel_speed <= 0 then
				self.run_speed = sd.run_speed_max_min
			else
				local a = sd.max_accel_speed
				if sd.max_accel_accel > 0 then
					a = fmin(__F(__F(sd.max_accel_accel * dt) + self.run_accel), sd.max_accel_speed)
				end
				self.run_accel = a
				self.run_speed = fmin(__F(__F(a * dt) + self.run_speed), sd.run_speed_max_min)
			end
		end
	else
		self.run_speed = fmin(self.run_speed, sd.run_speed_max_max)
	end
	local run = self.run_speed
	local walk = fmin(run, sd.walk_speed_max)
	local low = fmin(__F(walk * 0.25), 0.25)
	-- the input (exe+b7e2e0: the stick's magnitude, no dead zone)
	local dir = self.facing
	local mag = self.entry_input
	local raw = (Swing.stick_raw(env))
	if raw >= 0.0099999997764825821 then
		self.input_time = if self.input_time >= 0 then __F(self.input_time + dt) else 5
	else
		self.input_time = 0
	end
	local steer_kinds = self.started or self:fall_from_jump()
	if self:steering(cfg, sh) and steer_kinds then
		local d = (Swing.stick_world(env))
		dir = d
		mag = if d == V3.ZERO then 0 else raw
	end
	local base_speed = base:len()
	if mag < 0.0099999997764825821 then
		dir = if base:flat_len() > 0.0099999997764825821 then new(base.x, 0, base.z):norm() else hero.fwd
	end
	-- slot 48 (exe+a8b140): the speed to settle at
	local target
	if mag > 0.039999999105930328 then
		if mag < dt then
			target = __F(__F(fmin(fmax(__F(mag / dt), 0), 1) * (__F(walk - low))) + low)
		else
			local t = if dt < 1 then __F((__F(mag - dt)) / (__F(1 - dt))) else 1
			target = __F(__F(fmin(fmax(t, 0), 1) * (__F(run - walk))) + walk)
		end
	else
		target = 0
	end
	local speed = self:drag(cfg, dir, mag, target, base, dt, sh)
	local cap = fmax(fmax(speed, run), walk)
	local disp = self:displacement(cfg, tr, env, dir, mag, base, speed, cap, sh)
	-- slot 54 (exe+a8c350): a held facing keeps the entry direction
	local held = not (
		self:steering(cfg, sh)
		and abs(self.hold_facing.x) <= 9.9999997473787516e-05
		and abs(self.hold_facing.y) <= 9.9999997473787516e-05
		and abs(self.hold_facing.z) <= 9.9999997473787516e-05
	)
	local want = if held then self.dir else self:facing_toward(cfg, env, dir, mag, __F(disp * (__F(1 / dt))), sh)
	local facing = if __F(__F(want.x * want.x) + __F(want.z * want.z)) <= 0.0010000000474974513 then hero.fwd else new(want.x, 0, want.z):norm()
	-- after the apex: the gravity for falling (from the state's +0x1fc on), or the tracker's
	if self.vy < 0 then
		self.fall_time = __F(self.fall_time + (dt))
		if self:age(env) > self.gravity_switch_time then
			self.gravity = self.gravity_after
			if tr.fall_gravity_override or self.tracker_gravity then
				self.gravity_after = tr.fall_gravity
				self.gravity = tr.fall_gravity
				self.tracker_gravity = true
			end
		end
	end
	self.input_out = if walk < base_speed then mag else raw
	self.last_vel = new(__F(disp.x / dt), 0, __F(disp.z / dt))
	if self.kind ~= 0x34 then
		self.started = not self.early
	end
	return { displacement = disp, facing = facing, snap = false, input = self.input_out }
end

-- Slot 49 (exe+a8b1d0): the speed allowed comes down toward `target` at the drag profile's rate, which is the forward
-- drag (by speed) with the input along the carried velocity, the turn drag across it, the no-input drag without input
function AirLocal.drag(self: AirLocal, cfg: Configs, dir: V3, mag: number, target: number, base: V3, dt: number, sh: AirShared): number
	if not self.started or self.boost_time > 9.9999997473787516e-05 or self.early then
		return self.speed
	end
	local p = self:drag_profile(cfg)
	local v = base:len()
	local fwd = __F(__F(unlerp(v, p.forward_speed_min, p.forward_speed_max) * (__F(p.forward_drag_max - p.forward_drag_min)))
		+ p.forward_drag_min)
	local b = unlerp(sh.clock, p.turn_blend_in_start, p.turn_blend_in_final)
	local drag = fmax(__F(__F((__F(p.no_input_drag - fwd)) * b) + fwd), fwd)
	local turn = fmax(__F(__F((__F(p.turn_drag - fwd)) * b) + fwd), fwd)
	if mag > 0.05000000074505806 then
		local d = fmax(self.carry:norm():dot(dir), 0)
		drag = __F(__F(unlerp(d, 0, p.forward_tolerance) * (__F(fwd - turn))) + turn)
	end
	-- slot 50: the fall's dive drag
	if self.fall and self.dive_drag then
		drag = 15
	end
	self.speed = fmin(self.speed, v)
	self.speed = fmax(approach(self.speed, target, drag, dt), target)
	return self.speed
end

-- Slot 52 (exe+a8b520): this frame's move. The horizontal velocity steers toward the input at `speed`, capped at
-- `cap`; the extra velocity rides on top; then the vertical.
function AirLocal.displacement(self: AirLocal, cfg: Configs, tr: Tracker, env: Env, dir: V3, mag: number, base: V3, speed: number, cap: number, sh: AirShared): V3
	local dt = env.dt
	local dd = dir:dot(dir)
	local want = if dd >= 1.0000000036274937e-15 then __F(dir * (__F(speed / __F(sqrt(dd))))) else new(speed, 0, 0)
	local flat = new(base.x, 0, base.z)
	if self.early then
		-- held: the motion carries on (the animation's root motion when +0x2d7)
		return new(__F((__F(flat.x + self.vel.x)) * dt), __F(self.vel.y * dt), __F((__F(flat.z + self.vel.z)) * dt))
	end
	if not self.started then
		local src_dir, src_len
		local k = self.kind
		if k == 6 or k == 7 or k == 0xd or k == 0xe or k == 0xf then
			src_dir, src_len = dir, cap
		elseif nonzero(self.hold_facing, 9.9999997473787516e-05) then
			src_dir, src_len = self.hold_facing, self.h_speed
		else
			src_dir, src_len = self.dir, self.h_speed
		end
		self.carry = scaled(src_dir, src_len)
		want = self.carry
		if self.boost_time >= 9.9999997473787516e-05 then
			local c = self.carry:norm()
			local cc = c:dot(c)
			local along = if cc <= 1.0000000036274937e-15 then V3.ZERO else __F(c * (__F((__F(__F(c.z * flat.z) + __F(c.x * flat.x))) / cc)))
			flat = if c:dot(along) < 0 then V3.ZERO else along
			local rest = fmax(__F(self.boost_speed - flat:flat_len()), 0)
			self.boost_rate = __F(rest / self.boost_time)
		else
			flat = self.carry
		end
	end
	if self:steering(cfg, sh) then
		flat = self:steer(cfg, flat, want, dt, mag, cap, sh)
		if self.boost_time > 9.9999997473787516e-05 then
			flat = self:boost(flat, dt)
		end
	elseif self.boost_time >= 9.9999997473787516e-05 then
		flat = self:boost(flat, dt)
	else
		flat = scaled(self.carry, fmin(self.carry:len(), cap))
	end
	local out = __F((__F(flat + self.vel)) * dt)
	return self:vertical(tr, env, out)
end

-- The entry's speed boost (+0x2e4 over +0x2e8 at +0x2ec). Returns the boosted flat velocity.
function AirLocal.boost(self: AirLocal, flat: V3, dt: number): V3
	local step = fmin(self.boost_time, dt)
	local rest = fmax(__F(self.boost_speed - flat:len()), 0)
	if rest > 9.9999997473787516e-05 then
		flat = __F(flat + scaled(self.carry, fmin(__F(step * self.boost_rate), rest)))
	end
	self.boost_time = __F(self.boost_time - (step))
	return flat
end

-- Slot 57 (exe+a8c7f0): the horizontal velocity moves toward `want` at the motion data's acceleration (higher later on
-- the air clock, and at once when the input turns back), scaled by the input and how long it has been held; at most
-- `cap`
function AirLocal.steer(self: AirLocal, cfg: Configs, cur: V3, want: V3, dt: number, m: number, cap: number, sh: AirShared): V3
	local back = 0
	if m > 0.10000000149011612 and fmin(want:len(), cur:len()) > 0.10000000149011612 then
		local a = new(cur.x, 0, cur.z):norm()
		local b = new(want.x, 0, want.z):norm()
		if a:dot(b) < -0.5 then
			back = m
		end
	end
	local md = self:motion(cfg)
	local tb = remap(sh.clock, md.velocity_accel_time_min, md.velocity_accel_time_max)
	local acc = __F(__F((__F(__F((__F(1 - tb)) * back) + tb)) * (__F(md.velocity_accel_accel_max - md.velocity_accel_accel_min)))
		+ md.velocity_accel_accel_min)
	local held = fmax(fmin(fmax(__F(self.input_time * 3.0303030014038086), 0), 1), 0.20000000298023224)
	local f = __F((__F(__F(fmin(fmax(__F(m * 1.3333333730697632), 0), 1) * 0.75) + 0.25)) * held)
	-- slot 51: the fall halves it while diving
	if self.fall and self.diving then
		f = __F(f * (0.5))
	end
	local r = approach_v(cur, want, __F(__F(f * acc) + back), dt)
	local l = fmin(r:len(), cap)
	local rr = r:dot(r)
	if rr >= 1.0000000036274937e-15 then
		return __F(r * (__F(l / __F(sqrt(rr)))))
	end
	return new(0, 0, 0)
end

-- Slot 56 (exe+a8c3c0): gravity (more while diving), the thrust, the terminal velocity; integrated at the frame's
-- midpoint. Returns `out` with the vertical move added.
function AirLocal.vertical(self: AirLocal, tr: Tracker, env: Env, out: V3): V3
	local dt = env.dt
	local y = env.hero.pos.y
	local floor = -1.0000000150474662e+30
	local g0 = self.gravity
	local tg = __F(self.thrust_time * self.thrust_gravity)
	local k = fmin(fmax(__F(self.thrust_time / dt), 0), 1)
	local thrust = __F(self.thrust_time * self.thrust_accel)
	local g1 = __F(g0 + tg)
	local half = __F((__F((__F(1 - k)) + 1)) * 0.5)
	if self.dive then
		g1 = __F(g1 + (__F(dt * 35)))
	end
	self.gravity = g1
	self.gravity_after = __F(self.gravity_after + (tg))
	local gdt = __F((__F(__F((__F(g1 - g0)) * half) + g0)) * dt)
	self.terminal = tr.terminal
	local min = -self.terminal
	local vy = fmax(__F(__F(self.vy - gdt) + thrust), min)
	local dy = __F(fmax(__F(__F(self.vy - __F(gdt * 0.5)) + __F(half * thrust)), min) * dt)
	if __F(__F(out.y + y) + dy) < floor then
		dy = __F(floor - y)
	end
	self.vy = vy
	return new(out.x, __F(out.y + dy), out.z)
end

-- Slot 53 (exe+a8beb0): the facing. The fall keeps the input's direction (or his own); the swing jump starts on its
-- travel and turns toward the input over FacingToInputTime on the air clock.
function AirLocal.facing_toward(self: AirLocal, cfg: Configs, env: Env, dir: V3, mag: number, vel: V3, sh: AirShared): V3
	local mf = env.hero.fwd
	local base = if mag <= 0.0099999997764825821 then mf else dir
	if self:fall_from_jump() then
		return base
	end
	local md = self:motion(cfg)
	local fb = remap(sh.clock, md.facing_to_input_time_min, md.facing_to_input_time_max)
	local travel = new(__F(vel.x - self.vel.x), 0, __F(vel.z - self.vel.z)):norm()
	if mag < 0.0099999997764825821 and vel:flat_len() < 0.25 then
		return mf
	end
	local out
	if fb > 0.99989998340606689 then
		out = base
	elseif fb > 9.9999997473787516e-05 then
		local prev = self.facing_blend
		local frac = fmin(fmax(__F((__F(fb - prev)) / (__F(1 - prev))), 0), 1)
		local ay = if __F(__F(base.x * mf.z) - __F(mf.x * base.z)) >= 0 then 1 else -1
		local ang = angle_between(mf, base)
		local left = ay > 0
		if self.turn_side and ang >= 2.9845130443572998 then
			if self.turn_side ~= left then
				ay = -ay
				ang = __F(6.2831854820251465 - ang)
			end
		else
			self.turn_side = left
		end
		out = rotate(mf, new(0, ay, 0), __F(ang * frac))
	else
		out = travel
	end
	self.facing_blend = fb
	sh.facing_blend = fb
	return out
end

-- The swing jump's slot 41 (exe+a8adb0): a dive past 0.3 s on the dive button (exe+a71380) when slot 17 (exe+a87850)
-- agrees: high enough and the dive input pushed; diving while still rising adds gravity at once
function AirLocal.jump_dive(self: AirLocal, env: Env, inp: AirInput)
	if self.dive or self:age(env) < 0.30000001192092896 then
		return
	end
	local t = self:age(env)
	local wants = inp.height >= 16 and self.anim_dive_ok < t and t > 0.30000001192092896 and inp.dive_input > 0.80000001192092896
	if inp.dive_button and wants then
		self.dive = true
		if self.vy > 0.10000000149011612 then
			self.gravity = __F(self.gravity + (fmax(__F(self.gravity * 1.5), 30)))
		end
	else
		self.dive = false
	end
end

-- The fall's slot 17 (exe+a70480)
function AirLocal.fall_wants_dive(self: AirLocal, env: Env, inp: AirInput): boolean
	if self.kind2 == KIND_NONE and self:age(env) <= 0.20000000298023224 then
		return false
	end
	return self.dive_input > 0.75 and not self.diving and inp.height >= 16
end

-- The fall's slot 41 (exe+a706a0): gravity grows by 3 m/s per second up to 30 (5 while diving)
function AirLocal.fall_gravity(self: AirLocal, tr: Tracker, env: Env, inp: AirInput)
	local dt = env.dt
	self.dive_input = inp.dive_input
	local check = self.b310 or inp.dive_button
	local wants = self:fall_wants_dive(env, inp)
	if check and (self.diving or wants) then
		self.b2d4 = true
		self.dive_drag = true
		self.kind = KIND_DIVE
		self.gravity = fmin(__F(__F(dt * 5) + self.gravity), 30)
		self.gravity_after = fmin(__F(__F(dt * 5) + self.gravity_after), 30)
		return
	end
	if not tr.fall_gravity_override then
		self.dive_drag = false
		self.gravity = fmin(__F(__F(dt * 3) + self.gravity), 30)
		self.gravity_after = fmin(__F(__F(dt * 3) + self.gravity_after), 30)
	end
end

-- exe+a71a40: falling fast builds momentum (more, and longer, when diving)
function AirLocal.fall_momentum(self: AirLocal, cfg: Configs, tr: Tracker, env: Env)
	local dt = env.dt
	local fd = cfg.swing.momentum_config.fall_data
	if not self.diving then
		self.dive_time = 0
		if tr.state ~= 2 then
			self.fall_clock = 0
		else
			self.fall_clock = __F(self.fall_clock + (dt))
		end
	else
		self.dive_time = __F(self.dive_time + (dt))
		self.fall_clock = __F(self.fall_clock + (dt))
	end
	local sf = if self.vy <= 0 then remap(abs(self.vy), fd.fall_speed_min, fd.fall_speed_max) else 0
	local tf = __F(remap(self:age(env), fd.fall_time_min, fd.fall_time_max) ^ fd.fall_time_bias)
	local gain = __F((lerp(fd.fall_gain_min, fd.fall_gain_max, tf)) * sf)
	local cap = lerp(fd.fall_momentum_cap_min, fd.fall_momentum_cap_max, tf)
	if self.diving then
		local df = __F(remap(self.dive_time, fd.dive_time_min, fd.dive_time_max) ^ fd.dive_time_bias)
		gain = fmax(lerp(fd.dive_gain_min, fd.dive_gain_max, df), gain)
		cap = fmax(lerp(fd.dive_momentum_cap_min, fd.dive_momentum_cap_max, df), cap)
	end
	tr:add_momentum(cfg, __F(gain * dt), cap, false)
end

-- The swing jump's transition check (exe+a86ad0 as far as a swing's jump goes): it hands over to the fall once its
-- animation has played out (exe+a87f10) while he is in the air. The fall's entry (exe+a885c0 -> exe+96e580) comes back.
function AirLocal.check(self: AirLocal, cfg: Configs, env: Env, inp: AirInput): AirEntry?
	if self.fall or self.kind == KIND_FALL or self.kind == KIND_DIVE or self:age(env) < 0.05000000074505806 then
		return nil
	end
	local phase = inp.anim_phase
	local playing = if inp.anim_playing == nil then self.vy > 0 else inp.anim_playing
	local dive_ready = self.dive and phase >= self.anim_dive
	if not ((self.anim_end <= phase or dive_ready) and inp.air_time < 0) then
		return nil
	end
	local long = fmax(self.anim_fall_b, self.anim_fall_a)
	if not ((0 <= long and long < phase) or dive_ready or not playing) then
		return nil
	end
	return self:fall_entry(cfg, env)
end

-- exe+a885c0 -> exe+96e580: the fall from the swing jump. His move's velocity with the state's vertical speed (no
-- faster than 4 m/s down when diving).
function AirLocal.fall_entry(self: AirLocal, cfg: Configs, env: Env): AirEntry
	local v = env.mover_vel
	local vy = self.vy
	if self.dive and -4 <= vy then
		vy = -4
	end
	local h = new(v.x, 0, v.z)
	local dir = if abs(h.x) > 0.0099999997764825821 or abs(h.z) > 0.0099999997764825821 then h:norm() else env.hero.fwd
	if abs(dir.x) > 0.0099999997764825821 or abs(dir.y) > 0.0099999997764825821 or abs(dir.z) > 0.0099999997764825821 then
		dir = new(dir.x, 0, dir.z):norm()
	end
	local h_speed = h:len()
	local kind = if self.dive then KIND_DIVE else KIND_FALL
	local sd = if self.dive
		then cfg.traversal.jump_configs.dive_jump_speed.standard_data
		else cfg.traversal.jump_configs.ground_jump_speed.standard_data
	local input = if sd.run_speed_max_max > 0.0010000000474974513 then fmin(__F(h_speed / sd.run_speed_max_max), 1) else 1
	local g = if abs(self.gravity_after) < 9.9999997473787516e-05 then 26 else self.gravity_after
	return Air.AirEntry({
		dir = dir,
		vel = self.vel,
		vy = vy,
		h_speed = h_speed,
		gravity = g,
		gravity_after = g,
		fall_time = self.fall_time,
		max_height = self.max_height,
		input = input,
		kind = kind,
		kind2 = self.kind,
	})
end

-- exe+974c90 (the transition manager's ground jump, as the perch's jump asks it) with exe+868850's numbers from the
-- kind's motion data: up at 2h/t (JumpHeight h, TimeToPeak t), gravity 2h/t^2 to the top and 2h/TimeToFall^2 after it
-- (with no TimeToFall, the rise's or the tracker's fall gravity, the larger). On along `dir` (flat): with the stick
-- past 0.04, (0.8 stick + 0.2) times the speed data's RunSpeedMaxMax, else `carry` (his speed); within the speed data's
-- launch speeds. The input is the stick's amount.
function Air.ground_jump(cfg: Configs, kind: number, dir: V3, carry: number, stick: number, fall_gravity: number): AirEntry
	local md = motion_data(cfg, kind)
	local sd = speed_data(cfg, kind)
	local h, t, tf = md.jump_height, md.time_to_peak, md.time_to_fall
	local vy = __F((__F(h + h)) * (__F(1 / t)))
	local rise = __F(__F((__F(h + h)) * (__F(1 / t))) * (__F(1 / t)))
	local after = if tf > 0 then __F((__F((__F(t * t)) / (__F(tf * tf)))) * rise) else fmax(rise, fall_gravity)
	local speed = if stick > 0.039999999105930328 then __F((__F(__F(stick * 0.80000001192092896) + 0.20000000298023224)) * sd.run_speed_max_max) else carry
	speed = fmax(speed, sd.min_launch_speed)
	if sd.max_launch_speed >= 0 then
		speed = fmin(speed, sd.max_launch_speed)
	end
	return Air.AirEntry({
		dir = new(dir.x, 0, dir.z):norm(),
		vy = vy,
		h_speed = speed,
		gravity = __F(vy * (__F(1 / t))),
		gravity_after = after,
		input = stick,
		kind = kind,
	})
end

return Air
