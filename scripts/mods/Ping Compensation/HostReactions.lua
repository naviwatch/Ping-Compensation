local mod = get_mod("Ping Compensation")
local pc = mod.pc
local host = pc.host

-- Host side of the enemy reactions a client decides (decisions D13, D14, D26 to D28, D31 and D32). The host still
-- runs the enemy; it just takes these decisions from the player who caused them:
--   * A hit from a modded player on an enemy in pc.REACTION_BREEDS: the host books the damage as usual but skips its
--     own stagger, and applies the stagger the client sends instead (pc_stagger), with the same animation, starting
--     from where the client saw the enemy (D27). It plays that stagger faster, or ends it early, by the client's
--     round trip, so the enemy's next move reaches the client just as the stagger ends on their screen (D32).
--   * A kill the client saw (pc_kill): if the hit left the enemy alive here, the host finishes it off, credited to
--     that player.
--   * A recoil the client played after a block: the host plays the same animation from where the client saw the
--     enemy, and ends it one ping early (D14), so the enemy's next move reaches the blocker as their recoil ends. Like
--     vanilla, it waits for both the recoil's timer and its animation's cue, each counted from the blocker's moment;
--     the cue's time into the animation is measured on the host and learned (recoil_cue).
-- Every stagger and recoil a client predicted is acknowledged (pc_reaction_ack), so a refused one never leaves that
-- client's copy of the enemy out of step for long.

local host_reactions = {}

pc.host_reactions = host_reactions

local FORCE_WAIT = 1 -- seconds a client's stagger or recoil may wait for the enemy's behaviour tree to take it up
local KILL_DELAY = 0.15 -- seconds between a client's kill arriving and the host finishing the enemy off
local TIMED_RECOIL_LIMIT = 3 -- seconds a recoil whose end was brought forward is watched
local MAX_DIRECTION_SQUARED = 64
local MAX_STRING_LENGTH = 64
local MAX_HEIGHT_DIFFERENCE = 1
local CUE_WATCH_LIMIT = 5 -- seconds a recoil animation is watched for its cue
local MIN_HOST_STAGGER = 0.1 -- shortest the host makes a client's stagger
local TIMING_LIMIT = 10 -- seconds a stagger animation is watched for its end cue
local STAGGER_ANIM_TABLES = {
	"stagger_anims",
	"standard_stagger_anims",
	"shield_block_anims",
	"shield_stagger_anims",
	"shield_break_anims",
}

local skip_stagger_for = nil -- the enemy whose vanilla stagger is skipped while the current hit is booked
local skip_capture = nil -- if set, handed the skipped stagger's arguments, so it can still be applied later (Blasts.lua)
local skip_is_blast = false -- the stagger being skipped is a client blast's (Blasts.lua), whose staggers can take longer
local forcing = nil -- the client stagger that BTStaggerAction is entering right now
local staggers = {} -- enemy unit -> client stagger waiting for BTStaggerAction.enter
local recoils = {} -- enemy unit -> client recoil waiting for BTBlockedAction.enter
local timed_recoils = {} -- enemy unit -> running recoil whose end was brought forward (D14)
local recoil_ends = {} -- enemy unit -> running recoil a client's block caused, until BTBlockedAction.leave logs why it ended
local kills = {} -- enemy unit -> client kill waiting to be finished off
local stagger_watch = {} -- enemy unit -> the stagger animation the host is playing for it, until its end cue
local playable = {} -- stagger action table -> set of every animation it can play
local cue_watch = {} -- enemy unit -> the recoil animation the host is playing for it, until its cue
local late_recoils = {} -- enemy unit -> a client's block booked with the recoil left to the host, until its recoil starts
local left_to_client = {} -- enemy unit -> a stagger skipped here, until that client's stagger or kill for it arrives
local answered = {} -- enemy unit -> when a client's stagger or kill for it arrived with no skipped stagger waiting for it
local stunned_drop = {} -- enemy unit -> until when the late anim_cb_stunned_finished of a recoil ended early is dropped
local attack_anims = {} -- enemy unit -> the animation of its latest single attack (BTAttackAction), for the log
local checks = {} -- enemy unit -> the host's own stagger decisions for client hits on it, oldest first (check_hit)
local early_answers = {} -- enemy unit -> client staggers and kills that arrived before the host booked their hit
local LEFT_TO_CLIENT_WAIT = 1 -- seconds; the client sends its stagger or kill right after the hit
local BLAST_LEFT_TO_CLIENT_WAIT = 3 -- seconds; a big blast's staggers reach the host over a second or more
local LATE_RECOIL_WAIT = 1 -- seconds; a booked block's recoil starts within a frame or two, or not at all
local RECOIL_END_LIMIT = 10 -- seconds a recoil is watched for its end
local STUNNED_DROP_MARGIN = 0.25 -- seconds; how much later than expected a recoil's own late stunned cue may come
-- For a client's hits on these, the host still works out its own stagger, without applying it, and logs where it
-- disagrees (check_hit).
local CHECK_BREEDS = pc.CHECK_BREEDS
local stagger_names = {}

for name, value in pairs(pc.stagger_types) do
	stagger_names[value] = name
end

local function ack(peer, kind, id, result)
	mod:network_send("pc_reaction_ack", peer, pc.VERSION, kind, id, result)
end

local function known(lookup, name)
	return type(name) == "string" and #name <= MAX_STRING_LENGTH and rawget(lookup, name) ~= nil
end

local function contains(list, value)
	if type(list) ~= "table" then
		return false
	end

	for i = 1, #list do
		if list[i] == value then
			return true
		end
	end

	return false
end

-- Moves the host's copy to where the client's screen showed the enemy (D27). Nothing happens if that spot is far
-- away, off the navmesh or on another floor: then the reaction starts where the host has the enemy.
-- Returns the distance moved, or nil if it stayed.
local function teleport(unit, blackboard, position)
	local current = POSITION_LOOKUP[unit] or Unit.local_position(unit, 0)
	local offset = position - current
	local flat_distance = Vector3.length(Vector3.flat(offset))

	if flat_distance > pc.TELEPORT_LIMIT or math.abs(offset.z) > MAX_HEIGHT_DIFFERENCE then
		return nil
	end

	if flat_distance < 0.05 then
		return 0
	end

	local nav_world = blackboard.nav_world

	if nav_world and not GwNavQueries.triangle_from_position(nav_world, position, 0.5, 0.5) then
		return nil
	end

	blackboard.locomotion_extension:teleport_to(position, Unit.local_rotation(unit, 0))

	local mover = Unit.mover(unit)

	if mover then
		Mover.set_position(mover, position)
	end

	return flat_distance
end

local function format_distance(distance)
	return distance and string.format("%.2fm", distance) or "no"
end

-- Called from the WeaponSystem.rpc_attack_hit hook. Returns the hit enemy when the attacking player's client decides
-- what this hit does to it, so its vanilla stagger is skipped. The client checks the same things (Reactions.lua).
-- Every hit a client sends counts, whatever the weapon or skill (D31).
function host_reactions.client_decides(channel_id, attacker_unit_id, hit_unit_id)
	local peer = channel_id and CHANNEL_TO_PEER_ID[channel_id]

	if not peer or not host.peer_decides_attacks(peer) then
		return nil
	end

	local unit_storage = Managers.state.unit_storage
	local hit_unit = unit_storage:unit(hit_unit_id)
	local breed = hit_unit and Unit.get_data(hit_unit, "breed")

	if not breed or not pc.REACTION_BREEDS[breed.name] then
		return nil
	end

	local attacker = unit_storage:unit(attacker_unit_id)
	local owner = attacker and Managers.player:owner(attacker)

	if not owner or owner.peer_id ~= peer or owner.bot_player then
		return nil
	end

	return hit_unit
end

-- The engine's ping is the round trip: the testers' host logs match it to the time from the host's damage frame to
-- the client's answer (median 0.223 s each, 246 swings, 2026-11-11).
local function peer_rtt(peer)
	local ping = pc.network():ping_by_peer(peer)

	if type(ping) ~= "number" or ping ~= ping or ping < 0 then
		return 0
	end

	return math.min(ping, 1)
end

local function can_play(action, anim)
	local set = playable[action]

	if not set then
		set = {}

		for i = 1, #STAGGER_ANIM_TABLES do
			local by_type = action[STAGGER_ANIM_TABLES[i]]

			if type(by_type) == "table" then
				for _, by_direction in pairs(by_type) do
					if type(by_direction) == "table" then
						for _, list in pairs(by_direction) do
							if type(list) == "table" then
								for j = 1, #list do
									set[list[j]] = true
								end
							end
						end
					end
				end
			end
		end

		playable[action] = set
	end

	return set[anim] == true
end

