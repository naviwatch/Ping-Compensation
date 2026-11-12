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
local forcing = nil -- the client stagger that BTStaggerAction is entering right now
local staggers = {} -- enemy unit -> client stagger waiting for BTStaggerAction.enter
local recoils = {} -- enemy unit -> client recoil waiting for BTBlockedAction.enter
local timed_recoils = {} -- enemy unit -> running recoil whose end was brought forward (D14)
local kills = {} -- enemy unit -> client kill waiting to be finished off
local stagger_watch = {} -- enemy unit -> the stagger animation the host is playing for it, until its end cue
local playable = {} -- stagger action table -> set of every animation it can play
local cue_watch = {} -- enemy unit -> the recoil animation the host is playing for it, until its cue
local late_recoils = {} -- enemy unit -> when a client's block was booked with the recoil left to the host
local left_to_client = {} -- enemy unit -> a stagger skipped here, until that client's stagger or kill for it arrives
local LEFT_TO_CLIENT_WAIT = 1 -- seconds; the client sends its stagger or kill right after the hit
local LATE_RECOIL_WAIT = 1 -- seconds; a booked block's recoil starts within a frame or two, or not at all

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
	local scalable = action ~= nil and action.scale_animation_speeds and not action.stagger_animation_scale
	local base_scale = blackboard.stagger_animation_scale or 1
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
		left_to_client[unit] = nil
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

-- Called before BTStaggerAction.enter. Returns the client stagger it is entering, if any.
function host_reactions.before_stagger_enter(node, unit, blackboard, t)
	local record = staggers[unit]

	if not record then
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

-- Called after every BTStaggerAction.enter of a covered enemy: the animation it plays and how fast, until its end
-- cue arrives (push_finished).
function host_reactions.stagger_entered(node, unit, blackboard, t)
	local breed = blackboard.breed
	local action = node._tree_node and node._tree_node.action_data
	local anim = blackboard.last_stagger_anim

	if not breed or not pc.REACTION_BREEDS[breed.name] or not action or type(anim) ~= "string" then
		return
	end

	local scale = action.scale_animation_speeds and (action.stagger_animation_scale or blackboard.stagger_animation_scale or 1) or 1

	stagger_watch[unit] = {
		anim = anim,
		scale = scale > 0 and scale or 1,
		t = t,
		breed_name = breed.name,
	}
end

