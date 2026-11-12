local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Client side of the enemy reactions this player causes (decisions D13 and D26 to D28). They show on this screen at
-- once, and the host is told, so it applies exactly the same thing (HostReactions.lua):
--   * This player's hit staggers an enemy: worked out here with the game's own stagger maths, played here with its
--     movement, and sent as pc_stagger. The host skips its own stagger for that hit and applies this one.
--   * This player's hit kills an enemy by this machine's reckoning: it dies here at once and pc_kill tells the host,
--     which finishes it off if the hit left it alive there.
--   * This player blocks a swing: the enemy's recoil plays here at once. Client.lua sends the choice with the answer.
-- The host's own copy of the reaction comes back a ping later (the echo) and is dropped. Until it arrives, the host's
-- other animation changes for that enemy are held back as well: the host sent them before it applied this reaction,
-- and the reaction replaces them there too. The host acknowledges every stagger and recoil. If it refuses one, the
-- last change held back is played, so this screen catches up with the host.
-- Only for enemies in pc.REACTION_BREEDS, only while the host runs the same build (pc.host_fresh), and only for this
-- player's own hits and blocks. Every hit this client sends counts: melee, pushes, ranged, career skills (D31).
-- Explosions and other area damage are worked out on the host and stay there (D33).

local reactions = {}

pc.reactions = reactions

local stagger_types = pc.stagger_types

local ECHO_WAIT = 1.5 -- seconds to wait for the host's copy of a reaction before giving up on it
local STAGGER_MARGIN = 2 -- seconds the position stays ours past the predicted end of a stagger, unless the host moves on
local RECOIL_HOLD = 2.5 -- the same for a recoil
local DEAD_MEMORY = 5 -- seconds the host's messages about an enemy killed on this screen are ignored
local SWEEP_INTERVAL = 1

local fakes = {} -- enemy unit -> what this client knows of that enemy's stagger state, in the shape of the host's blackboard
local predictions = {} -- enemy unit -> the reaction this screen is showing
local by_key = {} -- "stagger:<id>" or "recoil:<swing id>" -> the same record, for the host's acknowledgement
local dead = {} -- enemy unit -> { health = its health extension, t } for enemies killed on this screen
local stagger_lookup = {} -- breed name -> { [animation] = stagger type }
local recoil_lookup = {} -- breed name -> { [animation] = true } for its recoil animations
local measuring = {} -- enemy unit -> the stagger or recoil animation its copy here is playing, until its cue (Timings.lua)
local MEASURE_LIMIT = 10 -- seconds an animation is watched for its cue
local next_id = 0
local sweep_timer = 0
local inside_projectile = false -- true while the game's projectile code is sending a hit (see the hook at the bottom)

-- The hit being worked out. One table, refilled for every hit.
local hit = {}

local function animation_system()
	return Managers.state.entity:system("animation_system")
end

local function unit_position(unit)
	return POSITION_LOOKUP[unit] or Unit.world_position(unit, 0)
end

local function covered_breed(unit)
	local breed = Unit.get_data(unit, "breed")

	return breed and pc.REACTION_BREEDS[breed.name] and breed or nil
end

-- Whether this client decides what this player's hits do to this enemy. The host makes the same check from this
-- client's hello (host.peer_decides_attacks), so both sides agree on who decides.
function reactions.decides(unit)
	return pc.attacks and not pc.broken and pc.host_fresh() and pc.compat.matches() and unit ~= nil and covered_breed(unit) ~= nil
end

function reactions.active()
	return next(predictions) ~= nil
end

local breed_actions = {} -- breed name -> { stagger = action, blocked = action } as the breed's behaviour tree uses them

local function find_node_action(node, class_name, depth)
	if type(node) ~= "table" or depth > 30 then
		return nil
	end

	if node[1] == class_name and type(node.action_data) == "table" then
		return node.action_data
	end

	for i = 2, #node do
		local found = find_node_action(node[i], class_name, depth + 1)

		if found then
			return found
		end
	end

	return nil
end

-- The stagger and recoil actions this breed's behaviour tree runs. A breed's actions aren't always filed under its
-- own name: slave rats (skaven_slave) keep theirs under BreedActions.skaven_slave_rat. The behaviour tree
-- (BreedBehaviors[breed.behavior]) points at the right tables, so it is asked first.
local function actions_of(breed)
	local cached = breed_actions[breed.name]

	if cached then
		return cached
	end

	local behaviors = rawget(_G, "BreedBehaviors")
	local tree = behaviors and breed.behavior and behaviors[breed.behavior]
	local own = BreedActions[breed.name]

	cached = {
		stagger = find_node_action(tree, "BTStaggerAction", 0) or own and own.stagger,
		blocked = find_node_action(tree, "BTBlockedAction", 0) or own and own.blocked,
	}
	breed_actions[breed.name] = cached

	return cached
end

local function stagger_action(breed)
	return actions_of(breed).stagger
end

local function add_stagger_anims(lookup, anims_by_type)
	if type(anims_by_type) ~= "table" then
		return
	end

	for stagger_type, by_direction in pairs(anims_by_type) do
		if type(stagger_type) == "number" and type(by_direction) == "table" then
			for _, list in pairs(by_direction) do
				if type(list) == "table" then
					for i = 1, #list do
						lookup[list[i]] = stagger_type
					end
				end
			end
		end
	end
end

local function stagger_type_of(breed, anim)
	local lookup = stagger_lookup[breed.name]

	if not lookup then
		local action = stagger_action(breed)

		lookup = {}

		if action then
			add_stagger_anims(lookup, action.stagger_anims)
			add_stagger_anims(lookup, action.standard_stagger_anims)
			add_stagger_anims(lookup, action.shield_block_anims)
			add_stagger_anims(lookup, action.shield_stagger_anims)
			add_stagger_anims(lookup, action.shield_break_anims)
		end

		stagger_lookup[breed.name] = lookup
	end

	return lookup[anim]
end

-- The game reuses a dead enemy's unit for a new enemy of the same breed (BreedFreezer), with a new network id, so
-- everything kept per unit here is checked against the id it was made for.
local function is_recoil_anim(breed, anim)
	local lookup = recoil_lookup[breed.name]

	if not lookup then
		local action = actions_of(breed).blocked
		local anims = action and action.blocked_anims

		lookup = {}

		if type(anims) == "table" then
			for i = 1, #anims do
				lookup[anims[i]] = true
			end
		end

		recoil_lookup[breed.name] = lookup
	end

	return lookup[anim] == true