-- D32: how the host shortens a client's stagger, so the enemy's next move reaches that client just as the stagger
-- ends on their screen. lead is how much earlier it has to end: the client's round trip, plus however long the stagger
-- waited here for the behaviour tree. The animation's length comes from what this host has measured before
-- (push_finished below); one it hasn't measured yet only gets its timer shortened.
local function plan_timing(node, blackboard, record, t)
	local mode = pc.stagger_timing

	record.timing = "off"

	if mode == "off" then
		return
	end

	local rtt = peer_rtt(record.peer)
	local lead = rtt + math.max(t - record.t, 0)
	local action = node._tree_node and node._tree_node.action_data
	-- D42, D47: only some enemies' stagger animations follow the speed variable (pc.STAGGER_SCALE_BREEDS, from the
	-- probe); the others' end early on the timer. An action that sets its own speed keeps it (vanilla reads it first).
	local scalable = action ~= nil and not action.stagger_animation_scale and pc.STAGGER_SCALE_BREEDS[record.breed_name] == true
	local base_scale = scalable and blackboard.stagger_animation_scale or 1
	local length = pc.timings.get("length", record.breed_name, record.anim)

	record.rtt = rtt
	record.lead = lead
	record.timing = "timer only"

	if not length or base_scale <= 0 then
		return
	end

	local duration = scalable and length / base_scale or length
	local wanted = math.max(duration - lead, MIN_HOST_STAGGER)

	record.duration = duration

	if mode == "speed" and scalable then
		local speed = duration / wanted

		record.base_scale = base_scale

		if speed <= pc.MAX_STAGGER_SPEEDUP then
			record.timing = "sped up"
			record.speed = speed
		else
			record.timing = "sped up, then ended early"
			record.speed = pc.MAX_STAGGER_SPEEDUP
			record.end_at = t + wanted
		end
	else
		record.timing = "ended early"
		record.end_at = t + wanted
	end
end

-- The player's name, for the log. Their peer id is their Steam id, which the log doesn't need.
local function name_of(peer)
	local player = Managers.player and Managers.player:player_from_peer_id(peer)

	return player and player:name() or tostring(peer)
end

local function player_unit(peer)
	local player = Managers.player:player_from_peer_id(peer)
	local unit = player and player.player_unit

	return unit and Unit.alive(unit) and unit or nil
end

local function valid_stagger(id, go_id, stagger_type, duration, length, dx, dy, dz, anim_scale, stagger_value, always_stagger, is_push, anim, yaw, x, y, z, has_position, profile_name, target_index, damage_source)
	return type(id) == "number" and type(go_id) == "number"
		and type(stagger_type) == "number" and stagger_type >= 1 and stagger_type <= 9 and stagger_type == math.floor(stagger_type)
		and type(duration) == "number" and duration >= 0 and duration <= 10
		and type(length) == "number" and length >= 0 and length <= 10
		and type(dx) == "number" and type(dy) == "number" and type(dz) == "number" and dx * dx + dy * dy + dz * dz <= MAX_DIRECTION_SQUARED
		and type(anim_scale) == "number" and anim_scale >= -1 and anim_scale <= 10
		and type(stagger_value) == "number" and stagger_value >= 0 and stagger_value <= 10
		and type(always_stagger) == "boolean" and type(is_push) == "boolean"
		and type(anim) == "string" and #anim <= MAX_STRING_LENGTH and type(yaw) == "number" and yaw == yaw
		and type(x) == "number" and type(y) == "number" and type(z) == "number" and x == x and y == y and z == z
		and type(has_position) == "boolean" and type(profile_name) == "string" and #profile_name <= MAX_STRING_LENGTH
		and type(target_index) == "number" and known(NetworkLookup.damage_sources, damage_source)
end

-- The procs and achievement event that DamageUtils.stagger_ai (damage_utils.lua:3578) runs after a stagger, which
-- the host skipped for this hit.
local function stagger_procs(unit, blackboard, attacker, profile_name, target_index, stagger_type, duration, stagger_value, is_push, damage_source)
	local damage_profile = rawget(DamageProfileTemplates, profile_name)

	if not damage_profile then
		return
	end

	local item_data = rawget(ItemMasterList, damage_source)
	local weapon_template_name = item_data and item_data.template
	local weapon_template = weapon_template_name and WeaponUtils.get_weapon_template(weapon_template_name)
	local buff_type = weapon_template and weapon_template.buff_type or nil
	local index = target_index > 0 and target_index or nil
	local attacker_buffs = ScriptUnit.has_extension(attacker, "buff_system")

	if attacker_buffs and not blackboard.override_stagger then
		Managers.state.achievement:trigger_event("register_ai_stagger", unit, attacker, damage_profile, is_push, stagger_type)
		attacker_buffs:trigger_procs("on_stagger", unit, damage_profile, attacker, stagger_type, duration, stagger_value, buff_type, index)
	end

	local target_buffs = ScriptUnit.has_extension(unit, "buff_system")

	if target_buffs then
		target_buffs:trigger_procs("on_staggered", unit, damage_profile, attacker, stagger_type, duration, stagger_value, buff_type, index)
	end
end

-- Copy of action_ignores_stagger (damage_utils.lua:3537), without the side effect of its "reset_attack" case, which
-- none of CHECK_BREEDS use.
local function action_ignores(blackboard, attack_template, stagger_type)
	if blackboard.anim_cb_stagger_immune then
		return true
	end

	local action = blackboard.action
	local ignore_staggers = action and action.ignore_staggers

	if not ignore_staggers or attack_template.always_stagger then
		return false
	end

	if ignore_staggers.allow_push and attack_template.is_push then
		return false
	end

	local ignore = ignore_staggers[stagger_type]

	if type(ignore) == "table" then
		if ignore.type == "ignore_by_health" then
			local percent = blackboard.current_health_percent or 1

			return percent > ignore.health.min and percent <= ignore.health.max
		end

		return ignore.type == "reset_attack"
	end

	return ignore == true
end

-- What DamageUtils.stagger_ai (damage_utils.lua:3578) would have decided here for a hit whose stagger the client
-- decides, without applying it. Its maths, DamageUtils.calculate_stagger_player, runs as it would have in vanilla, procs
-- included. The one thing it leaves on the enemy, a shield's blocked_previous_attack, is put back (CHECK_BREEDS carry no
-- shield). Not copied: the stagger immunity of elites and bosses, which CHECK_BREEDS don't have.
-- Returns the stagger type (0 for none), why there is none, and the stagger strength the maths worked out.
local function host_would(damage_profile, target_index, power_level, target_unit, attacker_unit, hit_zone_name, boost_curve_multiplier, is_critical_strike, blocked, damage_source)
	local blackboard = BLACKBOARDS[target_unit]
	local target_settings = damage_profile.targets and damage_profile.targets[target_index] or damage_profile.default_target
	local attack_template = target_settings and DamageUtils.get_attack_template(target_settings.attack_template)

	if not blackboard or not attack_template or not attacker_unit or not Unit.alive(attacker_unit) then
		return nil
	end

	local shield = ScriptUnit.has_extension(target_unit, "ai_shield_system")
	local shield_blocked = shield and shield.blocked_previous_attack
	local t = pc.now()
	-- Before the maths, which can change the enemy's state (its procs).
	local inputs = pc.debug and pc.stagger_inputs(target_unit, blackboard, attacker_unit, damage_profile, target_index, hit_zone_name, power_level, boost_curve_multiplier, is_critical_strike, blocked, damage_source, t)
	local stagger_type, duration, _, stagger_value, strength = DamageUtils.calculate_stagger_player(ImpactTypeOutput, target_unit, attacker_unit, hit_zone_name, power_level, boost_curve_multiplier, is_critical_strike, damage_profile, target_index, blocked, damage_source)

	if shield then
		shield.blocked_previous_attack = shield_blocked
	end

	strength = type(strength) == "number" and strength or 0

	-- D45: what the maths used, to compare with the client's "client check" line for the same hit (go= is the enemy).
	if inputs then
		local owner = Managers.player:owner(attacker_unit)
		local result = type(stagger_type) == "number" and stagger_type or 0

		pc.log("host check maths enemy=%s go=%s from=%s profile=%s %s -> type=%s duration=%.2f strength=%.2f", blackboard.breed.name, tostring(Managers.state.unit_storage:go_id(target_unit)), owner and name_of(owner.peer_id) or "?",
			host_reactions.profile_name(damage_profile), inputs, stagger_names[result] or tostring(result), type(duration) == "number" and duration or 0, strength)
	end

	if type(stagger_type) ~= "number" or stagger_type <= pc.stagger_types.none then
		-- do_stagger_calculation returns all zeros when the enemy's action ignores the stagger (damage_utils.lua:802),
		-- as a frenzy does for light staggers.
		return 0, stagger_value == 0 and duration == 0 and "its action ignores this stagger" or "too weak to stagger", strength
	end

	if action_ignores(blackboard, attack_template, stagger_type) then
		return 0, blackboard.anim_cb_stagger_immune and "stagger immune (animation cue)" or "its action ignores this stagger", strength
	end

	-- AiUtils.stagger refuses this one (ai_utils.lua:1117).
	if not attack_template.always_stagger and not damage_profile.is_push and blackboard.stagger and blackboard.stagger_type == pc.stagger_types.explosion and stagger_type ~= pc.stagger_types.explosion then
		return 0, "already blown back", strength
	end

	return stagger_type, nil, strength
