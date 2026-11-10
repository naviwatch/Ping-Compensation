local mod = get_mod("Ping Compensation")
local geometry = mod.ping_compensation_geometry

local VERSION = 5
local HELLO_INTERVAL = 2
local PEER_EXPIRY = 8
local ATTACK_EXPIRY = 5
local MAX_WAIT = 0.75
local MIN_WAIT = 0.1
local MAX_RELATIVE = 50

local peers = {}
local host_attacks = {}
local host_area_attacks = {}
local client_attacks = {}
local pending = {}
local timeout_warnings = {}
local area_log_times = {}
local next_id = 0
local next_hello = 0
local context
local probe_recording = false

local function now()
	return Managers.time:time("game")
end

local function network()
	return Managers.state and Managers.state.network
end

local function host_peer()
	local manager = network()
	local lobby = manager and manager:lobby()
	local session_host = manager and manager:game_session_host()

	if session_host and session_host ~= "0" then
		return session_host
	end

	return lobby and lobby:lobby_host()
end

local function valid_number(value, limit)
	return type(value) == "number" and value == value and value >= -limit and value <= limit
end

-- we want to only compensate aoe attacks that make sense and whose side effects can be replayed safely without rubberbanding issues
local function valid_area_attack_action(action)
	return action and valid_number(action.damage, 100000) and action.damage > 0
		and valid_number(action.range, 20) and action.range > 0
		and valid_number(action.height, 20) and action.height > 0
		and valid_number(action.width, 20) and action.width > 0
		and valid_number(action.offset_up or 0, 20)
		and valid_number(action.offset_forward or 0, 20)
		and not action.push and not action.catapult
		-- Lua treats 0 as truthy; the game's blocked-damage callback still runs unchanged for this no-damage case.
		and (action.blocked_damage == nil or action.blocked_damage == false or action.blocked_damage == 0)
end

local function refresh_positions(entry)
	local attacker_position = Unit.world_position(entry.attacker, 0)
	local target_position = Unit.world_position(entry.target, 0)

	if not POSITION_LOOKUP or not attacker_position or not target_position then
		print("[PING COMPENSATION] Delayed melee hit could not be applied because fresh unit positions are unavailable")
		return false
	end

	POSITION_LOOKUP[entry.attacker] = attacker_position
	POSITION_LOOKUP[entry.target] = target_position
	return true
end

local function log_area_decision(entry, use_client, hit)
	local t = now()

	if not probe_recording and area_log_times[entry.peer] and t - area_log_times[entry.peer] < 2 then
		return
	end

	local observation = entry.observation
	local function elapsed(value, origin)
		return value and origin and string.format("%.3f", value - origin) or "n/a"
	end

	print(string.format(
		"[PING COMPENSATION] Area Attack: attack_id=%s attacker=%s target=%s attack=%s node=%s callback=%s callback_index=%s host_callback_t=%s host_resolve_t=%.3f since_begin_s=%s observation_after_callback_s=%s wait_s=%s ping_ms=%s host_hit=%s client_overlap=%s decision=%s source=%s host_block_checked=%s host_blocked=%s",
		tostring(entry.id), tostring(entry.attacker_id), tostring(entry.target_id), tostring(entry.attack_name or "unavailable"),
		tostring(entry.node_name or "unavailable"), tostring(entry.callback_name or "unavailable"), tostring(entry.callback_index),
		entry.callback_time and string.format("%.3f", entry.callback_time) or "n/a", t,
		elapsed(entry.callback_time, entry.begin_time), elapsed(observation and observation.received_time, entry.callback_time),
		elapsed(t, entry.callback_time), entry.ping and string.format("%.0f", entry.ping * 1000) or "unavailable",
		tostring(entry.vanilla_hit), observation and tostring(observation.area_hit) or "unavailable", tostring(hit),
		use_client and observation and "client" or "host", tostring(not not entry.block_checked), tostring(not not entry.blocked)))
	area_log_times[entry.peer] = t
end

