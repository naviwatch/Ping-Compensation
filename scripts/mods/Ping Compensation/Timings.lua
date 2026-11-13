local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Animation timings the host needs to end a client's stagger or recoil on time (D14, D32):
--   length: a stagger animation's length at normal speed, from its start to anim_cb_push_finished.
--   cue:    a recoil animation's time from its start to anim_cb_blocked_cooldown.
-- They are fixed properties of each animation, so they ship with the mod (DEFAULTS, measured in playtests), and every
-- machine keeps measuring: the host from its own staggers and recoils, a client from what its copy of each enemy plays.
-- What this machine has measured is kept with mod:set and is used before the defaults. /pingcomp timings writes
-- everything known to the console log in the form DEFAULTS uses, so a playtest's numbers can be copied in here.

local timings = {}

pc.timings = timings

-- The shortest real ones are about 0.4 s (a shield rat's stun_down) and 0.7 s (a rat's blocked_3). Shorter readings are
-- an earlier animation's callback arriving just after a new one started (0.11 to 0.17 s in the 2026-11-12 playtest).
local MIN_SECONDS = {
	length = 0.3,
	cue = 0.3,
}
local MAX_SECONDS = 6
local MIN_SHARE = 0.5 -- a reading under half of the value already known is taken for one of those, and ignored
-- A reading over half again the value already known is ignored too: a recoil timed from an older recoil's start (the
-- 2.2 host's marauder cues, 1.2 to 2.35 s instead of 0.95 s), or a sped-up stagger that didn't reach its speed.
local MAX_SHARE = 1.5
local LEARN_WEIGHT = 0.3 -- how far a new measurement moves the value already known
-- Builds before 2.2 saved under "stagger_lengths" and "recoil_cues", polluted by those readings and by recoils the
-- host started late; 2.2 hosts saved polluted cues under "recoil_cues_2". Those are no longer read.
local SETTINGS = {
	length = "stagger_lengths_2",
	cue = "recoil_cues_3",
}

