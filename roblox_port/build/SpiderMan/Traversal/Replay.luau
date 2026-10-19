--!strict
local __F = function(x: any): any if type(x) == "number" then return vector.create(x, 0, 0).x end return x end -- f32ify: f32 rounding (vector arithmetic rounds in its own metamethods)
-- Port of crates/sm_traversal/src/replay.rs: tools/native_oracle's scenarios run through the port, closed loop
-- (Sim.Traversal from the starting conditions alone), the way the oracle runs them through the game's code: the same
-- inputs, the same stand-in camera and the same scripted swings.
--
-- The scenario's numbers are parsed as f32 and its times computed in f32 (`f as f32 * dt`, `t + 1e-6`), as the Rust
-- does, so the scripted inputs switch on the same frames.
local Math = require("./Math")
local Sim = require("./Sim")
local Swing = require("./Swing")
local Air = require("./Air")
local V3 = Math.V3
type V3 = Math.V3

local f32 = Math.f32
local new = V3.new

local Replay = {}

export type Key = { t: number, x: number, y: number }
export type Scenario = {
	dt: number,
	frames: number,
	momentum: number,
	pos: V3,
	vel: V3,
	yaw: number,
	-- (time, anchor, attach)
	swings: { { any } },
	-- (time, into the fall, the entry): a launch or a fall entered directly
	enters: { { any } },
	sticks: { Key },
	r2: { Key },
	jumps: { number },
	cam_follow: boolean,
	cam_yaw: number,
	cam_pitch: number,
	cam_rate: number,
	drift: boolean,
}