-- apply either the client's hit result or the saved host's result, then replay damage
local function resolve(entry, use_client)
	local hit = entry.vanilla_hit

	if use_client and entry.observation then
		local observation = entry.observation

		if entry.kind == "area_attack" then
			if observation.dodging then
				hit = observation.area_hit
			end
		else
			local sample = observation.locked and entry.locked_snapshot or entry.unlocked_snapshot

			sample.attacker_x, sample.attacker_y, sample.attacker_z = 0, 0, 0
			sample.target_x, sample.target_y, sample.target_z = observation.dx, observation.dy, observation.dz
			sample.forward_x, sample.forward_y = observation.fx, observation.fy

			local in_range, in_front = geometry.check(sample)

			hit = in_range and in_front
		end
	end

	if entry.kind == "area_attack" then
		log_area_decision(entry, use_client, hit)
	end

	if not hit then
		return
	end

	if not Unit.alive(entry.attacker) or not Unit.alive(entry.target) then
		print("[PING COMPENSATION] Delayed melee hit could not be applied because its attacker or target no longer exists")
		return
	end

	if entry.frenzy_func then
		local blackboard = BLACKBOARDS[entry.attacker]
		local combo = blackboard and blackboard.combo_attack_data

		if blackboard ~= entry.blackboard or blackboard.active_node ~= BTComboAttackAction
			or blackboard.action ~= entry.action or blackboard.attack_aborted
			or combo ~= entry.combo or combo.current_attack_name ~= entry.combo_attack_name
			or combo.attack_start_time ~= entry.combo_start_time or combo.attacking_target ~= entry.target then
			print("[PING COMPENSATION] Delayed frenzy hit could not be applied because the combo swing is no longer active")
			return
		end

		if not refresh_positions(entry) then
			return
		end

		entry.replaying_frenzy = true
		context = entry
		entry.frenzy_func(entry.frenzy_node, entry.attacker, blackboard)
		context = nil
		entry.replaying_frenzy = nil
		return
	end

	if entry.kind == "area_attack" and not entry.block_checked then
		local attack_direction = entry.action.attack_directions and entry.action.attack_directions[entry.blackboard.attack_anim]

		if DamageUtils.check_block(entry.attacker, entry.target, entry.action.fatigue_type, attack_direction) then
			return
		end
	elseif entry.blocked then
		return
	end

	if not refresh_positions(entry) then
		return
	end

	local damage_func = entry.damage_func or AiUtils.damage_target

	damage_func(entry.target, entry.attacker, entry.action, entry.damage or entry.action.damage, entry.damage_source)

	local blackboard = BLACKBOARDS[entry.attacker]

	local combo = blackboard and blackboard.combo_attack_data
	local same_combo_attack = not entry.combo_attack_name
		or combo and combo.current_attack_name == entry.combo_attack_name and combo.attacking_target == entry.target
	local target_matches = entry.combo_attack_name and same_combo_attack
		or not entry.combo_attack_name and blackboard and blackboard.attacking_target == entry.target

	if entry.kind ~= "area_attack" and entry.success_func and blackboard == entry.blackboard and blackboard.action == entry.action
		and blackboard.active_node == entry.active_node and target_matches then
		entry.success_func(entry.success_node, entry.attacker, blackboard)
	elseif entry.kind ~= "area_attack" and entry.success_func then
		print("[PING COMPENSATION] Delayed melee hit landed after the enemy left its attack, could not replay attack-success animation")
	end
end

local function pending_key(id, callback_index)
	return tostring(id) .. ":" .. tostring(callback_index)
end

local function take_pending(key, use_client)
	local entry = pending[key]

	if entry then
		pending[key] = nil
		resolve(entry, use_client)
	end
end

-- optionally flush pending hits using host decisions, then reset everything
local function clear(flush)
	if flush then
		for id in pairs(pending) do
			take_pending(id, false)
		end
	end

	peers = {}
	host_attacks = {}
	host_area_attacks = {}
	client_attacks = {}
	pending = {}
	timeout_warnings = {}
	area_log_times = {}
	next_hello = 0
	context = nil
end

-- having mismatching versions will likely make the mod very fucky wucky so we do a version check to ensure everything is working
mod:network_register("pc_melee_hello", function (sender, version)
	if not mod:is_enabled() or not Managers.player or not Managers.player.is_server or version ~= VERSION or not network() then
		return
	end

	peers[sender] = now()
end)

