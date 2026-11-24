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

-- The breeds whose data the client's maths reads: those whose reactions it decides (pc.REACTION_BREEDS), and every other
-- enemy whose attacks it judges. The host sends a client the attacks of any enemy, bosses included since build 6
-- (Host.lua), so those are every breed whose behaviour tree has one of these nodes. In game version 6.13 that is the
-- bulwark, the lords, the ethereal skeletons of the wizard's tower map, the sorcerers of the skulking sorcerer mutator
-- and of its Chaos Wastes curse, the prologue's clan rat and marauder, chaos_skeleton, and the Necromancer's skeletons,
-- which fight only enemies. They are found from the game's own tables (fingerprint_breeds), so the list keeps up with
-- the game (D57 review: all but the bulwark had been left out of the list written by hand).
local JUDGED_NODES = {
	BTAttackAction = true, -- family A
	BTComboAttackAction = true, -- B
	BTStormVerminAttackAction = true, -- C
	BTStormVerminPushAction = true, -- D
	BTPackMasterAttackAction = true, -- F
	BTCorruptorGrabAction = true,
	BTCrazyJumpAction = true,
	BTRatlingGunnerShootAction = true, -- G
	BTFireProjectileAction = true,
	BTThrowPoisonGlobeAction = true, -- H
	BTWarpfireThrowerShootAction = true,
	BTMeleeOverlapAttackAction = true, -- E (build 6)
	BTMeleeSlamAction = true,
	BTChargeAttackAction = true,
	BTChampionAttackAction = true,
	BTJumpSlamImpactAction = true,
	BTThrowWeaponAction = true,
	BTVomitAction = true, -- build 6.1: the troll's vomit, the stormfiend's beam and Deathrattler's gun, the rings
	BTStormfiendShootAction = true,
	BTStormfiendDualShootAction = true,
	BTChaosSorcererSummoningAction = true,
}

