local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Client side. For every swing the host announces at this player, the client:
--   1. turns its copy of the enemy itself, by the game's own rules, from the player's live position and dodge,
--   2. judges the swing on the frame its copy of the enemy fires the damage animation event,
--   3. plays its own block at once if it blocked, and sends the result to the host.
-- A swing the host never announced is none of this file's business, so vanilla handles it.

local client = {}

pc.client = client

local DODGE_DISTANCE = 4 -- DEFAULT_DODGE_DISTANCE_THRESHOLD in bt_attack_action.lua
local DEFAULT_DODGE_ROTATION_TIME = 1.5 -- also from bt_attack_action.lua
local ROTATION_SPEED = 10 -- DEFAULT_ROTATION_SPEED in ai_locomotion_extension.lua
local FACING_HOLD = 1 -- seconds the facing stays ours after the damage frame, unless the enemy moves on first
local INTERRUPTED_GRACE = 2 -- seconds an interrupted swing may still fire its damage event before it counts as cut short
local MAX_FRAMES = 8

local swings = {} -- swing id -> record, kept for the stats and the debug log
local by_unit = {} -- enemy unit -> its newest record
local by_go_id = {} -- enemy network id -> the same record
local hello_timer = 0

local function local_player_unit()
	local player = Managers.player:local_player()
	local unit = player and player.player_unit

	return unit and Unit.alive(unit) and unit or nil
end

local function position(unit)
	return POSITION_LOOKUP[unit] or Unit.world_position(unit, 0)
end

local function flat_rotation(from, to)
	local direction = Vector3.flat(to - from)

	if Vector3.length_squared(direction) < 0.0001 then
		return nil
	end

	return Quaternion.look(Vector3.normalize(direction), Vector3.up())
end

local function send_answer(swing, frame, result, multiplier, improved, direction, through_block, distance, angle)
	local host_peer = pc.host_peer()

	if host_peer then
		mod:network_send("pc_swing_answer", host_peer, pc.VERSION, swing.id, frame, result, pc.finite(multiplier, 3), improved and true or false, direction or "", through_block and true or false, pc.finite(distance), pc.finite(angle, 1))
	end
end

local function forget(swing)
	swings[swing.id] = nil

	if by_unit[swing.unit] == swing then
		by_unit[swing.unit] = nil
	end

	if by_go_id[swing.go_id] == swing then
		by_go_id[swing.go_id] = nil
	end
end

-- The swing is over on this screen. If it never reached its damage frame, say so, so the host's stats can tell a
-- swing that was cut short from a client that stayed silent.
local function finish(swing, reason)
	if swing.frames == 0 then
		pc.count("client_cut")
		pc.log("client swing=%d enemy=%s attack=%s cut short (%s)", swing.id, swing.breed.name, swing.action_name, tostring(swing.interrupted_by or reason))
		send_answer(swing, 1, "cut")
	end

	forget(swing)
end

-- Copy of BTAttackAction._handle_movement (bt_attack_action.lua:390), fed from this player's live state.
-- The enemy faces where the player stood when the swing began, starts tracking after the dodge-window delay, and an
-- effective dodge within DODGE_DISTANCE freezes its facing for the window's duration.
local function update_facing(swing, unit, target, t, dt)
	local attacker_position = Unit.local_position(unit, 0)
	local target_position = Unit.local_position(target, 0)
	local distance = Vector3.distance(attacker_position, target_position)
	local status = ScriptUnit.has_extension(target, "status_system")

	if status and not swing.past_damage and t > swing.window_start then
		local dodging = status:get_is_dodging() or status:is_invisible()

		if not dodging and t > swing.lock_timer then
			local rotation = flat_rotation(attacker_position, target_position)

			if rotation then
				swing.wanted:store(rotation)
			end

			swing.frozen = false
		elseif dodging and not swing.frozen and distance < DODGE_DISTANCE then
			swing.lock_timer = t + swing.window_duration
			swing.frozen = true
		end
	end

	if swing.frozen and t > swing.lock_timer or distance > DODGE_DISTANCE then
		swing.frozen = false
	end

	-- The host eases an enemy towards its wanted rotation at ROTATION_SPEED. Do the same, so it turns no faster here.
	local rotation = Quaternion.lerp(swing.current:unbox(), swing.wanted:unbox(), math.min(ROTATION_SPEED * dt, 1))

	swing.current:store(rotation)

	if pc.facing and not swing.interrupted_by then
		Unit.set_local_rotation(unit, 0, rotation)
	end
end

