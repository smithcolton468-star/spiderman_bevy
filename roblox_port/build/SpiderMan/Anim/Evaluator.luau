--!strict
--!native
-- The suit's skeleton posed the way Bevy 0.19.1 poses it from the AnimationPlayer that src/main.rs `animate` drives:
--
-- - Each active clip has a seek time and a weight (speed 0, repeat). `ActiveAnimation::update` still runs at speed 0:
--   a seek at or past the clip's duration wraps to `seek % duration` (bevy_animation lib.rs).
-- - A clip's curve is sampled as bevy_math's UnevenCore does: before the first key the first, after the last the
--   last, exactly on a key that key (a binary search), else between two keys at s = (t - t0) / (t1 - t0); LINEAR
--   lerps translation and scale (glam `a * (1 - s) + b * s`) and slerps rotation (glam's Quat::slerp, below); STEP
--   holds the earlier key; one key is a constant.
-- - The clips blend per property in ascending node index, which is ascending clip name (main.rs builds the graph
--   from the names sorted): a zero-weight clip is skipped; the first sets the value and weight; each next one adds its
--   weight and interpolates acc toward its value by weight / total (BasicAnimationCurveEvaluator::combine).
-- - Forward kinematics as transform propagation does it: a joint's world matrix is its parent's times its local
--   T * R * S, so positions carry every scale above them. The world rotation is the product of the local rotations
--   with the scales left out (what a Roblox bone can show).
--
-- Positions are in metres in the armature's space (the armature node `SpiderMan` has no transform).

local Evaluator = {}
Evaluator.__index = Evaluator

local sqrt, sin, abs = math.sqrt, math.sin, math.abs

-- f32::EPSILON and glam's slerp threshold, as f32
local DOT_THRESHOLD = 1.0 - 1.1920928955078125e-07

-- glam's acos_approx (math.rs, from DirectXMath XMScalarAcos), which Quat::slerp uses
local function acos_approx(v: number): number
	local nonnegative = v >= 0
	local x = abs(v)
	local omx = 1 - x
	if omx < 0 then
		omx = 0
	end
	local root = sqrt(omx)
	local result = ((((((-0.0012624911 * x + 0.00667009) * x - 0.017088126) * x + 0.03089188) * x - 0.050174303) * x + 0.08897899) * x - 0.2145988) * x
		+ 1.5707963
	result *= root
	if nonnegative then
		return result
	end
	return 3.1415927 - result
end
Evaluator.acos_approx = acos_approx

-- glam Quat::slerp (sse2): the short way; lerp-and-normalise above 1 - f32::EPSILON; else sin weights
local function slerp(ax: number, ay: number, az: number, aw: number, bx: number, by: number, bz: number, bw: number, s: number): (number, number, number, number)
	local dot = ax * bx + ay * by + az * bz + aw * bw
	if dot < 0 then
		bx, by, bz, bw = -bx, -by, -bz, -bw
		dot = -dot
	end
	if dot > DOT_THRESHOLD then
		local x = ax * (1 - s) + bx * s
		local y = ay * (1 - s) + by * s
		local z = az * (1 - s) + bz * s
		local w = aw * (1 - s) + bw * s
		local r = 1 / sqrt(x * x + y * y + z * z + w * w)
		return x * r, y * r, z * r, w * r
	end
	local theta = acos_approx(dot)
	local s1 = sin(theta * (1 - s))
	local s2 = sin(theta * s)
	local st = sin(theta)
	return (ax * s1 + bx * s2) / st, (ay * s1 + by * s2) / st, (az * s1 + bz * s2) / st, (aw * s1 + bw * s2) / st
end
Evaluator.slerp = slerp

-- bevy_math uneven_interp: 0 = exact/tail at index i0; 1 = between i0 and i0 + 1 at s (1-based indices)
local function interp(times: { number }, t: number): (number, number, number)
	local n = #times
	-- binary search for t; else the insertion point (the number of keys before t)
	local lo, hi = 1, n
	while lo <= hi do
		local mid = (lo + hi) // 2
		local v = times[mid]
		if v == t then
			return 0, mid, 0
		elseif v < t then
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	local index = lo - 1 -- keys before t
	if index == 0 then
		return 0, 1, 0
	elseif index >= n then
		return 0, n, 0
	end
	local t0, t1 = times[index], times[index + 1]
	return 1, index, (t - t0) / (t1 - t0)
end
Evaluator.interp = interp

export type Layer = { clip: string, seek: number, weight: number }

-- `skeleton`: the pack's Skeleton JSON; `clips`: name -> Decoder.parseClip result
function Evaluator.new(skeleton: any, clips: { [string]: any })
	local joints = skeleton.joints
	local n = #joints
	local self = setmetatable({}, Evaluator) :: any
	self.n = n
	self.clips = clips
	self.names = table.create(n)
	self.parent = table.create(n) -- 1-based, 0 for a root
	self.index = {}
	-- the local transforms (the rest pose until a clip writes them)
	self.lt = table.create(n * 3, 0)
	self.lr = table.create(n * 4, 0)
	self.ls = table.create(n * 3, 1)
	for j, jt in joints do
		self.names[j] = jt.name
		self.index[jt.name] = j
		self.parent[j] = jt.parent + 1
		for c = 1, 3 do
			self.lt[(j - 1) * 3 + c] = jt.t[c]
			self.ls[(j - 1) * 3 + c] = jt.s[c]
		end
		for c = 1, 4 do
			self.lr[(j - 1) * 4 + c] = jt.r[c]
		end
	end
	-- world: position (through every scale), rotation (scales left out), and the 3x3 matrix (rotations and scales)
	self.wp = table.create(n * 3, 0)
	self.wq = table.create(n * 4, 0)
	self.wm = table.create(n * 9, 0)
	-- the clips' durations (each clip's last key time, as Bevy computes it)
	self.duration = {}
	for name, c in clips do
		self.duration[name] = c.duration
	end
	return self