end

-- Times a stagger or recoil animation on this client's copy of an enemy, from its start to its cue (see
-- reactions.animation_callback), for the shared timings the host uses to end a client's stagger or recoil on time.
-- scale is the speed it plays at, so a stagger's length is kept at normal speed.
local function measure_start(unit, kind, anim, scale, breed)
	measuring[unit] = {
		kind = kind,
		anim = anim,
		scale = scale and scale > 0 and scale or 1,
		t = pc.now(),
		breed_name = breed.name,
		go_id = Managers.state.unit_storage:go_id(unit),
	}
end

local function measure_host_animation(unit, anim, variable_id, variable_value)
	local breed = Unit.get_data(unit, "breed")

	if type(breed) ~= "table" or not breed.name or breed.is_player or breed.is_hero then
		return
	end

	if stagger_type_of(breed, anim) then
		local scale = 1

		if variable_id and NetworkLookup.anims[variable_id] == "stagger_scale" and type(variable_value) == "number" then
			scale = variable_value
		end

		measure_start(unit, "length", anim, scale, breed)
	elseif is_recoil_anim(breed, anim) then
		measure_start(unit, "cue", anim, 1, breed)
	end
end

local function fake_for(unit, breed)
	local fake = fakes[unit]
	local go_id = Managers.state.unit_storage:go_id(unit)

	if not fake or fake.breed ~= breed or fake.go_id ~= go_id then
		fake = {
			breed = breed,
			go_id = go_id,
		}
		fakes[unit] = fake
	end

	return fake
end

-- Whether this unit is an enemy killed on this screen, whose host messages are ignored. Only while the unit is still
-- that dead enemy: the same network id, and not alive again.
local function dead_here(unit)
	local record = dead[unit]

	if not record then
		return false
	end

	if HEALTH_ALIVE[unit] or Managers.state.unit_storage:go_id(unit) ~= record.go_id then
		dead[unit] = nil

		return false
	end

	return true
end

-- How far the enemy is from where the host has it, for the debug log when this screen hands it back.
local function offset_from_host(unit)
	local network = pc.network()
	local game = network and network:game()
	local go_id = Managers.state.unit_storage:go_id(unit)

	if not game or not go_id or not Unit.alive(unit) then
		return nil
	end

	local host_position = GameSession.game_object_field(game, go_id, "position")

	return host_position and Vector3.distance(Unit.local_position(unit, 0), host_position) or nil
end

-- The shield on this client's copy of a shielded enemy (AIShieldUserHuskExtension) has neither the host's
-- shield_broken flag nor set_is_blocking, both of which the game's stagger code for shielded breeds uses. While that
-- code runs here, ScriptUnit hands it this stand-in instead, kept per enemy as the host keeps its shield.
local function shield_for(unit, fake)
	local shield = fake.shield

	if shield == nil then
		shield = ScriptUnit.has_extension(unit, "ai_shield_system") and {
			shield_broken = false,
			blocked_previous_attack = false,
			is_blocking = true,
			set_is_blocking = function (self, is_blocking)
				self.is_blocking = is_blocking
			end,
		} or false
		fake.shield = shield
	end

	return shield or nil
end

-- Whether the host has the enemy's shield up, as its game object says (AIShieldUserHuskExtension.get_is_blocking).
local function shield_up(unit)
	local extension = ScriptUnit.has_extension(unit, "ai_shield_system")

	return extension ~= nil and extension.get_is_blocking ~= nil and extension:get_is_blocking() == true
end

local function end_stand_ins(unit, previous_blackboard, real_extension, real_has_extension, ok, ...)
	BLACKBOARDS[unit] = previous_blackboard
	ScriptUnit.extension = real_extension
	ScriptUnit.has_extension = real_has_extension

	if not ok then
		error((...), 0)
	end

	return ...
end

-- Runs one of the game's functions as if this client were the host for this enemy: its blackboard is the stand-in,
-- and so is its shield. Both are put back however the call ends.
local function with_stand_ins(unit, fake, fn, ...)
	local shield = shield_for(unit, fake)
	local previous_blackboard = BLACKBOARDS[unit]
	local real_extension, real_has_extension = ScriptUnit.extension, ScriptUnit.has_extension

	BLACKBOARDS[unit] = fake

	if shield then
		ScriptUnit.extension = function (target, system_name)
			if target == unit and system_name == "ai_shield_system" then
				return shield
			end

			return real_extension(target, system_name)
		end
		ScriptUnit.has_extension = function (target, system_name)
			if target == unit and system_name == "ai_shield_system" then
				return shield
			end

			return real_has_extension(target, system_name)
		end
	end

	return end_stand_ins(unit, previous_blackboard, real_extension, real_has_extension, pcall(fn, ...))
end

-- What BTStaggerAction.run does to these timers as time passes (bt_stagger_action.lua:255).
local function expire_timers(fake, t)
	if fake.stagger_immune_time and t > fake.stagger_immune_time then
		fake.stagger_immune_time = nil
	end

	if fake.heavy_stagger_immune_time and t > fake.heavy_stagger_immune_time then
		fake.heavy_stagger_immune_time = nil
	end
end

-- What BTStaggerAction.clean_blackboard does when a stagger ends.
local function stagger_over(fake)
	fake.action = nil
	fake.heavy_stagger_immune_time = nil
	fake.stagger = nil
	fake.stagger_anim_done = nil
	fake.stagger_immune_time = nil
	fake.stagger_time = nil
	fake.stagger_type = nil
	fake.staggering_id = nil
end

-- An enemy animation the host played and this screen shows. Keeps the stand-in blackboard close to the host's.
local function track_host_animation(unit, anim)
	local fake = fakes[unit]

	if anim == "stagger_finished" then
		if fake then
			stagger_over(fake)
		end

		return
	end

	local breed = fake and fake.breed or covered_breed(unit)
	local stagger_type = breed and stagger_type_of(breed, anim)

	if not stagger_type then
		-- A new move. The host clears this flag when the enemy starts its next attack (bt_attack_action.lua:224).
		if fake then
			fake.anim_cb_stagger_immune = nil
		end

		return
	end

	-- Someone else's stagger, seen as the host plays it. Its strength isn't sent, so it counts as one.
	local t = pc.now()
	local action = stagger_action(breed)

	fake = fake_for(unit, breed)
	fake.stagger = (fake.stagger or 0) + 1
	fake.stagger_type = stagger_type
	fake.stagger_anim_done = false
	fake.staggering_id = fake.stagger
	fake.action = action

	if action and action.custom_enter_function then
		pcall(with_stand_ins, unit, fake, action.custom_enter_function, unit, fake, t, action)
	end