local BREED_FIELDS = {
	"armor_category",
	"armored_boss_damage_reduction",
	"berzerking_stagger_time",
	"block_stagger_mod",
	"block_stagger_mod_2",
	"boost_curve_multiplier_override",
	"boss",
	"boss_damage_reduction",
	"boss_staggers",
	"diff_stagger_resist",
	"dodge_timer",
	"far_vomit",
	"hit_mass_counts",
	"hitzone_armor_categories",
	"hitzone_multiplier_types",
	"hitzone_primary_armor_categories",
	"lord_damage_reduction",
	"max_health",
	"max_stagger_duration",
	"near_vomit",
	"no_random_stagger_duration",
	"no_stagger_duration",
	"player_dodged_cone",
	"player_dodged_radius",
	"primary_armor_category",
	"race",
	"radius",
	"shield_opening_event",
	"small_boss_staggers",
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

-- For an enemy whose reactions the host decides, only the breed fields that judging its attacks reads (Geometry.lua,
-- Client.lua, HitResults.lua), so a change the host alone makes to the rest can't move every client's hits to the host:
-- the Chaos Wastes curse sets its sorcerer's health on the host only (mutator_curse_skulking_sorcerer.lua:36).
local REACH_FIELDS = {
	"dodge_timer",
	"far_vomit", -- build 6.1: the pools a troll's vomit leaves (bt_vomit_action.lua:299)
	"near_vomit",
	"player_dodged_cone",
	"player_dodged_radius",
	"race",
	"radius",
	"weapon_reach",
	"weapon_reach_cone",
}

-- The behaviour tree nodes whose action tables the client reads: swings it judges, and the stagger and recoil it plays.
local ACTION_NODES = {
	BTAttackAction = true,
	BTBlockedAction = true,
	BTComboAttackAction = true,
	BTStaggerAction = true,
	BTStormVerminAttackAction = true,
	BTStormVerminPushAction = true,
	-- Build 5 (D52): the disablers' attacks (family F), and the specials' holds, shooting and the globadier's suicide
	-- run, whose ignore_staggers the client's stagger maths reads.
	BTCorruptorGrabAction = true,
	BTCrazyJumpAction = true,
	BTPackMasterAttackAction = true,
	BTPackMasterDragAction = true,
	BTPackMasterHoistAction = true,
	BTPackMasterInitialPullAction = true,
	BTRatlingGunnerShootAction = true,
	BTSuicideRunAction = true,
	BTTargetPouncedAction = true,
	BTWarpfireThrowerShootAction = true,
	-- Build 5.1 (D52): the archer's arrows (family G) and the globadier's throw, whose impact the client judges (family H).
	BTFireProjectileAction = true,
	BTThrowPoisonGlobeAction = true,
	-- Build 6: the monsters' and lords' attacks (family E), and the troll's down, whose line the client's troll rule
	-- reads (D63).
	BTMeleeOverlapAttackAction = true,
	BTMeleeSlamAction = true,
	BTChargeAttackAction = true,
	BTChampionAttackAction = true,
	BTJumpSlamImpactAction = true,
	BTThrowWeaponAction = true,
	BTTrollDownedAction = true,
	-- Build 6.1: the troll's vomit, the stormfiend's beam and Deathrattler's gun, and the Drachenfels sorcerer's rings,
	-- whose ring_sequence is fed by its fixed fields only, since the host's node writes its progress into it (:957).
	BTVomitAction = true,
	BTStormfiendShootAction = true,
	BTStormfiendDualShootAction = true,
	BTChaosSorcererSummoningAction = true,
}

-- The fields of those action tables that the client's maths reads. Only these are fingerprinted, so state the host's
-- AI might keep in an action table can't make two machines look different. Family E's lists of attacks (attacks,
-- running_attacks, attack_sequence) and the charge's lunge go in whole, each attack with all its own fields; none of
-- the nodes writes to them (build 6).
local ACTION_FIELDS = {
	"aim_animation",
	"aim_cooldown",
	"aim_rotation_override_distance",
	"align_to_target_animation",
	"anim_driven",
	"anticipation_fx",
	"aoe_init_damage",
	"attack_anim",
	"attack_anims",
	"attack_anims_data",
	"attack_directions",
	"attack_sequence",
	"attack_time",
	"attacks",
	"become_downed_hp_percent",
	"blocked_anim",
	"blocked_anims",
	"blocked_damage",
	"blocked_velocity_scale",
	"buff_name",
	"cancel_animation",
	"catapult",
	"catapult_force_z",
	"catapult_on_push_other_targets",
	"catapult_on_push_z",
	"catapult_player",
	"catapult_players",
	"catapult_within_radius",
	"catapulted_player_speed",
	"catch_animation",
	"charge_blocked_animation",
	"charging_animations",
	"close_attack_animation",
	"close_attack_cooldown",
	"close_attack_range",
	"collision_filter",
	"collision_type",
	"combo_attacks",
	"damage",
	"damage_profile_name",
	"damage_type",
	"difficulty_duration",
	"direction",
	"dodge_angle",
	"dodge_distance",
	"dodge_mitigation_radius_squared",
	"dodge_past_push_speed",
	"dodge_window_duration",
	"dodge_window_start",
	"fatigue_type",
	"fire_rate_at_end",
	"fire_rate_at_start",
	"firing_time",
	"fixed_hp_chunks",
	"forward_offset",
	"grab_delay",
	"grabbing_stagger_anims",
	"head_radius",
	"height",
	"hit_during_impact_t",
	"hit_radius",
	"hit_react_type",
	"ignore_dodge",
	"ignore_shield_block",
	"ignore_staggers",
	"impact_animation",
	"impact_push_speed",
	"impact_shove_multiplier",
	"initial_radius",
	"knocked_down_attack_anim",
	"light_weight_projectile_template_name",
	"lunge",
	"max_distance_squared",
	"max_fire_rate_at_percentage",
	"max_impact_push_speed",
	"max_player_push_speed",
	"min_dodge_angle_squared",
	"mode",
	"movement_controlled_rotation",
	"moving_attack",
	"moving_stagger_minimum_destination_distance",
	"moving_stagger_threshold",
	"muzzle_node",
	"muzzle_nodes",
	"near_vomit_distance",
	"no_block_stagger",
	"offset_forward",
	"offset_right",
	"offset_up",
	"overlap_end_angle_offset",
	"overlap_end_time",
	"overlap_start_angle_offset",
	"overlap_start_time",
	"player_dodged_cone",
	"player_dodged_radius",
	"player_push_speed",
	"player_push_speed_blocked",
	"power_level",
	"projectile_gravity",
	"projectile_speed",
	"push",
	"push_speed",
	"push_speed_z",
	"radial_speed_feet_shooting",
	"radial_speed_upper_body_shooting",
	"radius",
	"range",
	"reset_attack_animations",
	"ring_info",
	"rotation_time",
	"rotation_time_step",
	"running_attacks",
	"scale_animation_speeds",
	"shield_block_anims",
	"shield_blocked_fatigue_type",
	"shield_break_anims",
	"shield_stagger_anims",
	"shoot_animation",
	"shoot_cooldown",
	"shove_speed",
	"shove_z_speed",
	"stagger_animation_scale",
	"stagger_anims",
	"stagger_reduction",
	"standard_stagger_anims",
	"start_animation",
	"step_attack_anim",
	"target_dodged_radius",
	"throw_animation",
	"unblockable",
	"unblockable_by_normal_blocks",
	"use_box_range",
	"wall_collision_anim",
	"wave_speed",
	"weapon_reach",
	"weapon_setup",
	"width",
}

-- Build 6.1: the fixed fields of a ring of the Drachenfels sorcerer (breed_chaos_exalted_sorcerer_drachenfels.lua:871).
local RING_FIELDS = {
	"catapult_direction",
	"catapult_strength",
	"delay",
	"position",
	"premination",
}

-- Build 6.1: what a client's copy of a pool reads from its template (BossAreas.lua; liquid_area_damage_extension.lua:26
-- to :106).
local POOL_FIELDS = {
	"above",
	"apply_buff_to_player",
	"below",
	"buff_condition_function",
	"buff_template_name",
	"buff_template_type",
	"cell_size",
	"damage_type",
	"delay",
	"difficulty_direct_damage",
	"do_direct_damage_player",
	"immune_breeds",
	"max_liquid",
}