end

-- a key's component (keys are key-major f32 in clip.values from ch.offset)
local readf32 = buffer.readf32

-- Sample one channel at t into out[o + 1 .. o + width]; rotation is slerped, translation and scale lerped
local function sample(values: buffer, ch: any, t: number, out: { number }, o: number)
	local width = ch.width
	local times = ch.times
	local base = ch.offset
	if ch.constant then
		-- every key is bit-identical; Bevy still interpolates between them when there are several (a no-op but for
		-- the last bit), which is far under the checks' tolerance: the key itself
		for c = 0, width - 1 do
			out[o + c + 1] = readf32(values, base + c * 4)
		end
		return
	end
	if #times == 1 then
		for c = 0, width - 1 do
			out[o + c + 1] = readf32(values, base + c * 4)
		end
		return
	end
	local kind, i0, s = interp(times, t)
	if kind == 0 or ch.interp == 1 then
		-- exact, a tail, or STEP (the earlier key)
		local at = base + (i0 - 1) * width * 4
		for c = 0, width - 1 do
			out[o + c + 1] = readf32(values, at + c * 4)
		end
		return
	end
	local a = base + (i0 - 1) * width * 4
	local b = a + width * 4
	if width == 4 then
		local x, y, z, w = slerp(
			readf32(values, a),
			readf32(values, a + 4),
			readf32(values, a + 8),
			readf32(values, a + 12),
			readf32(values, b),
			readf32(values, b + 4),
			readf32(values, b + 8),
			readf32(values, b + 12),
			s
		)
		out[o + 1], out[o + 2], out[o + 3], out[o + 4] = x, y, z, w
	else
		for c = 0, 2 do
			out[o + c + 1] = readf32(values, a + c * 4) * (1 - s) + readf32(values, b + c * 4) * s
		end
	end
end
Evaluator.sample = sample

local function byteLess(a: string, b: string): boolean
	local la, lb = #a, #b
	for i = 1, math.min(la, lb) do
		local x, y = string.byte(a, i), string.byte(b, i)
		if x ~= y then
			return x < y
		end
	end
	return la < lb
