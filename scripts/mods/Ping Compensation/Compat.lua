local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Difficulty mods (D34). A client works out its own hits with its own copy of the game's enemy data, so that copy has
-- to match the host's:
--   * Deathwish ("Cata 3 & Deathwish", VMF mod "catas"). In Adventure its /deathwish changes the host's tables only,
--     so a client running the same mod switches its own copy on and off to match the host, with that mod's own start
--     and stop. It switches it off again once it hosts itself.
--   * Everything else: host and client fingerprint the enemy data the client's maths reads. When they differ, both are
--     told in chat, and that client's hits are decided on the host until they match again.

local compat = {}

pc.compat = compat

-- Difficulty mods whose switch is mirrored onto clients. Their state is a VMF persistent table with active, start and
-- stop (Managers.vmf.persistent_tables[mod_name][table_name]).
local TOGGLES = {
	{
		key = "deathwish",
		label = "Deathwish",
		mod_name = "catas",
		table_name = "catas",
		workshop_name = "Cata 3 & Deathwish",
	},
}

-- The breeds whose data the client's maths reads: those whose reactions it decides, and those whose swings it judges.
local FINGERPRINT_BREEDS = {
	"beastmen_gor",
	"beastmen_ungor",
	"chaos_berzerker",
	"chaos_fanatic",
	"chaos_marauder",
	"chaos_marauder_with_shield",
	"skaven_clan_rat",
	"skaven_clan_rat_with_shield",
	"skaven_plague_monk",
	"skaven_slave",
	"skaven_storm_vermin_with_shield",
}

local BREED_FIELDS = {
	"armor_category",
	"berzerking_stagger_time",
	"block_stagger_mod",
	"block_stagger_mod_2",
	"boss_staggers",
	"diff_stagger_resist",
	"dodge_timer",
	"hit_mass_counts",
	"hitzone_armor_categories",
	"hitzone_multiplier_types",
	"hitzone_primary_armor_categories",
	"max_health",
	"max_stagger_duration",
	"no_random_stagger_duration",
	"no_stagger_duration",
	"player_dodged_cone",
	"player_dodged_radius",
	"primary_armor_category",
	"race",
	"radius",
	"shield_opening_event",
	"stagger_armor_category",
	"stagger_duration",
	"stagger_duration_difficulty_mod",
	"stagger_duration_mod",
	"stagger_immune",
	"stagger_multiplier",
	"stagger_reduction",
	"stagger_resistance",
	"stagger_resistance_ranged",
	"stagger_threshold_explosion",
	"stagger_threshold_heavy",
	"stagger_threshold_light",
	"stagger_threshold_medium",
	"unbreakable_shield",
	"weapon_reach",
	"weapon_reach_cone",
}

-- The behaviour tree nodes whose action tables the client reads: swings it judges, and the stagger and recoil it plays.
local ACTION_NODES = {
	BTAttackAction = true,
	BTBlockedAction = true,
	BTComboAttackAction = true,
	BTStaggerAction = true,
}

-- The fields of those action tables that the client's maths reads. Only these are fingerprinted, so state the host's
-- AI might keep in an action table can't make two machines look different.
local ACTION_FIELDS = {
	"attack_directions",
	"blocked_anim",
	"blocked_anims",
	"combo_attacks",
	"damage",
	"damage_type",
	"difficulty_duration",
	"dodge_window_duration",
	"dodge_window_start",
	"fatigue_type",
	"hit_react_type",
	"ignore_staggers",
	"max_player_push_speed",
	"moving_stagger_minimum_destination_distance",
	"moving_stagger_threshold",
	"no_block_stagger",
	"player_dodged_cone",
	"player_dodged_radius",
	"player_push_speed",
	"player_push_speed_blocked",
	"scale_animation_speeds",
	"shield_block_anims",
	"shield_break_anims",
	"shield_stagger_anims",
	"stagger_animation_scale",
	"stagger_anims",
	"stagger_reduction",
	"standard_stagger_anims",
	"unblockable",
	"use_box_range",
	"weapon_reach",
}

local SECTIONS = {
	"enemies",
	"actions",
	"difficulty",
	"staggers",
}

