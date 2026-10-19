--!strict
local __F = function(x: any): any if type(x) == "number" then return vector.create(x, 0, 0).x end return x end -- f32ify: f32 rounding (vector arithmetic rounds in its own metamethods)
-- Port of crates/sm_traversal/src/math.rs: vector and scalar helpers as Spider-Man.exe 4.0630 computes them (RVAs in
-- the comments). Vectors are normalized the way the game does: scaled by their largest component first, then by their
-- length; a zero vector stays as it is.
--
-- Numbers: the Rust is f32 and Luau numbers are f64, so the shipped build of this folder is rewritten by
-- tools/f32ify (see roblox_port/tools/build.py) to round every arithmetic result to f32, as the Rust computes. Where
-- the Rust itself computes in f64 (the game clock, part of the spring) the functions are named f64_*: the rewrite
-- leaves them alone and they round explicitly where the Rust casts to f32. Rust's f32::max/min return the other
-- operand when one is NaN, and Luau's math.max/min don't, so `fmax`/`fmin`/`clamp` here follow Rust.

local M = {}

-- x rounded to f32 (a vector component is an f32)
local function f32(x: number): number
	return vector.create(x, 0, 0).x
end
M.f32 = f32

-- Rust f32::max / f32::min (NaN loses)
local function fmax(a: number, b: number): number
	if a ~= a then
		return b
	elseif b ~= b then
		return a
	elseif a > b then
		return a
	else
		return b
	end
end
local function fmin(a: number, b: number): number
	if a ~= a then
		return b
	elseif b ~= b then
		return a
	elseif a < b then
		return a
	else
		return b
	end
end
-- Rust f32::clamp (NaN stays NaN)
local function clamp(x: number, lo: number, hi: number): number
	if x < lo then
		x = lo
	end
	if x > hi then
		x = hi
	end
	return x
end
M.fmax = fmax
M.fmin = fmin
M.clamp = clamp

local sqrt, abs = math.sqrt, math.abs

export type V3 = typeof(setmetatable({} :: { x: number, y: number, z: number }, {} :: any))

local V3 = {}
V3.__index = V3

local function new(x: number, y: number, z: number): V3
	return setmetatable({ x = x, y = y, z = z }, V3) :: any
end
V3.new = new
V3.ZERO = new(0, 0, 0)
V3.UP = new(0, 1, 0)

function V3.__add(a: V3, b: V3): V3
	return new(__F(a.x + b.x), __F(a.y + b.y), __F(a.z + b.z))
end
function V3.__sub(a: V3, b: V3): V3
	return new(__F(a.x - b.x), __F(a.y - b.y), __F(a.z - b.z))
end
function V3.__mul(a: V3, s: number): V3
	return new(__F(a.x * s), __F(a.y * s), __F(a.z * s))
end
function V3.__unm(a: V3): V3
	return new(-a.x, -a.y, -a.z)
end
function V3.__eq(a: V3, b: V3): boolean
	return a.x == b.x and a.y == b.y and a.z == b.z
end
function V3.__tostring(a: V3): string
	return string.format("V3(%.9g, %.9g, %.9g)", a.x, a.y, a.z)
end
function V3.fromSlice(t: { number }, i: number?): V3
	local o = i or 1
	return new(t[o], t[__F(o + 1)], t[__F(o + 2)])
end
function V3.dot(a: V3, o: V3): number
	return __F(__F(__F(a.x * o.x) + __F(a.y * o.y)) + __F(a.z * o.z))
end
function V3.cross(a: V3, o: V3): V3
	return new(__F(__F(a.y * o.z) - __F(a.z * o.y)), __F(__F(a.z * o.x) - __F(a.x * o.z)), __F(__F(a.x * o.y) - __F(a.y * o.x)))
end
function V3.max_abs(a: V3): number
	return fmax(fmax(abs(a.z), abs(a.y)), abs(a.x))
end
-- exe+2c2450
function V3.len(a: V3): number
	local m = a:max_abs()
	if not (m > 0) then
		return 0
	end
	local s = __F(1 / m)
	local x, y, z = __F(a.x * s), __F(a.y * s), __F(a.z * s)
	return __F(__F(sqrt(__F(__F(__F(y * y) + __F(x * x)) + __F(z * z)))) * m)