end

-- The host dropped an enemy's shield (AIShieldUserExtension.break_shield sends rpc_ai_drop_single_item).
function reactions.item_dropped(unit_id, reason_id)
	if NetworkLookup.item_drop_reasons[reason_id] ~= "shield_break" then
		return
	end

	local unit = Managers.state.unit_storage:unit(unit_id)
	local breed = unit and covered_breed(unit)
	local shield = breed and shield_for(unit, fake_for(unit, breed))

	if shield then
		shield.shield_broken = true
		shield.is_blocking = false
	end
end

-- Animation cues seen on this client's copy of an enemy, which the host's blackboard records the same way
-- (animation_callback_templates.lua:31 and :857).
function reactions.animation_callback(unit, callback_name)
	local measure = measuring[unit]

	if measure and (callback_name == "anim_cb_push_finished" and measure.kind == "length" or callback_name == "anim_cb_blocked_cooldown" and measure.kind == "cue") then
		measuring[unit] = nil

		if Managers.state.unit_storage:go_id(unit) == measure.go_id then
			local elapsed = pc.now() - measure.t

			pc.timings.learn(measure.kind, measure.breed_name, measure.anim, measure.kind == "length" and elapsed * measure.scale or elapsed)
		end
	end

	local fake = fakes[unit]

	if not fake then
		return
	end

	if callback_name == "anim_cb_push_finished" then
		fake.stagger_anim_done = true
	elseif callback_name == "anim_cb_stagger_immune" then
		fake.anim_cb_stagger_immune = true
	end
end

local function read_hit_args(...)
	hit.power_level = 0
	hit.target_index = 0
	hit.boost_curve_multiplier = 0
	hit.is_critical_strike = false
	hit.can_damage = true
	hit.can_stagger = true
	hit.ragdoll_actor_id = 1
	hit.blocking = false
	hit.shield_break_procced = false
	hit.backstab_multiplier = 1
	hit.first_hit = false
	hit.total_hits = 0

	for i = 1, select("#", ...) - 1, 2 do
		local name, value = select(i, ...)

		if value ~= nil then
			if name == "power_level" then
				hit.power_level = value
			elseif name == "hit_target_index" then
				hit.target_index = value
			elseif name == "boost_curve_multiplier" then
				hit.boost_curve_multiplier = value
			elseif name == "is_critical_strike" then
				hit.is_critical_strike = value
			elseif name == "can_damage" then
				hit.can_damage = value
			elseif name == "can_stagger" then
				hit.can_stagger = value
			elseif name == "hit_ragdoll_actor" then
				hit.ragdoll_actor_id = value
			elseif name == "blocking" then
				hit.blocking = value
			elseif name == "shield_break_procced" then
				hit.shield_break_procced = value
			elseif name == "backstab_multiplier" then
				hit.backstab_multiplier = value
			elseif name == "first_hit" then
				hit.first_hit = value
			elseif name == "total_hits" then
				hit.total_hits = value
			end
		end
	end

	-- WeaponSystem.send_rpc_attack_hit clamps it the same way before sending.
	local min_power, max_power = rawget(_G, "MIN_POWER_LEVEL"), rawget(_G, "MAX_POWER_LEVEL")

	if min_power and max_power then
		hit.power_level = math.clamp(hit.power_level, min_power, max_power)
	end
end

local function send(message, ...)
	local host_peer = pc.host_peer()

	if host_peer then
		mod:network_send(message, host_peer, pc.VERSION, ...)
	end
end

local function finish_prediction(prediction, reason, catch_up)
	if predictions[prediction.unit] == prediction then
		predictions[prediction.unit] = nil
	end

	by_key[prediction.key] = nil

	local held = prediction.held

	-- The host never played this reaction, so this screen plays the newest change the host did make.
	if catch_up and held and not prediction.echo_seen and Unit.alive(prediction.unit) and Unit.has_animation_state_machine(prediction.unit) then
		local event = NetworkLookup.anims[held.anim_id]

		if held.variable_id then
			animation_system():anim_event_with_variable_float(prediction.unit, event, NetworkLookup.anims[held.variable_id], held.variable_value, true)
		else
			animation_system():anim_event(prediction.unit, event, true)
		end

		pc.count("client_held_replayed")
	end

	local offset = pc.debug and offset_from_host(prediction.unit)

	pc.log("client %s=%s enemy=%s ended: %s, echo=%s, held=%s, moved=%.2fm, from_host=%s, lasted=%.3fs", prediction.kind, tostring(prediction.id), prediction.breed_name, reason, tostring(prediction.echo_seen), tostring(held ~= nil), prediction.moved,
		offset and string.format("%.2fm", offset) or "n/a", pc.now() - prediction.started_t)
end

local function start_prediction(kind, id, unit, breed, echo, moves, scale, hold, t)
	local previous = predictions[unit]

	if previous then
		finish_prediction(previous, "replaced")
	end

	local prediction = {
		kind = kind,
		id = id,
		key = kind .. ":" .. tostring(id),
		unit = unit,
		breed_name = breed.name,
		echo = echo, -- animation names the host will play for this reaction, in order
		echo_index = 1,
		echo_seen = false,
		held = nil, -- the newest host animation change held back while waiting for the echo
		moves = moves,
		scale = scale,
		position = Vector3Box(Unit.local_position(unit, 0)),
		rotation = QuaternionBox(Unit.local_rotation(unit, 0)),
		started_t = t,
		echo_deadline = t + ECHO_WAIT,
		expires = t + hold,
		moved = 0,
	}

	predictions[unit] = prediction
	by_key[prediction.key] = prediction

	return prediction
end

-- Called for each new swing the host announces. Returns why it can't land on this screen, or nil.
function reactions.busy(unit)
	if dead_here(unit) then
		return "killed by you"
	end

	local prediction = predictions[unit]

	if not prediction then
		return nil
	end

	-- Before the echo, the host started this swing without knowing of the reaction this screen shows, and that
	-- reaction cancels the swing there as well. After the echo, a new swing means the host's reaction is over.
	if not prediction.echo_seen then
		return prediction.kind == "recoil" and "recoiling" or "staggered by you"
	end

	finish_prediction(prediction, "the host started a new swing")

	return nil
end

