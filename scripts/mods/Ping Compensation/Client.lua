local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Client side. For every swing the host announces at this player, the client:
--   1. turns its copy of the enemy itself, by the game's own rules, from the player's live position and dodge,
--   2. judges the swing on the frame its copy of the enemy fires the damage animation event,
--   3. plays its own block at once if it blocked, and sends the result to the host,
--   4. shows the result at once: the enemy's recoil after a block (Reactions.lua) and, for a hit, the feedback,
--      knockback and HP estimate (HitResults.lua).
-- A swing the host never announced is none of this file's business, so vanilla handles it.

local client = {}

pc.client = client

local DODGE_DISTANCE = 4 -- DEFAULT_DODGE_DISTANCE_THRESHOLD in bt_attack_action.lua
local DEFAULT_DODGE_ROTATION_TIME = 1.5 -- also from bt_attack_action.lua
local ROTATION_SPEED = 10 -- DEFAULT_ROTATION_SPEED in ai_locomotion_extension.lua
local COMBO_ROTATION_SPEED = 20 -- DEFAULT_ROTATION_SPEED in bt_combo_attack_action.lua, set at every combo step
local COMBO_DODGED_ROTATION_SPEED = 2 -- what a dodge drops it to for the rest of the step (bt_combo_attack_action.lua:417)
local COMBO_DODGE_TIMER = 0.3 -- seconds the enemy aims where the player was when they dodged, unless the breed says (:421)
local FACING_HOLD = 1 -- seconds the facing stays ours after the damage frame, unless the enemy moves on first
local CUT_MEMORY = 2 -- seconds a cut swing is remembered, only so that a damage event that still fires gets logged
local MAX_FRAMES = 8

local swings = {} -- swing id -> record, kept for the stats and the debug log
local by_unit = {} -- enemy unit -> its newest record
local by_go_id = {} -- enemy network id -> the same record
local recently_cut = {} -- enemy unit -> { id, by, t } for swings cut in the last CUT_MEMORY seconds
local hello_timer = 0

local local_player_unit = pc.local_player_unit

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

-- recoil_anim, recoil_position and recoil_yaw: the enemy's recoil this client is about to play after a block, and
-- where its screen shows the enemy (only sent with /pingcomp recoil full).
local function send_answer(swing, frame, result, multiplier, improved, direction, through_block, distance, angle, recoil_anim, recoil_position, recoil_yaw)
	local host_peer = pc.host_peer()

	if host_peer then
		local x, y, z = 0, 0, 0

		if recoil_position then
			x, y, z = pc.finite(recoil_position.x, 3), pc.finite(recoil_position.y, 3), pc.finite(recoil_position.z, 3)
		end

		mod:network_send("pc_swing_answer", host_peer, pc.VERSION, swing.id, frame, result, pc.finite(multiplier, 3), improved and true or false, direction or "", through_block and true or false, pc.finite(distance), pc.finite(angle, 1),
			recoil_anim or "", recoil_position ~= nil, x, y, z, pc.finite(recoil_yaw or 0, 4))
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

-- The swing ended on this screen before its damage frame: the enemy died, was staggered, was pushed by this player or
-- started another swing. It did not land here, so it never counts (decision D5). The host hears "cut" and books
-- nothing, and the facing goes back to the host. The swing is remembered for a moment so that a damage event that
-- still fires during the blend into the stagger is logged instead of judged.
local function cut(swing, by)
	local t = pc.now()

	pc.count("client_cut")

	if by == "pushed" then
		pc.count("client_cut_pushed")
	end

	pc.log("client swing=%d enemy=%s attack=%s cut short (%s) %.3fs after it began", swing.id, swing.breed.name, swing.action_name, tostring(by), t - swing.begin_t)
	send_answer(swing, 1, "cut")

	recently_cut[swing.unit] = { id = swing.id, by = tostring(by), t = t }

	forget(swing)
end

-- The swing is over on this screen. One that never reached its damage frame was cut short.
local function finish(swing, reason)
	if swing.frames == 0 then
		cut(swing, reason)
	else
		forget(swing)
	end
end

-- Whether the enemy should lose track of this player, which is what BTAttackAction asks the host's copy of them.
-- The weapon's dodge count only exists on the dodging player's own machine (player_character_state_helper.lua:188),
-- so in vanilla the host treats every dodge a client makes as effective. /pingcomp dodgecount on, the default, applies
-- the count as the game always has for the host's own hero (decision D25). Off gives clients the vanilla behaviour.
local function is_dodging(status)
	if status:is_invisible() then
		return true
	end

	if pc.dodgecount then
		return status:get_is_dodging() and true or false
	end

	return status.is_dodging == true