end

local function stagger_name(stagger_type)
	return stagger_names[stagger_type] or tostring(stagger_type)
end

-- answer: the client's stagger type, 0 if it sent no stagger for that hit, or "kill".
local function compare_check(decision, answer, answer_id)
	if answer == "kill" then
		pc.count("host_check_killed")

		return
	end

	pc.count("host_check_compared")

	local host_type = decision.stagger_type

	if host_type == answer then
		pc.count("host_check_agreed")

		return
	end

	local key = host_type == 0 and "host_check_client_only" or answer == 0 and "host_check_host_only" or "host_check_different"
	local here = host_type == 0 and "no stagger (" .. decision.reason .. ")" or stagger_name(host_type)
	local there = answer == 0 and "no stagger" or string.format("%s (client stagger=%s)", stagger_name(answer), tostring(answer_id))

	pc.count(key)
	pc.log("host check enemy=%s from=%s profile=%s: host %s, client %s; strength=%.2f action=%s accumulated=%.2f%s", decision.breed_name, name_of(decision.peer), decision.profile, here, there, decision.strength, decision.action, decision.accumulated,
		decision.client_first and ", the client's answer arrived before the hit" or "")
end

local function take(list, peer)
	if list then
		for i = 1, #list do
			if list[i].peer == peer then
				return table.remove(list, i)
			end
		end
	end

	return nil
end