-- Moves the enemy by its own animation's root motion, the way the host moves it during a stagger or recoil, instead
-- of by the host's velocity, which is a ping behind here. The host's AI locomotion scales root motion by the
-- stagger length; a recoil uses 1.
local function move(prediction, unit, dt)
	if dt <= 0 then
		return
	end

	local pose = Unit.animation_wanted_root_pose(unit)
	local wanted = Matrix4x4.translation(pose)
	local current = prediction.position:unbox()
	local delta = wanted - current

	delta = Vector3(delta.x * prediction.scale, delta.y * prediction.scale, 0)

	local new_position = current + delta
	local ai_system = Managers.state.entity:system("ai_system")
	local nav_world = ai_system and ai_system:nav_world()
	local locomotion = ScriptUnit.has_extension(unit, "locomotion_system")

	if nav_world and locomotion and locomotion.traverse_logic then
		local on_navmesh = GwNavQueries.move_on_navmesh(nav_world, current, delta / dt, dt, locomotion:traverse_logic())

		if on_navmesh then
			new_position = on_navmesh
		end
	end

	prediction.position:store(new_position)
	prediction.moved = prediction.moved + Vector3.length(new_position - current)

	Unit.set_local_position(unit, 0, new_position)

	local current_rotation = prediction.rotation:unbox()
	local delta_rotation = Quaternion.multiply(Quaternion.inverse(current_rotation), Matrix4x4.rotation(pose))
	local rotation = Quaternion.multiply(current_rotation, Quaternion(Vector3.up(), Quaternion.yaw(delta_rotation)))

	prediction.rotation:store(rotation)
	Unit.set_local_rotation(unit, 0, rotation)
end

-- Runs after LocomotionSystem.update every frame while a reaction is showing, after the engine has moved every enemy
-- copy by the host's numbers, so the position set here is the one drawn.
function reactions.after_locomotion(t, dt)
	for unit, prediction in pairs(predictions) do
		if not Unit.alive(unit) or not HEALTH_ALIVE[unit] then
			finish_prediction(prediction, "enemy died")
		elseif not prediction.echo_seen and t > prediction.echo_deadline then
			pc.count("client_echo_timeout")
			finish_prediction(prediction, "the host never played it", true)
		elseif t > prediction.expires then
			finish_prediction(prediction, "held long enough")
		elseif prediction.moves then
			move(prediction, unit, dt)
		end
	end
end

-- Copy of action_ignores_stagger (damage_utils.lua:3537) for an enemy.
local function action_ignores_stagger(fake, attack_template, stagger_type)
	if fake.anim_cb_stagger_immune then
		return true
	end

	local action = fake.action
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
			local percent = fake.current_health_percent or 1

			return percent > ignore.health.min and percent <= ignore.health.max
		end

		return ignore.type == "reset_attack"
	end

	return ignore == true
end

-- What DamageUtils.stagger_ai (damage_utils.lua:3578) and AiUtils.stagger decide for this hit, on this client's
-- stand-in for the host's blackboard. The stagger maths itself is the game's own DamageUtils.calculate_stagger_player,
-- which reads BLACKBOARDS[unit]; enemies have none on a client, so the stand-in is put there for the call.
-- Not copied: the stagger immunity of elites and bosses, which none of pc.REACTION_BREEDS have.
local function work_out_stagger(unit, breed, fake, attacker, damage_profile, target_index, hit_zone_name, attack_direction, damage_source, t)
	local target_settings = damage_profile.targets and damage_profile.targets[target_index] or damage_profile.default_target
	local attack_template = target_settings and DamageUtils.get_attack_template(target_settings.attack_template)

	if not attack_template then
		return nil, "no attack template"
	end

	expire_timers(fake, t)

	local health = ScriptUnit.has_extension(unit, "health_system")

	fake.current_health_percent = health and health:current_health_percent() or 1

	local power_level = hit.can_stagger and hit.power_level or 0
	local stagger_type, duration, length, stagger_value = with_stand_ins(unit, fake, DamageUtils.calculate_stagger_player, ImpactTypeOutput, unit, attacker, hit_zone_name, power_level, hit.boost_curve_multiplier, hit.is_critical_strike, damage_profile, target_index, hit.blocking, damage_source)

	if type(stagger_type) ~= "number" or stagger_type <= stagger_types.none then
		return nil, "too weak to stagger"
	end

	if action_ignores_stagger(fake, attack_template, stagger_type) then
		return nil, fake.anim_cb_stagger_immune and "stagger immune (animation cue)" or "its action ignores this stagger"
	end

	local is_push = damage_profile.is_push and true or false
	local always_stagger = attack_template.always_stagger and true or false

	-- AiUtils.stagger refuses these (ai_utils.lua:1110).
	if not always_stagger and not is_push and fake.stagger and fake.stagger_type == stagger_types.explosion and stagger_type ~= stagger_types.explosion then
		return nil, "already blown back"
	end

	if breed.boss_staggers and stagger_type < stagger_types.explosion then
		return nil, "boss"
	end

	local direction = attack_direction
	local stagger_angle = attack_template.stagger_angle
	local target_position = unit_position(unit)
	local attacker_position = unit_position(attacker)

	if stagger_angle == "down" or stagger_angle == "smiter" and hit.blocking then
		direction = Vector3.normalize(target_position - attacker_position)
		direction = Vector3(direction.x, direction.y, -1)
	elseif stagger_angle == "stab" or stagger_angle == "smiter" or hit.blocking then
		direction = Vector3.normalize(target_position - attacker_position)
	elseif stagger_angle == "pull" then
		direction = Vector3.normalize(attacker_position - target_position)
	end

	return stagger_type, duration or 0, length or 0, stagger_value or 1, direction, attack_template.stagger_animation_scale, always_stagger, is_push
end

