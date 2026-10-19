--!strict
-- Port of crates/sm_traversal/src/config.rs: the game's traversal configs, read the way serde reads them there:
-- `rename_all = "PascalCase"` (snake_case field -> PascalCase key, with the struct's explicit renames), `default`
-- (a missing number is 0, a missing string "", a missing list empty, a missing struct its defaults), every number an
-- f32. Fields keep the Rust names, so the port reads like the Rust.
local Math = require("./Math")

local Config = {}

local f32 = Math.f32

-- snake_case -> PascalCase, as serde's rename_all does it
local function pascal(name: string): string
	return (string.gsub("_" .. name, "_(%l)", string.upper))
end

-- A schema: { {field, kind, sub?, key?} }; kind "f" f32, "s" string, "t" struct, "l" list of structs, "lf" list of f32
type Field = { any }

local function read(schema: { Field }, json: any): any
	local out = {}
	for _, f in schema do
		local name, kind, sub, key = f[1], f[2], f[3], f[4]
		local v = if json ~= nil then json[key or pascal(name)] else nil
		if kind == "f" then
			out[name] = if type(v) == "number" then f32(v) else 0
		elseif kind == "s" then
			out[name] = if type(v) == "string" then v else ""
		elseif kind == "t" then
			out[name] = read(sub, v)
		elseif kind == "l" then
			local list = {}
			if type(v) == "table" then
				for i, e in v do
					list[i] = read(sub, e)
				end
			end
			out[name] = list
		elseif kind == "lf" then
			local list = {}
			if type(v) == "table" then
				for i, e in v do
					list[i] = f32(e)
				end
			end
			out[name] = list
		else
			error("schema kind " .. tostring(kind))
		end
	end
	return out
end
Config.read = read

local function fields(...: string): { Field }
	local t = {}
	for i, n in { ... } do
		t[i] = { n, "f" }
	end
	return t
end

-- (field order as in config.rs; the tracker blends these field by field)
Config.SearchParams = fields(
	"broad_search_radius",
	"narrow_search_radius",
	"ideal_line_length_forward",
	"ideal_line_length_turn",
	"ideal_angle_forward",
	"ideal_angle_turn",
	"ideal_angle_turn_speed_min",
	"ideal_angle_turn_speed_max",
	"ideal_angle_fall",
	"ideal_angle_fall_speed_min",
	"ideal_angle_fall_speed_max",
	"ideal_angle_dive",
	"ideal_angle_dive_speed_min",
	"ideal_angle_dive_speed_max",
	"near_ground_distance_min",
	"near_ground_distance_max",
	"near_ground_angle",
	"line_length_fall_tweak",
	"line_length_dive_tweak",
	"line_length_tweak_speed_min",
	"line_length_tweak_speed_max"
)
Config.SpeedParams = fields(
	"fall_speed_threshold_min",
	"fall_speed_threshold_mid",
	"fall_speed_threshold_max",
	"terminal_velocity_horz_min",
	"terminal_velocity_horz_mid",
	"terminal_velocity_horz_max",
	"terminal_velocity_pure_max",
	"terminal_velocity_min_percent",
	"terminal_velocity_min_floor",
	"terminal_velocity_max_floor",
	"input_decel_zero",
	"input_decel_back",
	"in_speed_carryover",
	"speed_boost_target",
	"speed_boost_accel",
	"speed_boost_accel_accel",
	"release_boost_xz",
	"release_boost_alt_min",
	"jump_boost_xz",
	"jump_boost_pitch_low_min",
	"jump_boost_pitch_low_max",
	"jump_boost_pitch_high_min",
	"jump_boost_pitch_high_max"
)
-- #[serde(rename = "ReleaseBoostXZ")], #[serde(rename = "JumpBoostXZ")]
for _, f in Config.SpeedParams do
	if f[1] == "release_boost_xz" then
		f[4] = "ReleaseBoostXZ"
	elseif f[1] == "jump_boost_xz" then
		f[4] = "JumpBoostXZ"
	end
end
Config.TurnParams = fields(
	"turn_speed_min_min",
	"turn_speed_min_max",
	"turn_speed_max_min",
	"turn_speed_max_max",
	"turn_gain_min",
	"turn_gain_max",
	"turn_damp_min",
	"turn_damp_max",
	"turn_ramp_speed",
	"turn_speed_tilt_angle_min",
	"turn_speed_tilt_angle_max",
	"turn_speed_tilt_scale",
	"turn_speed_pitch_min",
	"turn_speed_pitch_max"
)
Config.GravityParams = fields(
	"gravity_fall_init",
	"gravity_fall_turn",
	"gravity_fall_hold",
	"init_tilt_angle_min",
	"init_tilt_angle_max",
	"rise_pitch_angle_min",
	"rise_pitch_angle_max",
	"rise_tilt_angle_min",
	"rise_tilt_angle_max",
	"rise_low_speed_min",
	"rise_low_speed_max",
	"rise_high_speed_min",
	"rise_high_speed_max",
	"rise_gravity_low_min",
	"rise_gravity_low_max",
	"rise_gravity_high_min",
	"rise_gravity_high_max",
	"rise_gravity_low_min_zero",
	"rise_gravity_low_max_zero",
	"rise_gravity_high_min_zero",
	"rise_gravity_high_max_zero",
	"rise_gravity_low_tilt",
	"rise_gravity_high_tilt",
	"rise_line_length_scale",
	"rise_line_length_min",
	"rise_line_length_max"
)
Config.MotionParams = {
	{ "speed_params", "t", Config.SpeedParams },
	{ "turn_params", "t", Config.TurnParams },
	{ "gravity_params", "t", Config.GravityParams },
}
Config.ReleaseParamSet = fields("jump_boost", "vert_floor_base", "vert_floor_jump")
Config.ReleaseGravityData = fields(
	"gravity_release_low",
	"gravity_release_mid",
	"gravity_release_high",
	"gravity_jump_low",
	"gravity_jump_mid",
	"gravity_jump_high",
	"gravity_angle_low",
	"gravity_angle_mid",
	"gravity_angle_high"
)
Config.ReleaseParams = {
	{ "params_fall", "t", Config.ReleaseParamSet },
	{ "params_low", "t", Config.ReleaseParamSet },
	{ "params_middle", "t", Config.ReleaseParamSet },
	{ "params_high", "t", Config.ReleaseParamSet },
	{ "release_gravity_data", "t", Config.ReleaseGravityData },
}
Config.SwingSetup = {
	{ "search_params", "t", Config.SearchParams },
	{ "motion_params", "t", Config.MotionParams },
	{ "release_params", "t", Config.ReleaseParams },
}
Config.InputBoost = fields(
	"gravity_scale_max",
	"gravity_factor_speed",
	"acceleration_time",
	"active_acceleration",
	"max_speed_acceleration",
	"max_speed_accel_min_speed",
	"max_speed_accel_max_speed"
)
Config.MomentumStage = {
	{ "momentum_value", "f" },
	{ "terminal_velocity_horz_floor", "f" },
	{ "skill_offset_for_horz_floor", "lf" },
	{ "gravity_scale", "f" },
	{ "line_length_tweak", "f" },
	{ "line_angle_tweak", "f" },
	{ "true_pivot_factor_start", "f" },
	{ "true_pivot_factor_trough", "f" },
	{ "true_pivot_factor_final", "f" },
	{ "turn_speed_scale", "f" },
}
Config.DecayData = fields("momentum_value", "decay_rate", "decay_delay")
Config.BoostData = fields("boost", "boost_cap", "retrigger_delay")
Config.AnglePoint = fields("angle", "rate", "scale")
Config.SwingMomentumData = {
	{ "rate_list", "l", Config.AnglePoint },
	{ "start_scale", "f" },
	{ "min_time", "f" },
	{ "max_time", "f" },
	{ "boost_cap", "f" },
}
Config.SwingReleaseMomentumData = {
	{ "rate_scale_list", "l", Config.AnglePoint },
	{ "release_data", "t", Config.BoostData },
	{ "jump_data", "t", Config.BoostData },
}
Config.FallMomentumData = fields(
	"fall_speed_min",
	"fall_speed_max",
	"fall_time_min",
	"fall_time_max",
	"fall_time_bias",
	"fall_gain_min",
	"fall_gain_max",
	"fall_momentum_cap_min",
	"fall_momentum_cap_max",
	"dive_time_min",
	"dive_time_max",
	"dive_time_bias",
	"dive_gain_min",
	"dive_gain_max",
	"dive_momentum_cap_min",
	"dive_momentum_cap_max"
)
Config.MomentumConfig = {
	{ "max_momentum", "f" },
	{ "decay_data_air", "l", Config.DecayData },
	{ "decay_data_ground", "l", Config.DecayData },
	{ "momentum_stages", "l", Config.MomentumStage },
	{ "swing_data", "t", Config.SwingMomentumData },
	{ "swing_release_data", "t", Config.SwingReleaseMomentumData },
	{ "fall_data", "t", Config.FallMomentumData },
}
Config.RedirectZone = fields("line_angle_start", "line_angle_end", "exit_angle_start", "exit_angle_end", "exit_bias")
Config.TransitionData = fields("forward_action_lookback_time")
Config.HeroSwingConfig = {
	{ "input_boost", "t", Config.InputBoost },
	{ "transition_data", "t", Config.TransitionData },
	{ "release_angle_low_start", "f" },
	{ "release_angle_low_final", "f" },
	{ "release_angle_high_start", "f" },
	{ "release_angle_high_final", "f" },
	{ "jump_from_fall_horz_damp", "f" },
	{ "jump_from_fall_horz_min", "f" },
	{ "jump_redirect_zones", "l", Config.RedirectZone },
	{ "speed_input_min", "f" },
	{ "speed_input_mid", "f" },
	{ "speed_input_max", "f" },
	{ "speed_input_mid_value", "f" },
	{ "zero_input_pivot_scale_start", "f" },
	{ "zero_input_pivot_scale_trough", "f" },
	{ "zero_input_pivot_scale_final", "f" },
	{ "momentum_config", "t", Config.MomentumConfig },
}
Config.JumpMotionData = {
	{ "jump_height", "f" },
	{ "time_to_peak", "f" },
	{ "time_to_fall", "f" },
	{ "button_thrust_accel", "f" },
	{ "button_thrust_accel_grav", "f" },
	{ "button_thrust_time_max", "f" },
	{ "velocity_accel_accel_min", "f" },
	{ "velocity_accel_accel_max", "f" },
	{ "velocity_accel_time_min", "f" },
	{ "velocity_accel_time_max", "f" },
	{ "braking_acceleration", "f" },
	{ "facing_to_input_time_min", "f" },
	{ "facing_to_input_time_max", "f" },
	{ "drag_profile_name", "s" },
	{ "no_input_time", "f" },
}
Config.JumpSpeedData = fields(
	"walk_speed_max",
	"run_speed_max_min",
	"run_speed_max_max",
	"walk_run_threshold",
	"run_speed_alt_min",
	"max_accel_speed",
	"max_accel_delay",
	"max_accel_accel",
	"min_launch_speed",
	"max_launch_speed"
)
Config.DragProfile = {
	{ "profile_name", "s" },
	{ "forward_speed_min", "f" },
	{ "forward_speed_max", "f" },
	{ "forward_drag_min", "f" },
	{ "forward_drag_max", "f" },
	{ "turn_drag", "f" },
	{ "no_input_drag", "f" },
	{ "scale_start_time", "f" },
	{ "scale_max_time", "f" },
	{ "scale_max_factor", "f" },
	{ "turn_blend_in_start", "f" },
	{ "turn_blend_in_final", "f" },
	{ "forward_tolerance", "f" },
}
Config.JumpConfig = { { "standard_data", "t", Config.JumpMotionData } }
Config.JumpSpeed = { { "standard_data", "t", Config.JumpSpeedData } }
Config.JumpConfigs = {
	{ "single_jump_config", "t", Config.JumpConfig },
	{ "swing_jump_config", "t", Config.JumpConfig },
	{ "zip_point_launch_jump_config", "t", Config.JumpConfig },
	{ "perch_jump_config", "t", Config.JumpConfig },
	{ "swing_jump_speed", "t", Config.JumpSpeed },
	{ "dive_jump_speed", "t", Config.JumpSpeed },
	{ "ground_jump_speed", "t", Config.JumpSpeed },
	{ "perch_jump_speed", "t", Config.JumpSpeed },
	{ "default_drag_profile", "t", Config.DragProfile },
	{ "drag_profile_list", "l", Config.DragProfile },
}
Config.PointLaunchExitData = fields(
	"launch_speed",
	"time_to_peak",
	"jump_height",
	"launch_speed_bonus",
	"time_to_peak_bonus",
	"jump_height_bonus"
)
Config.PointLaunchConfig = {
	{ "exit_data_full", "t", Config.PointLaunchExitData },
	{ "exit_data_zero", "t", Config.PointLaunchExitData },
	{ "exit_data_back", "t", Config.PointLaunchExitData },
	{ "auto_vault", "t", Config.PointLaunchExitData },
	{ "perch_to_perch_point_launch", "t", Config.PointLaunchExitData },
	{ "boost_window_min", "f" },
	{ "boost_window_max", "f" },
	{ "boost_min_apply", "f" },
	{ "boost_max_fx_perc", "f", nil, "BoostMaxFXPerc" },
	{ "max_exit_angle", "f" },
	{ "gravity_fall", "f" },
}
Config.HeroTraversalConfig = {
	{ "standard_fall_gravity", "f" },
	{ "standard_fall_terminal_velocity", "f" },
	{ "standard_fall_terminal_velocity_max", "f" },
	{ "standard_fall_term_vel_accel", "f" },
	{ "point_launch_config", "t", Config.PointLaunchConfig },
	{ "jump_configs", "t", Config.JumpConfigs },
}

export type Configs = {
	swing: any,
	setup_standard: any,
	setup_slow: any,
	setup_ground: any,
	traversal: any,
	drag_profile: (self: Configs, name: string) -> any,
}

local function drag_profile(self: Configs, name: string): any
	for _, d in self.traversal.jump_configs.drag_profile_list do
		if d.profile_name == name then
			return d
		end
	end
	return self.traversal.jump_configs.default_drag_profile
end

-- Configs::from_json, from already decoded JSON values
function Config.fromJson(swing: any, standard: any, slow: any, ground: any, traversal: any): Configs
	return {
		swing = read(Config.HeroSwingConfig, swing),
		-- SwingSetupConfig the tracker uses at full momentum or speed (exe+923930, holder +0x8c0)
		setup_standard = read(Config.SwingSetup, standard),
		-- ...and with none (exe+923910, holder +0x8e0): the slow start
		setup_slow = read(Config.SwingSetup, slow),
		-- ...near the ground, for releases (exe+923920, holder +0x900)
		setup_ground = read(Config.SwingSetup, ground),
		traversal = read(Config.HeroTraversalConfig, traversal),
		drag_profile = drag_profile,
	}
end

-- Configs::embedded(): assets/tuning/native, which the pack keeps as Tuning/native__<name>. `tuning(name)` returns
-- the decoded JSON of one Tuning module.
function Config.embedded(tuning: (string) -> any): Configs
	return Config.fromJson(
		tuning("native__hero_swing_config"),
		tuning("native__swing_setup_standard"),
		tuning("native__swing_setup_open"),
		tuning("native__swing_setup_ground"),
		tuning("native__hero_traversal_config")
	)
end

return Config