-- Seconds: the median of each animation's readings from the 2026-11-12 playtests of steps 2 and 2.1 (host and client
-- stagger lengths, the client's recoil cues), of step 2.2 (the host's stagger lengths; its recoil cues were timed
-- from the wrong start and left out) and of build 3 on 2026-11-13 (host and clients, but the Chaos breeds' stagger
-- lengths from the host only, and new animations only with two readings or more), with how many there were. Readings
-- under 0.3 s or under half the median were dropped. "saved average": measured on the testers' machines in earlier
-- sessions, not in these logs. The fanatic has no recoil cue: it depends on the attack blocked (VARIABLE_CUE_BREEDS).
local DEFAULTS = {
	length = {
		chaos_berzerker = {
			run_stagger_left = 0.79, -- 17
			stagger_bwd = 1.15, -- 3
			stagger_bwd_2 = 1.28, -- 4
			stagger_bwd_3 = 1.18, -- 5
			stagger_bwd_heavy = 2.52, -- 3
			stagger_bwd_heavy_2 = 2.86, -- 3
			stagger_bwd_heavy_3 = 2.51, -- 5
			stagger_bwd_heavy_4 = 2.58, -- 5
			stagger_bwd_light = 0.73, -- 4
			stagger_bwd_light_2 = 0.71, -- 4
			stagger_bwd_light_4 = 0.66, -- 4
			stagger_bwd_light_5 = 0.73, -- 3
			stagger_bwd_light_6 = 0.88, -- 5
			stagger_bwd_light_7 = 0.81, -- 3
			stagger_left = 0.83, -- 4
			stagger_left_light = 0.74, -- 6
			stagger_left_light_4 = 0.85, -- 2
			stagger_right_heavy_3 = 2.55, -- 2
		},
		chaos_fanatic = {
			stagger_bwd = 1.16, -- 78
			stagger_bwd_2 = 1.28, -- 98
			stagger_bwd_3 = 1.18, -- 92
			stagger_bwd_4 = 1.12, -- 89
			stagger_bwd_heavy = 2.67, -- 11
			stagger_bwd_heavy_2 = 2.92, -- 11
			stagger_bwd_heavy_3 = 2.66, -- 10
			stagger_bwd_heavy_4 = 2.64, -- 5
			stagger_bwd_light = 0.74, -- 66
			stagger_bwd_light_2 = 0.71, -- 43
			stagger_bwd_light_3 = 0.69, -- 63
			stagger_bwd_light_4 = 0.67, -- 53
			stagger_bwd_light_5 = 0.74, -- 60
			stagger_bwd_light_6 = 0.88, -- 40
			stagger_bwd_light_7 = 0.81, -- 53
			stagger_bwd_light_8 = 0.71, -- 47
			stagger_fwd = 1.18, -- 7
			stagger_fwd_2 = 1.20, -- 5
			stagger_fwd_3 = 1.12, -- 5
			stagger_fwd_4 = 1.18, -- 4
			stagger_fwd_heavy_2 = 2.96, -- 1
			stagger_fwd_light = 0.74, -- 20
			stagger_fwd_light_2 = 0.74, -- 13
			stagger_fwd_light_3 = 0.74, -- 14
			stagger_fwd_light_4 = 0.97, -- 23
			stagger_fwd_light_5 = 0.98, -- 15
			stagger_fwd_light_6 = 0.97, -- 14
			stagger_left = 0.84, -- 15
			stagger_left_2 = 1.20, -- 13
			stagger_left_3 = 1.38, -- 13
			stagger_left_4 = 1.38, -- 8
			stagger_left_5 = 1.15, -- 26
			stagger_left_heavy = 2.58, -- 2
			stagger_left_heavy_3 = 2.52, -- 3
			stagger_left_heavy_4 = 2.63, -- 2
			stagger_left_light = 0.74, -- 52
			stagger_left_light_2 = 0.88, -- 38
			stagger_left_light_3 = 0.88, -- 37
			stagger_left_light_4 = 0.86, -- 37
			stagger_right = 1.10, -- 24
			stagger_right_2 = 1.35, -- 13
			stagger_right_3 = 1.36, -- 20
			stagger_right_4 = 1.23, -- 11
			stagger_right_5 = 1.20, -- 16
			stagger_right_heavy = 1.97, -- 5
			stagger_right_heavy_2 = 2.54, -- 2
			stagger_right_heavy_3 = 2.55, -- 2
			stagger_right_heavy_4 = 2.73, -- 1
			stagger_right_light = 0.74, -- 45
			stagger_right_light_2 = 0.76, -- 38
			stagger_right_light_3 = 0.95, -- 54
			stagger_right_light_4 = 0.74, -- 81
			stagger_up_heavy = 3.59, -- 6
			stagger_up_heavy_2 = 3.40, -- 3
			stagger_up_heavy_3 = 3.49, -- 7
			stun_bwd_ranged_light = 1.69, -- 1
			stun_down = 0.69, -- 1
		},
		chaos_marauder = {
			stagger_bwd = 1.27, -- 47
			stagger_bwd_2 = 1.40, -- 73
			stagger_bwd_3 = 1.37, -- 69
			stagger_bwd_4 = 1.29, -- 57
			stagger_bwd_heavy = 2.52, -- 1
			stagger_bwd_heavy_2 = 2.92, -- 3
			stagger_bwd_heavy_3 = 2.48, -- 1
			stagger_bwd_heavy_4 = 2.57, -- saved average
			stagger_bwd_light = 0.74, -- 190
			stagger_bwd_light_2 = 0.71, -- 168
			stagger_bwd_light_3 = 0.69, -- 155
			stagger_bwd_light_4 = 0.67, -- 157
			stagger_bwd_light_5 = 0.74, -- 177
			stagger_bwd_light_6 = 0.88, -- 146
			stagger_bwd_light_7 = 0.81, -- 150
			stagger_bwd_light_8 = 0.71, -- 160
			stagger_explosion_back_2 = 4.21, -- 1
			stagger_fwd = 1.18, -- 5
			stagger_fwd_2 = 1.20, -- 8
			stagger_fwd_3 = 1.13, -- 6
			stagger_fwd_4 = 1.17, -- 4
			stagger_fwd_light = 0.74, -- 32
			stagger_fwd_light_2 = 0.74, -- 40
			stagger_fwd_light_3 = 0.74, -- 32
			stagger_fwd_light_4 = 0.98, -- 25
			stagger_fwd_light_5 = 0.98, -- 26
			stagger_fwd_light_6 = 0.98, -- 25
			stagger_left = 0.97, -- 9
			stagger_left_2 = 1.20, -- 12
			stagger_left_3 = 1.38, -- 8
			stagger_left_4 = 1.38, -- 16
			stagger_left_5 = 1.15, -- 7
			stagger_left_heavy = 2.58, -- 1
			stagger_left_heavy_2 = 2.77, -- 1
			stagger_left_heavy_4 = 2.63, -- 2
			stagger_left_light = 0.74, -- 145
			stagger_left_light_2 = 0.88, -- 133
			stagger_left_light_3 = 0.88, -- 117
			stagger_left_light_4 = 0.86, -- 138
			stagger_right = 1.10, -- 12
			stagger_right_2 = 1.36, -- 8
			stagger_right_3 = 1.36, -- 9
			stagger_right_4 = 1.22, -- 14
			stagger_right_5 = 1.19, -- 7
			stagger_right_heavy = 1.97, -- 2
			stagger_right_heavy_4 = 2.74, -- saved average
			stagger_right_light = 0.74, -- 152
			stagger_right_light_2 = 0.76, -- 135
			stagger_right_light_3 = 0.95, -- 117
			stagger_right_light_4 = 0.74, -- 129
			stagger_up_heavy = 3.52, -- 1
			stagger_up_heavy_2 = 3.41, -- saved average
			stagger_up_heavy_3 = 3.38, -- saved average
			stun_bwd_ranged_light = 1.69, -- 1
			stun_bwd_ranged_light_2 = 1.39, -- 1
			stun_bwd_ranged_light_3 = 2.05, -- 1
			stun_down = 0.86, -- 22
			stun_fwd_ranged_light_3 = 1.98, -- 1
			stun_right_ranged_light_2 = 1.56, -- 1
		},
		chaos_marauder_with_shield = {
			stagger_bwd = 1.15, -- 6
			stagger_bwd_2 = 1.27, -- 3
			stagger_bwd_3 = 1.18, -- 4
			stagger_bwd_4 = 1.12, -- 2
			stagger_bwd_heavy_2 = 2.85, -- 1
			stagger_bwd_heavy_4 = 2.58, -- 1
			stagger_bwd_light = 0.74, -- 10
			stagger_bwd_light_2 = 0.72, -- 8
			stagger_bwd_light_3 = 0.69, -- 8
			stagger_bwd_light_4 = 0.67, -- 9
			stagger_bwd_light_5 = 0.74, -- 15
			stagger_bwd_light_6 = 0.88, -- 12
			stagger_bwd_light_7 = 0.81, -- 8
			stagger_bwd_light_8 = 0.71, -- 6
			stagger_bwd_shield = 3.07, -- 1
			stagger_bwd_shield_light = 2.61, -- 9
			stagger_fwd = 1.18, -- 1
			stagger_fwd_2 = 1.20, -- 5
			stagger_fwd_3 = 1.13, -- 1
			stagger_fwd_4 = 1.18, -- 3
			stagger_fwd_light = 0.73, -- 3
			stagger_fwd_light_2 = 0.74, -- 3
			stagger_fwd_light_3 = 0.73, -- 3
			stagger_fwd_light_4 = 0.98, -- 1
			stagger_fwd_light_5 = 0.98, -- 3
			stagger_fwd_light_6 = 0.98, -- 2
			stagger_left = 0.85, -- 1
			stagger_left_2 = 1.20, -- 2
			stagger_left_light = 0.74, -- 7
			stagger_left_light_2 = 0.88, -- 5
			stagger_left_light_3 = 0.88, -- 4
			stagger_left_light_4 = 0.85, -- 7
			stagger_left_shield_light = 2.63, -- 2
			stagger_medium_downward_2 = 1.86, -- 1
			stagger_right = 1.10, -- 1
			stagger_right_3 = 1.45, -- 2
			stagger_right_5 = 1.20, -- 1
			stagger_right_light = 0.74, -- 6
			stagger_right_light_2 = 0.77, -- 9
			stagger_right_light_3 = 0.95, -- 4
			stagger_right_light_4 = 0.91, -- 5
			stagger_right_shield_light = 2.86, -- 7
			stagger_shield_light = 1.82, -- 50
			stagger_shield_medium = 2.33, -- 5
			stagger_shield_medium_break = 1.19, -- 14
			stun_bwd_ranged_light_2 = 1.39, -- 1
		},
		skaven_clan_rat = {
			stagger_bwd = 0.99, -- 234
			stagger_bwd_2 = 0.92, -- 220
			stagger_bwd_3 = 0.86, -- 192
			stagger_bwd_4 = 1.06, -- 154
			stagger_bwd_5 = 0.86, -- 177
			stagger_bwd_exp = 3.57, -- 48
			stagger_bwd_exp_2 = 3.82, -- 41
			stagger_bwd_fall = 2.05, -- 8
			stagger_bwd_fall_2 = 1.42, -- 11
			stagger_bwd_heavy = 1.62, -- 4
			stagger_bwd_heavy_2 = 1.72, -- 3
			stagger_bwd_heavy_3 = 2.01, -- 5
			stagger_bwd_heavy_4 = 1.82, -- 9
			stagger_fwd = 0.99, -- 43
			stagger_fwd_2 = 1.02, -- 25
			stagger_fwd_3 = 0.99, -- 18
			stagger_fwd_4 = 1.02, -- 26
			stagger_fwd_exp = 2.42, -- 4
			stagger_fwd_exp_2 = 2.66, -- 6
			stagger_left = 0.96, -- 75
			stagger_left_2 = 0.92, -- 61
			stagger_left_3 = 0.89, -- 72
			stagger_left_4 = 1.02, -- 69
			stagger_left_exp = 3.16, -- 11
			stagger_left_exp_2 = 3.52, -- 9
			stagger_left_heavy = 1.52, -- 2
			stagger_left_heavy_2 = 1.90, -- 1
			stagger_left_heavy_4 = 2.01, -- 3
			stagger_left_heavy_5 = 1.85, -- 2
			stagger_right = 0.96, -- 67
			stagger_right_2 = 0.96, -- 48
			stagger_right_3 = 0.96, -- 62
			stagger_right_4 = 1.12, -- 50
			stagger_right_exp = 3.59, -- 13
			stagger_right_exp_2 = 3.06, -- 20
			stagger_right_heavy = 2.08, -- 1
			stagger_right_heavy_2 = 2.09, -- 2
			stagger_right_heavy_3 = 1.42, -- 2
			stagger_right_heavy_5 = 1.51, -- 2
			stun_bwd_sword = 0.63, -- 291
			stun_down = 0.64, -- 11
			stun_fwd_ranged_light = 0.62, -- 1
			stun_fwd_ranged_light_2 = 0.63, -- 1
			stun_fwd_sword = 0.62, -- 1917
			stun_left_ranged_light_2 = 0.63, -- 1
			stun_left_sword = 0.62, -- 252
			stun_left_sword_2 = 0.62, -- 258
			stun_left_sword_3 = 0.62, -- 287
			stun_right_ranged_light = 0.63, -- 1
			stun_right_sword = 0.62, -- 277
			stun_right_sword_2 = 0.62, -- 267
			stun_right_sword_3 = 0.62, -- 246
		},
		skaven_clan_rat_with_shield = {
			stagger_bwd = 0.96, -- 69
			stagger_bwd_2 = 0.89, -- 53
			stagger_bwd_exp = 3.60, -- 6
			stagger_bwd_exp_2 = 3.60, -- 2
			stagger_bwd_fall_2 = 1.45, -- 2
			stagger_bwd_shield = 0.86, -- 12
			stagger_bwd_shield_2 = 0.86, -- 15
			stagger_bwd_shield_3 = 0.96, -- 10
			stagger_bwd_shield_light = 0.62, -- 199
			stagger_bwd_shield_up_2 = 0.99, -- 1
			stagger_bwd_shield_up_light = 0.66, -- 119
			stagger_bwd_shield_up_light_head = 0.76, -- 8
			stagger_fwd = 0.96, -- 17
			stagger_fwd_exp_2 = 4.09, -- 1
			stagger_left = 0.96, -- 6
			stagger_left_2 = 0.96, -- 7
			stagger_left_3 = 0.82, -- 9
			stagger_left_4 = 0.99, -- 11
			stagger_left_exp = 3.19, -- 1
			stagger_left_exp_2 = 3.42, -- 2
			stagger_left_heavy = 1.53, -- 1
			stagger_left_heavy_3 = 1.53, -- 2
			stagger_left_shield = 0.96, -- 9
			stagger_left_shield_light = 0.62, -- 24
			stagger_left_shield_up = 0.99, -- 2
			stagger_left_shield_up_light = 0.66, -- 17
			stagger_right = 0.95, -- 3
			stagger_right_2 = 0.96, -- 4
			stagger_right_3 = 0.96, -- 7
			stagger_right_4 = 0.96, -- 5
			stagger_right_heavy = 2.10, -- 1
			stagger_right_shield = 0.96, -- 7
			stagger_right_shield_light = 0.63, -- 24
			stagger_right_shield_up = 0.99, -- 4
			stagger_right_shield_up_light = 0.66, -- 12
			stagger_shield_break_bwd = 0.86, -- 20
			stagger_shield_break_left = 0.85, -- 3
			stun_bwd_sword = 0.66, -- 34
			stun_down = 0.62, -- 2
			stun_fwd_sword = 0.82, -- 82
			stun_left_sword = 0.66, -- 10
			stun_left_sword_2 = 0.66, -- 19
			stun_left_sword_3 = 0.66, -- 13
			stun_right_sword = 0.66, -- 16
			stun_right_sword_2 = 0.66, -- 12
			stun_right_sword_3 = 0.67, -- 11
		},
		skaven_plague_monk = {
			stagger_bwd = 1.02, -- 17
			stagger_bwd_2 = 0.92, -- 8
			stagger_right = 1.02, -- 2
			stun_bwd_sword = 0.69, -- 2
			stun_fwd_sword = 0.69, -- 20
			stun_right_sword = 0.66, -- 29
		},
		skaven_slave = {
			stagger_bwd = 0.99, -- 393
			stagger_bwd_2 = 0.92, -- 369
			stagger_bwd_3 = 0.85, -- 405
			stagger_bwd_4 = 1.05, -- 429
			stagger_bwd_5 = 0.85, -- 396
			stagger_bwd_exp = 3.57, -- 22
			stagger_bwd_exp_2 = 3.83, -- 12
			stagger_bwd_fall = 2.05, -- 12
			stagger_bwd_fall_2 = 1.42, -- 13
			stagger_bwd_heavy = 1.61, -- 16
			stagger_bwd_heavy_2 = 1.72, -- 12
			stagger_bwd_heavy_3 = 2.02, -- 9
			stagger_bwd_heavy_4 = 1.81, -- 9
			stagger_fwd = 0.99, -- 71
			stagger_fwd_2 = 1.02, -- 40
			stagger_fwd_3 = 0.99, -- 39
			stagger_fwd_4 = 1.02, -- 37
			stagger_fwd_exp = 2.42, -- 3
			stagger_fwd_exp_2 = 2.66, -- 3
			stagger_left = 0.96, -- 107
			stagger_left_2 = 0.92, -- 79
			stagger_left_3 = 0.89, -- 90
			stagger_left_4 = 1.02, -- 119
			stagger_left_exp = 3.16, -- 5
			stagger_left_exp_2 = 3.53, -- 3
			stagger_left_heavy = 1.52, -- 2
			stagger_left_heavy_3 = 1.55, -- 7
			stagger_left_heavy_4 = 2.02, -- 5
			stagger_left_heavy_5 = 1.85, -- 7
			stagger_right = 0.95, -- 118
			stagger_right_2 = 0.95, -- 97
			stagger_right_3 = 0.95, -- 113
			stagger_right_4 = 1.12, -- 121
			stagger_right_exp = 3.59, -- 3
			stagger_right_exp_2 = 3.06, -- 6
			stagger_right_heavy = 2.09, -- 1
			stagger_right_heavy_3 = 1.42, -- 4
			stagger_right_heavy_4 = 1.82, -- 1
			stun_bwd_sword = 0.80, -- 235
			stun_down = 0.62, -- 1
			stun_fwd_sword = 0.62, -- 1571
			stun_left_sword = 0.62, -- 197
			stun_left_sword_2 = 0.62, -- 225
			stun_left_sword_3 = 0.62, -- 179
			stun_right_sword = 0.62, -- 296
			stun_right_sword_2 = 0.62, -- 272
			stun_right_sword_3 = 0.62, -- 338
		},
	},
	cue = {
		chaos_marauder = {
			blocked = 0.95, -- 34
		},
		skaven_clan_rat = {
			blocked = 0.81, -- 114
			blocked_2 = 1.01, -- 140
			blocked_3 = 0.68, -- 139
		},
		skaven_slave = {
			blocked = 0.82, -- 14
			blocked_2 = 1.02, -- 13
			blocked_3 = 0.69, -- 6
		},
	},
}