end

-- Copy of BTAttackAction._handle_movement (bt_attack_action.lua:390), fed from this player's live state.
-- The enemy faces where the player stood when the swing began, starts tracking after the dodge-window delay, and an
-- effective dodge within DODGE_DISTANCE freezes its facing for the window's duration.
local function update_facing(swing, unit, target, t, dt)
	local attacker_position = Unit.local_position(unit, 0)
	local target_position = Unit.local_position(target, 0)
	local distance = Vector3.distance(attacker_position, target_position)
	local status = ScriptUnit.has_extension(target, "status_system")

	-- For the debug log: did the player dodge during this swing, and was any of those dodges over the dodge count?
	if status and not swing.past_damage and status.is_dodging then
		swing.dodged = true

		if not status:get_is_dodging() then
			swing.dodge_over_count = true
		end
	end

	if status and not swing.past_damage and t > swing.window_start then
		local dodging = is_dodging(status)

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

	if pc.facing then
		Unit.set_local_rotation(unit, 0, rotation)
	end
end

-- The turning speed a combo step with a lerped rotation scheme sets, by how far into the step it is
-- (BTComboAttackAction._update_rotation_target_lerped, bt_combo_attack_action.lua:446).
local function lerped_rotation_speed(scheme, attack_t)
	local start_in, end_in, start_out, end_out = scheme.start_lerp_in or 0, scheme.end_lerp_in or 0, scheme.start_lerp_out or 0, scheme.end_lerp_out or 0
	local target_speed = scheme.target_speed or COMBO_ROTATION_SPEED

	if attack_t < start_in then
		return COMBO_ROTATION_SPEED
	elseif attack_t < end_in then
		return math.lerp(COMBO_ROTATION_SPEED, target_speed, (attack_t - start_in) / math.max(end_in - start_in, 0.001))
	elseif attack_t < start_out then
		return target_speed
	elseif attack_t < end_out then
		return math.lerp(target_speed, COMBO_ROTATION_SPEED, (attack_t - start_out) / math.max(end_out - start_out, 0.001))
	end

	return COMBO_ROTATION_SPEED
end

-- Family B: copy of BTComboAttackAction._update_rotation_target (bt_combo_attack_action.lua:411), fed from this
-- player's live state. The enemy tracks the player the whole step. When the player first dodges during the step, it
-- aims where they were for the breed's dodge_timer and turns at 2 instead of 20 for the rest of the step. After the
-- damage frame it stops tracking ("no_rotation"), still easing towards where it last aimed.
local function update_combo_facing(swing, unit, target, t, dt)
	local status = ScriptUnit.has_extension(target, "status_system")
	local scheme = swing.step.rotation_scheme

	-- For the debug log, as for family A.
	if status and not swing.past_damage and status.is_dodging then
		swing.dodged = true

		if not status:get_is_dodging() then
			swing.dodge_over_count = true
		end
	end

	local speed = swing.rotation_speed

	if not swing.past_damage and (scheme == "continuous" or type(scheme) == "table") then
		if status and is_dodging(status) and not swing.dodged_during_attack then
			swing.rotation_speed = COMBO_DODGED_ROTATION_SPEED
			swing.dodged_during_attack = true
			swing.dodge_timer = t + (swing.breed.dodge_timer or COMBO_DODGE_TIMER)
		end

		local aim

		if swing.dodged_during_attack and t < swing.dodge_timer then
			aim = swing.last_target_position:unbox()
		else
			aim = Unit.local_position(target, 0)
		end

		swing.last_target_position:store(aim)

		local rotation = flat_rotation(Unit.local_position(unit, 0), aim)

		if rotation then
			swing.wanted:store(rotation)
		end

		speed = type(scheme) == "table" and lerped_rotation_speed(scheme, t - swing.begin_t) or swing.rotation_speed
	end

	-- The host's AI locomotion snaps once a frame's step reaches 1 (locomotion_templates_ai.lua:156).
	local step = speed * dt
	local rotation = step >= 1 and swing.wanted:unbox() or Quaternion.lerp(swing.current:unbox(), swing.wanted:unbox(), step)

	swing.current:store(rotation)

	if pc.facing then
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
		elseif swing.family == "B" then
			update_combo_facing(swing, unit, target, t, dt)
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
	status:blocked_attack(pc.fatigue_type(swing.action, swing.step), unit, multiplier, improved, direction)