-- Called from the DamageUtils.stagger_ai hook for every hit on CHECK_BREEDS whose stagger a client decides. The
-- client's own stagger or kill for that hit follows within a moment (check_answer), or nothing, if its maths found no
-- stagger.
local function check_hit(damage_profile, target_index, power_level, target_unit, attacker_unit, hit_zone_name, _, boost_curve_multiplier, is_critical_strike, blocked, damage_source)
	local blackboard = BLACKBOARDS[target_unit]
	local breed = blackboard and blackboard.breed
	local owner = breed and CHECK_BREEDS[breed.name] and attacker_unit and Managers.player:owner(attacker_unit)
	local peer = owner and owner.peer_id

	if not peer or type(damage_profile) ~= "table" then
		return
	end

	local stagger_type, reason, strength = host_would(damage_profile, target_index, power_level, target_unit, attacker_unit, hit_zone_name, boost_curve_multiplier, is_critical_strike, blocked, damage_source)

	if not stagger_type then
		return
	end

	local action = blackboard.action
	local decision = {
		peer = peer,
		t = pc.now(),
		wait = skip_is_blast and BLAST_LEFT_TO_CLIENT_WAIT or LEFT_TO_CLIENT_WAIT,
		held = skip_capture ~= nil,
		breed_name = breed.name,
		profile = host_reactions.profile_name(damage_profile),
		stagger_type = stagger_type,
		reason = reason,
		strength = strength,
		action = type(action) == "table" and tostring(action.name) or "none",
		accumulated = blackboard.stagger or 0,
	}
	local early = take(early_answers[target_unit], peer)

	if early then
		decision.client_first = true

		return compare_check(decision, early.answer, early.id)
	end

	local list = checks[target_unit] or {}

	list[#list + 1] = decision
	checks[target_unit] = list
end

-- A client's stagger (answer: its type) or kill (answer: "kill") for an enemy in CHECK_BREEDS.
local function check_answer(unit, peer, answer, id)
	local decision = take(checks[unit], peer)

	if decision then
		return compare_check(decision, answer, id)
	end

	local blackboard = BLACKBOARDS[unit]

	if blackboard and blackboard.breed and CHECK_BREEDS[blackboard.breed.name] then
		local list = early_answers[unit] or {}

		list[#list + 1] = {
			peer = peer,
			answer = answer,
			id = id,
			t = pc.now(),
		}
		early_answers[unit] = list
	end
end

local function update_checks(t)
	for unit, list in pairs(checks) do
		for i = #list, 1, -1 do
			local decision = list[i]

			if t - decision.t > decision.wait then
				table.remove(list, i)

				-- No stagger or kill came from the client: its maths found no stagger for that hit.
				if HEALTH_ALIVE[unit] then
					compare_check(decision, 0)
				else
					pc.count("host_check_killed")
				end
			end
		end

		if #list == 0 then
			checks[unit] = nil
		end
	end

	for unit, list in pairs(early_answers) do
		for i = #list, 1, -1 do
			if t - list[i].t > BLAST_LEFT_TO_CLIENT_WAIT then
				table.remove(list, i)
			end
		end

		if #list == 0 then
			early_answers[unit] = nil
		end
	end
end

-- A client's stagger or kill for this enemy arrived. It answers the stagger skipped here for that hit, or, if it came
-- first (a bomb's staggers can beat the host's copy of the bomb, 0.1 s in the 3.1 playtest), the one skipped next.
local function note_answer(unit)
	if left_to_client[unit] then
		left_to_client[unit] = nil
	else
		answered[unit] = pc.now()
	end
end

local function apply_stagger(sender, id, go_id, stagger_type, duration, length, dx, dy, dz, anim_scale, stagger_value, always_stagger, is_push, anim, yaw, x, y, z, has_position, profile_name, target_index, damage_source)
	local function refuse(reason)
		pc.count("host_stagger_refused")
		pc.log("host stagger=%d from=%s refused: %s", id, name_of(sender), reason)
		ack(sender, "stagger", id, "rejected")
	end

	-- A client whose hello has expired had its hits staggered by the host itself, so a second stagger would be wrong.
	if not host.peer_decides_attacks(sender) then
		return refuse("the host is deciding that player's hits")
	end

	local unit = Managers.state.unit_storage:unit(go_id)
	local blackboard = unit and BLACKBOARDS[unit]
	local breed = blackboard and blackboard.breed

	if unit then
		note_answer(unit)
		check_answer(unit, sender, stagger_type, id)
	end

	if not breed or not pc.REACTION_BREEDS[breed.name] or not HEALTH_ALIVE[unit] then
		return refuse("enemy dead, gone or not covered")
	end

	local attacker = player_unit(sender)

	if not attacker then
		return refuse("the player has no hero")
	end

	local t = pc.now()
	local before = blackboard.stagger_time

	AiUtils.stagger(unit, blackboard, attacker, Vector3(dx, dy, dz), length, stagger_type, duration, anim_scale >= 0 and anim_scale or nil, t, stagger_value, always_stagger, is_push, nil, nil, damage_source)

	-- AiUtils.stagger refuses a few combinations, such as a light stagger on an enemy already blown back.
	if blackboard.stagger_time == before then
		return refuse("the game refused the stagger")
	end

	local previous = staggers[unit]

	if previous then
		ack(previous.peer, "stagger", previous.id, "rejected")
	end

	staggers[unit] = {
		id = id,
		peer = sender,
		unit = unit,
		anim = anim,
		yaw = yaw,
		position = has_position and Vector3Box(x, y, z) or nil,
		stagger = blackboard.stagger,
		t = t,
		breed_name = breed.name,
	}

	pc.count("host_stagger_received")
	stagger_procs(unit, blackboard, attacker, profile_name, target_index, stagger_type, duration, stagger_value, is_push, damage_source)
end

mod:network_register("pc_stagger", function (sender, version, id, go_id, stagger_type, duration, length, dx, dy, dz, anim_scale, stagger_value, always_stagger, is_push, anim, yaw, x, y, z, has_position, profile_name, target_index, damage_source)
	if pc.broken or not pc.is_server() or not pc.in_game() or version ~= pc.VERSION then
		return
	end

	if not valid_stagger(id, go_id, stagger_type, duration, length, dx, dy, dz, anim_scale, stagger_value, always_stagger, is_push, anim, yaw, x, y, z, has_position, profile_name, target_index, damage_source) then
		pc.count("host_rejected")
		pc.print("host rejected a malformed stagger from %s", name_of(sender))

		if type(id) == "number" then
			ack(sender, "stagger", id, "rejected")
		end

		return
	end

	pc.guard("host client stagger", apply_stagger, sender, id, go_id, stagger_type, duration, length, dx, dy, dz, anim_scale, stagger_value, always_stagger, is_push, anim, yaw, x, y, z, has_position, profile_name, target_index, damage_source)
end)

local BLAST_STAGGER_FIELDS = 15 -- values per stagger in pc_blast_staggers, in the order below
local MAX_BLAST_STAGGER_VALUES = 20 * BLAST_STAGGER_FIELDS

-- A client's blast's staggers, several to a message: per stagger id, go_id, stagger_type, duration, length, dx, dy,
-- dz, anim_scale, stagger_value, flags (1 always_stagger, 2 is_push), the animation's and the damage profile's
-- NetworkLookup ids, yaw, target_index. They carry no position: the host doesn't move enemies for a blast.
mod:network_register("pc_blast_staggers", function (sender, version, damage_source, ...)
	if pc.broken or not pc.is_server() or not pc.in_game() or version ~= pc.VERSION then
		return
	end

	local count = select("#", ...)

	if not known(NetworkLookup.damage_sources, damage_source) or count == 0 or count % BLAST_STAGGER_FIELDS ~= 0 or count > MAX_BLAST_STAGGER_VALUES then
		pc.count("host_rejected")
		pc.print("host rejected a malformed list of blast staggers from %s", name_of(sender))

		return
	end

	local values = { ... }

	pc.count("host_blast_stagger_messages")

	for i = 1, count, BLAST_STAGGER_FIELDS do
		local id, go_id, stagger_type, duration, length, dx, dy, dz, anim_scale, stagger_value, flags, anim_id, yaw, profile_id, target_index = unpack(values, i, i + BLAST_STAGGER_FIELDS - 1)
		local anim = type(anim_id) == "number" and rawget(NetworkLookup.anims, anim_id) or nil
		local profile_name = type(profile_id) == "number" and rawget(NetworkLookup.damage_profiles, profile_id) or nil
		local always_stagger = flags == 1 or flags == 3
		local is_push = flags == 2 or flags == 3

		if (flags == 0 or always_stagger or is_push) and anim and profile_name and valid_stagger(id, go_id, stagger_type, duration, length, dx, dy, dz, anim_scale, stagger_value, always_stagger, is_push, anim, yaw, 0, 0, 0, false, profile_name, target_index, damage_source) then
			pc.guard("host client stagger", apply_stagger, sender, id, go_id, stagger_type, duration, length, dx, dy, dz, anim_scale, stagger_value, always_stagger, is_push, anim, yaw, 0, 0, 0, false, profile_name, target_index, damage_source)
		else
			pc.count("host_rejected")
			pc.print("host rejected a malformed blast stagger from %s", name_of(sender))

			if type(id) == "number" then
				ack(sender, "stagger", id, "rejected")
			end
		end
	end
end)

-- Called before BTStaggerAction.enter. Returns the client stagger it is entering, if any.
function host_reactions.before_stagger_enter(node, unit, blackboard, t)
	-- A stagger replaces a recoil's animation, so a recoil being watched for its cue will never reach it, and a recoil
	-- whose end was brought forward is over.
	cue_watch[unit] = nil
	timed_recoils[unit] = nil

	local record = staggers[unit]

	if not record then
		if pc.probe_tools and blackboard.breed then
			pc.probe_tools.before_reaction(unit)
		end

		return nil
	end

	staggers[unit] = nil

	-- Someone else's stagger landed on top of the client's before the behaviour tree took it up, and that newer
	-- stagger picks its own animation, as in vanilla.
	if record.stagger ~= blackboard.stagger then
		pc.count("host_stagger_overtaken")
		ack(record.peer, "stagger", record.id, "rejected")

		return nil
	end

	if record.position then
		record.moved = teleport(unit, blackboard, record.position:unbox())
	end

	plan_timing(node, blackboard, record, t)

	forcing = record

	return record
end

-- Called from the BTStaggerAction._select_animation hook while a client stagger is being entered.
function host_reactions.forced_animation(unit, blackboard, stagger_anims)
	local record = forcing

	if not record or record.unit ~= unit then
		return nil
	end

	-- The host plays exactly what the client chose (D26): any animation this enemy's stagger can play, not only the
	-- list the host's own state picked. One it can't play at all is left to vanilla.
	local action = blackboard.action

	if type(action) ~= "table" or not can_play(action, record.anim) then
		record.anim_refused = true

		return nil
	end

	-- What _select_animation does to the blackboard besides choosing.
	blackboard.always_stagger_suffered = nil
	blackboard.last_stagger_anim = record.anim
	record.anim_used = true

	-- BTStaggerAction.enter reads this straight after choosing, for the animation's speed (bt_stagger_action.lua:76).
	if record.speed then
		blackboard.stagger_animation_scale = record.base_scale * record.speed
	end

	return record.anim, Quaternion(Vector3.up(), record.yaw)
end

-- D47: ungors' stagger animations follow stagger_scale (the calibration probe), but their stagger action doesn't set
-- scale_animation_speeds, so vanilla never sends the variable with their staggers (bt_stagger_action.lua:73). For such
-- an enemy the host sets the flag for the length of BTStaggerAction.enter, so it sends the variable with every stagger
-- as it does for the others: a client's stagger at the faster speed (forced_animation), the host's own at normal
-- speed, as vanilla plays it, so a faster value never lingers on any machine. Returns what restore_stagger_flag puts
-- back.
function host_reactions.force_stagger_flag(node, unit, blackboard)
	local action = node._tree_node and node._tree_node.action_data
	local breed = blackboard.breed

	if type(action) ~= "table" or action.scale_animation_speeds or not breed or not pc.STAGGER_SCALE_BREEDS[breed.name] then
		return nil
	end

	local saved = {
		action = action,
		scale = action.stagger_animation_scale,
	}

	action.scale_animation_speeds = true

	if not (forcing and forcing.unit == unit) then
		action.stagger_animation_scale = 1
	end

	return saved
end

function host_reactions.restore_stagger_flag(saved)
	saved.action.scale_animation_speeds = nil
	saved.action.stagger_animation_scale = saved.scale
end

-- Called after every BTStaggerAction.enter, of any enemy (D47: every enemy is timed, for later steps), while
-- force_stagger_flag's flag is still set: the animation it plays and how fast, until its end cue arrives
-- (push_finished).
function host_reactions.stagger_entered(node, unit, blackboard, t)
	local breed = blackboard.breed
	local action = node._tree_node and node._tree_node.action_data
	local anim = blackboard.last_stagger_anim

	if not breed or not action or type(anim) ~= "string" then
		return
	end

	-- What enter sent with the animation (bt_stagger_action.lua:73), and the speed this enemy's animation plays at then.
	local asked = action.scale_animation_speeds and (action.stagger_animation_scale or blackboard.stagger_animation_scale or 1) or 1
	local scale = pc.stagger_speed(breed.name, asked)
	local record = forcing
	local client_stagger = record ~= nil and record.unit == unit and record.anim_used
	local watch = {
		anim = anim,
		scale = scale > 0 and scale or 1,
		t = t,
		breed_name = breed.name,
		-- /pingcomp probe: a speed variable tried on the host's own stagger, whose reading isn't at normal speed.
		probe = not client_stagger and pc.probe_tools and pc.probe_tools.reaction_entered(unit, "length", anim, breed.name) or nil,
	}

	-- D38: a client's stagger played faster here. Its time to the end cue shows the speed the animation really reached.
	if client_stagger and record.speed and record.base_scale and record.base_scale > 0 then
		watch.asked = record.speed
		watch.base = record.base_scale
		watch.id = record.id
		watch.peer = record.peer
	end

	stagger_watch[unit] = watch
end

local SLOW_SHARE = 0.9 -- a sped-up stagger that reached less than this share of the speed asked counts as slow

-- The host's anim_cb_push_finished: the stagger animation has reached the cue BTStaggerAction waits for. Its length,
-- at normal speed, is what plan_timing uses for animations with no shipped length. A stagger played faster here is
-- timed too, multiplied back to normal speed, but not learned from (Timings.lua): when the length it was timed against
-- was too long, a stagger that played at normal speed passed this speed check, and too long a length was learned again.
function host_reactions.push_finished(unit)
	local timing = stagger_watch[unit]

	if not timing then
		return
	end

	stagger_watch[unit] = nil

	local elapsed = pc.now() - timing.t

	if pc.probe_tools then
		pc.probe_tools.cue_reached(unit, "length")
	end

	if timing.probe then
		pc.probe_tools.reaction_timed(unit, "length", timing.breed_name, timing.anim, elapsed, nil, timing.probe)
		pc.timings.learn("length", timing.breed_name, timing.anim, elapsed, nil, timing.probe)

		return
	end

	if timing.asked then
		local length = pc.timings.get("length", timing.breed_name, timing.anim)

		if length and elapsed > 0 then
			-- The speed it reached, relative to the stagger's own speed, as timing.asked is.
			local reached = length / (timing.base * elapsed)
			local slow = reached < timing.asked * SLOW_SHARE

			pc.count("host_stagger_speed_checked")
			pc.count("host_stagger_speed_share_sum", reached / timing.asked)

			if slow then
				pc.count("host_stagger_slow")
			end

			pc.log("host stagger=%d from=%s enemy=%s anim=%s speed asked=%.2f reached=%.2f%s", timing.id, name_of(timing.peer), timing.breed_name, timing.anim, timing.asked, reached, slow and " (slow)" or "")

			-- Timed at a speed it didn't reach, the reading isn't this animation's length.
			if slow then
				return
			end
		end
	end

	pc.timings.learn("length", timing.breed_name, timing.anim, elapsed * timing.scale, nil, timing.scale)
end

function host_reactions.after_stagger_enter(unit, blackboard, t, record)
	forcing = nil

	if record.base_scale then
		blackboard.stagger_animation_scale = record.base_scale
	end

	local applied = record.anim_used == true

	pc.count(applied and "host_stagger_applied" or "host_stagger_own_animation")

	if applied and record.timing ~= "off" then
		-- The stagger's timer, set when the client's message arrived, ends one round trip early as well.
		if blackboard.stagger_time and record.rtt then
			blackboard.stagger_time = math.max(blackboard.stagger_time - record.rtt, t)
		end

		-- Past the speed-up limit, or for an enemy whose stagger animations ignore the speed variable (Chaos enemies,
		-- gors, shielded stormvermin), the timer alone ends the stagger, without waiting for the animation's cue.
		-- Other players see the animation cut short.
		if record.end_at then
			blackboard.stagger_ignore_anim_cb = true
			blackboard.stagger_time = math.max(blackboard.stagger_time or t, record.end_at)
		end

		if record.speed then
			pc.count("host_stagger_sped_up")
			pc.count("host_stagger_speed_sum", record.speed)
		end

		if record.end_at then
			pc.count("host_stagger_ended_early")
		end

		if record.timing == "timer only" then
			pc.count("host_stagger_timer_only")
		end
	end

	if record.moved and record.moved > 0 then
		pc.count("host_teleports")
		pc.count("host_teleport_distance_sum", record.moved)
	end

	pc.log("host stagger=%d from=%s enemy=%s anim=%s applied=%s moved=%s timing=%s speed=%.2f lead=%.3fs length=%s", record.id, name_of(record.peer), record.breed_name, record.anim, tostring(applied), format_distance(record.moved),
		tostring(record.timing), record.speed or 1, record.lead or 0, record.duration and string.format("%.2fs", record.duration) or "unknown")
	ack(record.peer, "stagger", record.id, applied and "applied" or "rejected")
end

function host_reactions.end_forcing()
	forcing = nil
end

-- Called from book_block in Host.lua once the enemy's recoil is set. The client's animation replaces the random one
-- BTBlockedAction.enter would pick (it reads blackboard.blocked_anim first).
function host_reactions.recoil_booked(swing, blackboard, recoil)
	if not recoil then
		-- This recoil starts when the answer arrives, after the damage frame, so it isn't measured; its end is logged.
		late_recoils[swing.attacker] = {
			t = pc.now(),
			id = swing.id,
			peer = swing.peer,
			frame_t = swing.blocked_frame_t,
			blocked_attack = swing.attack_anim,
		}

		return "recoil left to the host"
	end

	blackboard.blocked_anim = recoil.anim

	local previous = recoils[swing.attacker]

	if previous then
		ack(previous.peer, "recoil", previous.id, "rejected")
	end

	recoils[swing.attacker] = {
		id = swing.id,
		peer = swing.peer,
		anim = recoil.anim,
		blocked_attack = swing.attack_anim,
		attack_anim = swing.action.blocked_anim,
		position = recoil.position and Vector3Box(recoil.position) or nil,
		frame_t = recoil.frame_t,
		t = pc.now(),
		blackboard = blackboard,
		breed_name = blackboard.breed and blackboard.breed.name or swing.breed_name,
	}

	return "recoil " .. recoil.anim
end

-- The client played a recoil that won't happen on the host, so it is told at once to catch up.
function host_reactions.recoil_refused(swing, recoil, reason)
	if not recoil then
		return
	end

	pc.count("host_recoil_refused")
	pc.log("host swing=%d recoil %s refused: %s", swing.id, recoil.anim, reason)
	ack(swing.peer, "recoil", swing.id, "rejected")
end

-- Called before BTBlockedAction.enter. Returns the client recoil it is entering, or for a covered enemy's other
-- recoils a record that only watches for the animation's cue. Vanilla picks a random animation inside enter; for
-- those, the same random pick is made here and handed to enter through blackboard.blocked_anim, so it is known.
function host_reactions.before_recoil_enter(node, unit, blackboard)
	-- A recoil watched for its cue may have been cut short (a stagger) before its cue came, and this recoil may be one
	-- that isn't measured (a client's, or one started late). Without this, this recoil's cue would be timed from the
	-- older one's start: in the 2.2 playtest the host's marauder readings came out at 1.2 to 2.35 s instead of 0.95 s.
	-- A recoil whose end was brought forward is over too, and the late stunned cue of one ended early is dropped no
	-- more: this recoil's own may come next.
	cue_watch[unit] = nil
	timed_recoils[unit] = nil
	stunned_drop[unit] = nil

	-- A recoil ends once anim_cb_blocked_cooldown is set and its timer has run out, and only BTBlockedAction.leave
	-- clears the flag. When before_recoil_run ended a recoil before its animation's own cue, that cue still fires
	-- afterwards and sets the flag again, so the enemy's next recoil would end as soon as its timer ran out (0.5 to
	-- 0.75 s on Cataclysm, measured from the damage frame). The new recoil's animation hasn't started yet, so a flag
	-- set now is always left over from an earlier one.
	if blackboard.anim_cb_blocked_cooldown then
		blackboard.anim_cb_blocked_cooldown = nil

		pc.count("host_recoil_stale_cue_cleared")
		pc.log("host recoil enemy=%s: cleared a cue left over from its last recoil", tostring(blackboard.breed and blackboard.breed.name))
	end

	local record = recoils[unit]
	local action = node._tree_node and node._tree_node.action_data

	if not record then
		local breed = blackboard.breed
		local anims = action and action.blocked_anims
		local late = late_recoils[unit]

		late_recoils[unit] = nil

		-- Every enemy's own recoils are timed (D47), for later steps as well as for the covered enemies.
		if not breed then
			return nil
		end

		if not blackboard.blocked_anim and type(anims) == "table" and #anims > 0 then
			blackboard.blocked_anim = anims[Math.random(1, #anims)]
		end

		-- A client's block whose recoil the client left to the host (recoil off): not measured, but its end is logged.
		if late and pc.now() - late.t < LATE_RECOIL_WAIT then
			return {
				left_to_host = true,
				id = late.id,
				peer = late.peer,
				frame_t = late.frame_t,
				anim = blackboard.blocked_anim,
				blocked_attack = late.blocked_attack,
				breed_name = breed.name,
			}
		end

		if not blackboard.blocked_anim then
			return nil
		end

		if pc.probe_tools then
			pc.probe_tools.before_reaction(unit)
		end

		return {
			watch_only = true,
			anim = blackboard.blocked_anim,
			blocked_attack = attack_anims[unit],
			breed_name = breed.name,
		}
	end

	recoils[unit] = nil

	if record.anim ~= record.attack_anim and not contains(action and action.blocked_anims, record.anim) then
		-- Not an animation this enemy's recoil can play here, so vanilla picks one.
		blackboard.blocked_anim = nil
		record.refused = true

		return record
	end

	if record.position then
		record.moved = teleport(unit, blackboard, record.position:unbox())
	end

	return record
end

-- Every recoil a client's block caused is watched until BTBlockedAction.leave, which says why it ended (recoil_ended).
local function watch_recoil_end(unit, blackboard, t, record, kind)
	recoil_ends[unit] = {
		id = record.id,
		peer = record.peer,
		kind = kind,
		anim = kind ~= "vanilla's animation" and record.anim or nil,
		blocked_attack = record.blocked_attack,
		breed_name = record.breed_name,
		blackboard = blackboard,
		t = t,
		frame_t = record.frame_t,
		leave_at = blackboard.leave_blocked_at_t,
	}
end

function host_reactions.after_recoil_enter(unit, blackboard, t, record)
	-- Only the host's own recoils, which start at the damage frame as in vanilla, are measured. A client's starts when
	-- its answer arrives, and its cue can then come later than vanilla's; the client measures its own copy instead,
	-- which starts at its damage frame.
	if record.watch_only then
		cue_watch[unit] = {
			anim = record.anim,
			blocked_attack = record.blocked_attack,
			breed_name = record.breed_name,
			t = t,
			done = {}, -- the cues already timed: "cue" (anim_cb_blocked_cooldown), "stunned" (anim_cb_stunned_finished)
			-- /pingcomp probe: a speed variable tried on this recoil, whose readings aren't at normal speed (Probe.lua).
			probe = pc.probe_tools and pc.probe_tools.reaction_entered(unit, "cue", record.anim, record.breed_name) or nil,
		}

		return
	end

	if record.left_to_host then
		watch_recoil_end(unit, blackboard, t, record, "left to the host")

		return
	end

	if record.refused then
		pc.count("host_recoil_own_animation")
		ack(record.peer, "recoil", record.id, "rejected")
		watch_recoil_end(unit, blackboard, t, record, "vanilla's animation")

		return
	end

	-- D14: the recoil's length counts from the host's own damage frame, not from when the answer arrived, so the
	-- enemy's next move reaches the blocker just as their copy's recoil ends.
	local early = record.frame_t and math.max(t - record.frame_t, 0) or 0

	if blackboard.leave_blocked_at_t then
		blackboard.leave_blocked_at_t = blackboard.leave_blocked_at_t - early
	end

	-- The recoil's cue times, looked up by its animation and the attack it interrupted (D43). A cue not yet known is
	-- left to the animation, which can leave the blocker a ping of extra recoil but never cuts it short.
	timed_recoils[unit] = {
		blackboard = blackboard,
		t = t,
		frame_t = record.frame_t or t,
		anim = record.anim,
		breed_name = record.breed_name,
		blocked_attack = record.blocked_attack,
		cue = (pc.timings.get("cue", record.breed_name, record.anim, record.blocked_attack)),
		stunned = (pc.timings.get("stunned", record.breed_name, record.anim, record.blocked_attack)),
	}

	watch_recoil_end(unit, blackboard, t, record, "predicted")
	pc.count("host_recoil_applied")

	if record.moved and record.moved > 0 then
		pc.count("host_teleports")
		pc.count("host_teleport_distance_sum", record.moved)
	end

	pc.log("host swing=%d recoil=%s enemy=%s moved=%s ends_early_by=%.3fs", record.id, record.anim, record.breed_name, format_distance(record.moved), early)
	ack(record.peer, "recoil", record.id, "applied")
end

-- Called before BTBlockedAction.run, every frame, for a recoil whose end was brought forward (D14). Vanilla ends a
-- recoil once its timer has run out and its animation has reached its cue (anim_cb_blocked_cooldown), or at once when
-- the animation's anim_cb_stunned_finished clears blackboard.blocked (the savage's recoils). The timer was already
-- moved to the blocker's moment, and so are the cues, once their times into the animation are known (Timings.lua):
--   * The cue: until its time has passed, counted from the damage frame, the flag is held off whatever set it, and
--     once it has, the flag is set. A cue that isn't this recoil's own can set the flag early (2026-11-12 playtest:
--     marauder recoils ended 0.1 s after they began), so it can't be trusted before then.
--   * The stunned cue: the animation's own is held back until its time (recoil_stunned), and then blackboard.blocked
--     is cleared here, as that cue does.
-- Until a cue time is known, the animation's own cue decides, which can leave the blocker a ping of extra recoil but
-- never cuts it short.
function host_reactions.before_recoil_run(unit, blackboard, t)
	local record = timed_recoils[unit]

	if not record then
		return
	end

	if record.blackboard ~= blackboard then
		timed_recoils[unit] = nil

		return
	end

	if record.stunned and not record.stunned_done and t > record.frame_t + record.stunned then
		record.stunned_done = true
		blackboard.blocked = nil
		-- This recoil's own stunned cue comes about as much later as the recoil started after the damage frame.
		stunned_drop[unit] = t + math.max(record.t - record.frame_t, 0) + STUNNED_DROP_MARGIN

		local watch = recoil_ends[unit]

		if watch then
			watch.stunned_t = t
			watch.stunned_learned = true
		end

		pc.count("host_recoil_stunned_brought_forward")
	end

	local cue = record.cue

	if record.cue_done then
		-- Nothing left to do for the cue.
	elseif not cue then
		if blackboard.anim_cb_blocked_cooldown then
			record.cue_done = true
		end
	elseif t <= record.frame_t + cue then
		if blackboard.anim_cb_blocked_cooldown then
			blackboard.anim_cb_blocked_cooldown = nil

			if not record.early_cue then
				record.early_cue = true

				pc.count("host_recoil_early_cue_ignored")
				pc.log("host recoil=%s enemy=%s: ignored a cue %.3fs after it began, %.3fs before its time", record.anim, record.breed_name, t - record.t, record.frame_t + cue - t)
			end
		end
	else
		blackboard.anim_cb_blocked_cooldown = true
		record.cue_done = true

		local watch = recoil_ends[unit]

		if watch then
			watch.cue_learned = true
		end

		pc.count("host_recoil_cue_brought_forward")
	end

	if record.cue_done and (not record.stunned or record.stunned_done) then
		timed_recoils[unit] = nil
	end
end

-- The host's anim_cb_blocked_cooldown (kind "cue") or anim_cb_stunned_finished (kind "stunned") during one of its own
-- recoils: the recoil animation reached that cue. Its time into the animation, looked up by the animation and the
-- attack it interrupted, is what before_recoil_run uses for a client's recoil. A recoil the host started late (a
-- client's) isn't measured: the client measures its own copy.
function host_reactions.recoil_cue(unit, kind)
	local watch = cue_watch[unit]

	if not watch or watch.done[kind] then
		return
	end

	watch.done[kind] = true

	if watch.done.cue and watch.done.stunned then
		cue_watch[unit] = nil
	end

	if not watch.breed_name then
		return
	end

	local elapsed = pc.now() - watch.t

	if pc.probe_tools then
		pc.probe_tools.cue_reached(unit, kind)
	end

	if watch.probe then
		pc.probe_tools.reaction_timed(unit, kind, watch.breed_name, watch.anim, elapsed, watch.blocked_attack, watch.probe)
	end

	pc.timings.learn(kind, watch.breed_name, watch.anim, elapsed, watch.blocked_attack, watch.probe or 1)
end

-- The host's anim_cb_stunned_finished, which ends a recoil. Returns true to hold it back from vanilla: for a client's
-- recoil whose stunned cue time is known, until that time counted from the damage frame (before_recoil_run then does
-- what the cue does), and the late cue of a recoil already ended that way, which could end the next one at once.
function host_reactions.recoil_stunned(unit)
	host_reactions.recoil_cue(unit, "stunned")

	local t = pc.now()
	local drop_until = stunned_drop[unit]

	if drop_until then
		stunned_drop[unit] = nil

		if t <= drop_until then
			pc.count("host_recoil_late_stunned_dropped")

			return true
		end
	end

	local record = timed_recoils[unit]

	if record and record.stunned and not record.stunned_done then
		if not record.stunned_held then
			record.stunned_held = true

			pc.count("host_recoil_stunned_held")
		end

		return true
	end

	local watch = recoil_ends[unit]

	if watch and not watch.stunned_t then
		watch.stunned_t = t
	end

	return false
end

function host_reactions.has_timed_recoil(unit)
	return timed_recoils[unit] ~= nil
end

-- Called from the BTAttackAction.enter hook in Host.lua for every single attack.
function host_reactions.note_attack(unit, anim)
	attack_anims[unit] = anim
end

-- Called for every animation the host plays on an enemy (AnimationSystem.anim_event): an attack animation is the attack
-- a recoil after it interrupted, which recoil timings are kept by (D43). This covers every enemy's attacks (D47),
-- including the sweeps and shoves of elites (BTStormVerminAttackAction plays its animation without noting it).
function host_reactions.note_animation(unit, anim)
	local blackboard = BLACKBOARDS[unit]
	local breed = blackboard and blackboard.breed

	if breed and type(anim) == "string" and pc.reactions.is_attack_anim(breed, anim) then
		attack_anims[unit] = anim
	end
end

-- Called from the BTBlockedAction.run hook, after before_recoil_run, for a recoil watched for its end: when its cue
-- flag was first set, by the animation's own cue or brought forward to the learned cue time.
function host_reactions.note_recoil_cue(unit, blackboard, t)
	local record = recoil_ends[unit]

	if record.blackboard == blackboard and not record.cue_t and blackboard.anim_cb_blocked_cooldown then
		record.cue_t = t
	end
end

-- Who staggered an enemy out of a recoil: the player whose client decided it, or the owner of blackboard.pushing_unit,
-- which AiUtils.stagger sets to the attacker.
local function stagger_cause(unit, blackboard, record)
	local pending = staggers[unit]

	if pending then
		return string.format("%s's hit, decided on their screen%s", name_of(pending.peer), pending.peer == record.peer and " (the blocker)" or "")
	end

	local pusher = blackboard.pushing_unit
	local owner = pusher and Unit.alive(pusher) and Managers.player:owner(pusher)

	if owner then
		local who = owner.bot_player and "a bot's" or owner.peer_id == record.peer and "the blocker's" or owner.local_player and "the host's" or "another player's"

		return string.format("%s's hit (%s), decided here", owner:name(), who)
	end

	local breed = pusher and Unit.alive(pusher) and Unit.get_data(pusher, "breed")

	return breed and string.format("a %s", breed.name) or "something else"
end

-- Called from the BTBlockedAction.leave hook for a recoil a client's block caused. reason "done" means its run ended
-- it (timer and cue); otherwise a higher branch of the behaviour tree took over (a stagger, a fall), or the enemy died
-- or was removed (destroy).
function host_reactions.recoil_ended(unit, blackboard, t, reason, destroy)
	local record = recoil_ends[unit]

	recoil_ends[unit] = nil

	if record.blackboard ~= blackboard then
		return
	end

	local why, key

	if reason == "done" then
		local cue_last = record.cue_t ~= nil and record.leave_at ~= nil and record.cue_t > record.leave_at

		key = "done"
		why = cue_last and "its cue, after its timer" or "its timer, after its cue"

		if cue_last then
			pc.count("host_recoil_end_cue_last")
		end
	elseif destroy then
		key = HEALTH_ALIVE[unit] and "other" or "death"
		why = HEALTH_ALIVE[unit] and "the enemy was removed" or "death"
	elseif blackboard.stagger then
		local cause = stagger_cause(unit, blackboard, record)

		key = "stagger"
		why = "a stagger, " .. cause

		if not string.find(cause, "the blocker", 1, true) then
			pc.count("host_recoil_end_stagger_other")
		end
	elseif record.stunned_t then
		-- anim_cb_stunned_finished cleared blackboard.blocked, or the host did at its time (D14).
		key = "stunned"
		why = record.stunned_learned and "its stunned cue (learned)" or "its stunned cue"
	else
		key = "other"
		why = blackboard.is_falling and "a fall" or blackboard.in_vortex and "a vortex" or "the behaviour tree (" .. tostring(reason) .. ")"
	end

	pc.count("host_recoil_end_" .. key)

	-- lasted, cue, stunned and timer_left count from the recoil's start here; from_frame from the host's damage frame,
	-- which is what the blocker's lasted= counts from on their screen.
	local cue = record.cue_t and string.format("%.3fs%s", record.cue_t - record.t, record.cue_learned and " (learned)" or "") or "not reached"
	local stunned = record.stunned_t and string.format("%.3fs%s", record.stunned_t - record.t, record.stunned_learned and " (learned)" or "") or "not reached"
	local known_cue = record.anim and pc.timings.get("cue", record.breed_name, record.anim, record.blocked_attack)
	local known_stunned = record.anim and pc.timings.get("stunned", record.breed_name, record.anim, record.blocked_attack)

	pc.log("host swing=%d recoil=%s enemy=%s ended: %s; kind=%s blocker=%s after=%s from_frame=%s lasted=%.3fs timer_left=%s cue=%s known_cue=%s stunned=%s known_stunned=%s", record.id, tostring(record.anim or "vanilla's"), record.breed_name, why, record.kind, name_of(record.peer), tostring(record.blocked_attack),
		record.frame_t and string.format("%.3fs", t - record.frame_t) or "n/a", t - record.t, record.leave_at and string.format("%.3fs", record.leave_at - t) or "n/a", cue, known_cue and string.format("%.2fs", known_cue) or "none",
		stunned, known_stunned and string.format("%.2fs", known_stunned) or "none")
end

local function schedule_kill(sender, id, go_id, hit_zone, damage_type, dx, dy, dz, damage_source)
	local unit = Managers.state.unit_storage:unit(go_id)

	if unit then
		note_answer(unit)
		check_answer(unit, sender, "kill", id)
	end

	if not unit or not HEALTH_ALIVE[unit] then
		pc.count("host_kill_already_dead")

		return
	end

	kills[unit] = {
		id = id,
		peer = sender,
		go_id = go_id,
		attacker = player_unit(sender),
		hit_zone = known(NetworkLookup.hit_zones, hit_zone) and hit_zone or "full",
		damage_type = known(NetworkLookup.damage_types, damage_type) and damage_type or "kinetic",
		direction = Vector3Box(dx, dy, dz),
		damage_source = known(NetworkLookup.damage_sources, damage_source) and damage_source or nil,
		due = pc.now() + KILL_DELAY,
	}
end

-- Kills are honoured whatever the client's hello says: that enemy is already dead on the player's screen, and one
-- left alive here would keep fighting there unseen.
mod:network_register("pc_kill", function (sender, version, id, go_id, hit_zone, damage_type, dx, dy, dz, damage_source)
	if pc.broken or not pc.is_server() or not pc.in_game() or version ~= pc.VERSION then
		return
	end

	if type(id) ~= "number" or type(go_id) ~= "number" or type(dx) ~= "number" or type(dy) ~= "number" or type(dz) ~= "number" or dx ~= dx or dy ~= dy or dz ~= dz then
		pc.count("host_rejected")
		pc.print("host rejected a malformed kill from %s", name_of(sender))

		return
	end

	pc.count("host_kill_received")
	pc.guard("host client kill", schedule_kill, sender, id, go_id, hit_zone, damage_type, dx, dy, dz, damage_source)
end)

local function finish_kill(unit, record)
	if not Unit.alive(unit) or not HEALTH_ALIVE[unit] or Managers.state.unit_storage:go_id(unit) ~= record.go_id then
		pc.count("host_kill_already_dead")
		pc.log("host kill=%d from=%s: the hit had already killed it here", record.id, name_of(record.peer))

		return
	end

	local attacker = record.attacker and Unit.alive(record.attacker) and record.attacker or nil

	AiUtils.kill_unit(unit, attacker, record.hit_zone, record.damage_type, record.direction:unbox(), record.damage_source)
	pc.count("host_kill_finished")
	pc.log("host kill=%d from=%s: finished off an enemy the hit left alive here", record.id, name_of(record.peer))
end

function host_reactions.update()
	local t = pc.now()

	for unit, record in pairs(kills) do
		if t >= record.due then
			kills[unit] = nil

			finish_kill(unit, record)
		end
	end

	for unit, record in pairs(staggers) do
		if t - record.t > FORCE_WAIT then
			staggers[unit] = nil

			pc.count("host_stagger_not_entered")
			ack(record.peer, "stagger", record.id, "rejected")
		end
	end

	for unit, record in pairs(recoils) do
		if t - record.t > FORCE_WAIT then
			recoils[unit] = nil

			if record.blackboard.blocked_anim == record.anim then
				record.blackboard.blocked_anim = nil
			end

			pc.count("host_recoil_not_entered")
			ack(record.peer, "recoil", record.id, "rejected")
		end
	end

	for unit, record in pairs(timed_recoils) do
		if t - record.t > TIMED_RECOIL_LIMIT or BLACKBOARDS[unit] ~= record.blackboard then
			timed_recoils[unit] = nil
		end
	end

	-- BTBlockedAction.leave runs for every recoil, even on death, so this only catches an enemy removed without it.
	for unit, record in pairs(recoil_ends) do
		if t - record.t > RECOIL_END_LIMIT or not Unit.alive(unit) or BLACKBOARDS[unit] ~= record.blackboard then
			recoil_ends[unit] = nil
		end
	end

	update_checks(t)

	-- A stagger skipped here that no client stagger or kill followed: the enemy didn't stagger anywhere.
	for unit, skip in pairs(left_to_client) do
		if t - skip.t > skip.wait then
			left_to_client[unit] = nil

			if HEALTH_ALIVE[unit] then
				pc.count("host_left_to_client_unanswered")
				pc.log("host skipped stagger enemy=%s profile=%s: no client stagger or kill followed", skip.breed_name, tostring(skip.profile))
			end
		end
	end

	for unit, answered_t in pairs(answered) do
		if t - answered_t > LEFT_TO_CLIENT_WAIT then
			answered[unit] = nil
		end
	end

	for unit, drop_until in pairs(stunned_drop) do
		if t > drop_until then
			stunned_drop[unit] = nil
		end
	end

	for unit, timing in pairs(stagger_watch) do
		if t - timing.t > TIMING_LIMIT or not Unit.alive(unit) then
			stagger_watch[unit] = nil
		end
	end

	for unit, watch in pairs(cue_watch) do
		if t - watch.t > CUE_WATCH_LIMIT or not Unit.alive(unit) then
			cue_watch[unit] = nil
		end
	end
end

function host_reactions.clear()
	skip_stagger_for = nil
	skip_capture = nil
	skip_is_blast = false
	forcing = nil
	staggers = {}
	recoils = {}
	timed_recoils = {}
	recoil_ends = {}
	kills = {}
	stagger_watch = {}
	cue_watch = {}
	late_recoils = {}
	left_to_client = {}
	answered = {}
	stunned_drop = {}
	attack_anims = {}
	checks = {}
	early_answers = {}

	pc.timings.save()
end

local profile_names = nil -- damage profile table -> its name in DamageProfileTemplates

-- Most damage profiles don't carry their own name (the 2.2 playtest's log said "profile=table" for a third of them).
local function profile_name(damage_profile)
	if type(damage_profile) ~= "table" then
		return tostring(damage_profile)
	end

	if damage_profile.name then
		return damage_profile.name
	end

	if not profile_names then
		profile_names = {}

		for name, profile in pairs(DamageProfileTemplates) do
			if type(profile) == "table" then
				profile_names[profile] = name
			end
		end
	end

	return profile_names[damage_profile] or "unnamed"
