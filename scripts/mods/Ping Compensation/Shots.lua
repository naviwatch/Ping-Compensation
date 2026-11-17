local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Family G (build 5.1, D52, D55): enemy shots judged on the screen of the player they reach.
--   * Ratling gunner (BTRatlingGunnerShootAction). Every client already fires its own copy of the stream, aimed at
--     the gunner's synced aim (ProjectileSystem.rpc_clients_continuous_shoot_start, projectile_system.lua:1115), and
--     that copy's bullets ray-test the world every frame but are only removed when they hit something (:1694).
--   * Ungor archer (BTFireProjectileAction). The host owns each arrow and sends clients a copy that only flies
--     (rpc_client_spawn_light_weight_projectile, :1072). It rolls a hit first; an arrow that rolled a miss can't hit a
--     player (bt_fire_projectile_action.lua:291).
-- Host: its own bullets and arrows stop at a modded player without hurting them, and it books what that player's
-- client reports (pc_shots) as vanilla's projectile hit would have (DamageUtils._projectile_hit_character,
-- damage_utils.lua:3059). It tells the target when a stream is aimed at them (pc_aim), and every modded player about
-- each arrow that rolled a hit (pc_arrow).
-- Client: judges each bullet of its own stream, and each arrow it was told of, that reaches its own player's body
-- first, with the game's ranged block run on this screen; pushes the player, shows the hit at once (HitResults.lua)
-- and reports it. On the target's screen the stream aims, and each arrow is aimed, at the player's live position by
-- the host's own rule, so a high ping doesn't make them easier to outrun (D10's facing, extended to aim). There the
-- shooter's body turns by its node's own rule too (D59): the ratling gunner's while its stream is aimed there, the
-- archer's while it aims and shoots, which the host announces (pc_aim, kind arrow).

local shots = {}

pc.shots = shots

local INDEX_DISTANCE = 2
local INDEX_ACTOR = 4
local AIM_PIVOT_HEIGHT = 0.7 -- bt_ratling_gunner_shoot_action.lua:447
local HIT_FILTER = "filter_enemy_player_afro_ray_projectile" -- the filter of a shot that can hit players
local MAX_ENTRIES = 12 -- shots per pc_shots message
local MAX_LIST_LENGTH = 450 -- characters per pc_shots message (VMF allows 500 for all of a message's values)
local ARROW_MEMORY = 3 -- seconds an arrow's announcement waits for its copy, and the copy for nothing else
local MAX_ARROW_TIME = 6 -- seconds an arrow is followed at most
local AIM_MEMORY = 10 -- seconds a stream's aim waits for the stream itself
local VOLLEY_WAIT = 4 -- seconds an archer in a volley may wait past its aim for the others (bt_fire_projectile_action.lua:72 to :116)
local ARCHER_FACING_DOT = 0.70710678 -- math.inverse_sqrt_2: an archer turns only while its target is over 45 degrees off (:188)

local shooters = {} -- breed name -> { kind, action } from its behaviour tree, or false

-- The breed's shooting node, found in its own behaviour tree: every enemy that runs one of pc.SHOOTER_NODES is covered
-- (principle 4).
local function shooter_of(breed)
	if not breed then
		return nil
	end

	local cached = shooters[breed.name]

	if cached ~= nil then
		return cached or nil
	end

	local found = false
	local node = pc.find_node(pc.tree_of(breed), function (candidate)
		return pc.SHOOTER_NODES[candidate[1]] ~= nil and type(candidate.action_data) == "table"
	end)

	if node then
		found = {
			kind = pc.SHOOTER_NODES[node[1]],
			action = node.action_data,
		}
	end

	shooters[breed.name] = found

	return found or nil
end

shots.shooter_of = shooter_of

local function template_of(shooter)
	return shooter and LightWeightProjectiles[shooter.action.light_weight_projectile_template_name] or nil
end

local function power_level_of(template)
	local rank = Managers.state.difficulty:get_difficulty_rank()

	return template.attack_power_level[rank] or template.attack_power_level[2]
end

-- The hit zone a shot finds on this unit. A player's near-miss capsule (c_afro) only plays a sound (damage_utils.lua:3142),
-- and so does an enemy's "afro" zone, so neither stops a shot.
local function zone_of(unit, actor)
	local breed = AiUtils.unit_breed(unit)

	if not breed then
		return nil
	end

	-- Only a player has the capsule; the game asks for it the same way (damage_utils.lua:3142).
	if Managers.player:is_player_unit(unit) and Unit.actor(unit, "c_afro") == actor then
		return "afro"
	end

	local lookup = breed.hit_zones_lookup
	local zone = lookup and lookup[Actor.node(actor)]

	return zone and zone.name or nil
end

-- Who a shot reaches first among this frame's hits, in the order the game walks them (process_projectile_hit,
-- damage_utils.lua:3356): hits without a live unit and the shooter itself are passed over, and so is a near miss.
-- Returns "player", its hit zone and the hit when it is this player's body; "other" for anything else, which stops
-- the shot; nil if nothing in these hits does.
local function first_stop(hits, owner, target)
	for i = 1, #hits do
		local hit = hits[i]
		local actor = hit[INDEX_ACTOR]
		local unit = actor and Actor.unit(actor)

		if unit and unit ~= owner and Unit.alive(unit) and not Unit.is_frozen(unit) then
			local zone = zone_of(unit, actor)

			if zone ~= "afro" then
				if unit == target then
					return "player", zone or "torso", hit
				end

				return "other", zone, hit
			end
		end
	end

	return nil
end

local function by_distance(a, b)
	return (a[INDEX_DISTANCE] or 0) < (b[INDEX_DISTANCE] or 0)
end

-- Host ---------------------------------------------------------------------------------------------------------------

-- A shot of the host's own that reaches a modded player's body: the hits before that player, which vanilla still
-- works through, and the player. Nil when the shot isn't an enemy shooter's or reaches no modded player this frame.
function shots.host_cut(projectile_data, hits)
	local owner = projectile_data.owner_unit

	if not owner or not Unit.alive(owner) or Managers.player:owner(owner) then
		return nil
	end

	if not shooter_of(AiUtils.unit_breed(owner)) then
		return nil
	end

	for i = 1, #hits do
		local actor = hits[i][INDEX_ACTOR]
		local unit = actor and Actor.unit(actor)

		if unit and unit ~= owner and Unit.alive(unit) and pc.host.client_judges(unit) and zone_of(unit, actor) ~= "afro" then
			local kept = {}

			for j = 1, i - 1 do
				kept[j] = hits[j]
			end

			return {
				hits = kept,
				player = unit,
			}
		end
	end

	return nil
end

-- After vanilla has worked through the hits before the player: if nothing stopped the shot, it stops at the player,
-- as it would have in vanilla, without hurting them. Their own screen judges it.
function shots.host_stop(system, projectile_data, cut)
	local own = system._light_weight.own_data
	local index = projectile_data.index

	if own.projectiles[index] == projectile_data then
		system:_remove_light_weight_projectile(own, index)
		pc.count("host_shot_stopped")
	end
end

-- Family G: a ratling gunner's stream starts here, aimed at a player its own screen aims it at from now on.
function shots.announce_stream(unit, data)
	local target = data and data.target_unit
	local peer = target and pc.host.client_judges(target)
	local go_id = peer and pc.network():unit_game_object_id(unit)
	local target_go_id = go_id and pc.network():unit_game_object_id(target)

	if not target_go_id then
		return
	end

	local node_name = type(data.target_node_name) == "string" and data.target_node_name or "j_spine"

	mod:network_send("pc_aim", peer, pc.VERSION, go_id, "stream", node_name, target_go_id, true)
	pc.count("host_streams_aimed")
	pc.log("host stream go=%d aimed at %s node=%s", go_id, pc.host.player_name(peer), node_name)
end

-- Family G (D59): an archer starts aiming at a modded player (BTFireProjectileAction.enter), whose own screen turns it
-- from now on, by the node's own rule.
function shots.announce_aim(unit, blackboard)
	local target = blackboard and blackboard.attacking_target
	local peer = target and Unit.alive(target) and pc.host.client_judges(target)
	local go_id = peer and pc.network():unit_game_object_id(unit)
	local target_go_id = go_id and pc.network():unit_game_object_id(target)

	if not target_go_id then
		return
	end

	mod:network_send("pc_aim", peer, pc.VERSION, go_id, "arrow", "", target_go_id, true)
	pc.count("host_archers_aimed")
	pc.log("host archer go=%d aiming at %s", go_id, pc.host.player_name(peer))
end

-- Family G: the archer's aim before its spread, as _fire_projectile is about to work it out (bt_fire_projectile_action.lua:275).
function shots.arrow_base(node, unit, blackboard, dt)
	local action = blackboard.action

	if not action or not action.projectile_speed or not action.projectile_gravity then
		return nil
	end

	local from, _, velocity = node:_fire_from_position_direction(blackboard, unit, dt, action.projectile_speed, action.projectile_gravity)

	if not from or not velocity then
		return nil
	end

	return {
		owner = unit,
		velocity = Vector3Box(velocity),
	}
end

-- The arrow _fire_projectile has just created: its id, direction and whether its roll let it hit players.
function shots.captured(system, capture, owner_unit, direction, collision_filter)
	if owner_unit ~= capture.owner then
		return
	end

	local own = system._light_weight.own_data
	local projectile = own.projectiles[own.current_index]

	if not projectile then
		return
	end

	capture.created = true
	capture.identifier = projectile.identifier
	capture.direction = Vector3Box(direction)
	capture.hit = collision_filter == HIT_FILTER
end

-- Family G: an arrow that rolled a hit goes to every modded player, with its spread from the aim, which only the host
-- knows (D3), and whether they are its target, whose screen aims it again at where they really are.
function shots.announce_arrow(unit, blackboard, capture)
	pc.count("host_arrows")

	if not capture.hit then
		pc.count("host_arrows_missed_roll")

		return
	end

	local go_id = pc.network():unit_game_object_id(unit)

	if not go_id then
		return
	end

	local aim = Quaternion.look(Vector3.normalize(capture.velocity:unbox()), Vector3.up())
	local spread = Quaternion.rotate(Quaternion.inverse(aim), Vector3.normalize(capture.direction:unbox()))
	local target = blackboard.attacking_target
	local sent = 0

	for _, player in pairs(Managers.player:human_players()) do
		local player_unit = player.player_unit
		local peer = player_unit and Unit.alive(player_unit) and pc.host.client_judges(player_unit)

		if peer then
			mod:network_send("pc_arrow", peer, pc.VERSION, go_id, capture.identifier, player_unit == target, pc.finite(spread.x, 4), pc.finite(spread.y, 4), pc.finite(spread.z, 4))

			sent = sent + 1
		end
	end

	if sent > 0 then
		pc.count("host_arrows_sent", sent)
		pc.log("host arrow=%d go=%d sent to %d modded players", capture.identifier, go_id, sent)
	end
end

-- Books one shot a client reported. A hit books what vanilla's projectile hit would have (damage_utils.lua:3279);
-- the player's own screen already pushed them, and a block reached the host as vanilla's own message.
local function book_shot(target, kind, shooter_go_id, result, zone, breed_name)
	local breed = Breeds[breed_name]
	local shooter = shooter_of(breed)
	local template = template_of(shooter)

	if not template or shooter.kind ~= kind then
		return "unknown shooter"
	end

	if result == "blocked" then
		pc.count("host_shot_blocked")

		return "blocked on the client's screen"
	end

	local profile_name = template.damage_profile
	local power_level = power_level_of(template)
	local unit_storage = Managers.state.unit_storage
	local shooter_unit = unit_storage:unit(shooter_go_id)
	local target_go_id = unit_storage:go_id(target)
	local zone_name = NetworkLookup.hit_zones[zone] and zone or "torso"
	local position = POSITION_LOOKUP[target] + Vector3(0, 0, 1)
	local outcome

	pc.host.booking = true

	if shooter_unit and Unit.alive(shooter_unit) and Unit.get_data(shooter_unit, "breed") == breed and target_go_id then
		local direction = Vector3.normalize(position - POSITION_LOOKUP[shooter_unit])
		local ok, _, boost = pcall(ActionUtils.get_ranged_boost, shooter_unit)

		Managers.state.entity:system("weapon_system"):send_rpc_attack_hit(NetworkLookup.damage_sources[breed_name], shooter_go_id, target_go_id, NetworkLookup.hit_zones[zone_name], position, direction, NetworkLookup.damage_profiles[profile_name],
			"power_level", power_level, "hit_target_index", 1, "blocking", false, "shield_break_procced", false, "boost_curve_multiplier", ok and boost or 0, "is_critical_strike", false, "attacker_is_level_unit", false, "first_hit", true)

		outcome = "booked"
	else
		-- The shooter has gone, which the game's own hit message wouldn't survive (weapon_system.lua:209). The hit
		-- still counts (D5), as the game books damage whose attacker has gone: the victim stands in for it.
		DamageUtils.add_damage_network_player(DamageProfileTemplates[profile_name], 1, power_level, target, target, zone_name, position, Vector3(0, 0, -1), breed_name)

		outcome = "booked without the shooter"
	end

	pc.host.booking = false
	pc.count("host_shot_booked")

	return outcome
end

mod:network_register("pc_shots", function (sender, version, list)
	if not pc.is_server() or not pc.in_game() or version ~= pc.VERSION or type(list) ~= "string" or #list > MAX_LIST_LENGTH + 50 then
		return
	end

	local player = Managers.player:player_from_peer_id(sender)
	local target = player and player.player_unit

	if not target or not Unit.alive(target) then
		return
	end

	-- A client the host doesn't count as fresh had its shots judged here too, and booking both would count them twice.
	local fresh = pc.host.client_judges(target) == sender
	local ping = pc.debug and pc.network():ping_by_peer(sender)

	for entry in string.gmatch(list, "[^;]+") do
		local kind, go_id, result, zone, breed_name = string.match(entry, "^([ab]),(%d+),([hk]),([%w_]+),([%w_]+)$")

		if not kind then
			pc.count("host_rejected")
			pc.print("host rejected a malformed shot from %s: %s", pc.host.player_name(sender), entry)
		elseif not fresh then
			pc.count("host_shot_ignored_stale")
		else
			kind = kind == "a" and "arrow" or "bullet"
			result = result == "k" and "blocked" or "hit"

			local ok, outcome = pc.guard("host shot booking", book_shot, target, kind, tonumber(go_id), result, zone, breed_name)

			pc.host.booking = false
			pc.count("host_shots")
			pc.count("host_shot_" .. kind)

			pc.log("host shot=%s from=%s go=%s target=%s answer=%s zone=%s outcome=%s ping=%s", kind, breed_name, go_id, pc.host.player_name(sender), result, zone, ok and tostring(outcome) or "error", type(ping) == "number" and string.format("%.0fms", ping * 1000) or "n/a")
		end
	end
end)

-- Client -------------------------------------------------------------------------------------------------------------

local aims = {} -- gunner network id -> { node, t, rotation, point, body } while its stream is aimed at this player
local turns = {} -- archer network id -> { t, ends_t, turn_speed, rotation, ... } while it aims at this player (D59)
local arrows = {} -- arrow id -> what this screen knows of it, while it follows the arrow's copy
local pending = {} -- arrow id -> an announcement whose copy hasn't arrived yet
local queued = {} -- shots judged here, waiting to go to the host
local flush_at = 0

local function judging()
	return not pc.broken and not pc.is_server() and pc.host_fresh()
end

local function queue(kind, go_id, result, zone, breed_name)
	queued[#queued + 1] = string.format("%s,%d,%s,%s,%s", kind == "arrow" and "a" or "b", go_id, result == "blocked" and "k" or "h", zone, breed_name)
end

-- Several shots to a message, at most every pc.SHOT_FLUSH seconds: a stream fires up to 25 bullets a second.
local function flush(t)
	if #queued == 0 or t < flush_at then
		return
	end

	local host_peer = pc.host_peer()

	if host_peer then
		local parts, length = {}, 0

		for i = 1, #queued do
			local entry = queued[i]

			if #parts > 0 and (length + #entry + 1 > MAX_LIST_LENGTH or #parts >= MAX_ENTRIES) then
				mod:network_send("pc_shots", host_peer, pc.VERSION, table.concat(parts, ";"))

				parts, length = {}, 0
			end

			parts[#parts + 1] = entry
			length = length + #entry + 1
		end

		if #parts > 0 then
			mod:network_send("pc_shots", host_peer, pc.VERSION, table.concat(parts, ";"))
		end
	end

	queued = {}
	flush_at = t + pc.SHOT_FLUSH
end

-- The push a shot gives the player it hits, block or no block (damage_utils.lua:3214). The host sends none for a shot
-- this screen judges, so it is applied here whatever /pingcomp predict says.
local function push_player(target, action_data)
	local push = action_data.player_push_velocity

	if not push then
		return
	end

	local buffs = ScriptUnit.has_extension(target, "buff_system")

	if buffs and buffs:has_buff_perk("no_ranged_knockback") then
		return
	end

	local status = ScriptUnit.has_extension(target, "status_system")

	if status and status:is_disabled() then
		return
	end

	local locomotion = ScriptUnit.has_extension(target, "locomotion_system")

	if locomotion then
		locomotion:add_external_velocity(push:unbox(), action_data.max_impact_push_speed)
	end
end

-- A shot that reached this player's body on this screen: the push, the ranged block from this player's own state
-- (which plays the block here and tells the host with vanilla's own message, damage_utils.lua:2809), then the hit's
-- feedback at once and the report.
local function judge_shot(kind, owner, target, zone, direction, action_data, arrow_id)
	local breed = Unit.get_data(owner, "breed")
	local go_id = Managers.state.unit_storage:go_id(owner)

	if not breed or not go_id then
		return
	end

	local profile = DamageProfileTemplates[action_data.damage_profile]
	local fatigue_type = profile and profile.fatigue_damage_override or "blocked_ranged"

	push_player(target, action_data)

	local blocked = DamageUtils.check_ranged_block(owner, target, fatigue_type) == true

	queue(kind, go_id, blocked and "blocked" or "hit", zone, breed.name)
	pc.count("client_shot_" .. kind)
	pc.count(blocked and "client_shot_blocked" or "client_shot_hit")

	local estimate = 0

	if not blocked then
		local ok, amount = pc.guard("client shot shown", pc.hit_results.shot, owner, go_id, breed, target, action_data, zone, direction)

		estimate = ok and amount or 0
	end

	pc.log("client shot=%s from=%s go=%d verdict=%s zone=%s estimate=%.1f aimed=%s%s", kind, breed.name, go_id, blocked and "blocked" or "hit", zone, estimate,
		tostring(kind == "bullet" and aims[go_id] ~= nil or kind == "arrow" and arrow_id ~= nil and arrows[arrow_id] ~= nil and arrows[arrow_id].aimed == true), arrow_id and string.format(" arrow=%d", arrow_id) or "")
end

-- A bullet of this client's own copy of a stream hit something this frame (physics_cb_light_weight_projectile_hit).
function shots.client_bullet(projectile_data, hits)
	if not judging() then
		return
	end

	local target = pc.local_player_unit()
	local owner = projectile_data.owner_unit
	local action_data = projectile_data.action_data

	if not target or not owner or not Unit.alive(owner) or not action_data then
		return
	end

	local verdict, zone = first_stop(hits, owner, target)

	if verdict == "player" then
		judge_shot("bullet", owner, target, zone, projectile_data.direction:unbox(), action_data)
	end
end

-- On the target's screen the stream aims at the player's live position by the host's own rule
-- (BTRatlingGunnerShootAction._aim_at_target, bt_ratling_gunner_shoot_action.lua:501): the aim turns towards the
-- target's node at radial_speed_upper_body_shooting, from a pivot just above the gunner's feet, starting from the
-- aim the host last synced. The body turns towards the node on the flat at radial_speed_feet_shooting (:519), set
-- outright since the node turns it with lerping off (:61), so the gun points where its bullets go (D59).
local function rotate_from_to(from, to, max_angle_speed, dt)
	local max_delta = max_angle_speed * dt
	local angle_difference = 2 * math.acos(math.clamp(Quaternion.dot(to, from), -1, 1))
	local lerp_t = angle_difference == 0 and 1 or math.min(max_delta / angle_difference, 1)

	return Quaternion.lerp(from, to, lerp_t)
end

shots.rotate_from_to = rotate_from_to

local function update_aim(go_id, aim, target, dt, t)
	local unit = Managers.state.unit_storage:unit(go_id)
	local shooter = unit and Unit.alive(unit) and shooter_of(Unit.get_data(unit, "breed"))
	local streams = Managers.state.entity:system("projectile_system")._light_weight.husk_shoot_list

	if not shooter or shooter.kind ~= "bullet" then
		aims[go_id] = nil

		return
	end

	if not streams[go_id] then
		if t - aim.t > AIM_MEMORY then
			aims[go_id] = nil
		end

		return
	end

	local pivot = POSITION_LOOKUP[unit] + Vector3(0, 0, AIM_PIVOT_HEIGHT)
	local node = Unit.has_node(target, aim.node) and Unit.node(target, aim.node) or 0
	local node_position = Unit.world_position(target, node)
	local offset = node_position - pivot

	if Vector3.length_squared(offset) < 0.0001 then
		return
	end

	local flat = Vector3.flat(node_position - POSITION_LOOKUP[unit])

	if Vector3.length_squared(flat) > 0.0001 then
		local body = aim.body and aim.body:unbox() or Unit.local_rotation(unit, 0)
		local turned = rotate_from_to(body, Quaternion.look(Vector3.normalize(flat), Vector3.up()), shooter.action.radial_speed_feet_shooting or math.pi, dt)

		if aim.body then
			aim.body:store(turned)
		else
			aim.body = QuaternionBox(turned)
		end

		if pc.facing then
			Unit.set_local_rotation(unit, 0, turned)
		end
	end

	local wanted = Quaternion.look(offset, Vector3.up())
	local current = aim.rotation and aim.rotation:unbox()

	if not current then
		local game = pc.network():game()
		local synced = game and GameSession.game_object_field(game, go_id, "aim_position")

		current = synced and Vector3.length_squared(synced - pivot) > 0.0001 and Quaternion.look(synced - pivot, Vector3.up()) or wanted
	end

	local rotation = rotate_from_to(current, wanted, shooter.action.radial_speed_upper_body_shooting or math.pi, dt)
	local point = pivot + Quaternion.forward(rotation) * Vector3.length(offset)

	if aim.rotation then
		aim.rotation:store(rotation)
		aim.point:store(point)
	else
		aim.rotation = QuaternionBox(rotation)
		aim.point = Vector3Box(point)
	end
end

-- Where this client's copy of the stream fires from and at, while it aims at this player (ProjectileSystem
-- ._fire_from_position_direction, projectile_system.lua:1174). Nil leaves it to the host's synced aim.
function shots.stream_fire(ratling_gun_unit, go_id)
	local aim = aims[go_id]
	local point = aim and aim.point

	if not point or not judging() then
		return nil
	end

	local position = Unit.world_position(ratling_gun_unit, Unit.node(ratling_gun_unit, "p_fx"))
	local direction = point:unbox() - position

	if Vector3.length_squared(direction) < 0.0001 then
		return nil
	end

	aim.bullets = (aim.bullets or 0) + 1

	return position - Vector3.normalize(direction) * 0.25, direction
end

function shots.stream_stopped(go_id)
	local aim = aims[go_id]

	if aim then
		aims[go_id] = nil

		pc.count("client_streams_aimed")
		pc.log("client stream go=%d stopped: %d bullets aimed here at this player, body turned here %s", go_id, aim.bullets or 0, tostring(aim.body ~= nil))
	end
end

-- Family G (D59): an archer aims at this player. While it aims, shoots and waits after the shot, its body turns here by
-- BTFireProjectileAction.run's rule (bt_fire_projectile_action.lua:179 to :192), which the host runs through all three.
function shots.archer_aimed(go_id)
	local unit = Managers.state.unit_storage:unit(go_id)
	local breed = unit and Unit.alive(unit) and Unit.get_data(unit, "breed")
	local shooter = shooter_of(breed)

	if not shooter or shooter.kind ~= "arrow" or not judging() then
		return
	end

	local action = shooter.action
	local t = pc.now()
	local longest_aim = type(action.aim_cooldown) == "table" and action.aim_cooldown[2] or 1.5

	turns[go_id] = {
		t = t,
		ends_t = t + longest_aim + VOLLEY_WAIT + (action.shoot_cooldown or 2) + 1,
		turn_speed = pc.turn_speed(breed, action),
		aim_animation = action.aim_animation,
		shoot_animation = action.shoot_animation,
		frames = 0,
	}

	pc.count("client_archers_aimed")
end

local function end_turn(go_id, turn, why)
	turns[go_id] = nil

	pc.count("client_archers_ended")
	pc.log("client archer go=%d stopped aiming here (%s): turned on %d frames in %.2fs, turn speed %s", go_id, why, turn.frames, pc.now() - turn.t, tostring(turn.turn_speed))
end

-- Only while this player is more than 45 degrees off its facing, the archer turns towards them on the flat, eased at
-- its turn speed (T18) and snapping once a frame's step reaches 1, as the host's locomotion does (locomotion_templates_ai
-- .lua:156). Otherwise it doesn't turn at all, since the node sets no wanted rotation then.
local function update_archer(go_id, turn, target, dt, t)
	local unit = Managers.state.unit_storage:unit(go_id)

	if not unit or not Unit.alive(unit) or not HEALTH_ALIVE[unit] then
		end_turn(go_id, turn, "the archer is gone")

		return
	elseif t > turn.ends_t then
		end_turn(go_id, turn, "its time is over")

		return
	end

	local current = turn.rotation and turn.rotation:unbox() or Unit.local_rotation(unit, 0)
	local forward = Vector3.flat(Quaternion.forward(current))
	local to_target = Vector3.flat(POSITION_LOOKUP[target] - POSITION_LOOKUP[unit])

	if Vector3.length_squared(forward) > 0.0001 and Vector3.length_squared(to_target) > 0.0001 then
		local direction = Vector3.normalize(to_target)

		if Vector3.dot(direction, Vector3.normalize(forward)) < ARCHER_FACING_DOT then
			local wanted = Quaternion.look(direction, Vector3.up())
			local step = turn.turn_speed * dt

			current = step >= 1 and wanted or Quaternion.lerp(current, wanted, step)
			turn.frames = turn.frames + 1
		end
	end

	if turn.rotation then
		turn.rotation:store(current)
	else
		turn.rotation = QuaternionBox(current)
	end

	if pc.facing then
		Unit.set_local_rotation(unit, 0, current)
	end
end

function shots.has_turning()
	return next(aims) ~= nil or next(turns) ~= nil
end

-- Every frame after LocomotionSystem.update, which has just turned every enemy copy by the host's numbers (Client.lua):
-- the streams' aim and their gunners' bodies, and the archers' bodies, on this player's screen.
function shots.after_locomotion(t, dt)
	local target = pc.local_player_unit()

	if not target or not judging() then
		aims = {}
		turns = {}

		return
	end

	for go_id, aim in pairs(aims) do
		update_aim(go_id, aim, target, dt, t)
	end

	for go_id, turn in pairs(turns) do
		update_archer(go_id, turn, target, dt, t)
	end
end

-- The host's other animations for an archer end its aim here: the next node's, or a stagger's.
function shots.animation_changed(go_id, anim_id)
	local turn = turns[go_id]

	if not turn then
		return
	end

	local event = NetworkLookup.anims[anim_id]

	if event ~= turn.aim_animation and event ~= turn.shoot_animation then
		end_turn(go_id, turn, tostring(event))
	end
end

-- This player's hit staggered or killed the shooter on their screen (Reactions.lua): it stops turning here, and a
-- stream goes back to the host's aim, until the host's own messages end it.
function shots.stop_turning(unit, reason)
	local go_id = Managers.state.unit_storage:go_id(unit)

	if not go_id then
		return
	end

	if aims[go_id] then
		shots.stream_stopped(go_id)
	end

	if turns[go_id] then
		end_turn(go_id, turns[go_id], tostring(reason))
	end
end

-- Family G: what this client's copy of the archer's aim would be at this player, from the arrow's start, by the host's
-- rule (BTFireProjectileAction._fire_from_position_direction, bt_fire_projectile_action.lua:231): their neck, led by
-- their own velocity, capped at 4 m/s.
local function arrow_velocity(action, from, target)
	local neck = Unit.has_node(target, "j_neck") and Unit.node(target, "j_neck")
	local target_position = neck and Unit.world_position(target, neck) or POSITION_LOOKUP[target] + Vector3(0, 0, 1.5)
	local locomotion = ScriptUnit.has_extension(target, "locomotion_system")
	local velocity = Vector3.zero()

	if locomotion and locomotion.small_sample_size_average_velocity then
		velocity = locomotion:small_sample_size_average_velocity()
	elseif locomotion and locomotion.current_velocity then
		velocity = locomotion:current_velocity()
	end

	local speed = Vector3.length(velocity)

	if speed > 4 then
		velocity = velocity * (4 / speed)
	end

	local angle, estimated = WeaponHelper.angle_to_hit_moving_target(from, target_position, action.projectile_speed, velocity, action.projectile_gravity, 0.1)

	if not angle or not estimated then
		return nil
	end

	local to_target = estimated - from

	Vector3.set_z(to_target, 0)

	if Vector3.length_squared(to_target) < 0.0001 then
		return nil
	end

	local flat = Vector3.normalize(to_target)

	return Quaternion.rotate(Quaternion.axis_angle(Vector3.cross(flat, Vector3.up()), angle), flat) * action.projectile_speed
end

local function projectile_system()
	return Managers.state.entity:system("projectile_system")
end

-- This client's copy of the host's arrow, and the list it sits in.
local function find_copy(system, id, projectile)
	local data = system._light_weight.husk_list[pc.host_peer()]

	if not data then
		return nil
	end

	for index = 1, data.current_index do
		local candidate = data.projectiles[index]

		if candidate and (candidate == projectile or projectile == nil and candidate.identifier == id) then
			return candidate, data, index
		end
	end

	return nil
end

-- The shot's own data, which a client's copy of an arrow doesn't carry: as _fire_projectile builds it
-- (bt_fire_projectile_action.lua:316).
local function arrow_action_data(shooter, direction)
	local template = template_of(shooter)

	if not template then
		return nil
	end

	return {
		power_level = power_level_of(template),
		damage_profile = template.damage_profile,
		player_push_velocity = Vector3Box(Vector3.normalize(direction) * (template.impact_push_speed or 0)),
	}
end

local function attach(system, record, projectile)
	record.projectile = projectile
	record.last = Vector3Box(projectile.position:unbox())
	arrows[record.id] = record
	pending[record.id] = nil

	local target = pc.local_player_unit()
	local unit = Managers.state.unit_storage:unit(record.go_id)
	local shooter = unit and Unit.alive(unit) and shooter_of(Unit.get_data(unit, "breed"))

	record.shooter = shooter

	if not record.aimed or not target or not shooter or shooter.kind ~= "arrow" then
		return
	end

	-- On the target's screen the arrow flies at where they really are, with the host's spread.
	local velocity = arrow_velocity(shooter.action, projectile.position:unbox(), target)

	if not velocity then
		return
	end

	local aim = Quaternion.look(Vector3.normalize(velocity), Vector3.up())
	local direction = Vector3.normalize(Quaternion.rotate(aim, record.spread:unbox()))

	projectile.direction:store(direction)
	projectile.rotation:store(Quaternion.look(direction, Vector3.up()))
	projectile.flat_speed = Vector3.length(Vector3.flat(velocity))
	record.reaimed = true

	pc.count("client_arrows_aimed")
end

mod:network_register("pc_arrow", function (sender, version, go_id, id, aimed, sx, sy, sz)
	if pc.broken or pc.is_server() or not pc.in_game() or sender ~= pc.host_peer() or version ~= pc.VERSION then
		return
	end

	if type(go_id) ~= "number" or type(id) ~= "number" or type(sx) ~= "number" or type(sy) ~= "number" or type(sz) ~= "number" then
		return
	end

	local record = {
		id = id,
		go_id = go_id,
		aimed = aimed == true,
		spread = Vector3Box(sx, sy, sz),
		t = pc.now(),
	}

	pc.count("client_arrows")

	local system = projectile_system()
	local projectile = find_copy(system, id)

	if projectile then
		pc.guard("client arrow", attach, system, record, projectile)
	else
		pending[id] = record
	end
end)

-- The arrow's copy arrived after its announcement.
function shots.copy_spawned(system, id)
	local record = pending[id]

	if not record then
		return
	end

	local projectile = find_copy(system, id)

	if projectile then
		attach(system, record, projectile)
	end
end

local function finish_arrow(system, record, why)
	arrows[record.id] = nil

	local projectile, data, index = find_copy(system, record.id, record.projectile)

	-- The host's removal of the copy waited for this screen (rpc_client_despawn_light_weight_projectile below), and an
	-- arrow that hit something here disappears where it hit.
	if projectile and (why ~= "lost" or record.despawned) then
		system:_remove_light_weight_projectile(data, index)
	end

	if why ~= "hit" then
		pc.count("client_arrow_" .. why)
	end
end

-- Every frame, after the game has moved its copies: each arrow this client follows is tested along this frame's
-- flight with the arrow's own filter (the roll let it hit players), as the host's own arrow is (:1863).
function shots.follow(system)
	local target = pc.local_player_unit()
	local t = pc.now()
	local physics_world = World.get_data(system.world, "physics_world")

	for _, record in pairs(arrows) do
		local projectile = find_copy(system, record.id, record.projectile)
		local owner = Managers.state.unit_storage:unit(record.go_id)

		if not projectile or not target or not judging() or t - record.t > MAX_ARROW_TIME or not owner or not Unit.alive(owner) then
			finish_arrow(system, record, "lost")
		else
			local from = record.last:unbox()
			local to = projectile.position:unbox()
			local offset = to - from
			local length = Vector3.length(offset)

			if length > 0.001 then
				local direction = offset / length
				local hits = PhysicsWorld.immediate_raycast(physics_world, from, direction, length, "all", "types", "both", "collision_filter", HIT_FILTER)

				record.last:store(to)

				if hits and #hits > 0 then
					table.sort(hits, by_distance)

					local verdict, zone = first_stop(hits, owner, target)

					if verdict == "player" then
						local action_data = arrow_action_data(record.shooter or shooter_of(Unit.get_data(owner, "breed")), direction)

						if action_data then
							judge_shot("arrow", owner, target, zone, direction, action_data, record.id)
						end

						finish_arrow(system, record, "hit")
					elseif verdict == "other" then
						finish_arrow(system, record, "stopped")
					end
				end
			end
		end
	end
end

-- The host removed its arrow (it hit something there). If this screen is still following its copy, the copy flies on
-- until this screen has judged it. Returns true to hold the removal back.
function shots.despawn(id)
	local record = arrows[id]

	if not record then
		return false
	end

	record.despawned = true
	pc.count("client_arrow_despawn_held")

	return true
end

function shots.update(dt)
	if pc.is_server() then
		return
	end

	local t = pc.now()

	flush(t)

	-- The aims and the turning run after LocomotionSystem.update (shots.after_locomotion).
	for id, record in pairs(pending) do
		if t - record.t > ARROW_MEMORY then
			pending[id] = nil
			pc.count("client_arrow_never_seen")
		end
	end
end

function shots.clear()
	aims = {}
	turns = {}
	arrows = {}
	pending = {}
	queued = {}
	flush_at = 0
end

-- Both sides -----------------------------------------------------------------------------------------------------------

-- target_go_id: the attack's target, aimed: whether that is this player. A stream and an archer's aim go to their
-- target only; a jet goes to every modded player (T19).
mod:network_register("pc_aim", function (sender, version, go_id, kind, node_name, target_go_id, aimed)
	if pc.broken or pc.is_server() or not pc.in_game() or sender ~= pc.host_peer() or version ~= pc.VERSION or type(go_id) ~= "number" then
		return
	end

	if kind == "stream" then
		aims[go_id] = {
			node = type(node_name) == "string" and node_name ~= "" and node_name or "j_spine",
			t = pc.now(),
		}

		pc.count("client_streams_announced")
	elseif kind == "arrow" then
		pc.guard("client archer aim", shots.archer_aimed, go_id)
	elseif kind == "jet" and pc.areas and type(target_go_id) == "number" then
		pc.guard("client jet aim", pc.areas.jet_aimed, go_id, target_go_id, aimed == true)
	end
end)

-- Host: an enemy shooter's own shot that reaches a modded player stops there without hurting them. Client: a bullet of
-- this client's own copy of a stream is judged before the game removes it. A mod:hook on the game's hit callback, so
-- everything except the original call runs through pc.guard.
mod:hook("ProjectileSystem", "physics_cb_light_weight_projectile_hit", function (func, self, projectile_data, hits)
	if pc.broken or not hits or not projectile_data then
		return func(self, projectile_data, hits)
	end

	if self.is_server then
		if not projectile_data.projectile_list_reference and not projectile_data.husk_projectile then
			local ok, cut = pc.guard("host shot filter", shots.host_cut, projectile_data, hits)

			if ok and cut then
				func(self, projectile_data, cut.hits)
				pc.guard("host shot stop", shots.host_stop, self, projectile_data, cut)

				return
			end
		end
	elseif projectile_data.projectile_list_reference then
		pc.guard("client bullet", shots.client_bullet, projectile_data, hits)
	end

	return func(self, projectile_data, hits)
end)

-- Client: the stream's aim on the target's screen (shots.stream_fire).
mod:hook("ProjectileSystem", "_fire_from_position_direction", function (func, self, ratling_gun_unit, go_id)
	if not self.is_server and not pc.broken and aims[go_id] then
		local ok, position, direction = pc.guard("client stream aim", shots.stream_fire, ratling_gun_unit, go_id)

		if ok and position then
			return position, direction
		end
	end

	return func(self, ratling_gun_unit, go_id)
end)

mod:hook_safe("ProjectileSystem", "rpc_clients_continuous_shoot_stop", function (self, channel_id, owner_unit_id)
	shots.stream_stopped(owner_unit_id)
end)

mod:hook_safe("ProjectileSystem", "rpc_client_spawn_light_weight_projectile", function (self, channel_id, damage_source_id, owner_unit_id, position, direction, speed, gravity, flat_speed, effect_id, owner_is_level_unit, owner_peer_id, id)
	if not pc.broken and next(pending) ~= nil then
		pc.guard("client arrow copy", shots.copy_spawned, self, id)
	end
end)

mod:hook("ProjectileSystem", "rpc_client_despawn_light_weight_projectile", function (func, self, channel_id, owner_peer_id, index, id)
	if not self.is_server and not pc.broken and next(arrows) ~= nil then
		local ok, hold = pc.guard("client arrow despawn", shots.despawn, id)

		if ok and hold then
			return
		end
	end

	return func(self, channel_id, owner_peer_id, index, id)
end)

mod:hook_safe("ProjectileSystem", "update", function (self, context, t)
	if not self.is_server and not pc.broken and next(arrows) ~= nil then
		pc.guard("client arrows", shots.follow, self)
	end
end)

-- Host: a ratling gunner's stream starts (bt_ratling_gunner_shoot_action.lua:284).
mod:hook_safe("BTRatlingGunnerShootAction", "_start_shooting", function (self, blackboard, unit, data, t)
	if pc.broken or not pc.is_server() or not pc.in_game() then
		return
	end

	pc.guard("host stream aim", shots.announce_stream, unit, data)
end)

-- Host: an archer starts aiming (bt_fire_projectile_action.lua:24); a modded target's own screen turns it (D59).
mod:hook_safe("BTFireProjectileAction", "enter", function (self, unit, blackboard, t)
	if pc.broken or not pc.is_server() or not pc.in_game() then
		return
	end

	pc.guard("host archer aim", shots.announce_aim, unit, blackboard)
end)

-- Host: an archer's arrow. Its aim before the spread is worked out first, the arrow it creates is captured
-- (create_light_weight_projectile below), and it is announced after.
mod:hook("BTFireProjectileAction", "_fire_projectile", function (func, self, unit, blackboard, dt)
	if pc.broken or not pc.is_server() or not pc.in_game() then
		return func(self, unit, blackboard, dt)
	end

	local ok, base = pc.guard("host arrow aim", shots.arrow_base, self, unit, blackboard, dt)

	shots.capture = ok and base or nil

	local result = func(self, unit, blackboard, dt)
	local capture = shots.capture

	shots.capture = nil

	if capture and capture.created then
		pc.guard("host arrow", shots.announce_arrow, unit, blackboard, capture)
	end

	return result
end)

mod:hook("ProjectileSystem", "create_light_weight_projectile", function (func, self, damage_source, owner_unit, position, direction, speed, gravity, flat_speed, range, collision_filter, action_data, effect_name, owner_peer_id, is_husk, skip_rpc, husk_projectile, projectile_list, id)
	local capture = shots.capture
	local result = func(self, damage_source, owner_unit, position, direction, speed, gravity, flat_speed, range, collision_filter, action_data, effect_name, owner_peer_id, is_husk, skip_rpc, husk_projectile, projectile_list, id)

	if capture and not capture.created and self.is_server and not is_husk and not projectile_list then
		pc.guard("host arrow capture", shots.captured, self, capture, owner_unit, direction, collision_filter)
	end

	return result
end)
