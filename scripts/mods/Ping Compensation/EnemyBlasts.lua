local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Build 6.1 (D66, D70): enemy blasts on players, and the Drachenfels sorcerer's rings, judged on every modded player's
-- screen for that player alone (D55), from their live position, shown there at once (D11, D62).
--   * Enemy blasts: a blast none of whose attacker, damaging unit and source attacker is a player's unit or a player's
--     projectile, such as the lords' and the grey seer's missiles, the troll chief's rage, the standard bearer's planting,
--     grudge marks', and enemies' and mutators' deaths. The host's own test leaves the modded players out (Host.lua's
--     overlap hook, host.blast_skip) and remembers the blast. Every enemy blast reaches clients as rpc_create_explosion
--     (area_damage_system.lua:494), where each screen works out its own copy of the host branch of
--     DamageUtils.create_explosion for its own player (Blasts.lua, player_target), shows it at once and reports it
--     (pc_blast_hit); the host books it as the blast's own per-target code would have for that player. A blast the host
--     never sends to clients is booked a frame later from the host's own view, so it can't be lost.
--   * The rings (BTChaosSorcererSummoningAction.update_boss_rings, bt_chaos_sorcerer_summoning_action.lua:812): the host
--     leaves the modded players out of each ring's test and tells them when it deals its damage (pc_ring); each screen
--     tests its own player against its own copy of that ring, shows the damage and the throw at once, and reports a hit.
-- The missiles' flight and impact, the slow bomb's direct hit and blasts players set off stay the host's (D70 question 5).

local enemy_blasts = {}

pc.enemy_blasts = enemy_blasts

local BLAST_MEMORY = 3 -- seconds the host remembers a blast it left modded players out of
local MATCH_DISTANCE = 0.25 -- metres between where the host and a client have a blast; positions travel rounded
local SENT_DISTANCE = 0.01 -- the same between the host's blast and the message it sends clients, which carries its position
local RING_MEMORY = 10 -- seconds the host remembers a ring it told modded players of
local UNJUDGED_MARGIN = 2 -- metres past a blast's radius within which a screen that can't follow it says so
local MAX_NAME_LENGTH = 64
local PLAYER_MIDDLE = 0.9

local function unit_of(go_id)
	return type(go_id) == "number" and Managers.state.unit_storage:unit(go_id) or nil
end

local function alive(unit)
	return unit and Unit.alive(unit) and unit or nil
end

local function judging()
	return not pc.broken and not pc.is_server() and pc.host_fresh()
end

-- Whether a player set off a blast this unit took part in: a player's own unit, or a projectile a player owns
-- (PlayerProjectileUnitExtension and its husk keep the owner, player_projectile_unit_extension.lua). Both sides apply
-- this to the same units, so a blast is judged on one side only.
local function player_made(unit)
	if not unit or not Unit.alive(unit) then
		return false
	end

	if Managers.player:owner(unit) then
		return true
	end

	local projectile = ScriptUnit.has_extension(unit, "projectile_system")
	local owner = projectile and (projectile._owner_unit or projectile.owner_unit)

	return owner ~= nil and Unit.alive(owner) and Managers.player:owner(owner) ~= nil
end

-- Host ---------------------------------------------------------------------------------------------------------------

local recent = {} -- the enemy blasts of the last BLAST_MEMORY seconds that the host left modded players out of
local rings_sent = {} -- "<sorcerer go id>:<action>:<ring>" -> a ring the host told modded players of

-- Called around DamageUtils.create_explosion on the host (damage_utils.lua:1049) for a blast run as the host with a live
-- attacker (:1126). For an enemy blast that can reach players, the scope its own overlap leaves the fresh modded players
-- out with (the overlap hook in Host.lua matches its collision filter, its 9th argument), or nil to leave it to vanilla.
function enemy_blasts.before(attacker, template, damaging, source)
	local data = type(template) == "table" and template.explosion

	if type(data) ~= "table" or data.ignore_players or not alive(attacker) then
		return nil
	end

	if player_made(attacker) or player_made(damaging) or player_made(source) then
		return nil
	end

	local units = nil

	for _, player in pairs(Managers.player:human_players()) do
		local player_unit = player.player_unit

		if player_unit and Unit.alive(player_unit) and pc.host.client_judges(player_unit) then
			units = units or {}
			units[player_unit] = true
		end
	end

	if not units then
		return nil
	end

	return {
		filter = data.collision_filter or "filter_explosion_overlap",
		units = units,
		dropped = {},
	}