local function load(kind)
	local saved = mod:get(SETTINGS[kind])
	local clean = {}

	if type(saved) ~= "table" then
		return clean
	end

	for breed_name, by_anim in pairs(saved) do
		if type(breed_name) == "string" and type(by_anim) == "table" then
			local values = {}

			for anim, seconds in pairs(by_anim) do
				if type(anim) == "string" and type(seconds) == "number" and seconds >= MIN_SECONDS[kind] and seconds <= MAX_SECONDS then
					values[anim] = seconds
				end
			end

			clean[breed_name] = values
		end
	end

	return clean
end

local measured = {}
local dirty = {}

for kind in pairs(SETTINGS) do
	local ok, values = pcall(load, kind)

	measured[kind] = ok and values or {}

	if not ok then
		pc.print("could not read the saved %s: %s", SETTINGS[kind], tostring(values))
	end
end

-- The timing for this breed's animation: this machine's measurement, else the shipped default, else nil.
function timings.get(kind, breed_name, anim)
	local own = measured[kind][breed_name]
	local value = own and own[anim]

	if value then
		return value
	end

	local default = DEFAULTS[kind][breed_name]

	return default and default[anim] or nil
end

-- after: for a recoil cue, the animation of the attack that was blocked, if known. It only goes into the log line
-- (build 3.1: the fanatic's cue seems to depend on it, see pc.VARIABLE_CUE_BREEDS).
function timings.learn(kind, breed_name, anim, seconds, after)
	if type(breed_name) ~= "string" or type(anim) ~= "string" or type(seconds) ~= "number" then
		return
	end

	local known = timings.get(kind, breed_name, anim)
	local suffix = type(after) == "string" and " after=" .. after or ""

	if seconds < MIN_SECONDS[kind] or seconds > MAX_SECONDS or known and seconds < known * MIN_SHARE then
		pc.count("timings_ignored_" .. kind)
		pc.log("timing %s breed=%s anim=%s seconds=%.3f%s ignored: not this animation's own (known %s)", kind, breed_name, anim, seconds, suffix, known and string.format("%.3f", known) or "none")

		return
	end

	-- Measured against the shipped value only: against a value this machine learned, one short stray reading for an
	-- animation without a default would lock out every true reading after it.
	local default = DEFAULTS[kind][breed_name] and DEFAULTS[kind][breed_name][anim]

	if default and seconds > default * MAX_SHARE then
		pc.count("timings_ignored_" .. kind)
		pc.log("timing %s breed=%s anim=%s seconds=%.3f%s ignored: far longer than this animation's own (shipped %.3f)", kind, breed_name, anim, seconds, suffix, default)

		return
	end

	local by_anim = measured[kind][breed_name]

	if not by_anim then
		by_anim = {}
		measured[kind][breed_name] = by_anim
	end

	-- The first reading here moves the shipped default instead of replacing it, so one stray reading can't (the 2.2
	-- host's first marauder cue, 1.66 s, replaced the shipped 0.95 s).
	local old = by_anim[anim] or known

	by_anim[anim] = old and old + (seconds - old) * LEARN_WEIGHT or seconds
	dirty[kind] = true

	pc.count("timings_measured_" .. kind)
	pc.log("timing %s breed=%s anim=%s seconds=%.3f%s", kind, breed_name, anim, seconds, suffix)
end

local function known(kind)
	local all = {}

	for breed_name, by_anim in pairs(DEFAULTS[kind]) do
		all[breed_name] = all[breed_name] or {}

		for anim, seconds in pairs(by_anim) do
			all[breed_name][anim] = seconds
		end
	end

	for breed_name, by_anim in pairs(measured[kind]) do
		all[breed_name] = all[breed_name] or {}

		for anim, seconds in pairs(by_anim) do
			all[breed_name][anim] = seconds
		end
	end

	return all
end

-- How many animations have a timing, and how many of those this machine measured itself.
function timings.count(kind)
	local total, own = 0, 0

	for breed_name, by_anim in pairs(known(kind)) do
		for anim in pairs(by_anim) do
			total = total + 1

			if measured[kind][breed_name] and measured[kind][breed_name][anim] then
				own = own + 1
			end
		end
	end

	return total, own
end

local function sorted_keys(t)
	local keys = {}

	for key in pairs(t) do
		keys[#keys + 1] = key
	end

	table.sort(keys)

	return keys
end

-- /pingcomp timings: everything known, in the form DEFAULTS uses, one line per animation.
function timings.dump()
	for _, kind in ipairs({ "length", "cue" }) do
		local all = known(kind)

		pc.print("timings %s = {", kind)

		for _, breed_name in ipairs(sorted_keys(all)) do
			pc.print("timings 	%s = {", breed_name)

			for _, anim in ipairs(sorted_keys(all[breed_name])) do
				local own = measured[kind][breed_name] and measured[kind][breed_name][anim]

				pc.print("timings 		%s = %.2f,%s", anim, all[breed_name][anim], own and "" or " -- default")
			end

			pc.print("timings 	},")
		end

		pc.print("timings },")
	end
end

function timings.save()
	for kind in pairs(dirty) do
		local ok, message = pcall(mod.set, mod, SETTINGS[kind], measured[kind])

		if not ok then
			pc.print("could not save %s: %s", SETTINGS[kind], tostring(message))
		end
	end

	dirty = {}
end