mod:network_register("pc_melee_begin", function (sender, version, id, attacker_id, target_id, window_start, window_duration, kind, range, height, width, offset_up, offset_forward)
	if not mod:is_enabled() or not Managers.player or Managers.player.is_server or sender ~= host_peer()
		or version ~= VERSION or not valid_number(id, 2147483647) or not valid_number(attacker_id, 2147483647)
		or not valid_number(target_id, 2147483647) or not valid_number(window_start, ATTACK_EXPIRY)
		or not valid_number(window_duration, ATTACK_EXPIRY) or window_duration < 0
		or kind ~= "melee" and kind ~= "melee_multi" and kind ~= "combo" and kind ~= "combo_multi"
			and kind ~= "area_attack" then
		return
	end

	local combo_attack = kind == "combo" or kind == "combo_multi"
	local multi_callback = kind == "melee_multi" or kind == "combo_multi"
	kind = kind == "area_attack" and kind or "melee"

	if kind == "area_attack" and (not valid_number(range, 20) or range <= 0
		or not valid_number(height, 20) or height <= 0 or not valid_number(width, 20) or width <= 0
		or not valid_number(offset_up, 20) or not valid_number(offset_forward, 20)) then
		return
	end

	local player = Managers.player:local_player()
	local target = player and player.player_unit
	local manager = network()

	if not target or not Unit.alive(target) or not manager or manager:unit_game_object_id(target) ~= target_id then
		return
	end

	local t = now()

	client_attacks[attacker_id] = {
		id = id,
		target_id = target_id,
		kind = kind,
		begin_time = t,
		expires = t + ATTACK_EXPIRY,
		window_start = t + window_start,
		window_duration = window_duration,
		range = range,
		height = height,
		width = width,
		offset_up = offset_up,
		offset_forward = offset_forward,
		multi_callback = multi_callback,
		combo_attack = combo_attack,
		callback_index = 0,
		rotation_timer = t,
		locked = false,
	}
end)

-- we validate each attack and peer to ensure that only legitimate observations are processed and prevents duplicate or invalid data from affecting the game state
mod:network_register("pc_melee_observation", function (sender, version, id, attacker_id, target_id, dx, dy, dz, fx, fy, dodging, locked, area_hit, callback_index)
	if not mod:is_enabled() or not Managers.player or not Managers.player.is_server or version ~= VERSION then
		return
	end

	if not valid_number(id, 2147483647) or not valid_number(attacker_id, 2147483647)
		or not valid_number(target_id, 2147483647) or not valid_number(dx, MAX_RELATIVE)
		or not valid_number(dy, MAX_RELATIVE) or not valid_number(dz, MAX_RELATIVE)
		or not valid_number(fx, 1.01) or not valid_number(fy, 1.01) or type(dodging) ~= "boolean" or type(locked) ~= "boolean"
		or fx * fx + fy * fy > 1.03 or type(area_hit) ~= "boolean"
		or not valid_number(callback_index, 2147483647) or callback_index < 1 or callback_index ~= math.floor(callback_index) then
		print("[PING COMPENSATION] Rejected invalid melee observation")
		return
	end

	local area_attack = host_area_attacks[attacker_id]
	local area_entry = area_attack and area_attack.targets[target_id]
	local key = pending_key(id, callback_index)
	local pending_entry = pending[key]
	local entry = pending_entry or area_entry or host_attacks[attacker_id]

	if not entry or entry.id ~= id or entry.peer ~= sender or entry.attacker_id ~= attacker_id
		or entry.target_id ~= target_id or now() > entry.expires then
		return
	end

	local observation = { dx = dx, dy = dy, dz = dz, fx = fx, fy = fy, dodging = dodging, locked = locked, area_hit = area_hit, received_time = now() }

	if pending_entry then
		if pending_entry.observation then
			return
		end

		pending_entry.observation = observation
		take_pending(key, true)
	elseif callback_index == entry.callback_index + 1 and not (entry.observations and entry.observations[callback_index]) then
		entry.observations = entry.observations or {}
		entry.observations[callback_index] = observation
	end
end)