end

-- After the host's blast ran without the modded players: it is remembered for their screens' reports, with what the
-- host's own view would have done to each modded player its overlap found, for the log and for a screen that can't
-- follow the blast. Run with the host's own attacker (a missile, for the lords' missiles: AiUtils.ai_explosion,
-- ai_utils.lua:601), whose radius buffs the original reads.
function enemy_blasts.noted(scope, world, attacker, position, rotation, template, scale, damage_source, damaging, attacker_power_level, source)
	local numbers = pc.blasts.numbers(attacker, template, scale or 1, attacker_power_level)

	if not numbers or type(template.name) ~= "string" then
		return
	end

	local record = {
		template_name = template.name,
		position = Vector3Box(position),
		attacker = attacker,
		damaging = damaging,
		source = source,
		damage_source = damage_source,
		numbers = numbers,
		t = pc.now(),
		sent = false,
		settled = false,
		booked = {},
		would = {},
	}
	local reached = 0

	for player_unit in pairs(scope.dropped) do
		local result = pc.blasts.player_target(world, attacker, position, rotation, template, scale, attacker_power_level, player_unit, true)

		if result then
			-- Kept for later frames, so its direction is boxed: a plain Vector3 goes stale at the end of its frame.
			record.would[player_unit] = {
				distance = result.distance,
				direction = Vector3Box(result.direction),
			}
			reached = reached + 1
		end
	end

	recent[#recent + 1] = record

	pc.count("host_enemy_blasts")

	if reached > 0 then
		pc.count("host_enemy_blast_would", reached)
		pc.log("host enemy blast template=%s source=%s: the host's own view reached %d modded players (left to their screens)", record.template_name, tostring(damage_source), reached)
	end
end

-- NetworkTransmit.send_rpc_clients for rpc_create_explosion: the blast went to every client, whose screens judge it.
function enemy_blasts.sent(attacker_unit_id, attacker_is_level_unit, position, rotation, template_id)
	local name = type(template_id) == "number" and rawget(NetworkLookup.explosion_templates, template_id)

	if not name or not position then
		return
	end

	for i = #recent, 1, -1 do
		local record = recent[i]

		if not record.sent and record.template_name == name and Vector3.distance(record.position:unbox(), position) <= SENT_DISTANCE then
			record.sent = true

			return
		end
	end
end

-- A player blocked a blast whose catapult a block weakens (catapult_blocked_multiplier, only grudge marks' in the 6.13
-- data): what DamageUtils.check_block does on the host after a block (damage_utils.lua:2746 to :2763), minus the message
-- back to the blocker, whose screen played it. peer: nil for a blast booked from the host's own view.
local function show_block(peer, player_unit, attacker, data)
	local status = ScriptUnit.has_extension(player_unit, "status_system")
	local network = pc.network()
	local fatigue_type = pc.fatigue_type(data)
	local fatigue_type_id = rawget(NetworkLookup.fatigue_types, fatigue_type)
	local go_id = Managers.state.unit_storage:go_id(player_unit)
	local attacker_id, attacker_is_level_unit = network:game_object_or_level_id(attacker)

	if not status or not fatigue_type_id or not go_id or not attacker_id then
		return
	end

	local _, multiplier, improved, direction = status:can_block(attacker)

	multiplier = type(multiplier) == "number" and multiplier or 1
	improved = improved == true
	direction = type(direction) == "string" and direction or "front"

	status:blocked_attack(fatigue_type, attacker, multiplier, improved, direction)

	if peer then
		network.network_transmit:send_rpc_clients_except("rpc_player_blocked_attack", peer, go_id, fatigue_type_id, attacker_id, multiplier, improved, direction, attacker_is_level_unit == true)
	else
		network.network_transmit:send_rpc_clients("rpc_player_blocked_attack", go_id, fatigue_type_id, attacker_id, multiplier, improved, direction, attacker_is_level_unit == true)
	end

	local blackboard = BLACKBOARDS[attacker]
	local action = blackboard and blackboard.action

	if blackboard and not blackboard.is_player and not (action and action.no_block_stagger) and not blackboard.stagger then
		blackboard.blocked = true
	end
end

-- One player's part in a remembered blast, booked as its per-target code would have for them (damage_utils.lua:1412 to
-- :1538): the target record add_aoe_damage_target fills (area_damage_system.lua:259), booked at once by
-- AreaDamageSystem._damage_unit (the damage, the damage over time and the push, from the distance and direction the
-- player's screen saw, with the host's own numbers for that distance), then the blast's buff, its server_hit_func and
-- its catapult. The attacker is the blast's if it is still there, else its damaging unit, else the player standing in
-- (D5), since _damage_unit books nothing for a dead attacker (:341).
local function book_blast(peer, player_unit, record, distance, direction, blocked)
	local template = ExplosionUtils.get_template(record.template_name)
	local data = template and template.explosion
	local numbers = record.numbers

	if type(data) ~= "table" or not numbers then
		return "no template"
	end

	local attacker = alive(record.attacker) or alive(record.damaging) or player_unit
	local position = record.position:unbox()
	local radius, max_damage_radius = numbers.radius, numbers.max_damage_radius
	local glancing = max_damage_radius < distance
	local scaled = numbers.power_level_min and numbers.power_level_max and math.lerp(numbers.power_level_min, numbers.power_level_max, numbers.scale) or nil
	local factor = 1

	if glancing and radius - max_damage_radius > 0 then
		factor = 1 - (distance - max_damage_radius) / (radius - max_damage_radius)

		if data.exponential_falloff then
			factor = factor * factor
		end
	end

	local push_speed = data.player_push_speed and math.auto_lerp(max_damage_radius, radius, data.player_push_speed, 1, math.clamp(distance, max_damage_radius, radius)) or nil
	local aoe_damage_data = {
		hit_unit = player_unit,
		attacker_unit = attacker,
		source_attacker_unit = alive(record.source),
		impact_position = Vector3Box(position),
		shield_blocked = false,
		do_damage = numbers.do_damage,
		hit_zone_name = "torso",
		damage_source = record.damage_source,
		hit_distance = distance,
		push_speed = push_speed,
		radius = radius,
		max_damage_radius = max_damage_radius,
		radius_min = data.radius_min,
		radius_max = data.radius_max,
		full_power_level = numbers.power_level,
		actual_power_level = (glancing and numbers.power_level_glance or scaled or numbers.power_level or 0) * factor,
		hit_direction = Vector3Box(direction),
		explosion_template_name = record.template_name,
		is_critical_strike = false,
		allow_critical_proc = false,
		target_number = 1,
	}

	pc.host.booking = true

	Managers.state.entity:system("area_damage_system"):_damage_unit(aoe_damage_data)

	if data.buff_to_apply and not data.only_facing then
		Managers.state.entity:system("buff_system"):add_buff(player_unit, data.buff_to_apply, player_unit, false)
	end

	if data.server_hit_func then
		local ok, message = pcall(data.server_hit_func, player_unit, record.damage_source, attacker, position, data)

		if not ok then
			pc.print("host enemy blast %s: its server_hit_func failed: %s", record.template_name, tostring(message))
		end
	end

	local velocity = pc.blasts.catapult_velocity(data, direction, blocked)

	if velocity then
		StatusUtils.set_catapulted_network(player_unit, true, velocity)
	end

	if blocked and data.catapult_blocked_multiplier then
		show_block(peer, player_unit, attacker, data)
	end

	pc.host.booking = false
	pc.count("host_enemy_blast_booked")

	return string.format("booked at %.2f m%s%s", distance, velocity and ", thrown" or "", blocked and ", blocked" or "")