-- Copy of BTStaggerAction._select_animation (bt_stagger_action.lua:115). The host's distance to its destination
-- isn't known here, so the distance to this player stands in for it.
local function select_animation(unit, fake, impact_vec, stagger_anims, attacker)
	local impact_dir = Vector3.normalize(impact_vec)
	local my_fwd = Quaternion.forward(Unit.local_rotation(unit, 0))
	local dot = math.clamp(Vector3.dot(my_fwd, impact_dir), -1, 1)
	local angle = math.acos(dot)
	local action = fake.action
	local locomotion = ScriptUnit.has_extension(unit, "locomotion_system")
	local velocity = locomotion and locomotion:current_velocity() or Vector3.zero()
	local destination_dist = Vector3.distance(unit_position(unit), unit_position(attacker))
	local moving_stagger_distance = action.moving_stagger_minimum_destination_distance
	local in_moving_stagger_distance = moving_stagger_distance and moving_stagger_distance < destination_dist
	local moving_stagger_threshold = action.moving_stagger_threshold
	local in_moving_stagger_velocity = moving_stagger_threshold and moving_stagger_threshold < Vector3.dot(velocity, my_fwd)
	local moving_stagger = false

	if not fake.always_stagger_suffered then
		moving_stagger = in_moving_stagger_distance and in_moving_stagger_velocity
	end

	fake.always_stagger_suffered = nil

	local impact_rot, anim_table

	if impact_vec.z == -1 and stagger_anims.dwn then
		impact_dir = Vector3(impact_dir.x, impact_dir.y, 0)
		impact_rot = Quaternion.look(-impact_dir)
		anim_table = moving_stagger and stagger_anims.moving_dwn or stagger_anims.dwn
	else
		impact_dir = Vector3(impact_dir.x, impact_dir.y, 0)

		if angle > math.pi * 0.75 then
			impact_rot = Quaternion.look(-impact_dir)
			anim_table = moving_stagger and stagger_anims.moving_bwd or stagger_anims.bwd
		elseif angle < math.pi * 0.25 then
			impact_rot = Quaternion.look(impact_dir)
			anim_table = moving_stagger and stagger_anims.moving_fwd or stagger_anims.fwd
		elseif Vector3.cross(my_fwd, impact_dir).z > 0 then
			impact_rot = Quaternion.look(Vector3.cross(Vector3(0, 0, -1), impact_dir))
			anim_table = moving_stagger and stagger_anims.moving_left or stagger_anims.left
		else
			impact_rot = Quaternion.look(Vector3.cross(Vector3(0, 0, 1), impact_dir))
			anim_table = moving_stagger and stagger_anims.moving_right or stagger_anims.right
		end
	end

	local num_anims = anim_table and #anim_table or 0

	if num_anims == 0 then
		return nil
	end

	local index = math.random(1, num_anims)
	local anim = anim_table[index]

	if anim == fake.last_stagger_anim then
		anim = anim_table[index % num_anims + 1]
	end

	fake.last_stagger_anim = anim

	return anim, Quaternion(Vector3.up(), Quaternion.yaw(impact_rot))
end

-- What AiUtils.stagger writes to the host's blackboard, then what BTStaggerAction.enter does with it, on the
-- stand-in. Returns the animations the host will play and the enemy's new facing.
local function enter_stagger(unit, breed, fake, attacker, stagger_type, duration, length, stagger_value, direction, anim_scale, always_stagger, is_push, t)
	local action = stagger_action(breed)

	if not action then
		return nil
	end

	local difficulty_settings = Managers.state.difficulty:get_difficulty_settings()

	fake.stagger_length = length
	fake.stagger_time = duration * (difficulty_settings.stagger_modifier or 1) + t
	fake.stagger = (fake.stagger or 0) + stagger_value
	fake.stagger_type = stagger_type
	fake.stagger_animation_scale = anim_scale
	fake.always_stagger_suffered = always_stagger
	fake.stagger_was_push = is_push

	-- AiUtils.stagger: a shield user hit while attacking with its shield down counts as heavily staggered. The host's
	-- attack token isn't known here; an open swing at this player stands in for it.
	if fake.shield and fake.stagger < 3 and not shield_up(unit) and pc.client.swinging(unit) then
		fake.stagger = 3
	end

	local prediction = predictions[unit]

	fake.blocked = prediction ~= nil and prediction.kind == "recoil" or nil
	fake.stagger_anim_done = false
	fake.staggering_id = fake.stagger
	fake.action = action

	local stagger_anims, idle_event, override_rotation

	if action.custom_enter_function then
		local _

		stagger_anims, idle_event, _, override_rotation = with_stand_ins(unit, fake, action.custom_enter_function, unit, fake, t, action)
	else
		idle_event = "idle"
		stagger_anims = action.stagger_anims and action.stagger_anims[stagger_type]
	end

	if type(stagger_anims) ~= "table" then
		return nil
	end

	local anim, impact_rotation = select_animation(unit, fake, direction, stagger_anims, attacker)

	if not anim then
		return nil
	end

	local variable_scale = action.scale_animation_speeds and (action.stagger_animation_scale or anim_scale or 1) or nil

	return anim, idle_event or "idle", override_rotation or impact_rotation, variable_scale
end

local function stagger(unit, breed, attacker, damage_profile, profile_name, target_index, hit_zone_name, attack_direction, damage_source_name, t)
	local fake = fake_for(unit, breed)
	local stagger_type, duration, length, stagger_value, direction, anim_scale, always_stagger, is_push = work_out_stagger(unit, breed, fake, attacker, damage_profile, target_index, hit_zone_name, attack_direction, damage_source_name, t)

	if not stagger_type then
		pc.count("client_hit_no_stagger")
		pc.log("client hit enemy=%s profile=%s no stagger: %s", breed.name, tostring(profile_name), tostring(duration))

		return
	end

	local anim, idle_event, rotation, variable_scale = enter_stagger(unit, breed, fake, attacker, stagger_type, duration, length, stagger_value, direction, anim_scale, always_stagger, is_push, t)

	if not anim then
		stagger_over(fake)
		pc.count("client_hit_no_stagger_animation")
		pc.print("client hit enemy=%s type=%d: no stagger animation found for this breed, so nothing was staggered", breed.name, stagger_type)

		return
	end

	next_id = next_id + 1

	local id = next_id
	local position = Unit.local_position(unit, 0)

	-- The host hears of it before anything plays here, so a problem in the local effects can't leave it out.
	send("pc_stagger", id, pc.network():unit_game_object_id(unit), stagger_type, pc.finite(duration, 3), pc.finite(length, 3), pc.finite(direction.x, 3), pc.finite(direction.y, 3), pc.finite(direction.z, 3),
		anim_scale and pc.finite(anim_scale, 3) or -1, pc.finite(stagger_value, 3), always_stagger, is_push, anim, pc.finite(Quaternion.yaw(rotation), 4),
		pc.finite(position.x, 3), pc.finite(position.y, 3), pc.finite(position.z, 3), true, profile_name, target_index or 0, damage_source_name)

	pc.client.reaction_started(unit, "staggered by you")

	-- What BTStaggerAction.enter shows on every machine, played here now.
	Unit.set_local_rotation(unit, 0, rotation)

	local animations = animation_system()

	if variable_scale then
		animations:anim_event_with_variable_float(unit, anim, "stagger_scale", variable_scale, true)
	else
		animations:anim_event(unit, anim, true)
	end

	animations:anim_event(unit, idle_event, true)

	local difficulty_settings = Managers.state.difficulty:get_difficulty_settings()

	local prediction = start_prediction("stagger", id, unit, breed, { anim, idle_event }, true, length, duration * (difficulty_settings.stagger_modifier or 1) + STAGGER_MARGIN, t)

	prediction.opening_event = breed.shield_opening_event

	measure_start(unit, "length", anim, variable_scale or 1, breed)

	pc.count("client_stagger")
	pc.log("client stagger=%d enemy=%s type=%d duration=%.2f length=%.2f anim=%s push=%s accumulated=%.2f", id, breed.name, stagger_type, duration, length, anim, tostring(is_push), fake.stagger or 0)