end

-- Called from the AnimationSystem.animation_callback hook when an enemy copy fires anim_cb_damage (family A) or
-- anim_cb_frenzy_damage (family B) on this client.
function client.damage_frame(unit, callback_name)
	local swing = by_unit[unit]

	-- A frenzy step's damage frame is anim_cb_frenzy_damage, a single swing's anim_cb_damage.
	if swing and (callback_name == "anim_cb_frenzy_damage") ~= (swing.family == "B") then
		return
	end

	if not swing then
		local cut_record = recently_cut[unit]

		if cut_record then
			recently_cut[unit] = nil

			local since = pc.now() - cut_record.t

			if since <= CUT_MEMORY then
				pc.count("client_damage_after_cut")
				pc.log("client swing=%d fired its damage event %.3fs after it was cut short (%s); not judged", cut_record.id, since, cut_record.by)
			end
		end

		return
	end

	if swing.frames >= MAX_FRAMES then
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
	local combo = swing.family == "B"
	local use_our_facing = pc.facing
	local rotation = use_our_facing and swing.current:unbox() or Unit.local_rotation(unit, 0)
	local forward = Quaternion.forward(rotation)
	local offset = position(target) - position(unit)
	-- The game tightens the reach and cone after a dodge: family A while its facing is frozen, family B once the player
	-- has dodged during the step (target_dodged_during_attack, damage_utils.lua:2642).
	local tightened = combo and swing.dodged_during_attack or not combo and swing.frozen
	local in_reach, in_front, distance, reach, angle, cone = pc.geometry.single_target(offset.x, offset.y, offset.z, forward.x, forward.y, tightened, action, breed, swing.box_up, swing.box_down, swing.box_flat)
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

	local reactions = pc.reactions
	local recoil_anim, recoil_position, recoil_yaw

	-- A blocked frenzy step has no recoil and no push (bt_combo_attack_action.lua:544).
	if result == "blocked" and not combo then
		local ok

		ok, recoil_anim, recoil_position, recoil_yaw = pc.guard("client recoil choice", reactions.choose_recoil, swing, unit)

		if not ok then
			recoil_anim, recoil_position, recoil_yaw = nil, nil, nil
		end
	end

	-- The answer goes out before the local effects, so a problem in those can't leave the host without one.
	send_answer(swing, frame, result, multiplier, improved, direction, through_block, distance, angle, recoil_anim, recoil_position, recoil_yaw)

	if result == "blocked" then
		play_block(swing, unit, status, multiplier, improved, direction)

		if recoil_anim then
			pc.guard("client recoil", reactions.play_recoil, swing, unit, recoil_anim)
		end

		if not combo then
			pc.guard("client blocked push", pc.hit_results.blocked, swing, unit, target)
		end
	elseif result == "hit" then
		pc.guard("client hit results", pc.hit_results.hit, swing, unit, target)
	end

	if result == "hit" and swing.dodge_over_count then
		pc.count("client_hit_over_dodge_count")
	end

	if pc.debug then
		local dodging_now = status ~= nil and status.is_dodging == true
		local effective_now = status ~= nil and status:get_is_dodging() and true or false

		pc.log("client swing=%d enemy=%s attack=%s%s frame=%d verdict=%s reason=%s distance=%.2f reach=%.2f angle=%.1f cone=%.1f frozen=%s facing=%s since_begin=%.3fs dodging=%s effective=%s dodges=%s/%s dodged_in_swing=%s over_count_in_swing=%s dodgecount=%s recoil=%s",
			swing.id, breed.name, swing.action_name, combo and "/" .. tostring(swing.step_name) or "", frame, result, reason, distance, reach, angle, cone, tostring(tightened), use_our_facing and "client" or "host", t - swing.begin_t,
			tostring(dodging_now), tostring(effective_now), tostring(status and status.dodge_cooldown), tostring(status and status.dodge_count), tostring(swing.dodged == true), tostring(swing.dodge_over_count == true), pc.dodgecount and "on" or "off",
			tostring(recoil_anim or "host"))
	end
end

-- The host changed this enemy's animation. Before the damage frame that means the swing was interrupted, almost
-- always by a stagger, and the player now sees the enemy stop swinging. On the host a staggered enemy's damage event
-- does nothing, so here the swing is cut at once (decision D22). The first playtests showed the damage event can still
-- fire during the blend into the stagger; damage_frame logs that instead of judging it.
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
	else
		cut(swing, tostring(event))
	end