end
-- exe+2d0740: unchanged when zero
function V3.norm(a: V3): V3
	local m = a:max_abs()
	if not (m > 0) then
		return a
	end
	local s = __F(1 / m)
	local x, y, z = __F(a.x * s), __F(a.y * s), __F(a.z * s)
	local l = __F(1 / __F(sqrt(__F(__F(__F(y * y) + __F(x * x)) + __F(z * z)))))
	return new(__F(x * l), __F(y * l), __F(z * l))
end
-- The x/z part (y = 0)
function V3.flat(a: V3): V3
	return new(a.x, 0, a.z)
end
-- exe+3e3f30
function V3.flat_len(a: V3): number
	local m = fmax(abs(a.x), abs(a.z))
	if not (m > 0) then
		return 0
	end
	local x, z = __F(a.x * (__F(1 / m))), __F(a.z * (__F(1 / m)))
	return __F(__F(sqrt(__F(__F(z * z) + __F(x * x)))) * m)
end
-- The x/z direction, normalized as the game does it inline (zero stays zero)
function V3.flat_norm(a: V3): V3
	local x, z = a.x, a.z
	local m = fmax(fmax(abs(z), 0), abs(x))
	if m > 0 then
		z = __F(z * (__F(1 / m)))
		x = __F(x * (__F(1 / m)))
		local l = __F(1 / __F(sqrt(__F(__F(z * z) + __F(x * x)))))
		z = __F(z * (l))
		x = __F(x * (l))
	end
	return new(x, 0, z)
end
-- v scaled to length `l` along its direction, zero when it has none (the "/ sqrt(len^2) if >= 1e-15" pattern)
function V3.with_len(a: V3, l: number): V3
	local d = a:dot(a)
	if d >= 1.0000000036274937e-15 then
		return __F(a * (__F(l / __F(sqrt(d)))))
	end
	return V3.ZERO
end
local function finite(x: number): boolean
	return x == x and x ~= math.huge and x ~= -math.huge
end
M.finite = finite
function V3.is_finite(a: V3): boolean
	return finite(a.x) and finite(a.y) and finite(a.z)
end
M.V3 = V3

-- A transform's rows as the game keeps them: side (= up x forward; for a camera it points left), up, forward, position
export type Rows = { side: V3, up: V3, fwd: V3, pos: V3 }
local Rows = {}
function Rows.default(): Rows
	return { side = V3.ZERO, up = V3.ZERO, fwd = V3.ZERO, pos = V3.ZERO }
end
-- Upright, facing `fwd` (flattened)
function Rows.facing(fwd: V3, pos: V3): Rows
	local f = fwd:flat_norm()
	return { side = V3.UP:cross(f), up = V3.UP, fwd = f, pos = pos }
end
M.Rows = Rows

M.RAD = 57.295780181884766
M.DEG = 0.017453290522098541

local atan2_, acos_, cos_, sin_, exp_ = math.atan2, math.acos, math.cos, math.sin, math.exp

-- exe+1c58560: atan2(y, x)
function M.atan2(y: number, x: number): number
	return __F(atan2_(y, x))
end
-- exe+876340: minus the angle of v above the horizontal (radians; negative going up)
function M.pitch_of(v: V3): number
	return -__F(atan2_(v.y, v:flat_len()))
end
-- exe+1c59090: the angle between two unit vectors
function M.angle_between(a: V3, b: V3): number
	return __F(acos_(clamp(a:dot(b), -1, 1)))
end
-- exe+1c58210
function M.acos(x: number): number
	return __F(acos_(clamp(x, -1, 1)))
end
-- exe+1c58730 / exe+366a0e0
function M.cos(x: number): number
	return __F(cos_(x))
end
-- exe+1c58e50
function M.sin(x: number): number
	return __F(sin_(x))
end
-- exe+3667c70
function M.exp(x: number): number
	return __F(exp_(x))
end

-- The game clock (f64 in the Rust: `time += dt as f64`)
function M.f64_add(time: number, dt: number): number
	return time + dt
end
-- Time in a state: `(env.time - self.entry_time) as f32`
function M.f64_elapsed(now: number, since: number): number
	return f32(now - since)
end

-- exe+1c477e0: x moved toward the target by at most rate * dt
function M.approach(cur: number, target: number, rate: number, dt: number): number
	local step = __F(rate * dt)
	local d = __F(target - cur)
	if d >= 0 then
		return __F(cur + fmin(d, step))
	else
		return __F(cur - fmin(-d, step))
	end
