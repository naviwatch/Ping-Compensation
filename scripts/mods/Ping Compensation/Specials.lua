local mod = get_mod("Ping Compensation")
local VERSION = mod.ping_compensation_melee.protocol_version
local pending = {}
local next_id = 0

local function now()
	return Managers.time:time("game")
end

local function valid_number(value, limit)
	return type(value) == "number" and value == value and value >= -limit and value <= limit
end

local function ready_peer(target)
	local network = Managers.state and Managers.state.network
	local owner = target and Unit.alive(target) and Managers.player:unit_owner(target)
	local peer = owner and owner.remote and not owner.bot_player and owner.peer_id

	if not network or not mod.ping_compensation_melee.peer_ready(peer) then
		return
	end

	local ping = network:ping_by_peer(peer)
	local target_id = network:unit_game_object_id(target)

	if not target_id or not valid_number(ping, 5) or ping < 0 then
		print("[PING COMPENSATION] Special attack compensation unavailable: invalid target or ping")
		return
	end

	return peer, target_id, math.min(0.75, math.max(0.1, ping * 1.5 + 0.05))
end

local function request(kind, unit, target, blackboard, extra1, extra2, extra3)
	local peer, target_id, wait = ready_peer(target)
	local network = Managers.state.network
	local attacker_id = network:unit_game_object_id(unit)

	if not peer or not attacker_id then
		return
	end

	next_id = next_id + 1
	local entry = {
		id = next_id, kind = kind, attacker = unit, target = target, blackboard = blackboard,
		peer = peer, attacker_id = attacker_id, target_id = target_id, expires = now() + wait,
	}

	pending[unit] = entry
	mod:network_send("pc_special_request", peer, VERSION, entry.id, kind, attacker_id, target_id, extra1, extra2, extra3)
	return entry
end

local function hook_dodged(unit, target, action, dodging, invisible, host_snapshot)
	if not dodging and not invisible then
		return false
	end

	local pos = host_snapshot and POSITION_LOOKUP[unit] or Unit.world_position(unit, 0)
	local target_pos = host_snapshot and POSITION_LOOKUP[target] or Unit.world_position(target, 0)
	local relative = target_pos - pos
	local direction = Vector3.normalize(Vector3.flat(relative))
	local forward = Quaternion.forward(Unit.local_rotation(unit, 0))
	local dot = Vector3.dot(direction, forward)
	local angle = math.acos(math.max(-1, math.min(1, dot))) * 180 / math.pi

	return angle > action.dodge_angle or Vector3.length_squared(relative) >= action.dodge_distance * action.dodge_distance
end

local function client_leap_hit(unit, target, vx, vy, vz, snapping)
	if not Unit.has_node(unit, "j_neck") or not Unit.has_node(target, "j_neck") then
		return nil
	end

	local world = Unit.world(unit)
	local physics_world = World.get_data(world, "physics_world")

	if not physics_world then
		return nil
	end

	local pos = Unit.world_position(unit, Unit.node(unit, "j_neck"))
	local actors, count = PhysicsWorld.immediate_overlap(physics_world, "shape", "sphere", "position", pos,
		"size", 1, "types", "both", "collision_filter", "filter_player_and_husk_trigger")

	if type(actors) ~= "table" or type(count) ~= "number" then
		return nil
	end

	local target_pos = Unit.world_position(target, Unit.node(target, "j_neck"))
	local velocity = Vector3(vx, vy, vz)
	local velocity_length = Vector3.length(velocity)
	local to_target = target_pos - pos
	local distance = Vector3.length(to_target)

	if snapping then
		if velocity_length == 0 or distance == 0 then
			return nil
		end

		local direction = velocity / velocity_length

		if Vector3.dot(direction, to_target / distance) < 0 then
			return false
		end
	end

	for i = 1, count do
		if Actor.unit(actors[i]) == target then
			return true
		end
	end

	if snapping and distance < 2 then
		local direction = velocity / velocity_length
		local closest = Geometry.closest_point_on_line(pos, pos, pos + direction * 3)
		return Vector3.length(Vector3.flat(closest - target_pos)) < 1
	end

	return false