local function announce_melee_attack(unit, blackboard, target, peer, window_start, window_duration, combo_attack_name, multi_callback)
	local manager = network()
	local attacker_id = manager and manager:unit_game_object_id(unit)
	local target_id = target and manager:unit_game_object_id(target)

	if not attacker_id or not target_id then
		return
	end

	if not valid_number(window_start, ATTACK_EXPIRY) or not valid_number(window_duration, ATTACK_EXPIRY)
		or window_duration < 0 then
		return
	end

	next_id = next_id + 1
	local attack = {
		id = next_id,
		kind = "melee",
		peer = peer,
		attacker = unit,
		target = target,
		attacker_id = attacker_id,
		target_id = target_id,
		action = blackboard.action,
		blackboard = blackboard,
		active_node = blackboard.active_node,
		combo_attack_name = combo_attack_name,
		multi_callback = multi_callback,
		callback_index = 0,
		observations = {},
		expires = now() + ATTACK_EXPIRY,
	}

	host_attacks[attacker_id] = attack
	local kind = combo_attack_name and (multi_callback and "combo_multi" or "combo")
		or (multi_callback and "melee_multi" or "melee")
	mod:network_send("pc_melee_begin", peer, VERSION, attack.id, attacker_id, target_id, window_start, window_duration,
		kind)
end

-- announce trash melee attacks to the client being targeted by the attack
mod:hook_safe("BTAttackAction", "enter", function (self, unit, blackboard)
	if not mod:is_enabled() or not Managers.player or not Managers.player.is_server then
		return
	end

	local target = blackboard.attacking_target
	local owner = target and Managers.player:unit_owner(target)
	local peer = owner and owner.remote and not owner.bot_player and owner.peer_id
	local t = now()
	local manager = network()

	if not manager or not peer or not peers[peer] or t - peers[peer] > PEER_EXPIRY then
		return
	end

	local window_start = blackboard.attack_dodge_window_start and blackboard.attack_dodge_window_start - t
	local window_duration = blackboard.attack_dodge_window_duration

	announce_melee_attack(unit, blackboard, target, peer, window_start, window_duration, nil, false)
end)

-- A combo can contain several separately animated swings; announce every swing, not just node entry.
mod:hook_safe("BTComboAttackAction", "_start_attack", function (self, unit, blackboard, t, action, attack_name)
	if not mod:is_enabled() or not Managers.player or not Managers.player.is_server then
		return
	end

	local combo = blackboard.combo_attack_data
	local target = combo and combo.attacking_target
	local owner = target and Managers.player:unit_owner(target)
	local peer = owner and owner.remote and not owner.bot_player and owner.peer_id

	if not peer or not peers[peer] or now() - peers[peer] > PEER_EXPIRY then
		return
	end

	local attack_data = action.combo_attacks and action.combo_attacks[attack_name]
	local start_offset = attack_data and attack_data.dodge_window_start or action.dodge_window_start or 0
	local window_start = t + start_offset - now()
	local window_duration = attack_data and attack_data.dodge_window_duration or action.dodge_window_duration or 0

	announce_melee_attack(unit, blackboard, target, peer, window_start, window_duration, attack_name,
		attack_data and attack_data.triggers_anim_cb_damage_multiple_times or false)
end)

-- announce eligible area attacks to clients
mod:hook_safe("BTStormVerminAttackAction", "enter", function (self, unit, blackboard)
	if not mod:is_enabled() or not Managers.player or not Managers.player.is_server then
		return
	end

	local action = blackboard.action

	if not valid_area_attack_action(action) then
		return
	end

	local manager = network()
	local side_manager = Managers.state and Managers.state.side
	local heroes = side_manager and side_manager:get_side_from_name("heroes")
	local player_units = heroes and heroes:player_units()
	local attacker_id = manager and manager:unit_game_object_id(unit)

	if not manager or not attacker_id or not player_units then
		return
	end

	local t = now()
	local entries = {}

	for i = 1, #player_units do
		local target = player_units[i]
		local owner = Unit.alive(target) and Managers.player:unit_owner(target)
		local peer = owner and owner.remote and not owner.bot_player and owner.peer_id
		local target_id = target and manager:unit_game_object_id(target)

		if peer and target_id and peers[peer] and t - peers[peer] <= PEER_EXPIRY then
			next_id = next_id + 1

			local attack = {
				id = next_id,
				kind = "area_attack",
				peer = peer,
				attacker = unit,
				target = target,
				attacker_id = attacker_id,
				target_id = target_id,
				attack_name = action.name,
				node_name = self._tree_node and self._tree_node.name,
				begin_time = t,
				action = action,
				blackboard = blackboard,
				expires = t + ATTACK_EXPIRY,
				vanilla_hit = false,
				callback_index = 0,
				observations = {},
			}

			entries[target_id] = attack
			mod:network_send("pc_melee_begin", peer, VERSION, attack.id, attacker_id, target_id, 0, 0,
				"area_attack", action.range, action.height, action.width, action.offset_up or 0, action.offset_forward or 0)
		end
	end

	if next(entries) then
		host_area_attacks[attacker_id] = {
			action = action,
			blackboard = blackboard,
			targets = entries,
			expires = t + ATTACK_EXPIRY,
		}
	end
end)