end

-- What HealthSystem.rpc_add_damage does on this machine when the host's killing blow arrives: the damage, which the
-- ragdoll and the blood read, then the death (health_system.lua:368).
local function kill(unit, breed, attacker, health, damage, damage_profile, target_index, hit_zone_name, hit_position, attack_direction, damage_source_name, t)
	local damage_type = DamageUtils.get_damage_type(damage_profile, target_index) or "kinetic"

	next_id = next_id + 1

	local id = next_id

	send("pc_kill", id, pc.network():unit_game_object_id(unit), hit_zone_name, damage_type, pc.finite(attack_direction.x, 3), pc.finite(attack_direction.y, 3), pc.finite(attack_direction.z, 3), damage_source_name)

	dead[unit] = {
		go_id = pc.network():unit_game_object_id(unit),
		t = t,
	}

	local prediction = predictions[unit]

	if prediction then
		finish_prediction(prediction, "killed by you")
	end

	pc.client.reaction_started(unit, "killed by you")

	local ragdoll_actor = NetworkLookup.hit_ragdoll_actors[hit.ragdoll_actor_id]

	if ragdoll_actor == "n/a" then
		ragdoll_actor = nil
	end

	health:add_damage(attacker, damage, hit_zone_name, damage_type, hit_position, attack_direction, damage_source_name, ragdoll_actor, attacker, nil, hit.is_critical_strike, false, hit.first_hit, hit.total_hits, damage_profile.charge_value, hit.backstab_multiplier, target_index)

	if health:is_alive() then
		-- A plain table: the death system keeps it until its own update, which may come a frame later, so a frame
		-- table could be reused by then.
		local killing_blow = {}

		killing_blow[DamageDataIndex.DAMAGE_AMOUNT] = damage
		killing_blow[DamageDataIndex.DAMAGE_TYPE] = damage_type
		killing_blow[DamageDataIndex.ATTACKER] = attacker
		killing_blow[DamageDataIndex.HIT_ZONE] = hit_zone_name
		killing_blow[DamageDataIndex.POSITION] = hit_position and Vector3Aux.box(nil, hit_position)
		killing_blow[DamageDataIndex.DIRECTION] = Vector3Aux.box(nil, attack_direction)
		killing_blow[DamageDataIndex.DAMAGE_SOURCE_NAME] = damage_source_name
		killing_blow[DamageDataIndex.HIT_RAGDOLL_ACTOR_NAME] = ragdoll_actor
		killing_blow[DamageDataIndex.SOURCE_ATTACKER_UNIT] = attacker
		killing_blow[DamageDataIndex.HIT_REACT_TYPE] = nil
		killing_blow[DamageDataIndex.CRITICAL_HIT] = hit.is_critical_strike
		killing_blow[DamageDataIndex.FIRST_HIT] = hit.first_hit
		killing_blow[DamageDataIndex.TOTAL_HITS] = hit.total_hits
		killing_blow[DamageDataIndex.ATTACK_TYPE] = damage_profile.charge_value
		killing_blow[DamageDataIndex.BACKSTAB_MULTIPLIER] = hit.backstab_multiplier
		killing_blow[DamageDataIndex.TARGET_INDEX] = target_index or 1

		Managers.state.entity:system("death_system"):kill_unit(unit, killing_blow)
	end

	pc.count("client_kill")
	pc.log("client kill=%d enemy=%s damage=%.1f", id, breed.name, damage)
end

-- The damage half of DamageUtils.server_apply_hit (damage_utils.lua:3666) and add_damage_network_player (:1864), as
-- far as this client can follow it: the host's damage buffs (apply_buffs_to_damage) only run there, and they mostly
-- add damage, so this guess falls short of a kill more often than past one. Returns true if the hit kills.
local function damage(unit, breed, attacker, damage_profile, target_index, hit_zone_name, hit_position, attack_direction, damage_source_name, t)
	if hit.blocking then
		return false
	end

	local health = ScriptUnit.has_extension(unit, "health_system")

	if not health or not health.apply_client_predicted_damage then
		return false
	end

	-- The game's projectile code has already recorded this hit's damage (player_projectile_unit_extension.lua:765).
	local already_recorded = inside_projectile

	if not already_recorded and not health:client_predicted_is_alive() then
		return false
	end

	local power_level = hit.can_damage and hit.power_level or 0

	if damage_profile.charge_value == "heavy_attack" then
		local status = ScriptUnit.has_extension(attacker, "status_system")
		local min_fall, fall_bonus = rawget(_G, "MinFallDistanceForBonus"), rawget(_G, "FallingPowerLevelBonusMultiplier")

		if status and min_fall and fall_bonus and status:fall_distance() >= min_fall then
			power_level = power_level * fall_bonus
		end
	end

	local amount

	if damage_profile.instant_death then
		amount = health:current_health()
	else
		local target_settings = damage_profile.targets and damage_profile.targets[target_index] or damage_profile.default_target

		amount = DamageUtils.calculate_damage(DamageOutput, unit, attacker, hit_zone_name, power_level, BoostCurves[target_settings.boost_curve_type], hit.boost_curve_multiplier, hit.is_critical_strike, damage_profile, target_index, hit.backstab_multiplier, damage_source_name)
	end

	amount = DamageUtils.networkify_damage(amount or 0)

	if amount <= 0 then
		return false
	end

	-- The game's own record of damage a client expects (player_projectile_unit_extension.lua:765 does the same). The
	-- host's damage message takes it off again when it arrives.
	if not already_recorded then
		health:apply_client_predicted_damage(amount)
	end

	if health:client_predicted_is_alive() then
		return false
	end

	kill(unit, breed, attacker, health, amount, damage_profile, target_index, hit_zone_name, hit_position, attack_direction, damage_source_name, t)

	return true