end
Evaluator.byteLess = byteLess

-- ActiveAnimation::update at speed 0: the seek wraps once it reaches the clip's duration
function Evaluator.wrapSeek(seek: number, duration: number): number
	if seek >= duration then
		seek = math.fmod(seek, duration)
	end
	if seek < 0 then
		seek += duration
	end
	return seek
end

local tmpT = table.create(3, 0)
local tmpR = table.create(4, 0)
local tmpS = table.create(3, 0)

-- Pose the skeleton from the active layers (any order; they fold in ascending clip name). A joint no clip writes
-- keeps its last local transform, as a Bevy Transform does.
function Evaluator.pose(self: any, layers: { Layer })
	local active = {}
	for _, l in layers do
		local clip = self.clips[l.clip]
		if clip and l.weight ~= 0 then
			table.insert(active, { clip = clip, name = l.clip, seek = Evaluator.wrapSeek(l.seek, clip.duration), weight = l.weight })
		end
	end
	table.sort(active, function(a, b)
		return byteLess(a.name, b.name)
	end)
	local lt, lr, ls = self.lt, self.lr, self.ls
	if #active > 0 then
		for j = 1, self.n do
			local ot, orr = (j - 1) * 3, (j - 1) * 4
			local wT, wR, wS = 0, 0, 0
			for _, a in active do
				local chans = a.clip.channels[j]
				local w = a.weight
				local ch = chans.T
				if ch then
					sample(a.clip.values, ch, a.seek, tmpT, 0)
					if wT == 0 then
						lt[ot + 1], lt[ot + 2], lt[ot + 3] = tmpT[1], tmpT[2], tmpT[3]
						wT = w
					else
						wT += w
						local f = w / wT
						lt[ot + 1] = lt[ot + 1] * (1 - f) + tmpT[1] * f
						lt[ot + 2] = lt[ot + 2] * (1 - f) + tmpT[2] * f
						lt[ot + 3] = lt[ot + 3] * (1 - f) + tmpT[3] * f
					end
				end
				ch = chans.R
				if ch then
					sample(a.clip.values, ch, a.seek, tmpR, 0)
					if wR == 0 then
						lr[orr + 1], lr[orr + 2], lr[orr + 3], lr[orr + 4] = tmpR[1], tmpR[2], tmpR[3], tmpR[4]
						wR = w
					else
						wR += w
						lr[orr + 1], lr[orr + 2], lr[orr + 3], lr[orr + 4] = slerp(
							lr[orr + 1],
							lr[orr + 2],
							lr[orr + 3],
							lr[orr + 4],
							tmpR[1],
							tmpR[2],
							tmpR[3],
							tmpR[4],
							w / wR
						)
					end
				end
				ch = chans.S
				if ch then
					sample(a.clip.values, ch, a.seek, tmpS, 0)
					if wS == 0 then
						ls[ot + 1], ls[ot + 2], ls[ot + 3] = tmpS[1], tmpS[2], tmpS[3]
						wS = w
					else
						wS += w
						local f = w / wS
						ls[ot + 1] = ls[ot + 1] * (1 - f) + tmpS[1] * f
						ls[ot + 2] = ls[ot + 2] * (1 - f) + tmpS[2] * f
						ls[ot + 3] = ls[ot + 3] * (1 - f) + tmpS[3] * f
					end
				end
			end
		end
	end
	self:forward()
end