-- A scenario file (the oracle's format: see tools/native_oracle/oracle.cpp)
function Replay.parse(text: string): Scenario
	local s: Scenario = {
		dt = f32(__F(1 / 60)),
		frames = 300,
		momentum = 0,
		pos = new(0, 40, 0),
		vel = new(0, 0, 20),
		yaw = 0,
		swings = {},
		enters = {},
		sticks = {},
		r2 = {},
		jumps = {},
		cam_follow = true,
		cam_yaw = 0,
		cam_pitch = -12,
		cam_rate = 3,
		drift = true,
	}
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		line = string.match(line, "^([^#]*)") or ""
		local w = {}
		for word in string.gmatch(line, "%S+") do
			table.insert(w, word)
		end
		if #w == 0 then
			continue
		end
		local function n(i: number): number
			local v = tonumber(w[__F(i + 1)])
			assert(v, "a number at " .. line)
			return f32(v)
		end
		local k = w[1]
		if k == "dt" then
			s.dt = n(1)
		elseif k == "frames" then
			s.frames = math.floor(n(1))
		elseif k == "momentum" then
			s.momentum = n(1)
		elseif k == "pos" then
			s.pos = new(n(1), n(2), n(3))
		elseif k == "vel" then
			s.vel = new(n(1), n(2), n(3))
		elseif k == "yaw" then
			s.yaw = n(1)
		elseif k == "swing" then
			table.insert(s.swings, { n(1), new(n(2), n(3), n(4)), new(n(5), n(6), n(7)) })
		elseif k == "enter" then
			local e = Air.AirEntry({
				dir = new(n(5), 0, n(6)):norm(),
				h_speed = n(7),
				vy = n(8),
				gravity = n(9),
				gravity_after = n(10),
				input = n(11),
				kind = __F(math.floor(n(3)) % 256),
				kind2 = __F(math.floor(n(4)) % 256),
			})
			table.insert(s.enters, { n(1), w[3] == "fall", e })
		elseif k == "stick" then
			table.insert(s.sticks, { t = n(1), x = n(2), y = n(3) })
		elseif k == "r2" then
			table.insert(s.r2, { t = n(1), x = n(2), y = 0 })
		elseif k == "jump" then
			table.insert(s.jumps, n(1))
		elseif k == "cam" then
			s.cam_follow = w[2] ~= "fixed"
			if s.cam_follow then
				s.cam_rate = n(2)
			else
				s.cam_yaw = n(2)
			end
			s.cam_pitch = n(3)
		elseif k == "drift" then
			s.drift = n(1) ~= 0
		else
			error("unknown scenario key " .. k)
		end
	end
	return s
end

local EPS6 = f32(9.9999999747524271e-07)

local function at(keys: { Key }, t: number): Key?
	local last = nil
	local lim = f32(__F(t + EPS6))
	for _, k in keys do
		if k.t <= lim then
			last = k
		end
	end
	return last
end

-- The oracle's camera: 5.5 m behind him and 1 m up, at a fixed pitch
local function camera(yaw: number, pitch_deg: number, pos: V3): Math.Rows
	local p = __F(pitch_deg * 0.017453290522098541)
	local sin, cos = math.sin, math.cos
	local f = new(__F(__F(sin(yaw)) * __F(cos(p))), __F(sin(p)), __F(__F(cos(yaw)) * __F(cos(p))))
	local up = new(__F(-__F(sin(yaw)) * __F(sin(p))), __F(cos(p)), __F(-__F(cos(yaw)) * __F(sin(p))))
	return { side = up:cross(f), up = up, fwd = f, pos = __F(__F(pos - __F(f * 5.5)) + new(0, 1, 0)) }
end

-- A frame after the move and the turn: where he is, his forward and the state (0 swing, 1 swing jump, 2 fall, 3 none)
export type Sample = { pos: V3, fwd: V3, mode: number }

local MODE_INDEX = { Swing = 0, SwingJump = 1, Fall = 2, Off = 3 }

function Replay.run(sc: Scenario, cfg: any): { Sample }
	local dt = sc.dt
	local yaw = __F(sc.yaw * 0.017453290522098541)
	local tr = Sim.Traversal.new(cfg, sc.pos, sc.vel, new(__F(math.sin(yaw)), 0, __F(math.cos(yaw))))
	tr.air_time = -dt
	tr.tracker.momentum = sc.momentum
	tr.tracker:update(cfg, { velocity = sc.vel, airborne = true, height_above_ground = 50 }, dt)
	local cam_yaw = if sc.cam_follow then Math.atan2(sc.vel.x, sc.vel.z) else __F(sc.cam_yaw * 0.017453290522098541)
	local next_swing, next_enter = 1, 1
	local out = table.create(sc.frames)
	for f = 0, __F(sc.frames - 1) do
		local t = f32(__F(f * dt))
		local sk = at(sc.sticks, t)
		local stick = if sk then { sk.x, sk.y } else { 0, 0 }
		local rk = at(sc.r2, t)
		local r2 = if rk then rk.x else 1
		local jump = false
		for _, j in sc.jumps do
			if t >= f32(__F(j - EPS6)) and t < f32(__F(j + f32(0.05000000074505806))) then
				jump = true
			end
		end
		if sc.cam_follow then
			local v = tr.mover_vel
			if __F(__F(v.x * v.x) + __F(v.z * v.z)) > 1 then
				local d = Math.wrap_pi(__F(Math.atan2(v.x, v.z) - cam_yaw))
				cam_yaw = Math.wrap_pi(__F(cam_yaw + __F(d * (__F(1 - __F(math.exp(__F(-sc.cam_rate * dt))))))))
			end
		end
		local si = Sim.StepInput({
			input = { stick = stick, swing_button = r2, jump_pressed = jump, jump_held = false, look = 0 },
			cam = camera(cam_yaw, sc.cam_pitch, tr.pos),
			drift = sc.drift,
			height = 50,
		})
		local en, sw = sc.enters[next_enter], sc.swings[next_swing]
		if en and t >= f32(__F(en[1] - EPS6)) then
			si.air = { en[3], en[2] }
			next_enter = __F(next_enter + (1))
		elseif sw and t >= f32(__F(sw[1] - EPS6)) and tr.mode ~= "Swing" then
			si.swing = Swing.SwingEntry(sw[2], sw[3])
			next_swing = __F(next_swing + (1))
		end
		local o = tr:step(si, dt)
		-- before the first swing the oracle moves him by plain gravity
		local disp = if tr.mode == "Off"
			then new(__F(tr.mover_vel.x * dt), __F(__F(tr.mover_vel.y * dt) - __F(__F(13 * dt) * dt)), __F(tr.mover_vel.z * dt))
			else o.displacement
		tr:moved(__F(tr.pos + disp), true, dt)
		out[__F(f + 1)] = { pos = tr.pos, fwd = tr.fwd, mode = MODE_INDEX[tr.mode] }
	end
	return out
end

return Replay