-- function to match the game's hitbox query against the local player's hitbox
local function client_area_attack_hit(attack, unit, target)
	local world = Unit.world(unit)
	local physics_world = World.get_data(world, "physics_world")

	if not physics_world then
		return nil
	end

	local rotation = Unit.local_rotation(unit, 0)
	local half_range = attack.range * 0.5
	local half_height = attack.height * 0.5
	local forward = Quaternion.rotate(rotation, Vector3.forward()) * (attack.offset_forward + half_range)
	local up = Vector3.up() * (half_height + attack.offset_up)
	local center = Unit.world_position(unit, 0) + forward + up
	local size = Vector3(attack.width * 0.5, half_range, half_height)
	local hit_actors = PhysicsWorld.immediate_overlap(
		physics_world,
		"position", center,
		"rotation", rotation,
		"size", size,
		"shape", "oobb",
		"types", "dynamics",
		"collision_filter", "filter_player_hit_box_check"
	)

	if type(hit_actors) ~= "table" then
		return nil
	end

	for _, actor in ipairs(hit_actors) do
		if Actor.unit(actor) == target then
			return true
		end
	end

	return false
end

-- function to approximate the client's dodge window and whether the enemy should have locked rotation
local function update_client_attack(attack, unit, target, status, t)
	if attack.kind == "area_attack" then
		return
	end

	local attacker_pos = Unit.world_position(unit, 0)
	local target_pos = Unit.world_position(target, 0)
	local distance = Vector3.distance(attacker_pos, target_pos)

	if t > attack.window_start then
		local dodging = status:get_is_dodging() or status:is_invisible()

		if not dodging and t > attack.rotation_timer then
			attack.locked = false
		elseif dodging and not attack.locked and distance < 4 then
			attack.rotation_timer = t + attack.window_duration
			attack.locked = true
		end
	end

	if attack.locked and t > attack.rotation_timer or distance > 4 then
		attack.locked = false
	end
end

mod:hook("DamageUtils", "check_distance", function (func, action, blackboard, attacker, target)
	if context and context.attacker == attacker and context.target == target and context.action == action then
		return true
	end

	return func(action, blackboard, attacker, target)
end)

mod:hook("DamageUtils", "check_infront", function (func, attacker, target)
	if context and context.attacker == attacker and context.target == target then
		return true
	end

	return func(attacker, target)
end)

mod:hook("DamageUtils", "check_block", function (func, attacker, target, fatigue_type, original_enemy_weapon_direction)
	local result = func(attacker, target, fatigue_type, original_enemy_weapon_direction)
	local entry = context and context.kind == "area_attack" and context.attacker == attacker
		and context.entries_by_unit[target]

	if entry then
		entry.block_checked = true
		entry.blocked = result
	end

	return result
end)

mod:hook("AiUtils", "damage_target", function (func, target, attacker, action, damage, damage_source)
	if context and not context.replaying_frenzy and context.attacker == attacker and context.target == target and context.action == action then
		context.damage_func = func
		context.damage = damage
		context.damage_source = damage_source
		return
	end

	if context and context.kind == "area_attack" and context.attacker == attacker and context.action == action then
		local entry = context.entries_by_unit[target]

		if entry and not entry.blocked then
			entry.vanilla_hit = true
			entry.damage_func = func
			entry.damage = damage
			entry.damage_source = damage_source
			return
		end
	end

	return func(target, attacker, action, damage, damage_source)
end)

-- delay the ordinary melee success callback along with its damage for resolving
local function hook_attack_success(node_name)
	mod:hook(node_name, "attack_success", function (func, self, unit, blackboard)
		if context and context.attacker == unit and context.blackboard == blackboard then
			context.success_func = func
			context.success_node = self
			return
		end

		return func(self, unit, blackboard)
	end)
end

hook_attack_success("BTAttackAction")
hook_attack_success("BTComboAttackAction")

