--!strict
local __F = function(x: any): any if type(x) == "number" then return vector.create(x, 0, 0).x end return x end -- f32ify: f32 rounding (vector arithmetic rounds in its own metamethods)
-- Port of crates/sm_traversal/src/tracker.rs: the hero's traversal tracker (Hero::HeroTraversalTracker), as far as the
-- swing, swing jump and fall read it: momentum (exe+8630f0), the blend of the swing setups by speed and momentum
-- (exe+864660), and fall gravity and terminal velocity (exe+85f580). Offsets are the tracker's.
local Math = require("./Math")
local Config = require("./Config")
type V3 = Math.V3

local approach, lerp, remap, fmax, fmin, clamp = Math.approach, Math.lerp, Math.remap, Math.fmax, Math.fmin, Math.clamp

local Tracker = {}
Tracker.__index = Tracker

-- The Blended params (+0x3a8 search, +0x408 motion, +0x528 release) start as all zero (Blended::default)
local function zeroed(schema: any): any
	return Config.read(schema, nil)
end

export type Tracker = typeof(setmetatable({} :: {
	momentum: number,
	ring_time: { number },
	ring_value: { number },
	ring_next: number,
	hold: boolean,
	momentum_frac: number,
	stage_momentum: number,
	terminal_floor: number,
	gravity_scale: number,
	line_length_tweak: number,
	line_angle_tweak: number,
	pivot_factor: { number },
	turn_speed_scale: number,
	speed_blend: number,
	params: any,
	fall_gravity: number,
	terminal: number,
	forward_action_time: number,
	skill_level: number,
	state: number,
	fall_gravity_override: boolean,
	cooldowns: { number },
}, Tracker))

function Tracker.new(): Tracker
	local ring_time, ring_value = table.create(32, 0), table.create(32, 0)
	return setmetatable({
		-- +0x1e8
		momentum = 0,
		-- +0x1ec / +0x26c: recent momentum gains (time left, value); +0x30c the next slot (0-based, as in the Rust)
		ring_time = ring_time,
		ring_value = ring_value,
		ring_next = 0,
		-- +0x314: no decay
		hold = false,
		-- +0x310: momentum / max, eased
		momentum_frac = 0,
		-- +0x320.. the momentum stage now
		stage_momentum = 0,
		terminal_floor = 0,
		gravity_scale = 1,
		line_length_tweak = 0,
		line_angle_tweak = 0,
		pivot_factor = { 1, 1, 1 },
		turn_speed_scale = 1,
		-- +0x5e8: speed blend (kept while airborne)
		speed_blend = 0,
		params = {
			search = zeroed(Config.SearchParams),
			motion = zeroed(Config.MotionParams),
			release = zeroed(Config.ReleaseParams),
		},
		-- +0x178 fall gravity, +0x174 terminal velocity (both positive)
		fall_gravity = 0,
		terminal = 0,
		-- +0x364: time since a forward action (stays 0 here, as in the research harness)
		forward_action_time = 0,
		-- the swing skill level (exe+cc0b20; 3 = all upgrades)
		skill_level = 3,
		-- +0x150: the traversal state (2: the fall keeps its own clock)
		state = 0,
		-- +0x17d: a mission's fall gravity is in force
		fall_gravity_override = false,
		-- +0x2ec..+0x308: cooldowns the tracker's own update counts down (exe+862d10)
		cooldowns = table.create(8, 0),
	}, Tracker) :: any
end

function Tracker.clone(self: Tracker): Tracker
	local c = table.clone(self)
	c.ring_time = table.clone(self.ring_time)
	c.ring_value = table.clone(self.ring_value)
	c.pivot_factor = table.clone(self.pivot_factor)
	c.cooldowns = table.clone(self.cooldowns)
	-- params is replaced wholesale every update, never mutated in place
	return setmetatable(c, Tracker) :: any
end

-- What the tracker reads off the mover each frame
export type MoverView = { velocity: V3, airborne: boolean, height_above_ground: number }

-- exe+85f810 / the loop in exe+8630f0: the first entry above `momentum` and the one before it
local function decay_at(list: { any }, momentum: number, field: string): number
	if #list == 0 then
		return 1
	end
	local prev = list[1]
	for i = 2, #list do
		local e = list[i]
		if momentum < e.momentum_value then
			local t = remap(momentum, prev.momentum_value, e.momentum_value)
			return lerp(prev[field], e[field], t)
		end
		prev = e
	end
	return prev[field]
end
Tracker.decay_at = decay_at

-- exe+85ed20, 85e5e0, 85e330, 85ef50 and the inline turn block: every float field from a to b by t
local function lerp_fields(schema: any, a: any, b: any, t: number): any
	local out = {}
	for _, f in schema do
		local name, kind = f[1], f[2]
		if kind == "f" then
			out[name] = lerp(a[name], b[name], t)
		elseif kind == "t" then
			out[name] = lerp_fields(f[3], a[name], b[name], t)
		else
			error("lerp_setup: unexpected field " .. name)
		end
	end
	return out
end
local function lerp_setup(a: any, b: any, t: number): any
	return {
		search = lerp_fields(Config.SearchParams, a.search_params, b.search_params, t),
		motion = lerp_fields(Config.MotionParams, a.motion_params, b.motion_params, t),
		release = lerp_fields(Config.ReleaseParams, a.release_params, b.release_params, t),
	}
end