-- The host's anim_cb_push_finished: the stagger animation has reached the cue BTStaggerAction waits for. Its length,
-- at normal speed, is what plan_timing uses next time.
function host_reactions.push_finished(unit)
	local timing = stagger_watch[unit]

	if not timing then
		return
	end

	stagger_watch[unit] = nil

	pc.timings.learn("length", timing.breed_name, timing.anim, (pc.now() - timing.t) * timing.scale)
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

		-- Past the speed-up limit, or for an enemy whose stagger has no speed variable (ungors), the timer alone ends
		-- the stagger, without waiting for the animation's cue. Other players see the animation cut short.
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
		-- This recoil starts when the answer arrives, after the damage frame, and then its animation's cue can come
		-- much later than vanilla's (marauders: 1.65 s instead of 0.95 s), so it isn't measured.
		late_recoils[swing.attacker] = pc.now()

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

		if not breed or not pc.REACTION_BREEDS[breed.name] or late and pc.now() - late < LATE_RECOIL_WAIT then
			return nil
		end

		if not blackboard.blocked_anim and type(anims) == "table" and #anims > 0 then
			blackboard.blocked_anim = anims[Math.random(1, #anims)]
		end

		return blackboard.blocked_anim and {
			watch_only = true,
			anim = blackboard.blocked_anim,
			breed_name = breed.name,
		} or nil
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

function host_reactions.after_recoil_enter(unit, blackboard, t, record)
	-- Only the host's own recoils, which start at the damage frame as in vanilla, are measured. A client's starts when
	-- its answer arrives, and its cue can then come later than vanilla's; the client measures its own copy instead,
	-- which starts at its damage frame.
	if record.watch_only then
		cue_watch[unit] = {
			anim = record.anim,
			breed_name = record.breed_name,
			t = t,
		}

		return
	end

	if record.refused then
		pc.count("host_recoil_own_animation")
		ack(record.peer, "recoil", record.id, "rejected")

		return
	end

	-- D14: the recoil's length counts from the host's own damage frame, not from when the answer arrived, so the
	-- enemy's next move reaches the blocker just as their copy's recoil ends.
	local early = record.frame_t and math.max(t - record.frame_t, 0) or 0

	if blackboard.leave_blocked_at_t then
		blackboard.leave_blocked_at_t = blackboard.leave_blocked_at_t - early
	end

	timed_recoils[unit] = {
		blackboard = blackboard,
		t = t,
		frame_t = record.frame_t or t,
		anim = record.anim,
		breed_name = record.breed_name,
	}

	pc.count("host_recoil_applied")

	if record.moved and record.moved > 0 then
		pc.count("host_teleports")
		pc.count("host_teleport_distance_sum", record.moved)
	end

	pc.log("host swing=%d recoil=%s enemy=%s moved=%s ends_early_by=%.3fs", record.id, record.anim, record.breed_name, format_distance(record.moved), early)
	ack(record.peer, "recoil", record.id, "applied")
end

-- Called before BTBlockedAction.run, every frame, for a recoil whose end was brought forward. Vanilla ends a recoil
-- once its timer has run out and its animation has reached its cue (anim_cb_blocked_cooldown). The timer was already
-- moved to the blocker's moment; the cue is too, once its time into the animation is known (recoil_cue): until that
-- time has passed, counted from the damage frame, the flag is held off whatever set it, and once it has, the flag is
-- set. A cue that isn't this recoil's own can set the flag early (2026-11-12 playtest: marauder recoils ended 0.1 s
-- after they began), so it can't be trusted before then. Until the cue time is known, the host's own cue decides,
-- which can leave the blocker a ping of extra recoil but never cuts it short.
function host_reactions.before_recoil_run(unit, blackboard, t)
	local record = timed_recoils[unit]

	if not record then
		return
	end

	if record.blackboard ~= blackboard then
		timed_recoils[unit] = nil

		return
	end

	local cue = pc.timings.get("cue", record.breed_name, record.anim)

	if not cue then
		if blackboard.anim_cb_blocked_cooldown then
			timed_recoils[unit] = nil
		end

		return
	end

	if t <= record.frame_t + cue then
		if blackboard.anim_cb_blocked_cooldown then
			blackboard.anim_cb_blocked_cooldown = nil

			if not record.early_cue then
				record.early_cue = true

				pc.count("host_recoil_early_cue_ignored")
				pc.log("host recoil=%s enemy=%s: ignored a cue %.3fs after it began, %.3fs before its time", record.anim, record.breed_name, t - record.t, record.frame_t + cue - t)
			end
		end

		return
	end

	blackboard.anim_cb_blocked_cooldown = true
	timed_recoils[unit] = nil

	pc.count("host_recoil_cue_brought_forward")
end

-- The host's anim_cb_blocked_cooldown: the recoil animation reached its cue. Its time into the animation is what
-- before_recoil_run uses next time. A recoil the host already ended itself isn't measured.
function host_reactions.recoil_cue(unit)
	local watch = cue_watch[unit]

	if not watch then
		return
	end

	cue_watch[unit] = nil

	if not watch.breed_name then
		return
	end

	pc.timings.learn("cue", watch.breed_name, watch.anim, pc.now() - watch.t)
end

function host_reactions.has_timed_recoil(unit)
	return timed_recoils[unit] ~= nil
end

local function schedule_kill(sender, id, go_id, hit_zone, damage_type, dx, dy, dz, damage_source)
	local unit = Managers.state.unit_storage:unit(go_id)

	if unit then
		left_to_client[unit] = nil
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

	-- A stagger skipped here that no client stagger or kill followed: the enemy didn't stagger anywhere.
	for unit, skip in pairs(left_to_client) do
		if t - skip.t > LEFT_TO_CLIENT_WAIT then
			left_to_client[unit] = nil

			if HEALTH_ALIVE[unit] then
				pc.count("host_left_to_client_unanswered")
				pc.log("host skipped stagger enemy=%s profile=%s: no client stagger or kill followed", skip.breed_name, tostring(skip.profile))
			end
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
	forcing = nil
	staggers = {}
	recoils = {}
	timed_recoils = {}
	kills = {}
	stagger_watch = {}
	cue_watch = {}
	late_recoils = {}
	left_to_client = {}

	pc.timings.save()
end

-- The client sends its stagger or kill right after the hit; host_reactions.update logs a skip that none followed.
local function note_left_to_client(target_unit, damage_profile)
	if left_to_client[target_unit] then
		return
	end

	local blackboard = BLACKBOARDS[target_unit]

	left_to_client[target_unit] = {
		t = pc.now(),
		breed_name = blackboard and blackboard.breed and blackboard.breed.name or "unknown",
		profile = type(damage_profile) == "table" and damage_profile.name or tostring(damage_profile),
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

mod:hook("DamageUtils", "stagger_ai", function (func, t, damage_profile, target_index, power_level, target_unit, ...)
	if skip_stagger_for ~= nil and skip_stagger_for == target_unit then
		pc.count("host_stagger_left_to_client")
		pc.guard("host skipped stagger", note_left_to_client, target_unit, damage_profile)
		pc.guard("host skipped stagger", note_shield_block, target_unit, (select(6, ...)))

		return
	end

	return func(t, damage_profile, target_index, power_level, target_unit, ...)
end)

mod:hook("BTStaggerAction", "enter", function (func, self, unit, blackboard, t)
	local ok, record = pc.guard("host stagger enter", host_reactions.before_stagger_enter, self, unit, blackboard, t)

	func(self, unit, blackboard, t)

	pc.guard("host stagger timing", host_reactions.stagger_entered, self, unit, blackboard, t)

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

	return func(self, unit, blackboard, t, dt)
end)
