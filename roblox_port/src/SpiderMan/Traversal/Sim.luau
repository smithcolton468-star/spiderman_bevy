--!strict
-- Port of crates/sm_traversal/src/sim.rs: one hero's traversal, frame by frame, the way the game runs it: the
-- tracker's update, then the active state's transition check, then its update, then the mover's move and turn. The
-- host supplies the input, the camera and the swings to start (the swing point search is its own), moves the body with
-- the displacement (its collisions), and reports where he ended up.
local Math = require("./Math")
local Config = require("./Config")
local Tracker = require("./Tracker")
local Swing = require("./Swing")
local Air = require("./Air")
local Turn = require("./Turn")
local V3 = Math.V3
type V3 = Math.V3
type Rows = Math.Rows
type Configs = Config.Configs

local Sim = {}

Sim.Mode = { Swing = "Swing", SwingJump = "SwingJump", Fall = "Fall", Off = "Off" }

-- What the host gives a frame
export type StepInput = {
	input: Swing.FrameInput,
	-- the camera's rows (side points left)
	cam: Rows,
	-- a swing to start this frame (the host's swing point search)
	swing: Swing.SwingEntry?,
	-- the jump state (or the fall, `[2]`) to enter this frame with this data, ending the state he is in
	air: { any }?,
	-- the swing processor's pivot drift (exe+ab8410), on in the game
	drift: boolean,
	-- the mover's height above the ground (the tracker's ground release parameters below 8 m; a dive needs 16 m)
	height: number,
	-- the animation's state for the swing jump's hand-over to the fall (nil: while rising)
	anim_playing: boolean?,
	-- the dive button's event and the dive input (0..1, the fall processor's +0x394)
	dive_button: boolean,
	dive_input: number,
}
function Sim.StepInput(t: { [string]: any }?): StepInput
	local si: any = {
		input = Swing.FrameInput(),
		cam = Math.Rows.default(),
		swing = nil,
		air = nil,
		drift = false,
		height = 0,
		anim_playing = nil,
		dive_button = false,
		dive_input = 0,
	}
	if t then
		for k, v in t do
			si[k] = v
		end
	end
	return si
end

-- What a frame hands the host
export type StepOutput = {
	-- this frame's move (zero when off)
	displacement: V3,
	-- the facing the state asks for, if it asked
	facing: V3?,
	snap: boolean,
	-- the swing let go this frame
	released: Swing.SwingRelease?,
	-- the swing jump handed over to the fall this frame
	fell: boolean,
}

local Traversal = {}
Traversal.__index = Traversal
Sim.Traversal = Traversal
export type Traversal = any

function Traversal.new(cfg: Configs, pos: V3, vel: V3, fwd: V3): Traversal
	-- the game's tracker has run before anything reads it: its fall gravity and terminal velocity are set
	local tracker = Tracker.new()
	tracker:update(cfg, { velocity = vel, airborne = true, height_above_ground = 50 }, 0)
	return setmetatable({
		cfg = cfg,
		tracker = tracker,
		swing = Swing.SwingLocal.new(),
		processor = Swing.Processor.new(),
		jump = Air.AirLocal.new(false),
		fall = Air.AirLocal.new(true),
		shared = Air.AirShared(),
		mode = "Off",
		-- the game clock and this traversal's frame count
		time = 100,
		frame = 0,
		entered_at = 0,
		-- his position, forward (flat) and the mover's velocity (its last move over the frame's time)
		pos = pos,
		fwd = fwd:flat_norm(),
		mover_vel = vel,
		-- the turn's angular velocity (rad/s)
		turn_v = 0,
		-- seconds in the air (negative), the mover's +0x6b4
		air_time = 0,
		-- the facing asked for this frame, kept for `moved`
		pending = nil,
	}, Traversal)
end

