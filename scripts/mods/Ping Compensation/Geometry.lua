local mod = get_mod("Ping Compensation")

local geometry = {}

-- our own custom math check to re-evaluate positions
function geometry.check(snapshot)
	local dx = snapshot.target_x - snapshot.attacker_x
	local dy = snapshot.target_y - snapshot.attacker_y
	local dz = snapshot.target_z - snapshot.attacker_z
	local flat_length_squared = dx * dx + dy * dy
	local radius = snapshot.player_radius
	local in_range

	if snapshot.use_box_range then
		local flat_range = snapshot.range_flat + radius

		in_range = dz < snapshot.range_up
			and dz > snapshot.range_down
			and flat_length_squared < flat_range * flat_range
	else
		local distance_squared = flat_length_squared + dz * dz
		local reach = snapshot.weapon_reach + radius

		in_range = distance_squared <= reach * reach
	end

	local in_front = false

	if flat_length_squared > 0 then
		local dot = (dx * snapshot.forward_x + dy * snapshot.forward_y) / math.sqrt(flat_length_squared)

		in_front = dot > snapshot.reach_cone
	end

	return in_range, in_front
end

-- copy the attack geometry needed later when client's data arrives
function geometry.snapshot(attacker_position, target_position, forward, action, blackboard)
	local breed = blackboard.breed
	local dodged = blackboard.target_dodged_during_attack
		or blackboard.set_dodge_rotation_timer
		or blackboard.locked_attack_rotation
	local player_radius = dodged and (action.player_dodged_radius or breed.player_dodged_radius or 0.75) or 1
	local reach_cone = breed.weapon_reach_cone
		or (dodged and (action.player_dodged_cone or breed.player_dodged_cone or 0.95) or 0.866)
	local snapshot = {
		attacker_x = attacker_position.x,
		attacker_y = attacker_position.y,
		attacker_z = attacker_position.z,
		target_x = target_position.x,
		target_y = target_position.y,
		target_z = target_position.z,
		forward_x = forward.x,
		forward_y = forward.y,
		player_radius = player_radius,
		reach_cone = reach_cone,
		use_box_range = action.use_box_range and true or false,
	}

	if snapshot.use_box_range then
		snapshot.range_flat = blackboard.attack_range_flat
		snapshot.range_up = blackboard.attack_range_up
		snapshot.range_down = blackboard.attack_range_down

		if not snapshot.range_flat or not snapshot.range_up or not snapshot.range_down then
			return nil, "missing box range"
		end
	else
		snapshot.weapon_reach = action.weapon_reach or breed.weapon_reach or breed.radius

		if not snapshot.weapon_reach then
			return nil, "missing weapon reach"
		end
	end

	return snapshot
end

mod.ping_compensation_geometry = geometry
