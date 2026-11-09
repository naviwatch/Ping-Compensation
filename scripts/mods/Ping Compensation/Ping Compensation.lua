local mod = get_mod("Ping Compensation")

mod:dofile("scripts/mods/Ping Compensation/Geometry")
mod:dofile("scripts/mods/Ping Compensation/Main")
mod:dofile("scripts/mods/Ping Compensation/Version")

local recording = false
local samples = {}
local sample_limit = 50
local callbacks = {
	anim_cb_damage = true,
	anim_cb_direct_damage = true,
	anim_cb_special_damage = true,
	anim_cb_frenzy_damage = true,
}

-- note down relevant animation callbacks after the game handles them and send them into samples
mod:hook_safe("flow_callback_animation_callback", function (params)
	local unit = params.unit
	local callback_name = params.callback

	if not recording or not callbacks[callback_name] or not unit or not Unit.alive(unit) then
		return
	end

	local network = Managers.state and Managers.state.network
	local player_manager = Managers.player
	local time_manager = Managers.time

	if not network or not player_manager or not time_manager then
		return
	end

	local breed = Unit.get_data(unit, "breed")
	local unit_id = network:unit_game_object_id(unit)

	if not breed or breed.is_player or not unit_id then
		return
	end

	local target
	local blackboard

	if player_manager.is_server then
		blackboard = BLACKBOARDS[unit]
		local combo = blackboard and blackboard.combo_attack_data
		target = blackboard and (blackboard.attacking_target or combo and combo.attacking_target or blackboard.drag_target_unit)
	else
		local player = player_manager:local_player()
		target = player and player.player_unit
	end

	if not target or not Unit.alive(target) then
		return
	end

	local owner = player_manager:unit_owner(target)

	if not owner or owner.bot_player then
		return
	end

	local attacker_position = Unit.world_position(unit, 0)
	local target_position = Unit.world_position(target, 0)
	local forward = Quaternion.forward(Unit.local_rotation(unit, 0))
	local distance = Vector3.distance(attacker_position, target_position)

	if not player_manager.is_server and distance > 10 then
		return
	end

	local status = ScriptUnit.has_extension(target, "status_system")
	local target_id = network:unit_game_object_id(target)
	local ping = "n/a"

	if player_manager.is_server and owner.remote then
		local ping_seconds = network:ping_by_peer(owner.peer_id)

		ping = type(ping_seconds) == "number" and string.format("%.0fms", ping_seconds * 1000) or "unavailable"
	end

	local active_node = blackboard and blackboard.active_node
	local active_node_name = active_node and (active_node.name or "unknown") or "unavailable"
	local combo = blackboard and blackboard.combo_attack_data
	local attack_name = active_node == BTComboAttackAction and combo and combo.current_attack_name
		or blackboard and blackboard.action and blackboard.action.name or "unavailable"
	local geometry_result = "client-node-unavailable"

	if player_manager.is_server then
		if not blackboard then
			geometry_result = "no-blackboard"
		elseif not active_node then
			geometry_result = "no-active-node"
		elseif active_node == BTStormVerminAttackAction then
			local supported = mod.ping_compensation_melee.supports_area_attack(blackboard.action)

			geometry_result = supported and "area-attack-eligible" or "unsupported-area-attack"
		elseif active_node ~= BTAttackAction and active_node ~= BTComboAttackAction then
			geometry_result = "unsupported-node:" .. tostring(active_node_name)
		elseif not blackboard.action or not blackboard.breed then
			geometry_result = "missing-attack-data"
		else
			local geometry = mod.ping_compensation_geometry
			local snapshot, reason = geometry.snapshot(attacker_position, target_position, forward, blackboard.action, blackboard)

			if snapshot then
				local in_range, in_front = geometry.check(snapshot)

				geometry_result = string.format("range:%s,front:%s,los:%s", tostring(in_range), tostring(in_front), tostring(blackboard.has_line_of_sight))
			else
				geometry_result = reason
			end
		end
	end

	local sample = string.format(
		"%s t=%.3f enemy=%s breed=%s target=%s attack=%s callback=%s distance=%.2f effective_dodge=%s ping=%s relative=(%.3f,%.3f,%.3f) forward=(%.3f,%.3f) node=%s geometry=%s",
		player_manager.is_server and "host" or "client",
		time_manager:time("game"),
		tostring(unit_id),
		tostring(breed.name),
		tostring(target_id),
		tostring(attack_name),
		callback_name,
		distance,
		status and tostring(status:get_is_dodging()) or "unavailable",
		ping,
		target_position.x - attacker_position.x,
		target_position.y - attacker_position.y,
		target_position.z - attacker_position.z,
		forward.x,
		forward.y,
		tostring(active_node_name),
		geometry_result
	)

	if #samples == sample_limit then
		table.remove(samples, 1)
	end

	samples[#samples + 1] = sample
end)

mod:command("ping_probe", mod:localize("probe_command_description"), function (action)
	if action == "start" then
		samples = {}
		recording = true
		mod.ping_compensation_melee.set_probe_recording(true)
		mod:echo("Starting ping recording")
	elseif action == "stop" then
		recording = false
		mod.ping_compensation_melee.set_probe_recording(false)
		mod:echo("Stopping ping recording. Use '/ping_probe report' next")
	elseif action == "report" then
		mod:echo(string.format("Ping probe: %d captured events (maximum %d)", #samples, sample_limit))

		for i = 1, #samples do
			mod:echo(samples[i])
		end
	else
		mod:echo("Usage: '/ping_probe start', '/ping_probe stop', or '/ping_probe report'")
	end
end)

-- discard fucking everything when the mod is disabled
mod.on_disabled = function ()
	mod.ping_compensation_version.clear()
	mod.ping_compensation_melee.clear(true)
	recording = false
	mod.ping_compensation_melee.set_probe_recording(false)
	samples = {}
end

mod.update = function (dt)
	mod.ping_compensation_melee.update()
	mod.ping_compensation_version.update(dt)
end

-- prevent state from leaking between runs
mod.on_game_state_changed = function (status, state_name)
	if status == "exit" and state_name == "StateIngame" then
		mod.ping_compensation_version.clear()
		mod.ping_compensation_melee.clear(true)
		recording = false
		mod.ping_compensation_melee.set_probe_recording(false)
		samples = {}
	end
end