end

local function find_record(template_name, position, player_unit)
	for i = #recent, 1, -1 do
		local record = recent[i]

		if record.template_name == template_name and Vector3.distance(record.position:unbox(), position) <= MATCH_DISTANCE then
			return record, record.booked[player_unit] == true
		end
	end

	return nil
end

-- A modded player's screen says an enemy blast reached them ("hit"), or that it couldn't follow a blast that may have
-- ("unjudged", which the host books from its own view, if that reached them).
function enemy_blasts.hit_reported(peer, player_unit, template_name, position, result, distance, direction, blocked)
	local record, twice = find_record(template_name, position, player_unit)
	local outcome

	pc.count("host_enemy_blast_reports")

	if not record then
		pc.count("host_enemy_blast_unmatched")

		outcome = "no such blast here"
	elseif twice then
		pc.count("host_enemy_blast_twice")

		outcome = "already booked"
	elseif result == "hit" then
		record.booked[player_unit] = true
		outcome = book_blast(peer, player_unit, record, math.clamp(distance, 0, record.numbers.radius), Vector3.normalize(direction), blocked)
	else
		local would = record.would[player_unit]

		pc.count("host_enemy_blast_unjudged")

		if would then
			record.booked[player_unit] = true
			outcome = "from the host's view: " .. book_blast(nil, player_unit, record, would.distance, would.direction:unbox(), false)

			pc.count("host_enemy_blast_unjudged_booked")
		else
			outcome = "the host's view didn't reach them either"
		end
	end

	local would = record and record.would[player_unit]

	pc.log("host enemy blast template=%s target=%s answer=%s distance=%.2f host_would=%s outcome=%s", template_name, pc.host.player_name(peer), result, distance, would and string.format("hit at %.2f m", would.distance) or "miss", tostring(outcome))