mod:hook("BTComboAttackAction", "anim_cb_frenzy_damage", function (func, self, unit, blackboard)
	if context and context.frenzy and context.attacker == unit and context.blackboard == blackboard then
		context.frenzy_func = func
		context.frenzy_node = self
		blackboard.attack_damage_triggered = true
		return
	end

	return func(self, unit, blackboard)
end)

mod:hook("BTComboAttackAction", "run", function (func, self, unit, blackboard, t, dt)
	local combo = blackboard.combo_attack_data

	if blackboard.attack_finished and not blackboard.attack_aborted and combo and Unit.alive(combo.attacking_target) then
		for _, entry in pairs(pending) do
			if entry.attacker == unit and entry.blackboard == blackboard
				and entry.combo_attack_name == combo.current_attack_name
				and (not entry.frenzy or entry.combo == combo and entry.combo_start_time == combo.attack_start_time) then
				return "running"
			end
		end
	end

	return func(self, unit, blackboard, t, dt)
end)

local function copy_for_callback(attack, callback_index)
	local entry = {}

	for key, value in pairs(attack) do
		entry[key] = value
	end

	entry.callback_index = callback_index
	entry.observation = attack.observations and attack.observations[callback_index]
	if attack.observations then
		attack.observations[callback_index] = nil
	end

	return entry
end

-- capture the host's area-hit decision during the original callback, then defer results later
local function resolve_area_attack_callback(func, system, unit, callback_name, param, attacker_id, entries)
	local blackboard = BLACKBOARDS[unit]

	if not system.is_server or not blackboard or blackboard ~= entries.blackboard
		or blackboard.active_node ~= BTStormVerminAttackAction or blackboard.action ~= entries.action
		or blackboard.attack_aborted or now() > entries.expires then
		host_area_attacks[attacker_id] = nil
				
		return func(system, unit, callback_name, param)
	end

	local entries_by_unit = {}
	local callback_time = now()

	for _, entry in pairs(entries.targets) do
		entry.callback_name = callback_name
		entry.callback_time = callback_time
		entry.callback_index = 1

		if Unit.alive(entry.target) and blackboard.action == entry.action then
			entries_by_unit[entry.target] = entry
		end
	end

	context = {
		kind = "area_attack",
		attacker = unit,
		action = blackboard.action,
		entries_by_unit = entries_by_unit,
	}

	local result = func(system, unit, callback_name, param)

	context = nil
	host_area_attacks[attacker_id] = nil

	for id, entry in pairs(entries.targets) do
		if entry.blocked then
			if probe_recording then
				entry.observation = entry.observations[entry.callback_index]
				log_area_decision(entry, false, false)
			end
			entries.targets[id] = nil
		else
			local ping = network():ping_by_peer(entry.peer)

			if valid_number(ping, 5) and ping >= 0 then
				entry.ping = ping
				entry.expires = now() + math.min(MAX_WAIT, math.max(MIN_WAIT, ping * 1.5 + 0.05))
				local key = pending_key(entry.id, entry.callback_index)
				pending[key] = entry

				entry.observation = entry.observations[entry.callback_index]
				entry.observations[entry.callback_index] = nil

				if entry.observation then
					take_pending(key, true)
				end
			else
				print("[PING COMPENSATION] Attack compensation unavailable: invalid peer ping, preserving host hit decision")
				resolve(entry, false)
				entries.targets[id] = nil
			end
		end
	end

	return result
end

