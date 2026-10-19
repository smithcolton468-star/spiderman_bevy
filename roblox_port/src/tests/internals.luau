-- Debug tracer (the twin of a throwaway Rust program): replays one scenario like Replay.run and prints the swing /
-- tracker internals each frame in the same format, to diff the port against the Rust.
-- Run: luau internals.luau -a <pack dir> <scenario name>
local Pack = require("./harness/Pack")
local Config = require("../SpiderMan/Traversal/Config")
local Replay = require("../SpiderMan/Traversal/Replay")
local Math = require("../SpiderMan/Traversal/Math")
local Sim = require("../SpiderMan/Traversal/Sim")
local Swing = require("../SpiderMan/Traversal/Swing")
local V3 = Math.V3
local f32 = Math.f32
local args = { ... }
local pack = Pack.open(args[1])
local cfg = Config.embedded(function(name) return pack:json("Tuning/" .. name) end)
local sc = Replay.parse(pack:text("OracleFixtures/" .. args[2] .. "/Scenario"))
local function v(a) return string.format("%.9e %.9e %.9e", a.x, a.y, a.z) end
local function e(x) return string.format("%.9e", x) end
local dt = sc.dt
local yaw = sc.yaw * 0.01745329
local tr = Sim.Traversal.new(cfg, sc.pos, sc.vel, V3.new(math.sin(yaw), 0, math.cos(yaw)))
tr.air_time = -dt
tr.tracker.momentum = sc.momentum
tr.tracker:update(cfg, { velocity = sc.vel, airborne = true, height_above_ground = 50 }, dt)
local cam_yaw = if sc.cam_follow then Math.atan2(sc.vel.x, sc.vel.z) else sc.cam_yaw * 0.01745329
local EPS6 = f32(1e-6)
local function at(keys, t)
	local last
	for _, k in keys do if k.t <= f32(t + EPS6) then last = k end end
	return last
end
local function camera(yaw, pitch_deg, pos)
	local p = pitch_deg * 0.01745329
	local f = V3.new(math.sin(yaw) * math.cos(p), math.sin(p), math.cos(yaw) * math.cos(p))
	local up = V3.new(-math.sin(yaw) * math.sin(p), math.cos(p), -math.cos(yaw) * math.sin(p))
	return { side = up:cross(f), up = up, fwd = f, pos = pos - f * 5.5 + V3.new(0, 1, 0) }
end
local ns, ne = 1, 1
for f = 0, sc.frames - 1 do
	local t = f32(f * dt)
	local sk = at(sc.sticks, t)
	local rk = at(sc.r2, t)
	local jump = false
	for _, j in sc.jumps do if t >= f32(j - EPS6) and t < f32(j + f32(0.05)) then jump = true end end
	if sc.cam_follow then
		local vv = tr.mover_vel
		if vv.x * vv.x + vv.z * vv.z > 1 then
			local d = Math.wrap_pi(Math.atan2(vv.x, vv.z) - cam_yaw)
			cam_yaw = Math.wrap_pi(cam_yaw + d * (1 - math.exp(-sc.cam_rate * dt)))
		end
	end
	local si = Sim.StepInput({ input = { stick = sk and { sk.x, sk.y } or { 0, 0 }, swing_button = rk and rk.x or 1, jump_pressed = jump, jump_held = false, look = 0 }, cam = camera(cam_yaw, sc.cam_pitch, tr.pos), drift = sc.drift, height = 50 })
	local en, sw = sc.enters[ne], sc.swings[ns]
	if en and t >= f32(en[1] - EPS6) then si.air = { en[3], en[2] }; ne += 1
	elseif sw and t >= f32(sw[1] - EPS6) and tr.mode ~= "Swing" then si.swing = Swing.SwingEntry(sw[2], sw[3]); ns += 1 end
	local o = tr:step(si, dt)
	local disp = if tr.mode == "Off" then V3.new(tr.mover_vel.x * dt, tr.mover_vel.y * dt - 13 * dt * dt, tr.mover_vel.z * dt) else o.displacement
	local s = tr.swing
	print(string.format("F %d mode %s camyaw %s", f, tr.mode, e(cam_yaw)))
	print(string.format("  pos %s disp %s mvel %s", v(tr.pos), v(disp), v(tr.mover_vel)))
	print(string.format("  s.vel %s s.dir %s s.anchor %s", v(s.vel), v(s.dir), v(s.anchor)))
	print(string.format("  s.si %s s.term %s s.gb %s s.pf %s s.turnv %s s.ramp %s s.agree %s s.twist %s s.yawrate %s s.sink %s s.floor %s %s %s %s push %s",
		e(s.speed_input), e(s.terminal), e(s.gravity_blend), e(s.pivot_factor), e(s.turn_v), e(s.turn_ramp), e(s.input_agree), e(s.twist), e(s.yaw_rate), e(s.sink), e(s.floor_y), e(s.floor_vel), e(s.floor_acc), e(s.floor_rate), v(s.push)))
	print(string.format("  t.mom %s t.term %s t.sb %s fwd %s turnv %s dirspringv %s dirtime %s boost %s %s", e(tr.tracker.momentum), e(tr.tracker.terminal), e(tr.tracker.speed_blend), v(tr.fwd), e(tr.turn_v), e(s.dir_spring_v), e(s.dir_time), tostring(s.boost_on), e(s.boost_accel)))
	tr:moved(tr.pos + disp, true, dt)
end
