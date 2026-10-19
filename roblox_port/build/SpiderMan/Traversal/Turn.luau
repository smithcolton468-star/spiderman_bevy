--!strict
local __F = function(x: any): any if type(x) == "number" then return vector.create(x, 0, 0).x end return x end -- f32ify: f32 rounding (vector arithmetic rounds in its own metamethods)
-- Port of crates/sm_traversal/src/turn.rs: how Spider-Man's mover turns him toward the facing his state asks for
-- (MoverStandard, exe+1fc0800 -> exe+1c46d50 -> exe+1c46be0). The constants are set by each state on entry
-- (exe+1fc3540). Ported from ArkWeb's turn.h, which predicts the recorded turns to 0.03 degrees a frame.
local Math = require("./Math")
local V3 = Math.V3
type V3 = Math.V3

local Turn = {}

-- (gain, damping, maximum rate in rad/s)
export type TurnConstants = { number }
-- the swing (its processor, exe+ab2af0): 240 degrees per second at most
Turn.SWING = { -1.4199999570846558, -44, 4.1887898445129395 }
-- the swing jump (exe+a7d260, jump type 0x11)
Turn.SWING_JUMP = { -1.2000000476837158, -33, 7.8539800643920898 }
-- other jumps and the fall's default (exe+a6f930)
Turn.FALL = { -1.1799999475479126, -18, 10.472000122070312 }

-- exe+1fc34b0: the facing a state asks for, if usable
function Turn.want_facing(f: V3): V3?
	if not f:is_finite() or not (math.abs(f.x) > 0.0010000000474974513 or math.abs(f.y) > 0.0010000000474974513 or math.abs(f.z) > 0.0010000000474974513) then
		return nil
	end
	local n = f:norm()
	if n:max_abs() > 0 then
		return n
	end
	return nil
end

-- One frame of the turn: `fwd` turned about `up` toward `want` (both taken flat), `v` the angular velocity carried
-- between frames. Returns the new forward and the new v.
function Turn.step(fwd: V3, up: V3, want: V3, v: number, k: TurnConstants, snap: boolean, dt: number): (V3, number)
	local function flat(a: V3): V3
		return __F(a - __F(up * a:dot(up)))
	end
	local w = flat(want)
	if w == V3.ZERO then
		w = V3.new(w.x, 1, w.z)
	end
	w = w:norm()
	local f = flat(fwd):norm()
	local angle = Math.acos(Math.clamp(f:dot(w), -1, 1))
	if snap or angle <= 0.004999999888241291 then
		return w, 0
	end
	local axis = f:cross(w):norm()
	local sign = if axis:dot(up) >= 0 then 1 else -1
	local target = Math.fmin(__F(sign * angle), 3.1101799011230469)
	local d = Math.wrap_pi(target)
	local x, nv = Math.spring(0, d, v, k[1], k[2], k[3], dt)
	local s = Math.wrap_pi(x)
	return Math.rotate(fwd, up:norm(), s), nv
end

return Turn