end

host_reactions.profile_name = profile_name

-- The client sends its stagger or kill right after the hit; host_reactions.update logs a skip that none followed.
local function note_left_to_client(target_unit, damage_profile)
	if left_to_client[target_unit] then
		return
	end

	-- The client's answer for this hit got here first.
	local answered_t = answered[target_unit]

	if answered_t then
		answered[target_unit] = nil

		if pc.now() - answered_t <= LEFT_TO_CLIENT_WAIT then
			pc.count("host_left_to_client_answered_first")

			return
		end
	end

	local blackboard = BLACKBOARDS[target_unit]

	left_to_client[target_unit] = {
		t = pc.now(),
		-- A big blast's staggers can reach the host over a second or more (the build 3 playtest's shouts).
		wait = skip_is_blast and BLAST_LEFT_TO_CLIENT_WAIT or LEFT_TO_CLIENT_WAIT,
		breed_name = blackboard and blackboard.breed and blackboard.breed.name or "unknown",
		profile = profile_name(damage_profile),
	}
end

-- The skipped stagger maths leaves one thing behind on the enemy: a shield records that it blocked the hit
-- (do_stagger_calculation, damage_utils.lua:574), and the shielded marauder's stagger reads it.
local function note_shield_block(target_unit, blocked)
	local shield = blocked and ScriptUnit.has_extension(target_unit, "ai_shield_system")

	if shield then
		shield.blocked_previous_attack = true
	end