-- Runs after LocomotionSystem.update, which is where the engine has just eased every enemy copy towards the facing
-- the host sent. Setting the rotation here, every frame, is what makes the facing ours.
function client.after_locomotion(t, dt)
	local target = local_player_unit()

	for unit, swing in pairs(by_unit) do
		if t > swing.expires then
			finish(swing, "expired")
		elseif not Unit.alive(unit) or not HEALTH_ALIVE[unit] then
			finish(swing, "enemy died")
		elseif target ~= swing.target then
			finish(swing, "player unit changed")
		elseif swing.past_damage and t > swing.release_t then
			forget(swing)
		else
			update_facing(swing, unit, target, t, dt)
		end
	end
end

-- The decision half of DamageUtils.check_block (damage_utils.lua:2697), without its host-only parts and without
-- side effects. It returns whether this player blocks the swing, the numbers the host needs to show the block to the
-- other players, and whether the swing went through a block.
local function would_block(swing, unit, target, status)
	local action = swing.action

	if action.unblockable or not status then
		return false
	end

	local attack_direction = action.attack_directions and action.attack_directions[swing.attack_anim]
	local is_blocking = status:is_blocking()
	local can_block, multiplier, improved, direction = status:can_block(unit, attack_direction)
	local buff_extension = ScriptUnit.has_extension(target, "buff_system")
	local invulnerable = buff_extension and buff_extension:has_buff_perk("invulnerable")

	if not is_blocking or not can_block or invulnerable then
		return false
	end

	-- Grudge-marked enemies with "crushing blow" hit through a block.
	local attacker_buffs = ScriptUnit.has_extension(unit, "buff_system")

	if attacker_buffs and attacker_buffs:has_buff_perk("ai_unblockable") then
		return false, nil, nil, nil, true
	end

	return true, multiplier, improved, direction, false
end

-- Spark, sound, stamina and parry, on this machine, now. This is what the host's message would have triggered.
local function play_block(swing, unit, status, multiplier, improved, direction)
	local fatigue_type = swing.action.fatigue_type

	if type(fatigue_type) == "table" then
		fatigue_type = Managers.state.difficulty:get_difficulty_value_from_table(fatigue_type)
	end

	if not fatigue_type or not PlayerUnitStatusSettings.fatigue_point_costs[fatigue_type] then
		fatigue_type = "blocked_attack"
	end

	status:blocked_attack(fatigue_type, unit, multiplier, improved, direction)
end

-- Called from the AnimationSystem.animation_callback hook when an enemy copy fires anim_cb_damage on this client.
function client.damage_frame(unit)
	local swing = by_unit[unit]

	if not swing or swing.frames >= MAX_FRAMES then
		return
	end

	local target = local_player_unit()

	if target ~= swing.target then
		return
	end

	local t = pc.now()
	local frame = swing.frames + 1

	swing.frames = frame
	swing.past_damage = true
	swing.release_t = t + FACING_HOLD

	local action = swing.action
	local breed = swing.breed
	local use_our_facing = pc.facing and not swing.interrupted_by
	local rotation = use_our_facing and swing.current:unbox() or Unit.local_rotation(unit, 0)
	local forward = Quaternion.forward(rotation)
	local offset = position(target) - position(unit)
	local in_reach, in_front, distance, reach, angle, cone = pc.geometry.single_target(offset.x, offset.y, offset.z, forward.x, forward.y, swing.frozen, action, breed, swing.box_up, swing.box_down, swing.box_flat)
	local status = ScriptUnit.has_extension(target, "status_system")
	local result, reason = "hit", "landed"
	local multiplier, improved, direction, through_block

	if not in_reach then
		result, reason = "miss", "reach"
	elseif not in_front then
		result, reason = "miss", "cone"
	else
		local blocked

		blocked, multiplier, improved, direction, through_block = would_block(swing, unit, target, status)

		if blocked then
			result, reason = "blocked", improved and "in arc" or "outer arc"
		elseif through_block then
			reason = "through block"
		end
	end

	pc.count("client_judged")
	pc.count(result == "miss" and "client_miss_" .. reason or "client_" .. result)

	-- The answer goes out before the local effects, so a problem in those can't leave the host without one.
	send_answer(swing, frame, result, multiplier, improved, direction, through_block, distance, angle)

	if result == "blocked" then
		play_block(swing, unit, status, multiplier, improved, direction)
	end

	pc.log("client swing=%d enemy=%s attack=%s frame=%d verdict=%s reason=%s distance=%.2f reach=%.2f angle=%.1f cone=%.1f frozen=%s facing=%s since_begin=%.3fs", swing.id, breed.name, swing.action_name, frame, result, reason, distance, reach, angle, cone,
		tostring(swing.frozen), use_our_facing and "client" or "host", t - swing.begin_t)
end