end
-- exe+1c47af0: a point moved toward the target by at most rate * dt
function M.approach_v(cur: V3, target: V3, rate: number, dt: number): V3
	local d = __F(target - cur)
	local l = d:len()
	local f = if l > 0 then __F(fmin(__F(rate * dt), l) / l) else 0
	return __F(cur + __F(d * f))
end
-- clamp((x - a) / (b - a)); for a degenerate range: 0 below, 1 above, 0.5 on it (the game's inline remap)
local function remap(x: number, a: number, b: number): number
	local r = __F(b - a)
	if abs(r) <= 9.9999997473787516e-05 then
		if a <= x then
			if x <= a then
				return 0.5
			else
				return 1
			end
		else
			return 0
		end
	else
		return clamp(__F((__F(x - a)) / r), 0, 1)
	end
end
M.remap = remap
-- exe+41c590: clamp((x - a) / (b - a)) (same degenerate rule)
M.unlerp = remap
function M.lerp(a: number, b: number, t: number): number
	return __F(__F((__F(b - a)) * t) + a)
end
function M.clamp01(x: number): number
	return fmin(fmax(x, 0), 1)
end

-- exe+1c46be0: one step of x toward a target. `v` (per second) carries over; a and b are (negative) rates, c caps the
-- speed (none when <= 0); the step never passes the target. Returns the new x and the new v. (Part of it is f64 in the
-- Rust, so it rounds by hand: `e` is f64, `((1 - e) * v) as f32`, the rest f32.)
function M.f64_spring(x: number, target: number, v: number, a: number, b: number, c: number, dt: number): (number, number)
	if not (dt > 0) or (x == target and v == 0) then
		return x, v
	end
	local d = f32(target - x)
	local e = exp_(b * 0.033333333333333333) ^ dt
	local s = f32(f32(f32(f32((1.0 - e) * v) + v) * 0.5) * dt)
	s = f32(s + f32(f32(1 - f32(exp_(f32(a * dt)))) * d))
	local lim = if c > 0 then f32(c * dt) else f32(1e30)
	local step = fmin(fmax(s, -lim), lim)
	local ad = abs(d)
	step = fmin(fmax(step, -ad), ad)
	return f32(x + step), f32(step / dt)
end
M.spring = M.f64_spring

-- The nearest whole turn, as exe+1c46d50 rounds
function M.wrap_pi(a: number): number
	local TWO_PI = 6.2831854820251465
	local t = __F(__F(a * 0.15915493667125702) + 0.5)
	if not (abs(t) < 2147483520) then
		return a
	end
	-- (t as i32) truncates toward zero
	local f = if t >= 0 then math.floor(t) else -math.floor(-t)
	if f ~= t and t < 0 then
		f = __F(f - (1))
	end
	return __F(a - __F(f * TWO_PI))
end

-- exe+1c54e30 + exe+1c5b320: v turned about `axis` by `angle` (radians)
function M.rotate(v: V3, axis: V3, angle: number): V3
	local l = axis:len()
	if not (l > 0) then
		return v
	end
	local u = __F(axis * (__F(1 / l)))
	local s, c = __F(sin_(__F(angle * 0.5))), __F(cos_(__F(angle * 0.5)))
	local q = __F(u * s)
	-- v' = v + 2w(q x v) + 2 q x (q x v)
	local t = __F(q:cross(v) * 2)
	return __F(__F(v + __F(t * c)) + q:cross(t))
end
-- exe+1c5b3e0: from unit a toward unit b by t of the angle between them
function M.slerp(a: V3, b: V3, t: number): V3
	local d = clamp(b:dot(a), -1, 1)
	local perp = (__F(b - __F(a * d))):norm()
	local th = __F(M.acos(d) * t)
	local s, c = __F(sin_(th)), __F(cos_(th))
	return new(__F(__F(c * a.x) + __F(perp.x * s)), __F(__F(perp.y * s) + __F(c * a.y)), __F(__F(c * a.z) + __F(perp.z * s)))
end
-- exe+1c511e0 (the usual case): rows side = up x f, up' = f x side, forward = f
function M.basis(f: V3, up: V3): (V3, V3, V3)
	local s = up:cross(f):norm()
	return s, f:cross(s), f
end

-- exe+311350
function M.dist(a: V3, b: V3): number
	return (__F(a - b)):len()
end
-- exe+4c4e20
function M.flat_dist(a: V3, b: V3): number
	return (__F(a - b)):flat_len()
end

return M