end

-- Every frame on the host: a blast that went to no client by the end of the frame it was made in is booked from the
-- host's own view for every modded player it reached, as vanilla would have, since no screen judges it.
function enemy_blasts.host_update()
	if #recent == 0 and next(rings_sent) == nil then
		return
	end

	local t = pc.now()

	for i = #recent, 1, -1 do
		local record = recent[i]

		if not record.sent and not record.settled and t > record.t then
			record.settled = true

			for player_unit, would in pairs(record.would) do
				if Unit.alive(player_unit) and not record.booked[player_unit] then
					record.booked[player_unit] = true

					local ok, outcome = pc.guard("host enemy blast unsent", book_blast, nil, player_unit, record, would.distance, would.direction:unbox(), false)

					pc.count("host_enemy_blast_unsent")
					pc.log("host enemy blast template=%s went to no client: booked from the host's view, %s", record.template_name, ok and tostring(outcome) or "error")
				end
			end
		end

		if t - record.t > BLAST_MEMORY then
			table.remove(recent, i)
		end
	end

	for key, record in pairs(rings_sent) do
		if t - record.t > RING_MEMORY then
			rings_sent[key] = nil
		end
	end
end

-- Called around update_boss_rings (bt_chaos_sorcerer_summoning_action.lua:812), a method run every frame of the spell
-- (:153): the rings it has dealt their damage with so far, and the fresh modded players, whom its test of the heroes'
-- side (:906) leaves out for the call. Returns the scope, or nil to leave the call to vanilla.
function enemy_blasts.rings_before(blackboard)
	local action = blackboard.action
	local sequence = type(action) == "table" and action.ring_sequence

	if type(sequence) ~= "table" then
		return nil
	end

	local side = Managers.state.side:get_side_from_name("heroes")
	local units = side and side.PLAYER_AND_BOT_UNITS
	local players = nil

	for i = 1, type(units) == "table" and #units or 0 do
		local peer = Unit.alive(units[i]) and pc.host.client_judges(units[i])

		if peer then
			players = players or {}
			players[units[i]] = peer
		end
	end

	if not players then
		return nil
	end

	local done = {}

	for i, ring in ipairs(sequence) do
		done[i] = ring.done == true
	end

	pc.boss_areas.hide_modded(side, "PLAYER_AND_BOT_UNITS")

	return {
		action = action,
		done = done,
		players = players,
	}
end

-- After the call: each ring that dealt its damage in it (several can in one call, ring.done, :957) goes to the modded
-- players it left out, with its centre (pc_ring), and is remembered for their screens' reports.
function enemy_blasts.rings_after(unit, blackboard, scope)
	local action = scope.action
	local go_id = pc.network():unit_game_object_id(unit)
	local centre = blackboard.ring_center_position and blackboard.ring_center_position:unbox()

	if not go_id or not centre or type(action.name) ~= "string" then
		return
	end

	for i, ring in ipairs(action.ring_sequence) do
		if ring.done and not scope.done[i] then
			rings_sent[string.format("%d:%s:%d", go_id, action.name, i)] = {
				sorcerer = unit,
				action = action,
				index = i,
				centre = Vector3Box(centre),
				players = scope.players,
				booked = {},
				t = pc.now(),
			}

			local sent = 0

			for _, peer in pairs(scope.players) do
				mod:network_send("pc_ring", peer, pc.VERSION, go_id, action.name, i, pc.finite(centre.x, 3), pc.finite(centre.y, 3), pc.finite(centre.z, 3))

				sent = sent + 1
			end

			pc.count("host_rings_sent", sent)
			pc.log("host ring go=%d action=%s ring=%d sent to %d modded players", go_id, action.name, i, sent)
		end
	end
