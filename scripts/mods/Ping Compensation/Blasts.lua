local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Explosions and area skills (D37). A blast this player sets off (a weapon whose hits explode, a career skill such as
-- the Mercenary's shout or the Slayer's leap) reaches the host as an explosion message (rpc_create_explosion), from
-- which the host works out who is hit. A projectile's blast (a bomb, a fireball) doesn't: each machine sets off its own
-- copy when its copy of the projectile lands, and the host's (PlayerProjectileHuskExtension.do_aoe) is the real one.
-- For the enemies in pc.REACTION_BREEDS this client now works the same blast out too, with the game's own maths, and
-- shows the staggers and kills at once, as for its hits (D26 to D28):
--   * Client: right after the explosion message goes out, or its own projectile's blast goes off, pc_blast lists the
--     covered enemies this client decides for that blast (in several parts if it is long), then pc_blast_staggers
--     carries their staggers several to a message, and pc_kill follows for those it killed (Reactions.lua).
--   * Host: books the blast's damage as before, from its own maths, but skips its own stagger for the enemies on that
--     list and plays the client's instead (HostReactions.lua). An enemy its blast reached that the list doesn't name
--     (the two machines saw it at slightly different spots) gets the host's own stagger, as in vanilla. Until the
--     whole list arrives, the host holds those staggers back, for at most BLAST_WAIT. A projectile's list is matched
--     to the host's blast by the projectile's network id, an explosion message's by its position.
-- Damage over time and lingering areas stay with the host (T8). Blasts the host sets off itself (enemies' attacks and
-- deaths, buffs, mutators) only go out to clients, so they stay with the host too.

local blasts = {}

pc.blasts = blasts

local BLAST_WAIT = 0.5 -- seconds the host holds its own staggers for a client's blast back, waiting for its list
local BLAST_MEMORY = 3 -- seconds a blast is remembered, on the host
local MATCH_DISTANCE = 0.25 -- metres between where the client and the host have a blast; positions travel rounded
local LIST_PART_LENGTH = 300 -- characters of network ids per pc_blast message; VMF allows 500 for all its values
local MAX_LIST_LENGTH = 500
local MAX_LIST_PARTS = 20
local MAX_NAME_LENGTH = 64

local next_blast_id = 0

local ok_perks, buff_perk_names = pcall(require, "scripts/unit_extensions/default_player_unit/buffs/settings/buff_perk_names")
local NO_FRIENDLY_FIRE_PERK = ok_perks and type(buff_perk_names) == "table" and buff_perk_names.no_explosion_friendly_fire or "no_explosion_friendly_fire"

local function lerp(a, b, t)
	return a + (b - a) * t
end

-- Client --------------------------------------------------------------------------------------------------------