-- Build 6.1: what a client's copy of a wave reads from its template (BossAreas.lua; damage_wave_extension.lua:61 to :117).
local WAVE_FIELDS = {
	"apply_impact_buff_to_player",
	"buff_wave_impact_name",
	"buff_wave_impact_type",
	"player_push_data",
}

-- Build 6.1: what a client's copy of an enemy blast reads from its template (Blasts.lua, player_target; damage_utils.lua
-- :1131 to :1538, area_damage_system.lua:347 to :449).
local EXPLOSION_FIELDS = {
	"ai_friendly_fire",
	"allow_friendly_fire_override",
	"attacker_power_level_offset",
	"catapult_blocked_multiplier",
	"catapult_force",
	"catapult_force_z",
	"catapult_players",
	"collision_filter",
	"damage_profile",
	"damage_profile_glance",
	"difficulty_power_level",
	"explosion_cone_angle",
	"explosion_forward_scaling",
	"explosion_right_scaling",
	"exponential_falloff",
	"fatigue_type",
	"ignore_attacker_unit",
	"ignore_players",
	"immune_breeds",
	"max_damage_radius",
	"max_damage_radius_max",
	"max_damage_radius_min",
	"no_friendly_fire",
	"only_line_of_sight",
	"player_push_speed",
	"power_level",
	"power_level_glance",
	"power_level_max",
	"power_level_min",
	"radius",
	"radius_max",
	"radius_min",
	"scale_power_level",
	"use_attacker_power_level",
}