end

-- A client's hit arrives here. While it is booked, DamageUtils.stagger_ai skips the enemy that client decides for.
-- This is a mod:hook, so everything except the original call runs through pc.guard.
mod:hook("WeaponSystem", "rpc_attack_hit", function (func, self, channel_id, damage_source_id, attacker_unit_id, hit_unit_id, hit_zone_id, hit_position, attack_direction, damage_profile_id, ...)
	if pc.broken or not channel_id then
		return func(self, channel_id, damage_source_id, attacker_unit_id, hit_unit_id, hit_zone_id, hit_position, attack_direction, damage_profile_id, ...)
	end

	local ok, unit = pc.guard("host attack hit", host_reactions.client_decides, channel_id, attacker_unit_id, hit_unit_id)

	if not ok or not unit then
		return func(self, channel_id, damage_source_id, attacker_unit_id, hit_unit_id, hit_zone_id, hit_position, attack_direction, damage_profile_id, ...)
	end

	skip_stagger_for = unit

	func(self, channel_id, damage_source_id, attacker_unit_id, hit_unit_id, hit_zone_id, hit_position, attack_direction, damage_profile_id, ...)

	skip_stagger_for = nil
end)

-- Blasts.lua: while a blast's damage is booked on this enemy, its stagger is skipped too. on_skip, if given, gets the
-- skipped call's arguments, for a stagger the client may turn out not to decide.
function host_reactions.begin_skip(unit, on_skip)
	skip_stagger_for = unit
	skip_capture = on_skip
	skip_is_blast = true