mod:hook("AnimationSystem", "animation_callback", function (func, system, unit, callback_name, param)
	if callback_name ~= "anim_cb_damage" and callback_name ~= "anim_cb_special_damage" and callback_name ~= "anim_cb_frenzy_damage"
		or not mod:is_enabled() or not Managers.player or not network()
		or not unit or not Unit.alive(unit) then
		return func(system, unit, callback_name, param)
	end

	local manager = network()
	local attacker_id = manager:unit_game_object_id(unit)

	if not attacker_id then
		return func(system, unit, callback_name, param)
	end

	if not system.is_server then
		local attack = client_attacks[attacker_id]
		local player = Managers.player:local_player()
		local target = player and player.player_unit

		if attack and now() <= attack.expires and target and Unit.alive(target)
			and (attack.kind == "area_attack" and callback_name ~= "anim_cb_frenzy_damage"
				or attack.kind ~= "area_attack" and (callback_name == "anim_cb_damage"
					or attack.combo_attack and callback_name == "anim_cb_frenzy_damage"))
			and manager:unit_game_object_id(target) == attack.target_id then
			attack.callback_index = attack.callback_index + 1
			local status = ScriptUnit.has_extension(target, "status_system")

			if status then
				update_client_attack(attack, unit, target, status, now())
				local attacker_pos = POSITION_LOOKUP[unit] or Unit.world_position(unit, 0)
				local target_pos = POSITION_LOOKUP[target] or Unit.world_position(target, 0)
				local forward = Quaternion.forward(Unit.local_rotation(unit, 0))
				local peer = host_peer()
				local area_hit = false

				if attack.kind == "area_attack" then
					area_hit = client_area_attack_hit(attack, unit, target)

					if area_hit == nil then
						print("[PING COMPENSATION] Area-attack overlap query unavailable on client, host will use its original hit decision")
					end

					if probe_recording then
						print(string.format(
							"[PING COMPENSATION] Area client callback: attack_id=%s attacker=%s target=%s callback=%s callback_index=%s client_callback_t=%.3f since_begin_received_s=%.3f client_overlap=%s dodging=%s",
							tostring(attack.id), tostring(attacker_id), tostring(attack.target_id), callback_name,
							tostring(attack.callback_index), now(), now() - attack.begin_time, tostring(area_hit),
							tostring(not not status:get_is_dodging())))
					end
				end

				if peer and area_hit ~= nil then
					mod:network_send("pc_melee_observation", peer, VERSION, attack.id, attacker_id, attack.target_id,
						target_pos.x - attacker_pos.x, target_pos.y - attacker_pos.y, target_pos.z - attacker_pos.z,
						forward.x, forward.y, not not status:get_is_dodging(), attack.locked, area_hit, attack.callback_index)
				end
			end

			if not attack.multi_callback then
				client_attacks[attacker_id] = nil
			end
		end

		return func(system, unit, callback_name, param)
	end

	local area_entries = host_area_attacks[attacker_id]

	if area_entries and callback_name ~= "anim_cb_frenzy_damage" then
		return resolve_area_attack_callback(func, system, unit, callback_name, param, attacker_id, area_entries)
	end

	local frenzy = callback_name == "anim_cb_frenzy_damage"

	if callback_name ~= "anim_cb_damage" and not frenzy then
		return func(system, unit, callback_name, param)
	end

	local attack = host_attacks[attacker_id]
	local blackboard = BLACKBOARDS[unit]
	local combo = blackboard and blackboard.combo_attack_data
	local target = attack and attack.target
	local status = target and Unit.alive(target) and ScriptUnit.has_extension(target, "status_system")
	local callback_index

	if frenzy and (not attack or attack.active_node ~= BTComboAttackAction) then
		return func(system, unit, callback_name, param)
	end

	if attack and blackboard == attack.blackboard and blackboard.active_node == attack.active_node
		and blackboard.action == attack.action then
		attack.callback_index = attack.callback_index + 1
		callback_index = attack.callback_index
	end

	if not attack or not blackboard or blackboard ~= attack.blackboard or blackboard.active_node ~= attack.active_node
		or attack.active_node ~= BTAttackAction and attack.active_node ~= BTComboAttackAction
		or frenzy and (attack.active_node ~= BTComboAttackAction or not combo or combo.attacking_target ~= target
			or combo.current_attack_name ~= attack.combo_attack_name)
		or not frenzy and blackboard.attacking_target ~= target
		or blackboard.action ~= attack.action or not attack.action or not blackboard.breed
		or not attack.action.damage or blackboard.active_node == BTAttackAction and blackboard.anim_cb_damage or blackboard.attack_aborted
		or not frenzy and (blackboard.has_line_of_sight == false or blackboard.active_node.anim_cb_damage)
		or not status or status:is_blocking() or now() > attack.expires then
		if attack and callback_index then
			attack.observations[callback_index] = nil

			if not attack.multi_callback then
				host_attacks[attacker_id] = nil
			end
		end

		return func(system, unit, callback_name, param)
	end

	local ping = manager:ping_by_peer(attack.peer)

	if not valid_number(ping, 5) or ping < 0 then
		print("[PING COMPENSATION] Melee compensation unavailable! Where the fuck are you connecting from?")
		attack.observations[callback_index] = nil

		if not attack.multi_callback then
			host_attacks[attacker_id] = nil
		end

		return func(system, unit, callback_name, param)
	end

	local attacker_pos = POSITION_LOOKUP[unit] or Unit.world_position(unit, 0)
	local target_pos = POSITION_LOOKUP[target] or Unit.world_position(target, 0)
	local forward = Quaternion.forward(Unit.local_rotation(unit, 0))
	local geometry_blackboard = {
		breed = blackboard.breed,
		target_dodged_during_attack = blackboard.target_dodged_during_attack,
		set_dodge_rotation_timer = blackboard.set_dodge_rotation_timer,
		attack_range_flat = blackboard.attack_range_flat,
		attack_range_up = blackboard.attack_range_up,
		attack_range_down = blackboard.attack_range_down,
	}
	local unlocked_snapshot, reason = geometry.snapshot(attacker_pos, target_pos, forward, attack.action, geometry_blackboard)

	if not unlocked_snapshot then
		print("[PING COMPENSATION] Melee compensation unavailable: %s.", reason)

		attack.observations[callback_index] = nil

		if not attack.multi_callback then
			host_attacks[attacker_id] = nil
		end

		return func(system, unit, callback_name, param)
	end

	geometry_blackboard.locked_attack_rotation = true
	local locked_snapshot = geometry.snapshot(attacker_pos, target_pos, forward, attack.action, geometry_blackboard)

	local callback_entry = copy_for_callback(attack, callback_index)
	callback_entry.frenzy = frenzy
	callback_entry.combo = frenzy and combo or nil
	callback_entry.combo_start_time = frenzy and combo.attack_start_time or nil
	callback_entry.unlocked_snapshot = unlocked_snapshot
	callback_entry.locked_snapshot = locked_snapshot
	callback_entry.vanilla_hit = DamageUtils.check_distance(attack.action, blackboard, unit, target)
		and DamageUtils.check_infront(unit, target)
	callback_entry.expires = now() + math.min(MAX_WAIT, math.max(MIN_WAIT, ping * 1.5 + 0.05))
	context = callback_entry
	local result = func(system, unit, callback_name, param)
	context = nil

	if not attack.multi_callback then
		host_attacks[attacker_id] = nil
	end

	if callback_entry.damage_func or callback_entry.frenzy_func then
		local key = pending_key(callback_entry.id, callback_index)
		pending[key] = callback_entry

		if callback_entry.observation then
			take_pending(key, true)
		end
	end

	return result
end)