end

-- A ring that caught a modded player on their screen, booked as update_boss_rings would have for them
-- (bt_chaos_sorcerer_summoning_action.lua:939 to :953): the action's damage profile at its power level, the throw
-- towards or away from the ring's centre, and hit_by_eruptions. Once per ring and player.
local function book_ring(player_unit, record)
	local action = record.action
	local ring = action.ring_sequence[record.index]
	local profile = DamageProfileTemplates[action.damage_profile_name]
	local power_level = type(action.power_level) == "table" and action.power_level[Managers.state.difficulty:get_difficulty()]

	if not ring or not profile or type(power_level) ~= "number" then
		return "no ring data"
	end

	local sorcerer = alive(record.sorcerer) or player_unit
	local position = POSITION_LOOKUP[player_unit]
	local centre = record.centre:unbox()

	pc.host.booking = true
	DamageUtils.add_damage_network_player(profile, nil, power_level, player_unit, sorcerer, "torso", position, Vector3.up(), "undefined")

	local thrown = false

	if ring.catapult_strength then
		local direction = Vector3.normalize(ring.catapult_direction == "in" and centre - position or position - centre)

		StatusUtils.set_catapulted_network(player_unit, true, (direction + Vector3.up()) * ring.catapult_strength)

		thrown = true
	end

	pc.host.booking = false

	local blackboard = alive(record.sorcerer) and BLACKBOARDS[record.sorcerer]

	if blackboard then
		blackboard.hit_by_eruptions = true
	end

	pc.count("host_ring_booked")

	return thrown and "booked, thrown" or "booked"
end

function enemy_blasts.ring_reported(peer, player_unit, go_id, action_name, ring_index)
	local record = rings_sent[string.format("%d:%s:%d", go_id, action_name, ring_index)]
	local outcome

	if not record or record.players[player_unit] ~= peer then
		outcome = "no such ring here"
	elseif record.booked[player_unit] then
		outcome = "already booked"
	else
		record.booked[player_unit] = true
		outcome = book_ring(player_unit, record)
	end

	pc.count("host_ring_reports")
	pc.log("host ring go=%d action=%s ring=%d target=%s outcome=%s", go_id, action_name, ring_index, pc.host.player_name(peer), outcome)
end

function enemy_blasts.host_clear()
	recent = {}
	rings_sent = {}
end

-- Client -------------------------------------------------------------------------------------------------------------

local own_overlaps = {} -- player unit -> filter -> whether a blast's overlap with that filter finds that unit's actors here

-- Whether a blast's overlap with this filter finds this player's own actors on this machine. It is checked once per
-- player unit and filter, with a small sphere round the player's middle, and logged.
local function overlap_sees(target, filter)
	local known_here = own_overlaps[target]

	if not known_here then
		known_here = {}
		own_overlaps[target] = known_here
	end

	local known = known_here[filter]

	if known == nil then
		local actors, num_actors = PhysicsWorld.immediate_overlap(World.get_data(Unit.world(target), "physics_world"), "shape", "sphere", "position", POSITION_LOOKUP[target] + Vector3(0, 0, PLAYER_MIDDLE), "size", 0.6, "collision_filter", filter)

		known = false

		for i = 1, num_actors or 0 do
			if actors[i] and Actor.unit(actors[i]) == target then
				known = true

				break
			end
		end

		known_here[filter] = known

		pc.log("client: a blast's overlap with %s %s this player's own actors, so enemy blasts are judged %s", filter, known and "finds" or "doesn't find", known and "with it" or "by shape")
	end

	return known
end

local function send_hit(template_name, position, result, distance, direction, blocked)
	local host_peer = pc.host_peer()

	if host_peer then
		mod:network_send("pc_blast_hit", host_peer, pc.VERSION, template_name, pc.finite(position.x, 3), pc.finite(position.y, 3), pc.finite(position.z, 3), result, pc.finite(distance, 3), pc.finite(direction.x, 4), pc.finite(direction.y, 4), pc.finite(direction.z, 4), blocked and true or false)
	end
end