-- Transform propagation: world matrix = parent's * T R S; the world rotation without the scales
function Evaluator.forward(self: any)
	local lt, lr, ls = self.lt, self.lr, self.ls
	local wp, wq, wm, parent = self.wp, self.wq, self.wm, self.parent
	for j = 1, self.n do
		local ot, orr, om = (j - 1) * 3, (j - 1) * 4, (j - 1) * 9
		local qx, qy, qz, qw = lr[orr + 1], lr[orr + 2], lr[orr + 3], lr[orr + 4]
		local sx, sy, sz = ls[ot + 1], ls[ot + 2], ls[ot + 3]
		-- the local rotation's matrix (columns), each column scaled (Mat3::from_quat * diag(s))
		local x2, y2, z2 = qx + qx, qy + qy, qz + qz
		local xx, xy, xz = qx * x2, qx * y2, qx * z2
		local yy, yz, zz = qy * y2, qy * z2, qz * z2
		local wx, wy, wz = qw * x2, qw * y2, qw * z2
		-- column-major: c0 = (m11, m21, m31) ...
		local a11, a21, a31 = (1 - (yy + zz)) * sx, (xy + wz) * sx, (xz - wy) * sx
		local a12, a22, a32 = (xy - wz) * sy, (1 - (xx + zz)) * sy, (yz + wx) * sy
		local a13, a23, a33 = (xz + wy) * sz, (yz - wx) * sz, (1 - (xx + yy)) * sz
		local tx, ty, tz = lt[ot + 1], lt[ot + 2], lt[ot + 3]
		local p = parent[j]
		if p == 0 then
			wm[om + 1], wm[om + 2], wm[om + 3] = a11, a21, a31
			wm[om + 4], wm[om + 5], wm[om + 6] = a12, a22, a32
			wm[om + 7], wm[om + 8], wm[om + 9] = a13, a23, a33
			wp[ot + 1], wp[ot + 2], wp[ot + 3] = tx, ty, tz
			wq[orr + 1], wq[orr + 2], wq[orr + 3], wq[orr + 4] = qx, qy, qz, qw
		else
			local pm, pp, pq = (p - 1) * 9, (p - 1) * 3, (p - 1) * 4
			local b11, b21, b31 = wm[pm + 1], wm[pm + 2], wm[pm + 3]
			local b12, b22, b32 = wm[pm + 4], wm[pm + 5], wm[pm + 6]
			local b13, b23, b33 = wm[pm + 7], wm[pm + 8], wm[pm + 9]
			wm[om + 1] = b11 * a11 + b12 * a21 + b13 * a31
			wm[om + 2] = b21 * a11 + b22 * a21 + b23 * a31
			wm[om + 3] = b31 * a11 + b32 * a21 + b33 * a31
			wm[om + 4] = b11 * a12 + b12 * a22 + b13 * a32
			wm[om + 5] = b21 * a12 + b22 * a22 + b23 * a32
			wm[om + 6] = b31 * a12 + b32 * a22 + b33 * a32
			wm[om + 7] = b11 * a13 + b12 * a23 + b13 * a33
			wm[om + 8] = b21 * a13 + b22 * a23 + b23 * a33
			wm[om + 9] = b31 * a13 + b32 * a23 + b33 * a33
			wp[ot + 1] = b11 * tx + b12 * ty + b13 * tz + wp[pp + 1]
			wp[ot + 2] = b21 * tx + b22 * ty + b23 * tz + wp[pp + 2]
			wp[ot + 3] = b31 * tx + b32 * ty + b33 * tz + wp[pp + 3]
			-- parent rotation * local rotation (Hamilton product)
			local px, py, pz, pw = wq[pq + 1], wq[pq + 2], wq[pq + 3], wq[pq + 4]
			wq[orr + 1] = pw * qx + px * qw + py * qz - pz * qy
			wq[orr + 2] = pw * qy - px * qz + py * qw + pz * qx
			wq[orr + 3] = pw * qz + px * qy - py * qx + pz * qw
			wq[orr + 4] = pw * qw - px * qx - py * qy - pz * qz
		end
	end
end

-- Joint j's world position (metres) and rotation (x, y, z, w)
function Evaluator.world(self: any, j: number): (number, number, number, number, number, number, number)
	local ot, orr = (j - 1) * 3, (j - 1) * 4
	local wp, wq = self.wp, self.wq
	return wp[ot + 1], wp[ot + 2], wp[ot + 3], wq[orr + 1], wq[orr + 2], wq[orr + 3], wq[orr + 4]
end

return Evaluator