end

-- This player's own push landed on an enemy that is swinging at them. On their screen the swing is over, as it will
-- be on the host once the push arrives and staggers the enemy, so it is cut now instead of a ping later (decision
-- D23). A push taken on the enemy's shield may not stagger it, so that swing goes on. Not called for a push whose
-- result this client decided itself (Reactions.lua): that one cuts the swing only if it staggered the enemy.
function client.pushed(attacker_go_id, hit_go_id, shield_blocked)
	local swing = by_go_id[hit_go_id]

	if not swing or swing.past_damage then
		return
	end

	local target = local_player_unit()

	if not target or target ~= swing.target or pc.network():unit_game_object_id(target) ~= attacker_go_id then
		return
	end

	if shield_blocked then
		pc.count("client_push_on_shield")
		pc.log("client swing=%d enemy=%s took the push on its shield; the swing goes on", swing.id, swing.breed.name)

		return
	end

	cut(swing, "pushed")
end

-- This player's hit staggered or killed the enemy on their screen (Reactions.lua), so a swing it had started is over.
function client.reaction_started(unit, reason)
	local swing = by_unit[unit]

	if swing and not swing.past_damage then
		cut(swing, reason)
	end
end

-- family: "A" for a single swing (BTAttackAction), "B" for one step of a frenzy combo (BTComboAttackAction), whose
-- step_name finds the step in action.combo_attacks. Each step of a combo is announced as its own swing.
mod:network_register("pc_swing_begin", function (sender, version, id, attacker_go_id, family, set_name, action_name, attack_anim, box_up, box_down, box_flat, damage_scale, step_name)
	if pc.broken or pc.is_server() or not pc.in_game() or sender ~= pc.host_peer() or version ~= pc.VERSION then
		return
	end

	if type(id) ~= "number" or type(attacker_go_id) ~= "number" or family ~= "A" and family ~= "B" or type(set_name) ~= "string" or type(action_name) ~= "string" or type(attack_anim) ~= "string" then
		return
	end

	local t = pc.now()
	local unit = Managers.state.unit_storage:unit(attacker_go_id)
	local target = local_player_unit()
	local breed = unit and Unit.alive(unit) and Unit.get_data(unit, "breed")
	local set = BreedActions[set_name]
	local action = set and set[action_name]
	local step = family == "B" and action and type(action.combo_attacks) == "table" and type(step_name) == "string" and action.combo_attacks[step_name] or nil

	pc.count("client_announced")

	if not breed or not target or not action or family == "B" and not step then
		-- This client can't judge the swing, so it says so. The host books nothing for it.
		pc.count("client_unjudged")
		pc.print("client swing=%d can't be judged: enemy=%s target=%s action=%s/%s%s", id, tostring(breed and breed.name), tostring(target ~= nil), set_name, action_name, family == "B" and "/" .. tostring(step_name) or "")
		send_answer({ id = id }, 1, "unjudged")

		return
	end

	-- This player's own hits on the enemy go by the attack it is in, which can ignore some staggers (Reactions.lua).
	pc.guard("client attack seen", pc.reactions.attack_started, unit, breed, action)

	-- The host started this swing before it heard of the stagger, kill or recoil this screen is already showing, and
	-- that reaction will cancel it there too.
	local busy = pc.reactions.busy(unit)

	if busy then
		pc.count("client_cut")
		pc.count("client_cut_by_reaction")
		pc.log("client swing=%d enemy=%s attack=%s cut at once: %s on this screen", id, breed.name, action_name, busy)
		send_answer({ id = id }, 1, "cut")

		return
	end

	-- The enemy started a new swing while an older one was still open, so the older one is over. A combo's next step
	-- turns on from where the last one left the enemy facing on this screen.
	local previous = by_unit[unit]
	local current_rotation = previous and previous.family == "B" and family == "B" and previous.current:unbox() or Unit.local_rotation(unit, 0)

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
	local wanted_rotation = flat_rotation(Unit.local_position(unit, 0), Unit.local_position(target, 0)) or current_rotation

	local swing = {
		id = id,
		family = family,
		unit = unit,
		go_id = attacker_go_id,
		target = target,
		action = action,
		action_name = action_name,
		set_name = set_name,
		step = step,
		step_name = step and step_name or nil,
		damage = pc.attack_damage(action, step),
		rotation_speed = COMBO_ROTATION_SPEED, -- family B: the step's turning speed, until a dodge drops it
		dodged_during_attack = false, -- family B: the player dodged during this step
		dodge_timer = 0,
		last_target_position = Vector3Box(Unit.local_position(target, 0)),
		breed = breed,
		damage_scale = type(damage_scale) == "number" and damage_scale == damage_scale and damage_scale or 1,
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
	if self.is_server or pc.broken then
		return
	end

	if next(by_unit) ~= nil then
		client.after_locomotion(t, context.dt)
	end

	if pc.reactions.active() then
		pc.guard("client reactions", pc.reactions.after_locomotion, t, context.dt)
	end
end)

-- The host's animation messages are hooked in Reactions.lua, which passes the ones it doesn't hold back to here.
function client.has_open_swings()
	return next(by_go_id) ~= nil
end

-- Whether this enemy is in the middle of a swing at this player, which is the nearest this client gets to the host's
-- "this enemy holds an attack token" (Reactions.lua).
function client.swinging(unit)
	local swing = by_unit[unit]

	return swing ~= nil and not swing.past_damage
end

-- Runs on this player's machine for every hit they land, as the game sends it to the host. Reactions.lua works out
-- what it does to the enemy. A push is the only hit sent with can_damage false and can_stagger true
-- (action_push_stagger.lua:288).
mod:hook_safe("WeaponSystem", "send_rpc_attack_hit", function (self, damage_source_id, attacker_unit_id, hit_unit_id, hit_zone_id, hit_position, attack_direction, damage_profile_id, ...)
	if self.is_server or pc.broken then
		return
	end

	local ok, decided = pc.guard("client attack hit", pc.reactions.attack_hit, damage_source_id, attacker_unit_id, hit_unit_id, hit_zone_id, hit_position, attack_direction, damage_profile_id, ...)

	-- A hit Reactions.lua decided has already cut the swing if it staggered or killed the enemy.
	if ok and decided or next(by_go_id) == nil then
		return
	end

	local can_damage, can_stagger, blocking = true, true, false

	for i = 1, select("#", ...) - 1, 2 do
		local name, value = select(i, ...)

		if name == "can_damage" then
			can_damage = value
		elseif name == "can_stagger" then
			can_stagger = value
		elseif name == "blocking" then
			blocking = value
		end
	end

	if can_damage == false and can_stagger == true then
		client.pushed(attacker_unit_id, hit_unit_id, blocking == true)
	end
end)

-- fingerprint and toggles: the host's enemy data fingerprint and difficulty mods; matched: whether the fingerprint this
-- client sent last was the host's (Compat.lua).
mod:network_register("pc_hello_reply", function (sender, version, fingerprint, toggles, matched)
	if not pc.is_server() and version == pc.VERSION and sender == pc.host_peer() then
		pc.heard_host()
		pc.guard("client difficulty mods", pc.compat.on_host_reply, fingerprint, toggles, matched)
	end
end)

-- The next update sends a hello at once, so the host hears about a changed /pingcomp attacks switch straight away.
function client.hello_now()
	hello_timer = 0
end

-- Tells the host this client runs the mod, which version, and whether its attacks switch is on. Without a recent
-- hello the host judges this player as vanilla.
function client.update(dt)
	if pc.broken or pc.is_server() or not pc.in_game() then
		return
	end

	pc.guard("client reactions upkeep", pc.reactions.update, dt)
	pc.guard("client hit results upkeep", pc.hit_results.update)

	if next(recently_cut) ~= nil then
		local t = pc.now()

		for unit, record in pairs(recently_cut) do
			if t - record.t > CUT_MEMORY then
				recently_cut[unit] = nil
			end
		end
	end

	hello_timer = hello_timer - dt

	if hello_timer <= 0 then
		hello_timer = pc.HELLO_INTERVAL

		local host_peer = pc.host_peer()

		if host_peer then
			mod:network_send("pc_hello", host_peer, pc.VERSION, pc.attacks and true or false, pc.compat.fingerprint())
		end
	end
end

function client.clear()
	swings = {}
	by_unit = {}
	by_go_id = {}
	recently_cut = {}
	hello_timer = 0

	pc.forget_host()
	pc.reactions.clear()
	pc.hit_results.clear()
end

function client.open_swing_count()
	local count = 0

	for _ in pairs(by_unit) do
		count = count + 1
	end

	return count
end
