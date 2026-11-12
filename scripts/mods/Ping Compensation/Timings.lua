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
local LEARN_WEIGHT = 0.3 -- how far a new measurement moves a value this machine has measured before
-- Builds before 2.2 saved under "stagger_lengths" and "recoil_cues", polluted by those readings and by recoils the
-- host started late, so those are no longer read.
local SETTINGS = {
	length = "stagger_lengths_2",
	cue = "recoil_cues_2",
}

-- Seconds: the median of each animation's readings from the 2026-11-12 playtests (host and client stagger lengths,
-- the client's recoil cues), with how many there were. Readings under 0.3 s or under half the median were dropped.
-- "saved average": measured on the testers' machines in earlier sessions, not in these logs.
local DEFAULTS = {
	length = {
		chaos_fanatic = {
			stagger_bwd = 1.27, -- 20
			stagger_bwd_2 = 1.43, -- 26
			stagger_bwd_3 = 1.33, -- 20
			stagger_bwd_4 = 1.12, -- 17
			stagger_bwd_heavy = 2.67, -- 10
			stagger_bwd_heavy_2 = 2.92, -- 11
			stagger_bwd_heavy_3 = 2.66, -- 9
			stagger_bwd_heavy_4 = 2.64, -- 5
			stagger_bwd_light = 0.74, -- saved average
			stagger_bwd_light_2 = 0.71, -- 1
			stagger_bwd_light_3 = 0.68, -- saved average
			stagger_bwd_light_4 = 0.66, -- saved average
			stagger_bwd_light_5 = 0.73, -- saved average
			stagger_bwd_light_6 = 0.87, -- saved average
			stagger_bwd_light_7 = 0.81, -- saved average
			stagger_bwd_light_8 = 0.71, -- saved average
			stagger_fwd = 1.17, -- saved average
			stagger_fwd_2 = 1.20, -- 1
			stagger_fwd_3 = 1.12, -- saved average
			stagger_fwd_light = 0.73, -- saved average
			stagger_fwd_light_5 = 0.97, -- saved average
			stagger_left = 0.83, -- 4
			stagger_left_2 = 1.20, -- 2
			stagger_left_3 = 1.38, -- 4
			stagger_left_4 = 1.38, -- 3
			stagger_left_5 = 1.22, -- 6
			stagger_left_heavy_3 = 2.52, -- 3
			stagger_left_heavy_4 = 2.63, -- 1
			stagger_left_light = 0.73, -- 1
			stagger_left_light_2 = 0.87, -- saved average
			stagger_left_light_3 = 0.88, -- 3
			stagger_left_light_4 = 0.85, -- 2
			stagger_right = 1.10, -- 5
			stagger_right_2 = 1.35, -- 1
			stagger_right_3 = 1.36, -- 2
			stagger_right_4 = 1.22, -- 3
			stagger_right_5 = 1.20, -- 2
			stagger_right_heavy = 1.97, -- 1
			stagger_right_heavy_2 = 2.54, -- saved average
			stagger_right_heavy_3 = 2.55, -- 2
			stagger_right_heavy_4 = 2.73, -- 1
			stagger_right_light = 0.73, -- 1
			stagger_right_light_2 = 0.75, -- saved average
			stagger_right_light_3 = 0.95, -- saved average
			stagger_right_light_4 = 0.73, -- 4
			stagger_up_heavy = 3.59, -- 6
			stagger_up_heavy_2 = 3.40, -- 2
			stagger_up_heavy_3 = 3.49, -- 7
		},
		chaos_marauder = {
			stagger_bwd = 1.27, -- 22
			stagger_bwd_2 = 1.40, -- 39
			stagger_bwd_3 = 1.37, -- 38
			stagger_bwd_4 = 1.29, -- 22
			stagger_bwd_heavy_2 = 2.92, -- 3
			stagger_bwd_heavy_3 = 2.48, -- 1
			stagger_bwd_heavy_4 = 2.57, -- saved average
			stagger_bwd_light = 0.88, -- 6
			stagger_bwd_light_2 = 0.80, -- 3
			stagger_bwd_light_3 = 0.78, -- 9
			stagger_bwd_light_4 = 0.66, -- 3
			stagger_bwd_light_5 = 0.73, -- 5
			stagger_bwd_light_6 = 0.87, -- 3
			stagger_bwd_light_7 = 0.80, -- 6
			stagger_bwd_light_8 = 0.71, -- 4
			stagger_fwd = 1.18, -- 1
			stagger_fwd_3 = 1.12, -- saved average
			stagger_fwd_4 = 1.17, -- saved average
			stagger_fwd_light = 0.74, -- saved average
			stagger_fwd_light_2 = 0.73, -- saved average
			stagger_left = 0.97, -- 5
			stagger_left_3 = 1.38, -- 1
			stagger_left_4 = 1.43, -- 4
			stagger_left_5 = 1.14, -- 1
			stagger_left_heavy_4 = 2.63, -- saved average
			stagger_left_light = 0.73, -- 5
			stagger_left_light_2 = 0.96, -- 13
			stagger_left_light_3 = 0.88, -- 9
			stagger_left_light_4 = 0.99, -- 12
			stagger_right = 1.10, -- 4
			stagger_right_2 = 1.36, -- 2
			stagger_right_3 = 1.35, -- 2
			stagger_right_4 = 1.22, -- 5
			stagger_right_5 = 1.19, -- 3
			stagger_right_heavy = 1.97, -- saved average
			stagger_right_heavy_4 = 2.74, -- saved average
			stagger_right_light = 0.90, -- 7
			stagger_right_light_2 = 0.85, -- 4
			stagger_right_light_3 = 1.03, -- 8
			stagger_right_light_4 = 0.82, -- 3
			stagger_up_heavy = 3.52, -- 1
			stagger_up_heavy_2 = 3.41, -- saved average
			stagger_up_heavy_3 = 3.38, -- saved average
		},
		skaven_clan_rat = {
			stagger_bwd = 0.98, -- 19
			stagger_bwd_2 = 0.92, -- 21
			stagger_bwd_3 = 0.85, -- 27
			stagger_bwd_4 = 1.05, -- 22
			stagger_bwd_5 = 0.85, -- 13
			stagger_bwd_fall = 2.05, -- 4
			stagger_bwd_fall_2 = 1.42, -- 4
			stagger_bwd_heavy_3 = 2.01, -- 5
			stagger_bwd_heavy_4 = 1.82, -- 7
			stagger_fwd = 0.98, -- 7
			stagger_fwd_4 = 1.02, -- 2
			stagger_left_2 = 0.92, -- 4
			stagger_left_3 = 0.88, -- 1
			stagger_left_4 = 1.01, -- 2
			stagger_left_heavy = 1.52, -- 2
			stagger_left_heavy_4 = 2.01, -- 2
			stagger_right = 0.95, -- 2
			stagger_right_2 = 0.94, -- 1
			stagger_right_3 = 0.95, -- 2
			stagger_right_4 = 1.11, -- 4
			stagger_right_heavy_2 = 2.09, -- saved average
			stagger_right_heavy_3 = 1.42, -- saved average
			stagger_right_heavy_5 = 1.51, -- 2
			stun_bwd_sword = 0.87, -- 17
			stun_fwd_sword = 0.62, -- 167
			stun_left_sword = 0.61, -- 16
			stun_left_sword_2 = 0.61, -- 18
			stun_left_sword_3 = 0.61, -- 7
			stun_right_sword = 0.62, -- 46
			stun_right_sword_2 = 0.62, -- 50
			stun_right_sword_3 = 0.62, -- 41
		},
		skaven_clan_rat_with_shield = {
			stagger_bwd_shield_light = 0.62, -- 13
			stagger_bwd_shield_up_light = 0.65, -- 2
			stagger_bwd_shield_up_light_head = 0.75, -- 2
			stun_down = 0.62, -- 2
			stun_fwd_sword = 0.82, -- 2
			stun_left_sword_2 = 0.64, -- 1
		},
		skaven_slave = {
			stagger_bwd = 0.98, -- 73
			stagger_bwd_2 = 0.92, -- 83
			stagger_bwd_3 = 0.85, -- 51
			stagger_bwd_4 = 1.05, -- 89
			stagger_bwd_5 = 0.85, -- 70
			stagger_bwd_fall = 2.05, -- 8
			stagger_bwd_fall_2 = 1.42, -- 6
			stagger_bwd_heavy = 1.61, -- 6
			stagger_bwd_heavy_2 = 1.71, -- 1
			stagger_bwd_heavy_3 = 2.02, -- 4
			stagger_bwd_heavy_4 = 1.81, -- 4
			stagger_fwd = 0.98, -- 10
			stagger_fwd_2 = 1.02, -- 4
			stagger_fwd_3 = 0.99, -- 12
			stagger_fwd_4 = 1.02, -- 12
			stagger_left = 0.95, -- 13
			stagger_left_2 = 0.92, -- 9
			stagger_left_3 = 0.88, -- 11
			stagger_left_4 = 1.02, -- 16
			stagger_left_heavy_3 = 1.55, -- 5
			stagger_left_heavy_4 = 2.02, -- 2
			stagger_left_heavy_5 = 1.85, -- 2
			stagger_right = 0.95, -- 7
			stagger_right_2 = 0.95, -- 8
			stagger_right_3 = 0.95, -- 13
			stagger_right_4 = 1.12, -- 13
			stagger_right_heavy_3 = 1.42, -- 4
			stun_bwd_sword = 0.87, -- 43
			stun_fwd_sword = 0.62, -- 325
			stun_left_sword = 0.61, -- 30
			stun_left_sword_2 = 0.61, -- 40
			stun_left_sword_3 = 0.62, -- 24
			stun_right_sword = 0.62, -- 94
			stun_right_sword_2 = 0.62, -- 98
			stun_right_sword_3 = 0.62, -- 102
		},
	},
	cue = {
		chaos_marauder = {
			blocked = 0.95, -- 23
		},
		skaven_clan_rat = {
			blocked = 0.82, -- 6
			blocked_2 = 1.02, -- 5
			blocked_3 = 0.68, -- 2
		},
		skaven_slave = {
			blocked = 0.82, -- 8
			blocked_2 = 1.02, -- 6
			blocked_3 = 0.69, -- 5
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

function timings.learn(kind, breed_name, anim, seconds)
	if type(breed_name) ~= "string" or type(anim) ~= "string" or type(seconds) ~= "number" then
		return
	end

	local known = timings.get(kind, breed_name, anim)

	if seconds < MIN_SECONDS[kind] or seconds > MAX_SECONDS or known and seconds < known * MIN_SHARE then
		pc.count("timings_ignored_" .. kind)
		pc.log("timing %s breed=%s anim=%s seconds=%.3f ignored: not this animation's own (known %s)", kind, breed_name, anim, seconds, known and string.format("%.3f", known) or "none")

		return
	end

	local by_anim = measured[kind][breed_name]

	if not by_anim then
		by_anim = {}
		measured[kind][breed_name] = by_anim
	end

	local old = by_anim[anim]

	by_anim[anim] = old and old + (seconds - old) * LEARN_WEIGHT or seconds
	dirty[kind] = true

	pc.count("timings_measured_" .. kind)
	pc.log("timing %s breed=%s anim=%s seconds=%.3f", kind, breed_name, anim, seconds)
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