-- This player's own block of a blast whose catapult a block weakens (damage_utils.lua:1524, DamageUtils.check_block,
-- :2697): played here at once, as the host's message would; the host shows it to everyone else. Returns whether they
-- blocked it.
local function blocks(own, attacker, data)
	local status = ScriptUnit.has_extension(own, "status_system")

	if not status or not status:is_blocking() or pc.unblockable(attacker) then
		return false
	end

	local can_block, multiplier, improved, direction = status:can_block(attacker)
	local buffs = ScriptUnit.has_extension(own, "buff_system")

	if not can_block or buffs and buffs:has_buff_perk("invulnerable") then
		return false
	end

	status:blocked_attack(pc.fatigue_type(data), attacker, multiplier, improved, direction)

	return true
end

-- Every blast the host sends goes through here (rpc_create_explosion, area_damage_system.lua:473), after vanilla has
-- played its effects: an enemy blast that reaches this player on this screen is reported first, then shown at once.
-- A blast a player set off stays the host's (D70 question 5); one whose attacker this screen can't find, but which may
-- have reached this player, is left to the host's own view ("unjudged").
function enemy_blasts.client_blast(world, attacker_unit_id, attacker_is_level_unit, position, rotation, template_id, scale, damage_source_id, attacker_power_level, source_attacker_unit_id)
	local own = pc.local_player_unit()

	if not judging() or not own or not HEALTH_ALIVE[own] or not position then
		return
	end

	local template_name = type(template_id) == "number" and rawget(NetworkLookup.explosion_templates, template_id)
	local template = template_name and ExplosionUtils.get_template(template_name)
	local data = template and template.explosion

	if type(data) ~= "table" or data.ignore_players then
		return
	end

	local attacker

	if attacker_is_level_unit then
		attacker = LevelHelper:unit_by_index(world, attacker_unit_id)
	else
		attacker = unit_of(attacker_unit_id)
	end

	local source = unit_of(source_attacker_unit_id)

	if player_made(attacker) or player_made(source) then
		return
	end

	if not alive(attacker) then
		local radius = type(data.radius) == "number" and data.radius or data.radius_max or 10

		if Vector3.distance(POSITION_LOOKUP[own], position) <= radius + UNJUDGED_MARGIN then
			send_hit(template_name, position, "unjudged", 0, Vector3.up(), false)
			pc.count("client_enemy_blast_unjudged")
			pc.log("client enemy blast template=%s: its attacker isn't here, so the host's own view decides", template_name)
		end

		return
	end

	local sees = overlap_sees(own, data.collision_filter or "filter_explosion_overlap")
	local result, why = pc.blasts.player_target(world, attacker, position, rotation or Quaternion.identity(), template, scale or 1, attacker_power_level, own, sees)

	pc.count("client_enemy_blasts")

	if not result then
		if why ~= "overlap" and why ~= "shape" then
			pc.log("client enemy blast template=%s missed this player: %s", template_name, tostring(why))
		end

		return
	end

	local blocked = data.catapult_players and data.catapult_blocked_multiplier and blocks(own, attacker, data) or false

	send_hit(template_name, position, "hit", result.distance, result.direction, blocked)
	pc.count("client_enemy_blast_hits")

	if blocked then
		pc.count("client_enemy_blast_blocked")
	end

	local breed = Unit.get_data(attacker, "breed")
	local damage_source = type(damage_source_id) == "number" and rawget(NetworkLookup.damage_sources, damage_source_id) or nil
	local ok, estimate, moved = pc.guard("client enemy blast shown", pc.hit_results.blast, own, {
		attacker = attacker,
		go_id = not attacker_is_level_unit and attacker_unit_id or nil,
		source_name = damage_source or breed and breed.name or "undefined",
		race = breed and breed.race,
		profile = not result.immune and rawget(DamageProfileTemplates, result.profile_name) or nil,
		power_level = result.power_level,
		direction = result.direction,
		push_speed = not result.immune and result.push_speed or nil,
		catapult = pc.blasts.catapult_velocity(data, result.direction, blocked),
	})

	pc.log("client enemy blast template=%s source=%s hit you: method=%s distance=%.2f power=%.1f profile=%s blocked=%s estimate=%.1f moved=%s", template_name, tostring(damage_source), result.method, result.distance, result.power_level, result.profile_name, tostring(blocked), ok and estimate or 0, ok and tostring(moved) or "error")
end