end

mod:network_register("pc_special_request", function (sender, version, id, kind, attacker_id, target_id, a, b, c)
	if not mod:is_enabled() or not Managers.player or Managers.player.is_server
		or sender ~= mod.ping_compensation_melee.host_peer() or version ~= VERSION
		or not valid_number(id, 2147483647) or id < 1 or id ~= math.floor(id)
		or not valid_number(attacker_id, 2147483647) or not valid_number(target_id, 2147483647)
		or kind ~= "hook" and kind ~= "leap" and kind ~= "leap_snap" then
		return
	end

	local player = Managers.player:local_player()
	local target = player and player.player_unit
	local network = Managers.state and Managers.state.network
	local storage = Managers.state and Managers.state.unit_storage
	local unit = storage and storage:unit(attacker_id)

	if not target or not Unit.alive(target) or not unit or not Unit.alive(unit)
		or not network or network:unit_game_object_id(target) ~= target_id then
		return
	end

	local result
	if kind == "hook" then
		if not valid_number(a, 180) or a < 0 or not valid_number(b, 50) or b <= 0 then
			return
		end

		local status = ScriptUnit.has_extension(target, "status_system")
		if not status then
			return
		end
		result = not hook_dodged(unit, target, { dodge_angle = a, dodge_distance = b },
			status:get_is_dodging(), status:is_invisible())
	else
		if not valid_number(a, 100) or not valid_number(b, 100) or not valid_number(c, 100) then
			return
		end
		result = client_leap_hit(unit, target, a, b, c, kind == "leap_snap")
	end

	if result == nil then
		print("[PING COMPENSATION] Special attack client geometry unavailable; host will use its original decision")
		return
	end
	mod:network_send("pc_special_result", sender, VERSION, id, attacker_id, target_id, result)
end)

mod:network_register("pc_special_result", function (sender, version, id, attacker_id, target_id, result)
	if not mod:is_enabled() or not Managers.player or not Managers.player.is_server or version ~= VERSION
		or not valid_number(id, 2147483647) or not valid_number(attacker_id, 2147483647)
		or not valid_number(target_id, 2147483647) or type(result) ~= "boolean" then
		return
	end

	local storage = Managers.state and Managers.state.unit_storage
	local unit = storage and storage:unit(attacker_id)
	local entry = unit and pending[unit]

	if entry and entry.id == id and entry.peer == sender and entry.attacker_id == attacker_id
		and entry.target_id == target_id and not entry.ready and now() <= entry.expires then
		entry.result = result
		entry.ready = true
		entry.client_result = true
	end
end)

mod:hook("BTPackMasterAttackAction", "attack_success", function (func, self, unit, blackboard)
	if not mod:is_enabled() or not Managers.player or not Managers.player.is_server or pending[unit]
		or blackboard.active_node ~= BTPackMasterAttackAction then
		return func(self, unit, blackboard)
	end

	local target = blackboard.target_unit
	local action = blackboard.action
	local status = blackboard.target_unit_status_extension

	if not target or not Unit.alive(target) or not status or not action
		or not valid_number(action.dodge_angle, 180) or not valid_number(action.dodge_distance, 50)
		or action.dodge_angle < 0 or action.dodge_distance <= 0 then
		return func(self, unit, blackboard)
	end

	local host_dodged = hook_dodged(unit, target, action, status:get_is_dodging(), status:is_invisible(), true)
	local line_of_sight = not host_dodged and PerceptionUtils.pack_master_has_line_of_sight_for_attack(blackboard.physics_world, unit, target)
	local entry = request("hook", unit, target, blackboard, action.dodge_angle, action.dodge_distance, 0)

	if not entry then
		return func(self, unit, blackboard)
	end

	entry.action = action
	entry.host_dodged = host_dodged
	entry.host_success = not host_dodged and line_of_sight
	entry.line_of_sight = host_dodged and PerceptionUtils.pack_master_has_line_of_sight_for_attack(blackboard.physics_world, unit, target) or line_of_sight
end)