end

-- Called after the game has sent one of this player's hits to the host (WeaponSystem.send_rpc_attack_hit). The host
-- skips its own stagger for this hit when this client decides (HostReactions.lua), so this decides it: the damage
-- first, which may kill, then the stagger, as DamageUtils.server_apply_hit does on the host.
function reactions.attack_hit(damage_source_id, attacker_unit_id, hit_unit_id, hit_zone_id, hit_position, attack_direction, damage_profile_id, ...)
	local unit_storage = Managers.state.unit_storage
	local unit = unit_storage:unit(hit_unit_id)

	if not unit or not Unit.alive(unit) or not HEALTH_ALIVE[unit] or dead_here(unit) or not reactions.decides(unit) then
		return
	end

	local attacker = pc.local_player_unit()

	if not attacker or unit_storage:unit(attacker_unit_id) ~= attacker then
		return
	end

	local profile_name = NetworkLookup.damage_profiles[damage_profile_id]
	local damage_profile = profile_name and DamageProfileTemplates[profile_name]
	local damage_source_name = NetworkLookup.damage_sources[damage_source_id]

	if not damage_profile or not damage_source_name then
		return
	end

	read_hit_args(...)

	local breed = Unit.get_data(unit, "breed")
	local hit_zone_name = NetworkLookup.hit_zones[hit_zone_id] or "full"
	local target_index = hit.target_index ~= 0 and hit.target_index or nil
	local t = pc.now()

	local fake = fake_for(unit, breed)
	local shield = shield_for(unit, fake)
	local breaks_shield = shield ~= nil and hit.blocking and not shield.shield_broken and (damage_profile.shield_break or hit.shield_break_procced) and not breed.unbreakable_shield

	if damage(unit, breed, attacker, damage_profile, target_index, hit_zone_name, hit_position, attack_direction, damage_source_name, t) then
		return true
	end

	-- A hit taken on the shield that breaks it: no damage, the shield goes (AIShieldUserExtension.break_shield), and
	-- the stagger counts as unblocked (DamageUtils.server_apply_hit).
	if breaks_shield then
		shield.shield_broken = true
		shield.is_blocking = false
		fake.shield_breaking_hit = true
		fake.shield_user = false
		hit.blocking = false

		pc.count("client_shield_broken")
	end

	if not damage_profile.no_stagger then
		stagger(unit, breed, attacker, damage_profile, profile_name, target_index, hit_zone_name, attack_direction, damage_source_name, t)
	end

	-- Decided here, stagger or not, so a swing from this enemy is cut only if a stagger was shown.
	return true
end

local function blocked_action(swing)
	local set = swing.set_name and BreedActions[swing.set_name]

	return set and set.blocked or actions_of(swing.breed).blocked
end

-- Called by Client.lua at a damage frame judged "blocked", before the answer goes out. Returns the recoil animation
-- the host should play, and where this screen shows the enemy (with /pingcomp recoil full), or nil to leave the
-- recoil to the host as before.
function reactions.choose_recoil(swing, unit)
	if pc.recoil == "off" or pc.broken or not pc.host_fresh() then
		return nil
	end

	local action = swing.action

	-- No recoil here either way: the attack has none, or the enemy is already staggered or recoiling (book_block).
	if action.no_block_stagger or predictions[unit] or dead_here(unit) or not Unit.alive(unit) or not HEALTH_ALIVE[unit] then
		return nil
	end

	local fake = fakes[unit]

	if fake and fake.stagger then
		return nil
	end

	local blocked = blocked_action(swing)
	local anims = blocked and blocked.blocked_anims
	local anim = action.blocked_anim or type(anims) == "table" and #anims > 0 and anims[math.random(1, #anims)] or nil

	if not anim then
		return nil
	end

	local position = pc.recoil == "full" and Unit.local_position(unit, 0) or nil

	return anim, position, Quaternion.yaw(Unit.local_rotation(unit, 0))
end

-- Plays the recoil chosen above, now. The host's copy comes back a ping later and is dropped.
function reactions.play_recoil(swing, unit, anim)
	animation_system():anim_event(unit, anim, true)
	measure_start(unit, "cue", anim, 1, swing.breed)
	start_prediction("recoil", swing.id, unit, swing.breed, { anim }, pc.recoil == "full", 1, RECOIL_HOLD, pc.now())
	pc.count("client_recoil")
end

-- Every enemy animation message from the host comes here first (the hooks at the bottom). Returns true to drop it.
function reactions.host_animation(go_id, anim_id, variable_id, variable_value)
	local unit = Managers.state.unit_storage:unit(go_id)

	if not unit then
		return false
	end

	if dead_here(unit) then
		pc.count("client_dropped_after_kill")

		return true
	end

	local anim = NetworkLookup.anims[anim_id]
	local prediction = predictions[unit]

	if prediction then
		if not prediction.echo_seen then
			if anim == prediction.echo[1] then
				prediction.echo_seen = true
				prediction.echo_index = 2

				pc.count("client_echo_dropped")

				return true
			end

			prediction.held = {
				anim_id = anim_id,
				variable_id = variable_id,
				variable_value = variable_value,
			}

			pc.count("client_held_back")

			return true
		end

		local expected = prediction.echo[prediction.echo_index]

		if expected and anim == expected then
			prediction.echo_index = prediction.echo_index + 1

			return true
		end

		-- The event after a stagger is the host's own pick of idle, which for a shielded enemy depends on its shield.
		-- Play the host's, still as part of the echo.
		if expected and prediction.kind == "stagger" and prediction.echo_index == 2 and (anim == "idle" or anim == prediction.opening_event) then
			prediction.echo_index = 3

			animation_system():anim_event(unit, anim, true)

			return true
		end

		-- Something new from the host after the echo: it has moved the enemy on.
		finish_prediction(prediction, "the host moved on (" .. tostring(anim) .. ")")
	end

	measure_host_animation(unit, anim, variable_id, variable_value)
	track_host_animation(unit, anim)

	return false
end