mod.ping_compensation_melee = {
	protocol_version = VERSION,
	supports_area_attack = valid_area_attack_action,
	host_peer = host_peer,
	peer_ready = function (peer)
		return peer and peers[peer] and now() - peers[peer] <= PEER_EXPIRY
	end,
	set_probe_recording = function (enabled)
		probe_recording = enabled
	end,
	update = function ()
		if not mod:is_enabled() or not Managers.player or not Managers.time or not network() then
			return
		end

		local t = now()

		if not Managers.player.is_server and t >= next_hello then
			local peer = host_peer()

			if peer then
				mod:network_send("pc_melee_hello", peer, VERSION)
			end

			next_hello = t + HELLO_INTERVAL
		end

		for id, attack in pairs(pending) do
			if t >= attack.expires then
				if not timeout_warnings[attack.peer] or t - timeout_warnings[attack.peer] >= 10 then
					print("Client melee observation timed out, using the host's ORIGINAL hit decision instead")
					timeout_warnings[attack.peer] = t
				end

				take_pending(id, false)
			end
		end

		for id, attack in pairs(host_attacks) do
			if t >= attack.expires then
				host_attacks[id] = nil
			end
		end

		for id, attack in pairs(host_area_attacks) do
			if t >= attack.expires then
				host_area_attacks[id] = nil
			end
		end

		for id, attack in pairs(client_attacks) do
			if t >= attack.expires then
				client_attacks[id] = nil
			else
				local storage = Managers.state.unit_storage
				local unit = storage and storage:unit(id)
				local player = Managers.player:local_player()
				local target = player and player.player_unit
				local status = target and Unit.alive(target) and ScriptUnit.has_extension(target, "status_system")

				if unit and Unit.alive(unit) and status and network():unit_game_object_id(target) == attack.target_id then
					update_client_attack(attack, unit, target, status, t)
				end
			end
		end
	end,
	clear = clear,
}