-- A ring dealt its damage on the host (pc_ring): this player, if between its radii on this screen
-- (bt_chaos_sorcerer_summoning_action.lua:939, the 3D distance from its centre), is shown the damage and the throw at once
-- and the host is told.
function enemy_blasts.ring(go_id, action_name, ring_index, centre)
	local own = pc.local_player_unit()

	if not judging() or not own or not HEALTH_ALIVE[own] then
		return
	end

	local unit = unit_of(go_id)
	local breed = unit and Unit.get_data(unit, "breed")
	local set = breed and BreedActions[breed.name]
	local action = set and set[action_name]
	local ring = action and type(action.ring_sequence) == "table" and action.ring_sequence[ring_index]
	local info = ring and type(action.ring_info) == "table" and action.ring_info[ring.position]

	pc.count("client_rings")

	if type(info) ~= "table" then
		pc.print("client ring go=%d action=%s ring=%s can't be judged here: no such ring", go_id, action_name, tostring(ring_index))

		return
	end

	local position = POSITION_LOOKUP[own]
	local distance_squared = Vector3.distance_squared(position, centre)
	local inner, outer = info.min_radius or 0, info.max_radius or 0

	if not (inner * inner < distance_squared and distance_squared < outer * outer) then
		pc.log("client ring go=%d action=%s ring=%d missed this player: %.2f m from its centre, between %.1f and %.1f hurts", go_id, action_name, ring_index, math.sqrt(distance_squared), inner, outer)

		return
	end

	local host_peer = pc.host_peer()

	if host_peer then
		mod:network_send("pc_ring_hit", host_peer, pc.VERSION, go_id, action_name, ring_index)
	end

	pc.count("client_ring_hits")

	local catapult = nil

	if ring.catapult_strength then
		catapult = (Vector3.normalize(ring.catapult_direction == "in" and centre - position or position - centre) + Vector3.up()) * ring.catapult_strength
	end

	local power_level = type(action.power_level) == "table" and action.power_level[Managers.state.difficulty:get_difficulty()]
	local ok, estimate, thrown = pc.guard("client ring shown", pc.hit_results.ring, own, {
		attacker = unit,
		go_id = go_id,
		race = breed.race,
		profile = rawget(DamageProfileTemplates, action.damage_profile_name),
		power_level = power_level,
		catapult = catapult,
	})

	pc.log("client ring go=%d action=%s ring=%d hit you: %.2f m from its centre, estimate=%.1f thrown=%s", go_id, action_name, ring_index, math.sqrt(distance_squared), ok and estimate or 0, tostring(ok and thrown))
end

function enemy_blasts.clear()
	own_overlaps = {}
end

-- Both sides -----------------------------------------------------------------------------------------------------------

-- Host: an enemy blast's own test leaves the modded players out (enemy_blasts.before; Host.lua's overlap hook uses
-- host.blast_skip once, for the blast's one overlap), then is remembered (enemy_blasts.noted). A plain function, which
-- returns nothing. A mod:hook, so everything except the original call runs through pc.guard.
mod:hook("DamageUtils", "create_explosion", function (func, world, attacker_unit, impact_position, rotation, explosion_template, scale, damage_source, is_server, is_husk, damaging_unit, attacker_power_level, is_critical_strike, source_attacker_unit, ...)
	if pc.broken or not is_server or not pc.is_server() or not pc.in_game() then
		return func(world, attacker_unit, impact_position, rotation, explosion_template, scale, damage_source, is_server, is_husk, damaging_unit, attacker_power_level, is_critical_strike, source_attacker_unit, ...)
	end

	local ok, scope = pc.guard("host enemy blast", enemy_blasts.before, attacker_unit, explosion_template, damaging_unit, source_attacker_unit)

	if not ok or not scope then
		return func(world, attacker_unit, impact_position, rotation, explosion_template, scale, damage_source, is_server, is_husk, damaging_unit, attacker_power_level, is_critical_strike, source_attacker_unit, ...)
	end

	local previous = pc.host.blast_skip

	pc.host.blast_skip = scope

	-- The skip goes whatever happens in there, so that no other overlap ever leaves anyone out.
	local called, message = pcall(func, world, attacker_unit, impact_position, rotation, explosion_template, scale, damage_source, is_server, is_husk, damaging_unit, attacker_power_level, is_critical_strike, source_attacker_unit, ...)

	pc.host.blast_skip = previous

	pc.guard("host enemy blast noted", enemy_blasts.noted, scope, world, attacker_unit, impact_position, rotation, explosion_template, scale, damage_source, damaging_unit, attacker_power_level, source_attacker_unit)

	if not called then
		error(message, 0)
	end
end)