-- The host branch of DamageUtils.create_explosion (damage_utils.lua:1126 to :1470), without its side effects: the
-- blast's radius and power, the units it reaches (an overlap, then line-of-sight rays for blasts that want them),
-- nearest first, and for each enemy it damages, its distance, power level, hit zone and whether its shield blocked.
-- Returns the covered enemies among them and the blast's numbers, or nil for a blast this copy can't follow.
local function find_targets(world, attacker, position, rotation, template, scale, attacker_power_level)
	local explosion_data = template.explosion

	if type(explosion_data) ~= "table" then
		return nil
	end

	-- Weaves' winds change a blast in ways not copied here. A cone scaled sideways with line of sight would make the
	-- game's own code fail (damage_utils.lua:1318), so no player blast can use it.
	if explosion_data.wind_mutator and Managers.weave:get_active_wind() or explosion_data.only_line_of_sight and explosion_data.explosion_right_scaling then
		return nil
	end

	local difficulty = Managers.state.difficulty
	local difficulty_rank = difficulty:get_difficulty()
	local fallback_difficulty = difficulty.fallback_difficulty
	local radius = explosion_data.radius
	local max_damage_radius = explosion_data.max_damage_radius or 0
	local radius_min, radius_max = explosion_data.radius_min, explosion_data.radius_max

	if radius_min and radius_max then
		radius = lerp(radius_min, radius_max, scale)

		if explosion_data.max_damage_radius_min then
			max_damage_radius = lerp(explosion_data.max_damage_radius_min, explosion_data.max_damage_radius_max, scale)
		end
	end

	if type(radius) ~= "number" then
		return nil
	end

	local buffs = ScriptUnit.has_extension(attacker, "buff_system")

	if buffs then
		local multiplier = 1

		if template.is_grenade then
			multiplier = multiplier + (buffs:apply_buffs_to_value(1, "grenade_radius") - 1)
		end

		multiplier = multiplier + (buffs:apply_buffs_to_value(1, "explosion_radius") - 1)
		radius = radius * multiplier
		max_damage_radius = max_damage_radius * multiplier
	end

	local difficulty_power_level = explosion_data.difficulty_power_level and (explosion_data.difficulty_power_level[difficulty_rank] or explosion_data.difficulty_power_level[fallback_difficulty])
	local power_settings = difficulty_power_level or explosion_data
	local power_level = power_settings.power_level
	local power_level_min = power_settings.power_level_min
	local power_level_max = power_settings.power_level_max

	if explosion_data.use_attacker_power_level then
		local offset = explosion_data.attacker_power_level_offset or rawget(_G, "DefaultAttackerPowerLevelOffset")

		if type(attacker_power_level) ~= "number" or type(offset) ~= "number" then
			return nil
		end

		power_level = attacker_power_level
		power_level_max = attacker_power_level
		power_level_min = power_level_max * offset
	end

	if explosion_data.scale_power_level then
		local factor = math.max(explosion_data.scale_power_level, scale)

		power_level = power_level and power_level * factor
		power_level_max = power_level_max and power_level_max * factor
		power_level_min = power_level_min and power_level_min * factor
	end

	local power_level_glance = power_settings.power_level_glance
	local do_damage = power_level or power_level_min and power_level_max or false
	local ignore_attacker_unit = explosion_data.ignore_attacker_unit
	local collision_filter = explosion_data.collision_filter or "filter_explosion_overlap"
	local only_line_of_sight = explosion_data.only_line_of_sight
	local attacker_player = Managers.player:owner(attacker)
	local difficulty_settings = difficulty:get_difficulty_settings()
	local friendly_fire_allowed = attacker_player ~= nil and (explosion_data.allow_friendly_fire_override or DamageUtils.allow_friendly_fire_ranged(difficulty_settings, attacker_player))

	if buffs and buffs:has_buff_perk(NO_FRIENDLY_FIRE_PERK) then
		friendly_fire_allowed = false
	end

	local friendly_fire_enabled = friendly_fire_allowed and not explosion_data.no_friendly_fire
	local physics_world = World.physics_world(world)
	local actors, num_actors = PhysicsWorld.immediate_overlap(physics_world, "shape", "sphere", "position", position, "size", radius, "collision_filter", collision_filter)
	local forward_scaling = explosion_data.explosion_forward_scaling
	local cone = explosion_data.explosion_cone_angle and math.cos(explosion_data.explosion_cone_angle / 2)
	local explosion_direction = (forward_scaling or explosion_data.explosion_right_scaling or cone) and Quaternion.forward(rotation)
	local seen = {}
	local hits = {}

	for i = 1, num_actors or 0 do
		local hit_actor = actors[i]
		local hit_unit = hit_actor and Actor.unit(hit_actor)

		if hit_unit and not seen[hit_unit] and ScriptUnit.has_extension(hit_unit, "health_system") and not Unit.get_data(hit_unit, "ignore_explosion_damage") and (not ignore_attacker_unit or hit_unit ~= attacker) then
			local hit_zone_name = DamageUtils.aoe_hit_zone(hit_unit, hit_actor)

			if hit_zone_name ~= "afro" then
				local delta = Unit.world_position(hit_unit, 0) + Vector3.up() - position
				local direction = Vector3.normalize(delta)
				local hit = false

				if not only_line_of_sight then
					hit = true

					if cone then
						hit = cone <= Vector3.dot(direction, explosion_direction)
					end

					if hit and forward_scaling then
						local modified = lerp(radius, radius * forward_scaling, math.abs(Vector3.dot(direction, explosion_direction)))

						hit = modified * modified >= Vector3.length_squared(delta)
					end
				else
					local in_cone = not cone or cone <= Vector3.dot(direction, explosion_direction)
					local in_range = true

					-- As the game has it: in range when the scaled radius is within the distance.
					if in_cone and forward_scaling then
						local modified = lerp(radius, radius * forward_scaling, math.abs(Vector3.dot(direction, explosion_direction)))

						in_range = modified * modified <= Vector3.length_squared(delta)
					end

					if in_cone and in_range then
						PhysicsWorld.prepare_actors_for_raycast(physics_world, position, direction, 0.1)

						local result = PhysicsWorld.immediate_raycast(physics_world, position, direction, radius, "all", "collision_filter", "filter_explosion_overlap_no_static")

						if result then
							for j = 1, #result do
								local raycast_unit = Actor.unit(result[j][4])

								if not AiUtils.unit_breed(raycast_unit) then
									break
								end

								if raycast_unit == hit_unit then
									hit = true

									break
								end
							end
						end
					end
				end

				if hit then
					seen[hit_unit] = true
					hits[#hits + 1] = hit_actor
				end
			end
		end
	end

	table.sort(hits, function (a, b)
		local a_unit, b_unit = Actor.unit(a), Actor.unit(b)
		local a_position = POSITION_LOOKUP[a_unit] or Unit.local_position(a_unit, 0)
		local b_position = POSITION_LOOKUP[b_unit] or Unit.local_position(b_unit, 0)

		return Vector3.distance_squared(position, a_position) < Vector3.distance_squared(position, b_position)
	end)

	local side_manager = Managers.state.side
	local targets = {}
	local target_number = 0

	for i = 1, #hits do
		local hit_actor = hits[i]
		local hit_unit = Actor.unit(hit_actor)
		local breed = Unit.get_data(hit_unit, "breed")
		local is_player = breed and breed.is_player or DamageUtils.is_player_unit(hit_unit)
		local is_ai = breed ~= nil and not is_player
		local is_ally = side_manager:is_ally(attacker, hit_unit)
		local damage_unit = not is_ally or friendly_fire_enabled

		if is_player then
			if explosion_data.ignore_players then
				damage_unit = false
			elseif not is_ally and damage_unit then
				local ghost_mode = ScriptUnit.has_extension(hit_unit, "ghost_mode_system")

				damage_unit = not ghost_mode or not ghost_mode:is_in_ghost_mode()
			end
		elseif attacker_player and is_ai and is_ally then
			damage_unit = false
		end

		if damage_unit then
			local target_radius, target_height = DamageUtils.calculate_aoe_size(hit_unit, is_ai and breed or nil)
			local unit_position = POSITION_LOOKUP[hit_unit] or Unit.local_position(hit_unit, 0)
			local top = unit_position + Vector3(0, 0, math.max(target_height - target_radius * 0.5, target_height * 0.5))
			local bottom = unit_position + Vector3(0, 0, math.min(target_radius * 0.5, target_height * 0.5))
			local closest = Geometry.closest_point_on_line(position, bottom, top)
			local hit_direction = closest - position
			local hit_distance = math.max(Vector3.length(hit_direction) - target_radius, 0)
			local glancing = max_damage_radius < hit_distance
			local scaled_power_level = power_level_min and power_level_max and lerp(power_level_min, power_level_max, scale) or nil
			local distance_factor = 1

			if max_damage_radius < hit_distance then
				local range = radius - max_damage_radius

				if range > 0 then
					distance_factor = 1 - (hit_distance - max_damage_radius) / range

					if explosion_data.exponential_falloff then
						distance_factor = distance_factor * distance_factor
					end
				end
			end

			if HEALTH_ALIVE[hit_unit] then
				target_number = target_number + 1
			end

			if is_ai and pc.REACTION_BREEDS[breed.name] then
				targets[#targets + 1] = {
					unit = hit_unit,
					breed = breed,
					hit_zone_name = DamageUtils.aoe_hit_zone(hit_unit, hit_actor),
					hit_distance = hit_distance,
					power_level = (glancing and power_level_glance or scaled_power_level or power_level or 0) * distance_factor,
					direction = Vector3Box(Vector3.normalize(hit_direction)),
					shield_blocked = AiUtils.attack_is_shield_blocked(hit_unit, attacker),
					target_number = target_number,
				}
			end
		end
	end

	return targets, radius, max_damage_radius, do_damage
end

local function send(message, ...)
	local host_peer = pc.host_peer()

	if host_peer then
		mod:network_send(message, host_peer, pc.VERSION, ...)
	end
end

-- The network ids, comma-separated, in pieces of at most LIST_PART_LENGTH characters. Always at least one piece, so
-- an empty list still tells the host to stagger that blast's enemies itself.
local function list_parts(ids)
	local parts = {}
	local current = {}
	local length = 0

	for i = 1, #ids do
		local id = ids[i]

		if length > 0 and length + 1 + #id > LIST_PART_LENGTH then
			parts[#parts + 1] = table.concat(current, ",")
			current = {}
			length = 0
		end

		current[#current + 1] = id
		length = length + (length > 0 and 1 or 0) + #id
	end

	parts[#parts + 1] = table.concat(current, ",")

	return parts
end

local function may_decide()
	return pc.attacks and not pc.broken and pc.host_fresh() and pc.compat.matches()
end

-- This player's blast, worked out here: the list of covered enemies this client decides, then their damage and
-- staggers. projectile_go_id is the network id of the projectile that set it off, or 0 for an explosion message.
local function work_out(attacker, template_name, template, position, rotation, scale, damage_source, attacker_power_level, projectile_go_id)
	local unit_storage = Managers.state.unit_storage
	local area_damage = Managers.state.entity:system("area_damage_system")

	if not template or not damage_source or not area_damage or not area_damage.world then
		return
	end

	local targets, radius, max_damage_radius, do_damage = find_targets(area_damage.world, attacker, position, rotation, template, scale or 1, attacker_power_level)

	if not targets then
		pc.count("client_blast_not_followed")
		pc.log("client blast template=%s: not worked out here, left to the host", template_name)

		return
	end

	local explosion_data = template.explosion
	local immune_breeds = explosion_data.immune_breeds
	local reactions = pc.reactions
	local decided = {}
	local ids = {}

	for i = 1, #targets do
		local target = targets[i]
		local unit = target.unit
		local breed = target.breed
		local immune = immune_breeds and (immune_breeds[breed.name] or immune_breeds.all)

		if Unit.alive(unit) and HEALTH_ALIVE[unit] and not immune and not reactions.killed_here(unit) and reactions.decides(unit) then
			-- AreaDamageSystem._damage_unit (area_damage_system.lua:355): a shield pushes the hit out to a glance.
			local hit_distance = target.shield_blocked and lerp(target.hit_distance, radius, 0.5) or target.hit_distance
			local profile_name = max_damage_radius < hit_distance and explosion_data.damage_profile_glance or explosion_data.damage_profile or "default"

			if not do_damage then
				profile_name = profile_name .. "_no_damage"
			end

			local damage_profile = rawget(DamageProfileTemplates, profile_name)
			local go_id = unit_storage:go_id(unit)

			if damage_profile and go_id then
				target.profile_name = profile_name
				target.damage_profile = damage_profile
				decided[#decided + 1] = target
				ids[#ids + 1] = tostring(go_id)
			end
		end
	end

	-- The list goes first, so the host knows whose staggers to hold back for this client's. A big blast's list takes
	-- several messages (VMF allows 500 characters for a message's values); the host waits for all of them.
	next_blast_id = next_blast_id + 1

	local blast_id = next_blast_id
	local parts = list_parts(ids)

	for part = 1, #parts do
		send("pc_blast", blast_id, part, #parts, template_name, pc.finite(position.x, 3), pc.finite(position.y, 3), pc.finite(position.z, 3), projectile_go_id, parts[part])
	end

	pc.count("client_blasts")
	pc.count("client_blast_targets", #decided)

	local t = pc.now()
	local kills = 0
	local batch = reactions.new_stagger_batch(damage_source)

	for i = 1, #decided do
		local target = decided[i]
		local translation = target.breed.hitbox_ragdoll_translation
		local ragdoll_actor = translation and (translation.j_spine or translation.j_spine1) or nil
		local ok, outcome = pc.guard("client blast target", reactions.blast_hit, target.unit, target.breed, attacker, target.damage_profile, target.profile_name, target.target_number, target.power_level, target.hit_zone_name, position, target.direction:unbox(), damage_source, target.shield_blocked, ragdoll_actor, t, batch)

		if ok and outcome == "kill" then
			kills = kills + 1
		end
	end

	local staggers = #batch.entries
	local _, messages = pc.guard("client blast staggers", reactions.send_stagger_batch, batch)

	pc.log("client blast template=%s source=%s enemies=%d kills=%d radius=%.2f blast=%d projectile=%d list_parts=%d staggers=%d stagger_messages=%d", template_name, damage_source, #decided, kills, radius, blast_id, projectile_go_id, #parts, staggers, messages or 0)
end

-- Called right after this client sends an explosion message to the host (NetworkTransmit.send_rpc_server), with that
-- message's own values, so this copy of the blast starts from exactly what the host gets.
function blasts.client_blast(attacker_unit_id, attacker_is_level_unit, position, rotation, explosion_template_id, scale, damage_source_id, attacker_power_level, is_critical_strike, source_attacker_unit_id)
	if attacker_is_level_unit or not may_decide() then
		return
	end

	local attacker = Managers.state.unit_storage:unit(attacker_unit_id)

	if not attacker or attacker ~= pc.local_player_unit() then
		return
	end

	local template_name = NetworkLookup.explosion_templates[explosion_template_id]
	local template = template_name and ExplosionUtils.get_template(template_name)

	work_out(attacker, template_name, template, position, rotation, scale, NetworkLookup.damage_sources[damage_source_id], attacker_power_level, 0)
end

-- Called right after this player's own projectile (a bomb, a fireball) has set off its blast on this screen
-- (PlayerProjectileUnitExtension.do_aoe), with the values the host's copy of the projectile uses for its own blast
-- (PlayerProjectileHuskExtension.do_aoe). No explosion message goes to the host for these.
function blasts.client_projectile_blast(extension, aoe_data, position)
	if not may_decide() then
		return
	end

	local attacker = extension._owner_unit
	local projectile = extension._projectile_unit

	if not attacker or attacker ~= pc.local_player_unit() or not projectile or not Unit.alive(projectile) then
		return
	end

	local projectile_go_id = Managers.state.unit_storage:go_id(projectile)
	local template_name = aoe_data.name

	if not projectile_go_id or type(template_name) ~= "string" then
		return
	end

	work_out(attacker, template_name, aoe_data, position, Unit.local_rotation(projectile, 0), extension.scale, extension.item_name, extension.power_level, projectile_go_id)
end

mod:hook_safe("NetworkTransmit", "send_rpc_server", function (self, rpc_name, ...)
	if rpc_name ~= "rpc_create_explosion" or self.is_server or pc.broken then
		return
	end

	pc.guard("client blast", blasts.client_blast, ...)
end)

-- A blast's explosion message (network_sync) is handled above, when it is sent.
mod:hook_safe("PlayerProjectileUnitExtension", "do_aoe", function (self, aoe_data, position, network_sync)
	if self._is_server or network_sync or pc.broken or type(aoe_data) ~= "table" or not aoe_data.explosion then
		return
	end

	pc.guard("client projectile blast", blasts.client_projectile_blast, self, aoe_data, position)
end)

-- Host ----------------------------------------------------------------------------------------------------------

local recent = {} -- peer -> list of that client's recent blasts
local early = {} -- peer -> lists that arrived before their blast
local gathering = {} -- peer -> the client's blast id -> the parts of that blast's list that have arrived

-- Whether a client's list (or part of one) and a blast on the host are the same blast. A projectile's blast is matched
-- by the projectile's network id, because the client's and the host's copies of the projectile can land a little
-- apart; an explosion message's by its position, which both have from the same message.
local function same_blast(entry, template_name, position, projectile_go_id)
	if entry.template_name ~= template_name then
		return false
	end

	if projectile_go_id ~= 0 or entry.projectile_go_id ~= 0 then
		return entry.projectile_go_id == projectile_go_id
	end

	return Vector3.distance(entry.position:unbox(), position) <= MATCH_DISTANCE
end

-- The newest blast of this client's with this template at this position on the host (where the host's own blast
-- books its targets).
local function find_blast(peer, template_name, position)
	local list = recent[peer]

	if not list then
		return nil
	end

	for i = #list, 1, -1 do
		local record = list[i]

		if record.template_name == template_name and Vector3.distance(record.position:unbox(), position) <= MATCH_DISTANCE then
			return record
		end
	end

	return nil
end

-- The newest blast of this client's that this list is for and that is still waiting for its list.
local function find_blast_for_list(peer, template_name, position, projectile_go_id)
	local list = recent[peer]

	if not list then
		return nil
	end

	for i = #list, 1, -1 do
		local record = list[i]

		if record.decided == nil and same_blast(record, template_name, position, projectile_go_id) then
			return record
		end
	end

	return nil
end

-- The host staggers this enemy itself after all, as vanilla would have, with the arguments of the stagger it held.
local function host_stagger(unit, held)
	if not Unit.alive(unit) or not HEALTH_ALIVE[unit] or not Unit.alive(held.attacker) then
		return
	end

	pc.host_reactions.forget_left_to_client(unit)
	pc.count("host_blast_host_staggers")

	DamageUtils.stagger_ai(pc.now(), held.damage_profile, held.target_index, held.power_level, unit, held.attacker, held.hit_zone_name, held.direction:unbox(), held.boost_curve_multiplier, held.is_critical_strike, held.blocked, held.damage_source, held.source_attacker and Unit.alive(held.source_attacker) and held.source_attacker or nil)
end

-- The client's list for a blast has arrived (or never will): the staggers held for enemies it doesn't name are the
-- host's own after all.
local function resolve(record, decided, reason)
	record.decided = decided

	local held_back = 0

	for unit, held in pairs(record.pending) do
		local go_id = Managers.state.unit_storage:go_id(unit)

		if not go_id or not decided[go_id] then
			held_back = held_back + 1

			pc.guard("host blast stagger", host_stagger, unit, held)
		end
	end

	record.pending = {}

	if held_back > 0 then
		pc.log("host blast template=%s from=%s: staggered %d enemies itself (%s)", record.template_name, record.name, held_back, reason)
	end
end

-- The parts of a list that has only partly arrived, for a blast that can't wait any longer. Normally every part
-- arrives together: they are sent in one go, one after the other.
local function partial_list(peer, template_name, position, projectile_go_id)
	local by_id = gathering[peer]

	if not by_id then
		return nil
	end

	for blast_id, entry in pairs(by_id) do
		if same_blast(entry, template_name, position, projectile_go_id) then
			by_id[blast_id] = nil

			return entry.decided, entry.count, entry.parts
		end
	end

	return nil
end

-- A blast of this client's that the host is about to work out, and whose list it waits for.
local function add_blast(peer, name, template_name, position, projectile_go_id)
	local record = {
		peer = peer,
		name = name,
		template_name = template_name,
		position = Vector3Box(position),
		projectile_go_id = projectile_go_id,
		t = pc.now(),
		decided = nil, -- go id -> true, once the client's list has arrived
		pending = {}, -- enemy unit -> the host's own stagger for it, held back until the list arrives
	}
	local list = recent[peer] or {}

	list[#list + 1] = record
	recent[peer] = list

	pc.count("host_blasts")

	if projectile_go_id ~= 0 then
		pc.count("host_projectile_blasts")
	end

	-- The list can overtake its blast: the two travel by different routes, and a client's projectile usually lands on
	-- its screen before the host's copy lands here.
	local waiting = early[peer]

	if waiting then
		for i = 1, #waiting do
			local entry = waiting[i]

			if same_blast(entry, template_name, position, projectile_go_id) then
				table.remove(waiting, i)
				resolve(record, entry.decided, "list arrived first")

				break
			end
		end
	end
end

-- Called before AreaDamageSystem.rpc_create_explosion runs a client's blast on the host.
function blasts.host_blast_arrived(channel_id, attacker_unit_id, position, explosion_template_id)
	local peer = channel_id and CHANNEL_TO_PEER_ID[channel_id]

	if not peer or not pc.host.peer_decides_attacks(peer) then
		return
	end

	local attacker = Managers.state.unit_storage:unit(attacker_unit_id)
	local owner = attacker and Managers.player:owner(attacker)

	if not owner or owner.peer_id ~= peer or owner.bot_player then
		return
	end

	local template_name = NetworkLookup.explosion_templates[explosion_template_id]

	if not template_name then
		return
	end

	add_blast(peer, owner:name(), template_name, position, 0)
end

-- Called before PlayerProjectileHuskExtension.do_aoe sets off the blast of a client's projectile on the host: the
-- host's copy of the projectile has landed, and this blast is the real one.
function blasts.host_projectile_blast(extension, aoe_data, position)
	local owner_unit = extension._owner_unit
	local owner = owner_unit and Unit.alive(owner_unit) and Managers.player:owner(owner_unit)
	local peer = owner and owner.remote and not owner.bot_player and owner.peer_id

	if not peer or not pc.host.peer_decides_attacks(peer) then
		return
	end

	local projectile = extension._projectile_unit
	local projectile_go_id = projectile and Unit.alive(projectile) and Managers.state.unit_storage:go_id(projectile)
	local template_name = aoe_data.name

	if not projectile_go_id or type(template_name) ~= "string" then
		return
	end

	add_blast(peer, owner:name(), template_name, position, projectile_go_id)
end

-- Called before AreaDamageSystem._damage_unit books one target of a blast. Returns the enemy whose stagger the
-- client decides, or may yet, and the blast it belongs to.
function blasts.target_of(aoe_damage_data)
	local hit_unit = aoe_damage_data.hit_unit
	local attacker = aoe_damage_data.attacker_unit
	local breed = hit_unit and Unit.alive(hit_unit) and Unit.get_data(hit_unit, "breed")

	if not breed or not pc.REACTION_BREEDS[breed.name] or not HEALTH_ALIVE[hit_unit] or not attacker or not Unit.alive(attacker) then
		return nil
	end

	local owner = Managers.player:owner(attacker)
	local peer = owner and owner.remote and not owner.bot_player and owner.peer_id

	if not peer or not recent[peer] or not aoe_damage_data.impact_position then
		return nil
	end

	local record = find_blast(peer, aoe_damage_data.explosion_template_name, aoe_damage_data.impact_position:unbox())

	if not record then
		return nil
	end

	if record.decided then
		local go_id = Managers.state.unit_storage:go_id(hit_unit)

		return go_id and record.decided[go_id] and hit_unit or nil, record
	end

	return hit_unit, record
end

local function hold_stagger(record)
	return function (t, damage_profile, target_index, power_level, target_unit, attacker_unit, hit_zone_name, attack_direction, boost_curve_multiplier, is_critical_strike, blocked, damage_source, source_attacker_unit)
		record.pending[target_unit] = {
			damage_profile = damage_profile,
			target_index = target_index,
			power_level = power_level,
			attacker = attacker_unit,
			hit_zone_name = hit_zone_name,
			direction = Vector3Box(attack_direction),
			boost_curve_multiplier = boost_curve_multiplier,
			is_critical_strike = is_critical_strike,
			blocked = blocked,
			damage_source = damage_source,
			source_attacker = source_attacker_unit,
		}
	end
end

mod:hook("AreaDamageSystem", "rpc_create_explosion", function (func, self, channel_id, attacker_unit_id, attacker_is_level_unit, position, rotation, explosion_template_name_id, ...)
	if self.is_server and not pc.broken and not attacker_is_level_unit then
		pc.guard("host blast", blasts.host_blast_arrived, channel_id, attacker_unit_id, position, explosion_template_name_id)
	end

	return func(self, channel_id, attacker_unit_id, attacker_is_level_unit, position, rotation, explosion_template_name_id, ...)
end)

-- This is a mod:hook, so everything except the original call runs through pc.guard.
mod:hook("AreaDamageSystem", "_damage_unit", function (func, self, aoe_damage_data)
	if pc.broken or not self.is_server or next(recent) == nil then
		return func(self, aoe_damage_data)
	end

	local ok, unit, record = pc.guard("host blast target", blasts.target_of, aoe_damage_data)

	if not ok or not unit then
		return func(self, aoe_damage_data)
	end

	pc.count("host_blast_targets")
	pc.host_reactions.begin_skip(unit, record.decided == nil and hold_stagger(record) or nil)

	func(self, aoe_damage_data)

	pc.host_reactions.end_skip()
end)

-- One part of a client's list for one of its blasts. Once every part is in, the list counts as arrived.
function blasts.list_part_arrived(sender, blast_id, part, parts, template_name, position, projectile_go_id, list)
	if not pc.host.peer_decides_attacks(sender) then
		return
	end

	local by_id = gathering[sender] or {}
	local entry = by_id[blast_id]

	if not entry or entry.parts ~= parts or entry.template_name ~= template_name or entry.projectile_go_id ~= projectile_go_id then
		entry = {
			template_name = template_name,
			position = Vector3Box(position),
			projectile_go_id = projectile_go_id,
			parts = parts,
			got = {},
			count = 0,
			decided = {}, -- go id -> true
			t = pc.now(),
		}
		by_id[blast_id] = entry
		gathering[sender] = by_id
	end

	if entry.got[part] then
		return
	end

	entry.got[part] = true
	entry.count = entry.count + 1

	for id in string.gmatch(list, "%d+") do
		entry.decided[tonumber(id)] = true
	end

	if entry.count < parts then
		return
	end

	by_id[blast_id] = nil

	if next(by_id) == nil then
		gathering[sender] = nil
	end

	blasts.list_arrived(sender, template_name, position, projectile_go_id, entry.decided)
end

function blasts.list_arrived(sender, template_name, position, projectile_go_id, decided)
	local record = find_blast_for_list(sender, template_name, position, projectile_go_id)

	pc.count("host_blast_lists")

	if record then
		resolve(record, decided, "the list didn't name them")

		return
	end

	local waiting = early[sender] or {}

	waiting[#waiting + 1] = {
		template_name = template_name,
		position = Vector3Box(position),
		projectile_go_id = projectile_go_id,
		decided = decided,
		t = pc.now(),
	}
	early[sender] = waiting
end

local function whole(value, low, high)
	return type(value) == "number" and value == math.floor(value) and value >= low and value <= high
end

mod:network_register("pc_blast", function (sender, version, blast_id, part, parts, template_name, x, y, z, projectile_go_id, list)
	if pc.broken or not pc.is_server() or not pc.in_game() or version ~= pc.VERSION then
		return
	end

	if not whole(blast_id, 1, math.huge) or not whole(parts, 1, MAX_LIST_PARTS) or not whole(part, 1, parts or 0) or type(template_name) ~= "string" or #template_name > MAX_NAME_LENGTH
		or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" or x ~= x or y ~= y or z ~= z or not whole(projectile_go_id, 0, math.huge) or type(list) ~= "string" or #list > MAX_LIST_LENGTH then
		pc.count("host_rejected")
		pc.print("host rejected a malformed blast list")

		return
	end

	pc.guard("host blast list", blasts.list_part_arrived, sender, blast_id, part, parts, template_name, Vector3(x, y, z), projectile_go_id, list)
end)

-- The host's copy of a client's projectile has landed (PlayerProjectileHuskExtension.do_aoe). Before its blast is
-- worked out here, it is noted as that client's, so its staggers wait for the client's list.
mod:hook("PlayerProjectileHuskExtension", "do_aoe", function (func, self, aoe_data, position, ...)
	if self._is_server and not pc.broken and type(aoe_data) == "table" and aoe_data.explosion then
		pc.guard("host projectile blast", blasts.host_projectile_blast, self, aoe_data, position)
	end

	return func(self, aoe_data, position, ...)
end)

function blasts.update()
	if next(recent) == nil and next(early) == nil and next(gathering) == nil then
		return
	end

	local t = pc.now()

	for peer, list in pairs(recent) do
		for i = #list, 1, -1 do
			local record = list[i]

			if record.decided == nil and t - record.t > BLAST_WAIT then
				local partial, count, parts = partial_list(peer, record.template_name, record.position:unbox(), record.projectile_go_id)

				pc.count("host_blast_list_missing")

				if partial then
					resolve(record, partial, string.format("only %d of %d parts of the list came", count, parts))
				else
					resolve(record, {}, "no list came")
				end
			end

			if t - record.t > BLAST_MEMORY then
				table.remove(list, i)
			end
		end

		if #list == 0 then
			recent[peer] = nil
		end
	end

	for peer, list in pairs(early) do
		for i = #list, 1, -1 do
			if t - list[i].t > BLAST_MEMORY then
				table.remove(list, i)
			end
		end

		if #list == 0 then
			early[peer] = nil
		end
	end

	for peer, by_id in pairs(gathering) do
		for blast_id, entry in pairs(by_id) do
			if t - entry.t > BLAST_MEMORY then
				by_id[blast_id] = nil
			end
		end

		if next(by_id) == nil then
			gathering[peer] = nil
		end
	end
end

function blasts.clear()
	recent = {}
	early = {}
	gathering = {}
end