-- (the Rust derives Clone; the presentation's snapshots clone the hero)
function Traversal.clone(self: Traversal): Traversal
	local c = table.clone(self)
	c.tracker = self.tracker:clone()
	c.swing = self.swing:clone()
	c.processor = table.clone(self.processor)
	c.jump = self.jump:clone()
	c.fall = self.fall:clone()
	c.shared = table.clone(self.shared)
	return setmetatable(c, Traversal)
end

function Traversal.hero_rows(self: Traversal): Rows
	return Math.Rows.facing(self.fwd, self.pos)
end

-- The turn constants of the active state (set on its entry, exe+1fc3540; the jump's by its kind, exe+a7d260)
function Traversal.turn_constants(self: Traversal): Turn.TurnConstants
	if self.mode == "Swing" then
		return Turn.SWING
	elseif self.mode == "SwingJump" and self.jump.kind == Air.KIND_SWING_JUMP then
		return Turn.SWING_JUMP
	end
	return Turn.FALL
end

function Traversal.env(self: Traversal, si: StepInput, dt: number): Swing.Env
	return { time = self.time, dt = dt, hero = self:hero_rows(), cam = si.cam, mover_vel = self.mover_vel, input = si.input }
end

-- An Env with the Rust's `..Default::default()` for what isn't given
local function env_of(self: Traversal, dt: number): Swing.Env
	local e = Swing.Env()
	e.time = self.time
	e.dt = dt
	e.hero = self:hero_rows()
	e.mover_vel = self.mover_vel
	return e
end

-- Leave the traversal states (he landed, or the host takes over)
function Traversal.stop(self: Traversal)
	if self.mode == "Fall" then
		self.fall:exit(self.tracker)
	elseif self.mode == "SwingJump" then
		self.jump:exit(self.tracker)
	end
	self.mode = "Off"
end

-- Let go of the swing without the release's jump (the host's own move takes over, e.g. a dive): the swing's exit as a
-- plain release
function Traversal.cancel_swing(self: Traversal, dt: number)
	if self.mode == "Swing" then
		self.swing:exit(self.cfg, self.tracker, env_of(self, dt), false)
	end
	self.mode = "Off"
end

-- The fall without a swing before it (walking off a ledge): the fall's kind with no second kind
function Traversal.start_fall(self: Traversal, dt: number)
	local v = self.mover_vel
	local e = Air.AirEntry({
		dir = v:flat_norm(),
		vy = v.y,
		h_speed = v:flat_len(),
		gravity = self.tracker.fall_gravity,
		gravity_after = self.tracker.fall_gravity,
		max_height = self.pos.y,
		kind = Air.KIND_FALL,
	})
	self.fall = Air.AirLocal.new(true)
	self.fall:enter(e, self.tracker, env_of(self, dt), self.shared)
	self.mode = "Fall"
	self.entered_at = self.frame
end

-- A frame: the tracker, the transitions, the update. Move the body by the displacement, then call `moved`.
function Traversal.step(self: Traversal, si: StepInput, dt: number): StepOutput
	self.time = Math.f64_add(self.time, dt)
	local out: StepOutput = { displacement = V3.ZERO, facing = nil, snap = false, released = nil, fell = false }
	local airborne = self.air_time < 0
	self.tracker:update(self.cfg, { velocity = self.mover_vel, airborne = airborne, height_above_ground = si.height }, dt)
	local env = self:env(si, dt)
	local air_in: Air.AirInput = {
		anim_playing = si.anim_playing,
		anim_phase = 0,
		dive_input = si.dive_input,
		dive_button = si.dive_button,
		height = si.height,
		air_time = self.air_time,
	}
	-- transitions
	if si.air ~= nil then
		local e, fall = si.air[1], si.air[2]
		if self.mode == "Swing" then
			self.swing:exit(self.cfg, self.tracker, env, false)
		elseif self.mode == "SwingJump" then
			self.jump:exit(self.tracker)
		elseif self.mode == "Fall" then
			self.fall:exit(self.tracker)
		end
		-- a requested state starts from its driver's init (exe+a85f70), as on a new activation
		if fall then
			self.fall = Air.AirLocal.new(true)
			self.fall:enter(e, self.tracker, env, self.shared)
			self.mode = "Fall"
		else
			self.jump = Air.AirLocal.new(false)
			self.jump:enter(e, self.tracker, env, self.shared)
			self.mode = "SwingJump"
		end
		self.entered_at = self.frame
	elseif si.swing ~= nil and self.mode ~= "Swing" then
		if self.mode == "SwingJump" then
			self.jump:exit(self.tracker)
		elseif self.mode == "Fall" then
			self.fall:exit(self.tracker)
		end
		local e = table.clone(si.swing :: any)
		if self.tracker.forward_action_time < self.cfg.swing.transition_data.forward_action_lookback_time then
			e.flags = bit32.bor(e.flags, 0x100)
		end
		self.swing:enter(self.cfg, self.tracker, self.processor, e, env)
		self.mode = "Swing"
		self.entered_at = self.frame
	elseif self.mode == "Swing" and self.frame > self.entered_at then
		local r = self.swing:check(self.cfg, self.tracker, env)
		if r then
			self.swing:exit(self.cfg, self.tracker, env, r.jumped)
			local e = Air.swing_jump(r, self.tracker)
			self.jump:enter(e, self.tracker, env, self.shared)
			self.mode = "SwingJump"
			self.entered_at = self.frame
			out.released = r
		end
	elseif self.mode == "SwingJump" and self.frame > self.entered_at then
		local e = self.jump:check(self.cfg, env, air_in)
		if e then
			self.jump:exit(self.tracker)
			self.fall:enter(e, self.tracker, env, self.shared)
			self.mode = "Fall"
			self.entered_at = self.frame
			out.fell = true
		end
	end
	-- the update
	if self.mode == "Swing" then
		if si.drift then
			Swing.Processor.drift(self.processor, self.pos, self.swing:age(env))
		end
		local o = self.swing:update(self.cfg, self.tracker, self.processor, env)
		self.swing:read_release_event(env)
		out.displacement = o.displacement
		out.facing = o.facing
		out.snap = o.snap
	elseif self.mode == "SwingJump" or self.mode == "Fall" then
		local st = if self.mode == "SwingJump" then self.jump else self.fall
		local o = st:update(self.cfg, self.tracker, env, air_in, self.shared)
		out.displacement = o.displacement
		out.facing = o.facing
		out.snap = o.snap
	end
	self.pending = if out.facing then { out.facing, out.snap } else nil
	return out
end

-- Where the body ended up after the host moved it (`airborne`: not standing on anything): the mover's velocity, its
-- air time, and the turn toward the facing the state asked for
function Traversal.moved(self: Traversal, new_pos: V3, airborne: boolean, dt: number)
	if dt > 0 then
		self.mover_vel = (new_pos - self.pos) * (1 / dt)
	end
	self.pos = new_pos
	self.air_time = if airborne then Math.fmin(self.air_time, 0) - dt else Math.fmax(self.air_time, 0) + dt
	local p = self.pending
	self.pending = nil
	if p then
		local want = Turn.want_facing(p[1])
		if want then
			local k = self:turn_constants()
			self.fwd, self.turn_v = Turn.step(self.fwd, V3.UP, want, self.turn_v, k, p[2], dt)
		end
	end
	self.frame += 1
end

return Sim