-- exe+85f580, once a frame before the states run
function Tracker.update(self: Tracker, cfg: Config.Configs, mover: MoverView, dt: number)
	-- exe+862d10 (the component's update, which tools/native_oracle doesn't run): the cooldowns
	for i = 1, 8 do
		self.cooldowns[i] = fmax(__F(self.cooldowns[i] - dt), 0)
	end
	self:update_momentum(cfg, dt)
	self:blend_setups(cfg, mover)
	-- fall gravity and terminal velocity (no mission overrides)
	local t = cfg.traversal
	self.fall_gravity = t.standard_fall_gravity
	local target = t.standard_fall_terminal_velocity
	local max = t.standard_fall_terminal_velocity_max
	local vy = mover.velocity.y
	if max > 0 and vy < -1 then
		target = fmin(fmax(self.terminal, target), max)
		if vy < __F(0.0099999997764825821 - self.terminal) then
			target = approach(self.terminal, max, t.standard_fall_term_vel_accel, dt)
		end
	end
	if vy <= -target then
		self.terminal = fmin(self.terminal, math.abs(vy))
		self.terminal = approach(self.terminal, target, 30, dt)
	else
		self.terminal = target
	end
end

-- exe+8630f0
function Tracker.update_momentum(self: Tracker, cfg: Config.Configs, dt: number)
	local mc = cfg.swing.momentum_config
	local held = 0
	for i = 1, 32 do
		local t = fmax(__F(self.ring_time[i] - dt), 0)
		self.ring_time[i] = t
		if t > 9.9999997473787516e-05 and self.ring_value[i] > held then
			held = self.ring_value[i]
		end
	end
	local max = fmax(mc.max_momentum, 0)
	self.momentum = fmin(self.momentum, max)
	local rate = decay_at(mc.decay_data_air, self.momentum, "decay_rate")
	if held < self.momentum and not self.hold then
		self.momentum = fmax(__F(self.momentum - __F(rate * dt)), 0)
	end
	local frac = if max > 0 then clamp(__F(self.momentum / max), 0, 1) else 0
	self.momentum_frac = approach(self.momentum_frac, frac, 3, dt)
	-- the momentum stage
	local stages = mc.momentum_stages
	local default = {
		momentum_value = 0,
		terminal_velocity_horz_floor = 0,
		skill_offset_for_horz_floor = { 0, 0, 0 },
		gravity_scale = 1,
		line_length_tweak = 0,
		line_angle_tweak = 0,
		true_pivot_factor_start = 1,
		true_pivot_factor_trough = 1,
		true_pivot_factor_final = 1,
		turn_speed_scale = 1,
	}
	local prev, nxt = default, default
	local t = 0
	for _, s in stages do
		nxt = s
		if self.momentum < s.momentum_value then
			t = remap(self.momentum, prev.momentum_value, s.momentum_value)
			break
		end
		prev = s
		t = 1
	end
	local function skill(s: any): number
		if self.skill_level > 0 then
			local i = math.min(self.skill_level, 3)
			return s.skill_offset_for_horz_floor[i] or 0
		end
		return 0
	end
	self.stage_momentum = self.momentum
	self.terminal_floor =
		lerp(__F(prev.terminal_velocity_horz_floor + skill(prev)), __F(nxt.terminal_velocity_horz_floor + skill(nxt)), t)
	self.gravity_scale = lerp(prev.gravity_scale, nxt.gravity_scale, t)
	self.line_length_tweak = lerp(prev.line_length_tweak, nxt.line_length_tweak, t)
	self.line_angle_tweak = lerp(prev.line_angle_tweak, nxt.line_angle_tweak, t)
	self.pivot_factor = {
		lerp(prev.true_pivot_factor_start, nxt.true_pivot_factor_start, t),
		lerp(prev.true_pivot_factor_trough, nxt.true_pivot_factor_trough, t),
		lerp(prev.true_pivot_factor_final, nxt.true_pivot_factor_final, t),
	}
	self.turn_speed_scale = lerp(prev.turn_speed_scale, nxt.turn_speed_scale, t)
end

-- exe+864660: the slow setup at no speed or momentum, the standard one from 30 m/s or momentum 1; releases near the
-- ground (under 8 m) use the ground setup's release parameters
function Tracker.blend_setups(self: Tracker, cfg: Config.Configs, mover: MoverView)
	self.speed_blend = if mover.airborne then self.speed_blend else 0
	local speed = mover.velocity:flat_len()
	self.speed_blend = fmax(self.speed_blend, remap(speed, 8, 30))
	self.momentum = fmax(self.momentum, self.speed_blend)
	local f = fmin(self.momentum, 1)
	self.params = lerp_setup(cfg.setup_slow, cfg.setup_standard, f)
	if mover.height_above_ground < 8 then
		self.params.release = cfg.setup_ground.release_params
	end
end

-- exe+85f220: momentum gained (while swinging), up to `cap`; recorded in the ring for its hold time
function Tracker.add_momentum(self: Tracker, cfg: Config.Configs, amount: number, cap: number, advance: boolean)
	if amount < 9.9999997473787516e-05 then
		return
	end
	if self.momentum < cap then
		self.momentum = fmin(fmin(__F(self.momentum + amount), cap), cfg.swing.momentum_config.max_momentum)
	end
	self.ring_value[__F(self.ring_next + 1)] = cap
	self.ring_time[__F(self.ring_next + 1)] =
		decay_at(cfg.swing.momentum_config.decay_data_air, self.momentum, "decay_delay")
	if advance then
		self.ring_next = __F((__F(self.ring_next + 1)) % 32)
	end
end

-- exe+85f2e0: momentum capped at `value` and held for its delay
function Tracker.hold_momentum(self: Tracker, cfg: Config.Configs, value: number)
	self.momentum = fmin(self.momentum, value)
	local delay = decay_at(cfg.swing.momentum_config.decay_data_air, self.momentum, "decay_delay")
	self.ring_time[__F(self.ring_next + 1)] = delay
	self.ring_value[__F(self.ring_next + 1)] = value
	self.ring_next = __F((__F(self.ring_next + 1)) % 32)
end

return Tracker