mod:hook("BTPackMasterAttackAction", "run", function (func, self, unit, blackboard, t, dt)
	local entry = pending[unit]

	if not entry or entry.kind ~= "hook" then
		return func(self, unit, blackboard, t, dt)
	end

	if entry.blackboard ~= blackboard or blackboard.active_node ~= BTPackMasterAttackAction
		or blackboard.action ~= entry.action or blackboard.target_unit ~= entry.target
		or blackboard.attack_aborted or not Unit.alive(entry.target)
		or not AiUtils.is_of_interest_to_packmaster(unit, entry.target) then
		pending[unit] = nil
		return func(self, unit, blackboard, t, dt)
	end

	if not entry.ready and now() < entry.expires then
		return "running"
	end

	pending[unit] = nil
	local dodged = entry.client_result and not entry.result or not entry.client_result and entry.host_dodged
	blackboard.attack_success = entry.client_result and entry.result and entry.line_of_sight or not entry.client_result and entry.host_success

	if dodged then
		QuestSettings.check_pack_master_dodge(entry.target)
	elseif blackboard.attack_success then
		local first_person = ScriptUnit.has_extension(entry.target, "first_person_system")
		if first_person then
			first_person:animation_event("shake_get_hit")
		end
	end

	if not entry.client_result then
		print("[PING COMPENSATION] Packmaster observation unavailable; using host decision")
	else
		print(string.format("[PING COMPENSATION] Packmaster decision: attacker=%s target=%s host_dodged=%s client_dodged=%s hit=%s",
			tostring(entry.attacker_id), tostring(entry.target_id), tostring(entry.host_dodged),
			tostring(not entry.result), tostring(blackboard.attack_success)))
	end

	return func(self, unit, blackboard, t, dt)
end)

mod:hook("BTCrazyJumpAction", "run", function (func, self, unit, blackboard, t, dt)
	local entry = pending[unit]

	if entry and (entry.kind == "leap" or entry.kind == "leap_snap") then
		if entry.blackboard ~= blackboard or blackboard.jump_data ~= entry.jump_data
			or entry.jump_data.target_unit ~= entry.target or not Unit.alive(entry.target)
			or not AiUtils.is_of_interest_to_gutter_runner(unit, entry.target, blackboard) then
			pending[unit] = nil
			return func(self, unit, blackboard, t, dt)
		end

		if not entry.ready and now() < entry.expires then
			return "running"
		end

		pending[unit] = nil
		if not entry.client_result then
			print("[PING COMPENSATION] Gutter-runner observation unavailable; using host decision")
			return "done"
		end

		print(string.format("[PING COMPENSATION] Gutter-runner decision: attacker=%s target=%s client_hit=%s",
			tostring(entry.attacker_id), tostring(entry.target_id), tostring(entry.result)))
		if entry.result then
			return "done"
		end

		entry.jump_data.state = "in_air"
		entry.jump_data.snap_failed = true
		return "running"
	end

	local jump = blackboard.jump_data
	local state = jump and jump.state
	local result = func(self, unit, blackboard, t, dt)

	if result ~= "done" or not mod:is_enabled() or not Managers.player or not Managers.player.is_server
		or not jump or blackboard.jump_data ~= jump or not jump.target_unit then
		return result
	end

	local velocity = blackboard.locomotion_extension:current_velocity()
	entry = request(state == "snapping" and "leap_snap" or "leap",
		unit, jump.target_unit, blackboard, velocity.x, velocity.y, velocity.z)

	if not entry then
		return result
	end

	entry.jump_data = jump
	return "running"
end)

mod:hook_safe("BTPackMasterAttackAction", "leave", function (self, unit)
	pending[unit] = nil
end)
mod:hook_safe("BTCrazyJumpAction", "leave", function (self, unit)
	pending[unit] = nil
end)

mod.ping_compensation_specials = {
	update = function ()
		for unit in pairs(pending) do
			if not Unit.alive(unit) then
				pending[unit] = nil
			end
		end
	end,
	clear = function (exiting)
		if exiting then
			pending = {}
		else
			for _, entry in pairs(pending) do
				entry.ready = true
				entry.client_result = false
			end
		end
	end,
}