end

function host_reactions.end_skip()
	skip_stagger_for = nil
	skip_capture = nil
	skip_is_blast = false
end

-- The host is staggering this enemy itself after all, so its skip isn't waiting for the client any more, and neither is
-- the host's own check of that stagger.
function host_reactions.forget_left_to_client(unit)
	left_to_client[unit] = nil

	local list = checks[unit]

	if list then
		for i = 1, #list do
			if list[i].held then
				table.remove(list, i)

				break
			end
		end
	end
end

-- D45: for a hit the host decides itself on pc.CHECK_BREEDS, what its stagger maths is about to use, so a session
-- without clients shows the host's side of it too (the enemy's action during attacks and recoils, the hero's buffs).
local function log_own_maths(damage_profile, target_index, power_level, target_unit, attacker_unit, hit_zone_name, _, boost_curve_multiplier, is_critical_strike, blocked, damage_source)
	local blackboard = BLACKBOARDS[target_unit]
	local breed = blackboard and blackboard.breed

	if not breed or not CHECK_BREEDS[breed.name] or type(damage_profile) ~= "table" or not attacker_unit or not Unit.alive(attacker_unit) then
		return
	end

	local owner = Managers.player:owner(attacker_unit)

	if not owner then
		return
	end

	pc.log("host own maths enemy=%s go=%s from=%s profile=%s %s", breed.name, tostring(Managers.state.unit_storage:go_id(target_unit)), owner:name(), profile_name(damage_profile),
		pc.stagger_inputs(target_unit, blackboard, attacker_unit, damage_profile, target_index, hit_zone_name, power_level, boost_curve_multiplier, is_critical_strike, blocked, damage_source, pc.now()))