-- The host switches an enemy's movement mode at the start and end of a stagger or recoil, and at the start it also
-- moves this screen's copy to where the host has it. While this screen is showing its own reaction for that enemy,
-- the mode switches but the copy stays where the reaction has taken it. Returns true if handled here.
function reactions.movement_message(unit_storage, game_object_id, animation_driven, script_driven_rotation, is_affected_by_gravity, is_on_transport)
	local unit = unit_storage:unit(game_object_id)

	if not unit then
		return false
	end

	if dead_here(unit) then
		return true
	end

	local prediction = predictions[unit]

	if not prediction then
		return false
	end

	-- The host's stagger or recoil is over (BTStaggerAction.leave and BTBlockedAction.leave), so the host has the
	-- enemy again. Before the echo this is the end of something older, and the reaction here goes on.
	if not animation_driven then
		if prediction.echo_seen then
			finish_prediction(prediction, "the host's reaction is over")
		end

		return false
	end

	if not prediction.moves then
		return false
	end

	local locomotion = ScriptUnit.has_extension(unit, "locomotion_system")

	if locomotion then
		locomotion:set_animation_driven(animation_driven, is_affected_by_gravity, script_driven_rotation, is_on_transport)
	end

	pc.count("client_teleport_skipped")

	return true
end

-- Returns true to drop a host message that would move an enemy this screen is moving itself, or one it has killed.
function reactions.keeps_position(unit_storage, game_object_id)
	local unit = unit_storage:unit(game_object_id)

	if not unit then
		return false
	end

	if dead_here(unit) then
		return true
	end

	local prediction = predictions[unit]

	return prediction ~= nil and prediction.moves
end

-- Returns true to drop the host's damage message for an enemy that is already dead on this screen.
function reactions.damage_message(victim_go_id)
	local unit = Managers.state.unit_storage:unit(victim_go_id)

	if unit and dead_here(unit) then
		pc.count("client_damage_after_kill")

		return true
	end

	return false
end

mod:network_register("pc_reaction_ack", function (sender, version, kind, id, result)
	if pc.is_server() or sender ~= pc.host_peer() or version ~= pc.VERSION then
		return
	end

	local prediction = by_key[tostring(kind) .. ":" .. tostring(id)]

	if not prediction then
		return
	end

	if result == "applied" then
		prediction.acked = true

		pc.count("client_ack_applied")
	else
		pc.count("client_ack_rejected")
		finish_prediction(prediction, "the host refused it", true)
	end
end)

function reactions.update(dt)
	sweep_timer = sweep_timer - dt

	if sweep_timer > 0 then
		return
	end

	sweep_timer = SWEEP_INTERVAL

	local t = pc.now()

	for unit, record in pairs(dead) do
		if t - record.t > DEAD_MEMORY or not Unit.alive(unit) then
			dead[unit] = nil
		end
	end

	for unit in pairs(fakes) do
		if not Unit.alive(unit) or not HEALTH_ALIVE[unit] then
			fakes[unit] = nil
		end
	end

	for unit, measure in pairs(measuring) do
		if t - measure.t > MEASURE_LIMIT or not Unit.alive(unit) then
			measuring[unit] = nil
		end
	end
end

function reactions.clear()
	measuring = {}
	fakes = {}
	predictions = {}
	by_key = {}
	dead = {}
	sweep_timer = 0
end

-- The host's animation messages for enemies. Echoes and held-back changes are dropped; everything else goes on to the
-- swing bookkeeping in Client.lua and to the game. These are mod:hooks, so everything except the original call runs
-- through pc.guard.
mod:hook("AnimationSystem", "rpc_anim_event", function (func, self, channel_id, anim_id, go_id)
	if self.is_server or pc.broken then
		return func(self, channel_id, anim_id, go_id)
	end

	local ok, drop = pc.guard("client animation message", reactions.host_animation, go_id, anim_id)

	if ok and drop then
		return
	end

	if pc.client.has_open_swings() then
		pc.guard("client swing animation", pc.client.animation_changed, go_id, anim_id)
	end

	return func(self, channel_id, anim_id, go_id)
end)

mod:hook("AnimationSystem", "rpc_anim_event_variable_float", function (func, self, channel_id, anim_id, go_id, variable_id, variable_value)
	if self.is_server or pc.broken then
		return func(self, channel_id, anim_id, go_id, variable_id, variable_value)
	end

	local ok, drop = pc.guard("client animation message", reactions.host_animation, go_id, anim_id, variable_id, variable_value)

	if ok and drop then
		return
	end

	if pc.client.has_open_swings() then
		pc.guard("client swing animation", pc.client.animation_changed, go_id, anim_id)
	end

	return func(self, channel_id, anim_id, go_id, variable_id, variable_value)
end)

mod:hook("LocomotionSystem", "rpc_set_animation_driven_movement", function (func, self, channel_id, game_object_id, animation_driven, script_driven_rotation, is_affected_by_gravity, is_on_transport, position, rotation)
	if not self.is_server and not pc.broken and (next(predictions) ~= nil or next(dead) ~= nil) then
		local ok, handled = pc.guard("client movement message", reactions.movement_message, self.unit_storage, game_object_id, animation_driven, script_driven_rotation, is_affected_by_gravity, is_on_transport)

		if ok and handled then
			return
		end
	end

	return func(self, channel_id, game_object_id, animation_driven, script_driven_rotation, is_affected_by_gravity, is_on_transport, position, rotation)
end)

local function leave_projectile(...)
	inside_projectile = false

	return ...
end

-- The game's projectile code records the expected damage of a hit on this client before it sends the hit, so while it
-- runs, damage() must not record it again.
mod:hook("PlayerProjectileUnitExtension", "hit_enemy_damage", function (func, self, ...)
	inside_projectile = not self._is_server

	return leave_projectile(func(self, ...))
end)

mod:hook_safe("AIInventorySystem", "rpc_ai_drop_single_item", function (self, channel_id, unit_id, item_inventory_index, item_drop_reason_id)
	if not self.is_server and not pc.broken then
		pc.guard("client shield drop", reactions.item_dropped, unit_id, item_drop_reason_id)
	end
end)

mod:hook("LocomotionSystem", "rpc_teleport_unit_with_yaw_rotation", function (func, self, channel_id, game_object_id, position, yaw)
	if not self.is_server and not pc.broken and (next(predictions) ~= nil or next(dead) ~= nil) then
		local ok, keep = pc.guard("client teleport message", reactions.keeps_position, self.unit_storage, game_object_id)

		if ok and keep then
			pc.count("client_teleport_skipped")

			return
		end
	end

	return func(self, channel_id, game_object_id, position, yaw)
end)