-- Build 6.1: the bosses' areas' buffs, which the client starts and ticks itself (BossAreas.lua, D58).
local BOSS_BUFFS = {
	"bile_troll_vomit_face_base",
	"bile_troll_vomit_ground_base",
	"bile_troll_vomit_ground_downed",
	"stormfiend_warpfire_face_base",
	"stormfiend_warpfire_ground_base",
	"plague_wave_face_base",
	"vermintide_face_base",
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

-- The listed fields of a table that it has, each with its name, in the list's order.
local function feed_fields(out, value, fields)
	for i = 1, #fields do
		local field_value = value[fields[i]]

		if field_value ~= nil then
			out[#out + 1] = fields[i]

			feed(out, field_value, 0)
		end
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

local function has_judged_node(node, depth)
	if type(node) ~= "table" or depth > 30 then
		return false
	end

	if JUDGED_NODES[node[1]] then
		return true
	end

	for i = 2, #node do
		if has_judged_node(node[i], depth + 1) then
			return true
		end
	end

	return false
end

local judged_breeds = nil -- worked out once: the game's breeds and trees don't change while it runs

-- The breeds to fingerprint, sorted by name so every machine feeds them in the same order: { name, decides }, where
-- decides says this client decides that enemy's reactions. Bosses count since build 6: the monsters' reactions are
-- decided on clients (D63), and every boss's attacks are judged there (D61); the lords, whose reactions stay with the
-- host (D64), get only the breed fields judging reads (REACH_FIELDS).
local function fingerprint_breeds()
	if judged_breeds then
		return judged_breeds
	end

	local list = {}

	for name, breed in pairs(Breeds) do
		if type(breed) == "table" and breed.name == name then
			local decides = pc.REACTION_BREEDS[name] == true

			if decides or not breed.is_player and has_judged_node(pc.tree_of(breed), 0) then
				list[#list + 1] = {
					name = name,
					decides = decides,
				}
			end
		end
	end

	table.sort(list, function (a, b)
		return a.name < b.name
	end)

	judged_breeds = list

	return list
end

local function feed_breed(out, entry)
	local breed = Breeds[entry.name]
	local fields = entry.decides and BREED_FIELDS or REACH_FIELDS

	out[#out + 1] = entry.name

	if breed then
		for j = 1, #fields do
			out[#out + 1] = fields[j]

			feed(out, breed[fields[j]], 0)
		end
	end
end

local function feed_breed_actions(out, entry)
	local name = entry.name
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

		feed_fields(out, action, ACTION_FIELDS)

		-- Build 6.1: the rings' own data, without what the host's node writes into it as the spell runs.
		if type(action.ring_sequence) == "table" then
			out[#out + 1] = "ring_sequence"

			for k = 1, #action.ring_sequence do
				if type(action.ring_sequence[k]) == "table" then
					feed_fields(out, action.ring_sequence[k], RING_FIELDS)
				end
			end
		end
	end
end

-- Build 6.1: each template of a table, by name, with only the fields judging reads.
local function feed_templates(out, templates, fields)
	if type(templates) ~= "table" then
		return
	end

	local names = sorted_keys(templates)

	for i = 1, #names do
		local template = templates[names[i]]

		if type(template) == "table" then
			out[#out + 1] = tostring(names[i])

			feed_fields(out, template, fields)
		end
	end
end

-- Build 6.1: every explosion template's blast fields that a client's copy of an enemy blast reads (Blasts.lua,
-- player_target), and whether it is a grenade's, whose radius the attacker's grenade buffs raise.
local function feed_explosions(out)
	local templates = rawget(_G, "ExplosionTemplates")

	if type(templates) ~= "table" then
		return
	end

	local names = sorted_keys(templates)

	for i = 1, #names do
		local template = templates[names[i]]

		if type(template) == "table" and type(template.explosion) == "table" then
			out[#out + 1] = tostring(names[i])

			feed(out, template.is_grenade, 0)
			feed_fields(out, template.explosion, EXPLOSION_FIELDS)
		end
	end
end

local SECTION_FEEDERS = {
	enemies = function (out)
		local breeds = fingerprint_breeds()

		for i = 1, #breeds do
			feed_breed(out, breeds[i])
		end
	end,
	actions = function (out)
		local breeds = fingerprint_breeds()

		for i = 1, #breeds do
			feed_breed_actions(out, breeds[i])
		end

		-- Build 5.1 (D52): the shots' and areas' own data, which the client's judging reads (Shots.lua, Areas.lua).
		local blobs = rawget(_G, "DamageBlobTemplates")

		feed(out, rawget(_G, "LightWeightProjectiles"), 0)
		feed(out, rawget(_G, "VortexTemplates"), 0)
		feed(out, blobs and blobs.templates, 0)

		-- D58: the burnings the client ticks itself, from its own copy of their buffs (Areas.lua), and from build 6.1 the
		-- bosses' areas' buffs (BossAreas.lua).
		local buffs = rawget(_G, "BuffTemplates")

		if type(buffs) == "table" then
			feed(out, buffs.warpfire_thrower_ground_base, 0)
			feed(out, buffs.warpfire_thrower_face_base, 0)
			feed(out, buffs.warpfire_thrower_face_base_mutator, 0)

			for i = 1, #BOSS_BUFFS do
				feed(out, buffs[BOSS_BUFFS[i]], 0)
			end
		end

		-- Build 6.1: the pools', the waves' and the blasts' own data (BossAreas.lua, EnemyBlasts.lua).
		local pools = rawget(_G, "LiquidAreaDamageTemplates")
		local waves = rawget(_G, "DamageWaveTemplates")

		feed_templates(out, pools and pools.templates, POOL_FIELDS)
		feed_templates(out, waves and waves.templates, WAVE_FIELDS)
		feed_explosions(out)
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
		local ok_list, breeds = pcall(fingerprint_breeds)

		for i = 1, ok_list and #breeds or 0 do
			local entry = breeds[i]
			local enemy_out, action_out = {}, {}
			local ok_enemy = pcall(feed_breed, enemy_out, entry)
			local ok_actions = pcall(feed_breed_actions, action_out, entry)

			pc.log("enemy data breed=%s reactions=%s enemy=%s actions=%s", entry.name, entry.decides and "client" or "host", ok_enemy and hash_text(table.concat(enemy_out, "|")) or "error000", ok_actions and hash_text(table.concat(action_out, "|")) or "error000")
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