end

mod:hook("DamageUtils", "stagger_ai", function (func, t, damage_profile, target_index, power_level, target_unit, ...)
	if pc.debug and not pc.broken and (skip_stagger_for == nil or skip_stagger_for ~= target_unit) then
		pc.guard("host own stagger maths", log_own_maths, damage_profile, target_index, power_level, target_unit, ...)
	end

	if skip_stagger_for ~= nil and skip_stagger_for == target_unit then
		pc.count("host_stagger_left_to_client")
		pc.guard("host skipped stagger", note_left_to_client, target_unit, damage_profile)
		-- Before note_shield_block, so the check's maths sees the shield as the skipped call would have.
		pc.guard("host stagger check", check_hit, damage_profile, target_index, power_level, target_unit, ...)
		pc.guard("host skipped stagger", note_shield_block, target_unit, (select(6, ...)))

		if skip_capture then
			pc.guard("host held stagger", skip_capture, t, damage_profile, target_index, power_level, target_unit, ...)
		end

		return
	end

	return func(t, damage_profile, target_index, power_level, target_unit, ...)
end)

mod:hook("BTStaggerAction", "enter", function (func, self, unit, blackboard, t)
	local ok, record = pc.guard("host stagger enter", host_reactions.before_stagger_enter, self, unit, blackboard, t)
	local flag_ok, saved_flag = pc.guard("host stagger speed flag", host_reactions.force_stagger_flag, self, unit, blackboard)

	func(self, unit, blackboard, t)

	pc.guard("host stagger timing", host_reactions.stagger_entered, self, unit, blackboard, t)

	if flag_ok and saved_flag then
		pc.guard("host stagger speed flag", host_reactions.restore_stagger_flag, saved_flag)
	end

	if ok and record then
		pc.guard("host stagger entered", host_reactions.after_stagger_enter, unit, blackboard, t, record)
	end

	host_reactions.end_forcing()
end)

mod:hook("BTStaggerAction", "_select_animation", function (func, self, unit, blackboard, impact_vec, stagger_anims)
	if forcing ~= nil then
		local ok, anim, rotation = pc.guard("host stagger animation", host_reactions.forced_animation, unit, blackboard, stagger_anims)

		if ok and anim then
			return anim, rotation
		end
	end

	return func(self, unit, blackboard, impact_vec, stagger_anims)
end)

mod:hook("BTBlockedAction", "enter", function (func, self, unit, blackboard, t)
	local ok, record = pc.guard("host recoil enter", host_reactions.before_recoil_enter, self, unit, blackboard)

	func(self, unit, blackboard, t)

	if ok and record then
		pc.guard("host recoil entered", host_reactions.after_recoil_enter, unit, blackboard, t, record)
	end
end)

mod:hook("BTBlockedAction", "run", function (func, self, unit, blackboard, t, dt)
	if timed_recoils[unit] ~= nil then
		pc.guard("host recoil timing", host_reactions.before_recoil_run, unit, blackboard, t)
	end

	if recoil_ends[unit] ~= nil then
		pc.guard("host recoil end", host_reactions.note_recoil_cue, unit, blackboard, t)
	end

	return func(self, unit, blackboard, t, dt)
end)

-- Every animation the host plays on a unit, sent to the clients or not (animation_system.lua:119 and :139). Only an
-- enemy's attack animations are noted.
mod:hook_safe("AnimationSystem", "anim_event", function (self, unit, event_name)
	if self.is_server and not pc.broken and BLACKBOARDS[unit] then
		pc.guard("host attack animation", host_reactions.note_animation, unit, event_name)
	end
end)

mod:hook_safe("AnimationSystem", "anim_event_with_variable_float", function (self, unit, event_name)
	if self.is_server and not pc.broken and BLACKBOARDS[unit] then
		pc.guard("host attack animation", host_reactions.note_animation, unit, event_name)
	end
end)

-- Every recoil leaves through here: reason "done" when its run ended it, "aborted" when a higher branch of the
-- behaviour tree took over, and destroy when the enemy died or was removed (bt_node.lua:87, ai_brain.lua:79).
mod:hook_safe("BTBlockedAction", "leave", function (self, unit, blackboard, t, reason, destroy)
	if recoil_ends[unit] ~= nil then
		pc.guard("host recoil end", host_reactions.recoil_ended, unit, blackboard, t, reason, destroy)
	end
end)