-- Host: an explosion message to every client (every enemy blast's, ai_utils.lua:607 and the others): its blast reaches
-- their screens, which judge it (enemy_blasts.sent).
mod:hook_safe("NetworkTransmit", "send_rpc_clients", function (self, rpc_name, ...)
	if rpc_name ~= "rpc_create_explosion" or pc.broken or #recent == 0 then
		return
	end

	pc.guard("host enemy blast sent", enemy_blasts.sent, ...)
end)

-- Host: the rings' test of the heroes leaves the modded players out (enemy_blasts.rings_before), whose lists come back
-- after the call whatever happens in there, with no pc.guard; the rings that dealt their damage are then announced.
mod:hook("BTChaosSorcererSummoningAction", "update_boss_rings", function (func, self, unit, blackboard, t, dt)
	if pc.broken or not pc.is_server() or type(blackboard) ~= "table" then
		return func(self, unit, blackboard, t, dt)
	end

	local ok, scope = pc.guard("host rings filter", enemy_blasts.rings_before, blackboard)

	if not ok or not scope then
		return func(self, unit, blackboard, t, dt)
	end

	local called, done = pcall(func, self, unit, blackboard, t, dt)

	pc.boss_areas.restore_hidden()

	if not called then
		error(done, 0)
	end

	pc.guard("host rings", enemy_blasts.rings_after, unit, blackboard, scope)

	return done
end)

local function number(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

mod:network_register("pc_blast_hit", function (sender, version, template_name, x, y, z, result, distance, dir_x, dir_y, dir_z, blocked)
	-- A host that has switched itself off judges its own blasts again, so a client's report would count twice.
	if pc.broken or not pc.is_server() or not pc.in_game() or version ~= pc.VERSION then
		return
	end

	if type(template_name) ~= "string" or #template_name > MAX_NAME_LENGTH or result ~= "hit" and result ~= "unjudged" or not number(x) or not number(y) or not number(z) or not number(distance)
		or not number(dir_x) or not number(dir_y) or not number(dir_z) or type(blocked) ~= "boolean" then
		pc.count("host_rejected")
		pc.print("host rejected a malformed blast hit from %s", pc.host.player_name(sender))

		return
	end

	local player = Managers.player:player_from_peer_id(sender)
	local player_unit = player and player.player_unit

	if not player_unit or not Unit.alive(player_unit) then
		return
	end

	-- A client the host doesn't count as fresh has been judged here meanwhile.
	if pc.host.client_judges(player_unit) ~= sender then
		pc.count("host_enemy_blast_ignored_stale")

		return
	end

	local direction = Vector3(dir_x, dir_y, dir_z)

	if Vector3.length_squared(direction) < 0.0001 then
		direction = Vector3.up()
	end

	pc.guard("host enemy blast hit", enemy_blasts.hit_reported, sender, player_unit, template_name, Vector3(x, y, z), result, distance, direction, blocked)
	pc.host.booking = false
end)

mod:network_register("pc_ring", function (sender, version, go_id, action_name, ring_index, x, y, z)
	if pc.broken or pc.is_server() or not pc.in_game() or sender ~= pc.host_peer() or version ~= pc.VERSION then
		return
	end

	if not number(go_id) or type(action_name) ~= "string" or not number(ring_index) or not number(x) or not number(y) or not number(z) then
		return
	end

	pc.guard("client ring", enemy_blasts.ring, go_id, action_name, ring_index, Vector3(x, y, z))
end)

mod:network_register("pc_ring_hit", function (sender, version, go_id, action_name, ring_index)
	if pc.broken or not pc.is_server() or not pc.in_game() or version ~= pc.VERSION then
		return
	end

	if not number(go_id) or type(action_name) ~= "string" or #action_name > MAX_NAME_LENGTH or not number(ring_index) then
		pc.count("host_rejected")

		return
	end

	local player = Managers.player:player_from_peer_id(sender)
	local player_unit = player and player.player_unit

	if not player_unit or not Unit.alive(player_unit) or pc.host.client_judges(player_unit) ~= sender then
		return
	end

	pc.guard("host ring hit", enemy_blasts.ring_reported, sender, player_unit, go_id, action_name, ring_index)
	pc.host.booking = false
end)
