--!strict
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
Turn.SWING = { -1.42, -44.0, 4.18879 }
-- the swing jump (exe+a7d260, jump type 0x11)
Turn.SWING_JUMP = { -1.2, -33.0, 7.85398 }
-- other jumps and the fall's default (exe+a6f930)
Turn.FALL = { -1.18, -18.0, 10.472 }

-- exe+1fc34b0: the facing a state asks for, if usable
function Turn.want_facing(f: V3): V3?
	if not f:is_finite() or not (math.abs(f.x) > 0.001 or math.abs(f.y) > 0.001 or math.abs(f.z) > 0.001) then
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
		return a - up * a:dot(up)
	end
	local w = flat(want)
	if w == V3.ZERO then
		w = V3.new(w.x, 1, w.z)
	end
	w = w:norm()
	local f = flat(fwd):norm()
	local angle = Math.acos(Math.clamp(f:dot(w), -1, 1))
	if snap or angle <= 0.005 then
		return w, 0
	end
	local axis = f:cross(w):norm()
	local sign = if axis:dot(up) >= 0 then 1 else -1
	local target = Math.fmin(sign * angle, 3.11018)
	local d = Math.wrap_pi(target)
	local x, nv = Math.spring(0, d, v, k[1], k[2], k[3], dt)
	local s = Math.wrap_pi(x)
	return Math.rotate(fwd, up:norm(), s), nv
end

return Turn