local SECTION_LABELS = {
	enemies = "enemy health, armour and stagger resistance",
	actions = "enemy attacks, recoils and staggers",
	difficulty = "difficulty settings",
	staggers = "stagger tables",
}

local MAX_DEPTH = 6
local CHECK_INTERVAL = 1

local fingerprint = nil -- this machine's, until something may have changed it
local started = {} -- toggle key -> true while this client has a toggle on to match its host
local data_state = nil -- client: "matches", "pending" (same data, the host hasn't confirmed yet) or "differs"
local differs_since = nil -- client: when the data last started to differ from the host's
local warned = false -- client: whether the player has been told it differs
local last_toggles = nil
local check_timer = 0

-- Seconds enemy data must differ before either side says so in chat (the hits move to the host at once).
compat.WARN_AFTER = 3

local function toggle_state(toggle)
	local other = get_mod(toggle.mod_name)

	if not other or other.is_enabled and not other:is_enabled() then
		return nil
	end

	local tables = Managers.vmf and Managers.vmf.persistent_tables
	local by_mod = tables and tables[toggle.mod_name]
	local state = by_mod and by_mod[toggle.table_name]

	return type(state) == "table" and state or nil
end

-- The mirrored toggles switched on here, as a comma-separated list of keys ("" for none).
function compat.active_toggles()
	local keys = {}

	for i = 1, #TOGGLES do
		local state = toggle_state(TOGGLES[i])

		if state and state.active then
			keys[#keys + 1] = TOGGLES[i].key
		end
	end

	return table.concat(keys, ",")
end

local function sorted_keys(t)
	local keys = {}

	for key, value in pairs(t) do
		local key_type = type(key)
		local value_type = type(value)

		if (key_type == "string" or key_type == "number") and (value_type == "number" or value_type == "string" or value_type == "boolean" or value_type == "table") then
			keys[#keys + 1] = key
		end
	end

	table.sort(keys, function (a, b)
		local type_a, type_b = type(a), type(b)

		if type_a ~= type_b then
			return type_a < type_b
		end

		return a < b
	end)

	return keys
end

-- Writes a value as text in a fixed order, so the same data gives the same text on every machine.
local function feed(out, value, depth)
	local value_type = type(value)

	if value_type == "number" then
		out[#out + 1] = string.format("%.4f", value)
	elseif value_type == "string" then
		out[#out + 1] = value
	elseif value_type == "boolean" then
		out[#out + 1] = value and "T" or "F"
	elseif value_type == "table" then
		if depth >= MAX_DEPTH then
			out[#out + 1] = "{}"

			return
		end

		out[#out + 1] = "{"

		local keys = sorted_keys(value)

		for i = 1, #keys do
			local key = keys[i]

			out[#out + 1] = tostring(key)
			out[#out + 1] = "="

			feed(out, value[key], depth + 1)
		end

		out[#out + 1] = "}"
	else
		out[#out + 1] = "-"
	end
end

-- djb2, kept exact in a double: the hash stays below 2^32 and h * 33 below 2^38.
local function hash_text(text)
	local hash = 5381
	local length = #text
	local i = 1

	while i <= length do
		local last = math.min(i + 63, length)
		local bytes = { string.byte(text, i, last) }

		for k = 1, #bytes do
			hash = (hash * 33 + bytes[k]) % 4294967296
		end

		i = last + 1
	end

	return string.format("%04x%04x", math.floor(hash / 65536), hash % 65536)
end

local function collect_actions(node, list, depth)
	if type(node) ~= "table" or depth > 30 then
		return
	end

	if ACTION_NODES[node[1]] and type(node.action_data) == "table" then
		list[#list + 1] = {
			name = tostring(node.name or node[1]),
			action = node.action_data,
		}
	end

	for i = 2, #node do
		collect_actions(node[i], list, depth + 1)
	end
end

local function feed_breed(out, name)
	local breed = Breeds[name]

	out[#out + 1] = name

	if breed then
		for j = 1, #BREED_FIELDS do
			out[#out + 1] = BREED_FIELDS[j]

			feed(out, breed[BREED_FIELDS[j]], 0)
		end
	end
end

local function feed_breed_actions(out, name)
	local behaviors = rawget(_G, "BreedBehaviors")
	local breed = Breeds[name]
	local tree = behaviors and breed and breed.behavior and behaviors[breed.behavior]
	local list = {}

	collect_actions(tree, list, 0)
	table.sort(list, function (a, b)
		return a.name < b.name
	end)

	out[#out + 1] = name

	for j = 1, #list do
		local action = list[j].action

		out[#out + 1] = list[j].name

		for k = 1, #ACTION_FIELDS do
			local value = action[ACTION_FIELDS[k]]

			if value ~= nil then
				out[#out + 1] = ACTION_FIELDS[k]

				feed(out, value, 0)
			end
		end
	end
end

local SECTION_FEEDERS = {
	enemies = function (out)
		for i = 1, #FINGERPRINT_BREEDS do
			feed_breed(out, FINGERPRINT_BREEDS[i])
		end
	end,
	actions = function (out)
		for i = 1, #FINGERPRINT_BREEDS do
			feed_breed_actions(out, FINGERPRINT_BREEDS[i])
		end
	end,
	difficulty = function (out)
		feed(out, DifficultySettings, 0)
	end,
	staggers = function (out)
		feed(out, rawget(_G, "ImpactTypeOutput"), 0)
		feed(out, rawget(_G, "DefaultStaggerDuration"), 0)
		feed(out, rawget(_G, "DefaultStaggerDurationModifier"), 0)
		feed(out, rawget(_G, "DefaultStaggerDistanceModifier"), 0)
	end,
}

-- This machine's fingerprint of the enemy data: one 8-character hash per section, joined with "-".
function compat.fingerprint()
	-- A difficulty mod switched on or off here changes the data. The host's reply carries its toggles and its
	-- fingerprint together, so they must agree (2026-11-12: a reply with Deathwish on still had the old fingerprint).
	local toggles = compat.active_toggles()

	if toggles ~= last_toggles then
		last_toggles = toggles
		fingerprint = nil
	end

	if fingerprint then
		return fingerprint
	end

	local parts = {}

	for i = 1, #SECTIONS do
		local out = {}
		local ok, message = pcall(SECTION_FEEDERS[SECTIONS[i]], out)

		if ok then
			parts[i] = hash_text(table.concat(out, "|"))
		else
			parts[i] = "error000"

			pc.print("could not fingerprint the %s: %s", SECTIONS[i], tostring(message))
		end
	end

	fingerprint = table.concat(parts, "-")

	pc.log("enemy data fingerprint %s", fingerprint)

	-- One line per enemy type, so the host's and a client's logs show which enemies differ, which points at the mod
	-- that changes them (2.2 playtest: one client's enemies and attacks differed for an hour, cause unknown).
	if pc.debug then
		for i = 1, #FINGERPRINT_BREEDS do
			local name = FINGERPRINT_BREEDS[i]
			local enemy_out, action_out = {}, {}
			local ok_enemy = pcall(feed_breed, enemy_out, name)
			local ok_actions = pcall(feed_breed_actions, action_out, name)

			pc.log("enemy data breed=%s enemy=%s actions=%s", name, ok_enemy and hash_text(table.concat(enemy_out, "|")) or "error000", ok_actions and hash_text(table.concat(action_out, "|")) or "error000")
		end
	end

	return fingerprint
end

function compat.invalidate()
	fingerprint = nil
end

-- What differs between two fingerprints, in words.
function compat.differences(a, b)
	local labels = {}

	if type(a) ~= "string" or type(b) ~= "string" then
		return "unknown"
	end

	for i = 1, #SECTIONS do
		local first = (i - 1) * 9 + 1

		if string.sub(a, first, first + 7) ~= string.sub(b, first, first + 7) then
			labels[#labels + 1] = SECTION_LABELS[SECTIONS[i]]
		end
	end

	return #labels > 0 and table.concat(labels, ", ") or "nothing"
end

local function start_toggle(toggle, state)
	local ok, message = pcall(state.start)

	compat.invalidate()

	if ok then
		started[toggle.key] = true

		pc.say("The host plays with %s, so it is switched on here too. Your hits follow its rules.", toggle.label)
	else
		pc.print("could not switch %s on: %s", toggle.label, tostring(message))
	end
end

local function stop_toggle(toggle, state, reason)
	local ok, message = pcall(state.stop)

	compat.invalidate()

	started[toggle.key] = nil

	if ok then
		pc.say("%s is switched off here again: %s.", toggle.label, reason)
	else
		pc.print("could not switch %s off: %s", toggle.label, tostring(message))
	end
end

-- Client: switches this machine's difficulty mods to match what the host says it runs. Returns the labels of those the
-- host runs that this machine doesn't have.
local function match_host_toggles(host_toggles)
	local wanted = {}
	local missing = {}

	for key in string.gmatch(type(host_toggles) == "string" and host_toggles or "", "[^,]+") do
		wanted[key] = true
	end

	for i = 1, #TOGGLES do
		local toggle = TOGGLES[i]
		local state = toggle_state(toggle)
		local want = wanted[toggle.key] == true

		if state and type(state.start) == "function" and type(state.stop) == "function" then
			if want and not state.active then
				start_toggle(toggle, state)
			elseif not want and state.active and started[toggle.key] then
				stop_toggle(toggle, state, "the host has it off")
			end
		elseif want then
			missing[#missing + 1] = toggle
		end
	end

	return missing
end

-- Client: called with every reply to a hello. matched is the host's verdict on the fingerprint this client last sent.
function compat.on_host_reply(host_fingerprint, host_toggles, matched)
	local missing = match_host_toggles(host_toggles)
	local own = compat.fingerprint()
	local state

	if type(host_fingerprint) ~= "string" or own ~= host_fingerprint then
		state = "differs"
	elseif matched == true then
		state = "matches"
	else
		state = "pending"
	end

	local now = pc.clock()

	if state ~= data_state then
		if state == "differs" then
			differs_since = differs_since or now
		elseif state == "matches" then
			if warned then
				pc.say("Your enemy data matches the host's again. Your hits are decided on your screen.")
			end

			differs_since = nil
			warned = false
		end

		pc.print("enemy data %s (own %s, host %s)", state, own, tostring(host_fingerprint))

		-- A changed fingerprint goes to the host at once, so it confirms without waiting for the next hello.
		if state == "pending" then
			pc.client.hello_now()
		end

		data_state = state
	end

	-- The hits are decided on the host from the first reply that differs. The warning waits, because a difficulty
	-- mod the host has just switched takes a hello or two to be switched here as well.
	if state == "differs" and not warned and differs_since and now - differs_since >= compat.WARN_AFTER then
		warned = true

		pc.say("Your enemy data differs from the host's (%s). Your hits are decided on the host until it matches.", compat.differences(own, host_fingerprint))

		for i = 1, #missing do
			pc.say("The host plays with %s. Install and enable \"%s\" to match it.", missing[i].label, missing[i].workshop_name)
		end
	end
end

-- Client: whether this machine's enemy data is the host's, as both sides see it.
function compat.matches()
	return data_state == "matches"
end

function compat.state()
	return data_state or "waiting for the host"
end

-- Switches off whatever this client switched on to match a host.
function compat.restore(reason)
	for i = 1, #TOGGLES do
		local toggle = TOGGLES[i]

		if started[toggle.key] then
			local state = toggle_state(toggle)

			if state and state.active and type(state.stop) == "function" then
				stop_toggle(toggle, state, reason)
			else
				started[toggle.key] = nil
			end
		end
	end
end

-- Every frame: notices a difficulty mod switched on or off here, which changes this machine's enemy data, and hands
-- back what a former client switched on once it hosts itself.
function compat.update(dt)
	check_timer = check_timer - dt

	if check_timer > 0 then
		return
	end

	check_timer = CHECK_INTERVAL

	local toggles = compat.active_toggles()

	if toggles ~= last_toggles then
		last_toggles = toggles

		compat.invalidate()
	end

	if next(started) ~= nil and pc.is_server() then
		compat.restore("you are hosting now")
	end
end

-- A new mission or keep: data may have been changed by a mod, and the host must confirm the fingerprint again.
function compat.clear()
	compat.invalidate()

	data_state = nil
	differs_since = nil
	warned = false
end