-- The host changed this enemy's animation. Before the damage frame that most likely means the swing was
-- interrupted, so the facing goes back to the host. The swing itself stays judgeable: if its damage event still
-- fires, it landed on this screen after all.
function client.animation_changed(go_id, anim_id)
	local swing = by_go_id[go_id]

	if not swing then
		return
	end

	local event = NetworkLookup.anims[anim_id]

	if event == swing.attack_anim then
		return
	end

	if swing.past_damage then
		forget(swing)
	elseif not swing.interrupted_by then
		swing.interrupted_by = tostring(event)

		-- Don't wait out the full lifetime: the host should hear "cut short" while it still remembers the swing.
		swing.expires = math.min(swing.expires, pc.now() + INTERRUPTED_GRACE)
	end
end

mod:network_register("pc_swing_begin", function (sender, version, id, attacker_go_id, family, set_name, action_name, attack_anim, box_up, box_down, box_flat)
	if pc.broken or pc.is_server() or not pc.in_game() or sender ~= pc.host_peer() or version ~= pc.VERSION then
		return
	end

	if type(id) ~= "number" or type(attacker_go_id) ~= "number" or family ~= "A" or type(set_name) ~= "string" or type(action_name) ~= "string" or type(attack_anim) ~= "string" then
		return
	end

	local t = pc.now()
	local unit = Managers.state.unit_storage:unit(attacker_go_id)
	local target = local_player_unit()
	local breed = unit and Unit.alive(unit) and Unit.get_data(unit, "breed")
	local set = BreedActions[set_name]
	local action = set and set[action_name]

	pc.count("client_announced")

	if not breed or not target or not action then
		-- This client can't judge the swing, so it says so. The host books nothing for it.
		pc.count("client_unjudged")
		pc.print("client swing=%d can't be judged: enemy=%s target=%s action=%s/%s", id, tostring(breed and breed.name), tostring(target ~= nil), set_name, action_name)
		send_answer({ id = id }, 1, "unjudged")

		return
	end

	-- The enemy started a new swing while an older one was still open, so the older one is over.
	local previous = by_unit[unit]

	if previous then
		finish(previous, "new swing")
	end

	-- Same lookups as BTAttackAction.enter (bt_attack_action.lua:102).
	local difficulty = Managers.state.difficulty:get_difficulty()
	local window_start = action.dodge_window_start

	if type(window_start) == "table" then
		window_start = window_start[difficulty]
	end

	local durations = action.dodge_window_duration
	local window_duration = type(durations) == "table" and durations[difficulty] or DEFAULT_DODGE_ROTATION_TIME
	local current_rotation = Unit.local_rotation(unit, 0)
	local wanted_rotation = flat_rotation(Unit.local_position(unit, 0), Unit.local_position(target, 0)) or current_rotation

	local swing = {
		id = id,
		unit = unit,
		go_id = attacker_go_id,
		target = target,
		action = action,
		action_name = action_name,
		breed = breed,
		attack_anim = attack_anim,
		begin_t = t,
		expires = t + pc.SWING_LIFETIME,
		window_start = type(window_start) == "number" and t + window_start or t,
		window_duration = window_duration,
		lock_timer = t,
		frozen = false,
		past_damage = false,
		release_t = 0,
		frames = 0,
		box_up = type(box_up) == "number" and box_up or 0,
		box_down = type(box_down) == "number" and box_down or 0,
		box_flat = type(box_flat) == "number" and box_flat or 0,
		wanted = QuaternionBox(wanted_rotation),
		current = QuaternionBox(current_rotation),
	}

	swings[id] = swing
	by_unit[unit] = swing
	by_go_id[attacker_go_id] = swing
end)

mod:hook_safe("LocomotionSystem", "update", function (self, context, t)
	if self.is_server or pc.broken or next(by_unit) == nil then
		return
	end

	client.after_locomotion(t, context.dt)
end)

mod:hook_safe("AnimationSystem", "rpc_anim_event", function (self, channel_id, anim_id, go_id)
	if not self.is_server and next(by_go_id) ~= nil then
		client.animation_changed(go_id, anim_id)
	end
end)

mod:hook_safe("AnimationSystem", "rpc_anim_event_variable_float", function (self, channel_id, anim_id, go_id)
	if not self.is_server and next(by_go_id) ~= nil then
		client.animation_changed(go_id, anim_id)
	end
end)

-- Tells the host this client runs the mod and which version. Without a recent hello the host judges this player as
-- vanilla.
function client.update(dt)
	if pc.broken or pc.is_server() or not pc.in_game() then
		return
	end

	hello_timer = hello_timer - dt

	if hello_timer <= 0 then
		hello_timer = pc.HELLO_INTERVAL

		local host_peer = pc.host_peer()

		if host_peer then
			mod:network_send("pc_hello", host_peer, pc.VERSION)
		end
	end
end

function client.clear()
	swings = {}
	by_unit = {}
	by_go_id = {}
	hello_timer = 0
end

function client.open_swing_count()
	local count = 0

	for _ in pairs(by_unit) do
		count = count + 1
	end

	return count
end
