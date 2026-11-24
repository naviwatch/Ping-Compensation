local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Client side. For every swing the host announces at this player, the client:
--   1. turns its copy of the enemy itself, by the game's own rules, from the player's live position and dodge (for an
--      elite's sweep, only if this player is the one it attacks),
--   2. judges the swing on the frame its copy of the enemy fires the damage animation event: reach and cone for single
--      swings, frenzy steps and shoves, the game's box for an elite's sweep or overhead, and for a monster's or lord's
--      attack (family E, build 6) the node's own box, arm sweep or slam capsule, on every modded player's screen; a
--      charge, a lord's lunge, spin or ground wave and a thrown axe on every frame of their window, and the jump slam
--      at its landing,
--   3. plays its own block at once if it blocked, and sends the result to the host,
--   4. shows the result at once: the enemy's recoil after a block (Reactions.lua) and, for a hit, the feedback,
--      knockback and HP estimate (HitResults.lua).
-- A swing the host never announced is none of this file's business, so vanilla handles it.

local client = {}

pc.client = client

local DODGE_DISTANCE = 4 -- DEFAULT_DODGE_DISTANCE_THRESHOLD in bt_attack_action.lua
local DEFAULT_DODGE_ROTATION_TIME = 1.5 -- also from bt_attack_action.lua
local ROTATION_SPEED = pc.DEFAULT_TURN_SPEED -- DEFAULT_ROTATION_SPEED in ai_locomotion_extension.lua; per attack, pc.turn_speed (T18)
local COMBO_ROTATION_SPEED = 20 -- DEFAULT_ROTATION_SPEED in bt_combo_attack_action.lua, set at every combo step
local COMBO_DODGED_ROTATION_SPEED = 2 -- what a dodge drops it to for the rest of the step (bt_combo_attack_action.lua:417)
local COMBO_DODGE_TIMER = 0.3 -- seconds the enemy aims where the player was when they dodged, unless the breed says (:421)
local FACING_HOLD = 1 -- seconds the facing stays ours after the damage frame, unless the enemy moves on first
local CUT_MEMORY = 2 -- seconds a cut swing is remembered, only so that a damage event that still fires gets logged
local MAX_FRAMES = 8

-- The damage frame of each family: A, single swings; B, frenzy combo steps; C, elites' sweeps and overheads; D,
-- elites' shoves; F, the packmaster's hook. A leech's grab and a gutter runner's pounce, the other disablers of
-- family F, are judged on the frame their projectile or leap reaches the player (judge_grab, judge_leap). E, monsters'
-- and lords' attacks: an overlap attack's box fires at anim_cb_frenzy_damage too, and its arm's window is judged on
-- every frame (client.monster_frame, sweep).
local FRAME_CALLBACKS = {
	A = "anim_cb_damage",
	B = "anim_cb_frenzy_damage",
	C = "anim_cb_damage",
	D = "anim_cb_stormvermin_push",
	E = "anim_cb_damage",
	F = "anim_cb_damage",
}

-- Family F: the kinds of disabler attack pc_swing_begin names in step_name (pc.DISABLER_KINDS).
local DISABLER_KINDS = {
	hook = true,
	grab = true,
	pounce = true,
}

-- Family E (build 6, D61): the kinds of monster and lord attack pc_swing_begin names in step_name. Every modded player's
-- screen judges its own player; only the screen of the player the enemy attacks turns it.
local E_KINDS = {
	overlap = true, -- BTMeleeOverlapAttackAction
	slam = true, -- BTMeleeSlamAction
	charge = true, -- BTChargeAttackAction, the bestigor's and the minotaur's (part (b), D65)
	champion = true, -- BTChampionAttackAction, the lords' attacks
	jump = true, -- BTJumpSlamImpactAction, the landing of the rat ogre's jump slam
	axe = true, -- BTThrowWeaponAction, the exalted champion's axe (D68)
}
local E_GRACE = 0.5 -- seconds past its attack's own length that a family E swing waits here for its copy's damage frame
local JUMP_WAIT = 1.5 -- seconds a jump slam's landing waits here for its copy's damage frame
-- Seconds a charge's test runs on here after the host's impact reaches this screen (the review of part (b)): the host
-- may start its impact from its own view, for the look alone (D65), while this screen's copy of the charger still
-- trails the host's by half a ping and the copy's smoothing. To tune from the logs (T22).
local CHARGE_IMPACT_GRACE = 0.4
local WAVE_FX_MEMORY = 1 -- seconds the anticipation effects of a lord's ground wave are kept for its swing
local AXE_SEARCH = 4 -- metres from the champion's hand (2 m up, bt_throw_weapon_action.lua:81) its axe's copy appears
local AXE_MEMORY = 2 -- seconds a thrown weapon's copy is kept for the swing that threw it
local RADIAL_CHECK_RADIUS = 0.5 -- check_radius in BTChampionAttackAction._update_radial_cylinder (:686)
local PLAYER_MIDDLE = 0.9 -- metres above a player's feet that stand in for their trigger's centre when judged by shape
local TWO_PI = 2 * math.pi
-- The animations a charge (BTChargeAttackAction) and a throw (BTThrowWeaponAction) play as part of themselves, besides
-- the tables of them by distance (charging_animations, lunge.animations).
local CHARGE_ANIM_FIELDS = { "start_animation", "impact_animation", "charge_blocked_animation", "cancel_animation", "align_to_target_animation" }
local THROW_ANIM_FIELDS = { "throw_animation", "catch_animation", "close_attack_animation" }

local LEAP_RADIUS = 1 -- the sphere round a gutter runner's neck (BTCrazyJumpAction.check_colliding_players)
local SNAP_START = 2.7 -- enter_snap_state_distance (bt_crazy_jump_action.lua:107)
local SNAP_DISTANCE = 2 -- snap_distance and side_snap_distance (bt_crazy_jump_action.lua:245 and :284)
local SNAP_SIDE = 1
local LEAP_TAKE_OFF = 0.3 -- metres a gutter runner's copy moves from where it crouched once its leap is in the air
local GRAB_ARRIVAL = 2 -- how near its aim point a leech's projectile grabs (BTCorruptorGrabAction.overlap_players)
local PLAYER_RADIUS = 0.35 -- about a player's width, for judging by shape
local PLAYER_HEIGHT = 1.8
-- The animations a gutter runner's leap plays as part of it (bt_crazy_jump_action.lua:38 to :47, :141 and :334); its
-- landing ends it on this screen.
local LEAP_ANIMS = {
	to_crouch = true,
	jump_start = true,
}
local LEAP_END_ANIMS = {
	jump_land = true,
	jump_fail = true,
}

local swings = {} -- swing id -> record, kept for the stats and the debug log
local by_unit = {} -- enemy unit -> its newest record
local by_go_id = {} -- enemy network id -> the same record
local recently_cut = {} -- enemy unit -> { id, by, t } for swings cut in the last CUT_MEMORY seconds
local wave_fx = {} -- { t, fx, points } for effects the host sent without sounds lately, newest last: a ground wave's
local thrown = {} -- { unit, t } for thrown weapons' copies that appeared lately, newest last: an axe's
local hello_timer = 0
local host_answered = false -- the host has replied to a hello since this mission started
local contact_lost = false -- the player has been told the host went quiet
local reping_timer = 0
local released_after_break = false -- what this screen showed at once was undone after the mod switched itself off

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

	-- The host eases an enemy towards its wanted rotation at its turn speed (T18). Do the same, so it turns no faster here.
	local rotation = Quaternion.lerp(swing.current:unbox(), swing.wanted:unbox(), math.min((swing.turn_speed or ROTATION_SPEED) * dt, 1))

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

-- For the debug log, as for family A: did the player dodge during this swing, and was any of those dodges over the
-- dodge count?
local function note_dodges(swing, status)
	if status and not swing.past_damage and status.is_dodging then
		swing.dodged = true

		if not status:get_is_dodging() then
			swing.dodge_over_count = true
		end
	end
end

-- The host's AI locomotion eases an enemy towards its wanted rotation at its turn speed and snaps once a frame's step
-- reaches 1 (locomotion_templates_ai.lua:156). Do the same here, so it turns no faster. The turn speed is the one the
-- host's locomotion has during this attack, worked out from this client's own copy of the behaviour tree (T18).
local function ease_facing(swing, unit, dt)
	local rotation = Quaternion.lerp(swing.current:unbox(), swing.wanted:unbox(), math.min((swing.turn_speed or ROTATION_SPEED) * dt, 1))

	swing.current:store(rotation)

	if pc.facing then
		Unit.set_local_rotation(unit, 0, rotation)
	end
end

-- Family C: copy of BTStormVerminAttackAction.attack (bt_storm_vermin_attack_action.lua:349), fed from this player's
-- live state. The enemy tracks the player until the attack's rotation time runs out, and a dodge stops the tracking
-- for good. Only on the screen of the player the enemy attacks; others in the box see the host's facing.
local function update_box_facing(swing, unit, target, t, dt)
	local status = ScriptUnit.has_extension(target, "status_system")

	note_dodges(swing, status)

	if status and not swing.past_damage then
		if is_dodging(status) then
			swing.track_until = t
			swing.frozen = true
		end

		if t < swing.track_until then
			local rotation = flat_rotation(Unit.local_position(unit, 0), Unit.local_position(target, 0))

			if rotation then
				swing.wanted:store(rotation)
			end
		end
	end

	ease_facing(swing, unit, dt)
end

-- Family D: copy of BTStormVerminPushAction.attack (bt_storm_vermin_push_action.lua:88). The enemy turns towards the
-- player the whole time; a dodge doesn't stop it.
local function update_shove_facing(swing, unit, target, t, dt)
	local status = ScriptUnit.has_extension(target, "status_system")

	note_dodges(swing, status)

	if not swing.past_damage then
		local rotation = flat_rotation(Unit.local_position(unit, 0), Unit.local_position(target, 0))

		if rotation then
			swing.wanted:store(rotation)
		end
	end

	ease_facing(swing, unit, dt)
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
		elseif swing.family == "E" and not swing.past_damage and t > swing.end_t + E_GRACE then
			-- The attack is over on this screen and its copy never reached a damage frame here.
			finish(swing, "attack over")
		elseif swing.family == "E" then
			client.update_monster(swing, unit, target, t, dt)
		elseif swing.family == "B" then
			update_combo_facing(swing, unit, target, t, dt)
		elseif swing.family == "C" then
			if swing.aimed then
				update_box_facing(swing, unit, target, t, dt)
			end
		elseif swing.family == "D" then
			update_shove_facing(swing, unit, target, t, dt)
		elseif swing.family == "F" then
			client.update_disabler(swing, unit, target, t, dt)
		else
			update_facing(swing, unit, target, t, dt)
		end
	end
end

-- The decision half of DamageUtils.check_block (damage_utils.lua:2697), without its host-only parts and without
-- side effects. It returns whether this player blocks the swing, the numbers the host needs to show the block to the
-- other players, and whether the swing went through a block. A monster's or lord's attack (family E) is blockable
-- whatever its data says, as its node never reads unblockable, and is blocked from no direction, as its node reads it
-- from blackboard.attack_anim, which it never sets (bt_melee_overlap_attack_action.lua:640). The jump slam's landing
-- goes through the game's generic damage frame, which reads both (animation_callback_templates.lua:185).
local function would_block(swing, unit, target, status)
	local action = swing.action
	local monster = swing.family == "E" and swing.kind ~= "jump"

	if action.unblockable and not monster or not status then
		return false
	end

	local attack_direction = not monster and action.attack_directions and action.attack_directions[swing.attack_anim] or nil
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

local own_hit_boxes = {} -- player unit -> filter and types -> whether the game's overlap finds that unit's own actors here

-- Whether the overlap an enemy's attack uses (an elite's box, a monster's box or slam) can see this player's own actors
-- on this machine. It is checked once per player unit and filter, with a small box around the player, and logged.
local function overlap_sees(target, filter, types)
	filter = filter or "filter_player_hit_box_check"
	types = types or "dynamics"

	local known_here = own_hit_boxes[target]

	if not known_here then
		known_here = {}
		own_hit_boxes[target] = known_here
	end

	local key = filter .. "/" .. types
	local known = known_here[key]

	if known == nil then
		local actors = PhysicsWorld.immediate_overlap(World.get_data(Unit.world(target), "physics_world"), "position", position(target) + Vector3(0, 0, 0.9), "rotation", Quaternion.identity(), "size", Vector3(0.5, 0.5, 0.9), "shape", "oobb", "types", types, "collision_filter", filter)

		known = false

		for _, actor in ipairs(actors or {}) do
			if Actor.unit(actor) == target then
				known = true

				break
			end
		end

		known_here[key] = known

		pc.log("client: the game's overlap with %s (%s) %s this player's own actors, so attacks that use it are judged %s", filter, types, known and "finds" or "doesn't find", known and "with it" or "by shape")
	end

	return known
end

-- Family C: whether this player is in the elite's box at its damage frame on this screen (Geometry.lua), with the
-- game's own overlap where it sees this player's hit boxes, else with plain shapes. Also returns the distance and
-- the angle from the enemy's facing, for the log.
local function judge_box(swing, unit, target, rotation)
	local centre, box_rotation, size = pc.geometry.elite_box(swing.action, Unit.local_position(unit, 0), rotation)
	local inside

	if overlap_sees(target) then
		inside = pc.geometry.units_in_box(Unit.world(unit), centre, box_rotation, size)[target] == true
		swing.box_method = "overlap"

		pc.count("client_box_overlap")
	else
		inside = pc.geometry.player_in_box(position(target), centre, box_rotation, size)
		swing.box_method = "shape"

		pc.count("client_box_shape")
	end

	local offset = position(target) - position(unit)
	local flat = Vector3.flat(offset)
	local forward = Quaternion.forward(rotation)
	local cosine = Vector3.length_squared(flat) > 0 and Vector3.dot(Vector3.normalize(flat), Vector3.normalize(Vector3.flat(forward))) or 1

	return inside, Vector3.length(offset), math.deg(math.acos(math.max(-1, math.min(1, cosine))))
end

local function angle_between(direction, forward)
	return math.deg(math.acos(math.max(-1, math.min(1, Vector3.dot(direction, forward)))))
end

local function line_of_sight_world(unit)
	return World.get_data(Unit.world(unit), "physics_world")
end

-- Family F: whether the game's own filter would let this disabler take this player, from what this screen knows of the
-- player's state (AiUtils.is_of_interest_to_packmaster, _corruptor and _gutter_runner, ai_utils.lua). The packmaster's
-- and the leech's nodes check theirs every frame, and the leap's sphere takes only a player the gutter runner's accepts
-- (bt_crazy_jump_action.lua:425). Whether another special has disabled the player only the host knows, and checks
-- (Host.lua, takes_now) (D57 review).
local function can_take(kind, special, target)
	local status = ScriptUnit.has_extension(target, "status_system")

	if not status then
		return false
	end

	local pounced = status:is_pounced_down()
	local pack_master = status:is_grabbed_by_pack_master() and status:get_pack_master_grabber()
	local corruptor = status:is_grabbed_by_corruptor() and status.corruptor_unit

	if status:is_knocked_down() or status.using_transport or status.is_ledge_hanging or status:is_grabbed_by_chaos_spawn() then
		return false
	elseif kind == "hook" then
		return not pounced and not (pack_master and pack_master ~= special) and not corruptor and status.pack_master_status ~= "pack_master_hanging"
	elseif kind == "grab" then
		return not pounced and not pack_master and not (corruptor and corruptor ~= special) and status.pack_master_status ~= "pack_master_hanging"
	end

	return not pack_master and not corruptor and not (pounced and status:get_pouncer_unit() ~= special)
end

-- Family F, the packmaster's hook, after its reach and cone (it is unblockable): copy of
-- BTPackMasterAttackAction.attack_success (bt_pack_master_attack_action.lua:110) on this screen. A dodging player
-- escapes unless they are still within the hook's dodge angle of the packmaster's facing and its dodge distance; then
-- line of sight decides. Returns nil if it lands, else why not.
local function hook_misses(swing, unit, target, status, rotation)
	local action = swing.action

	if status and is_dodging(status) then
		local attacker_position = position(unit)
		local dodge_position = position(target)
		local direction = Vector3.normalize(Vector3.flat(dodge_position - attacker_position))
		local dodge_distance = action.dodge_distance or 0

		if angle_between(direction, Quaternion.forward(rotation)) > (action.dodge_angle or 0) or Vector3.distance_squared(attacker_position, dodge_position) >= dodge_distance * dodge_distance then
			return "dodged"
		end
	end

	if not PerceptionUtils.pack_master_has_line_of_sight_for_attack(line_of_sight_world(unit), unit, target) then
		return "line of sight"
	end

	return nil
end

-- Family F, the leech's grab: copy of BTCorruptorGrabAction.grab_player (bt_corruptor_grab_action.lua:221) on this
-- screen, once its projectile has arrived. A player who dodged during the attack escapes unless they are close and in
-- front of the leech, or still near the projectile's aim point; one who didn't is grabbed unless they are too far
-- from that point. Then line of sight. Returns nil if it lands, else why not.
local function grab_misses(swing, unit, target, status)
	local action = swing.action
	local self_position = position(unit)
	local target_position = position(target)
	local target_distance_squared = Vector3.distance_squared(swing.aim_point:unbox(), target_position)
	local physics_world = line_of_sight_world(unit)
	local dodge_distance = action.dodge_distance or 0

	if not action.ignore_dodge and swing.dodged_during_attack or status and status:is_invisible() then
		local direction = Vector3.normalize(Vector3.flat(target_position - self_position))
		local angle = angle_between(direction, Quaternion.forward(Unit.local_rotation(unit, 0)))

		if Vector3.distance_squared(self_position, target_position) < (action.min_dodge_angle_squared or 0) and angle <= (action.dodge_angle or 0) or target_distance_squared < dodge_distance * dodge_distance then
			return not PerceptionUtils.is_position_in_line_of_sight(unit, self_position, target_position, physics_world) and "line of sight" or nil
		end

		return "dodged"
	elseif action.ignore_dodge and Vector3.distance_squared(self_position, target_position) > (action.max_distance_squared or math.huge) or target_distance_squared > 25 then
		return "out of reach"
	end

	return not PerceptionUtils.is_position_in_line_of_sight(unit, self_position + Vector3.up(), target_position + Vector3.up(), physics_world) and "line of sight" or nil
end

local own_triggers = {} -- player unit -> whether a gutter runner's leap overlap finds that unit on this machine

-- Whether the overlap a gutter runner's leap uses can see this player on this machine. Checked once per player unit,
-- with a small sphere round the player, and logged.
local function overlap_sees_trigger(target)
	local known = own_triggers[target]

	if known == nil then
		local actors = PhysicsWorld.immediate_overlap(line_of_sight_world(target), "shape", "sphere", "position", position(target) + Vector3(0, 0, 1), "size", 0.6, "types", "both", "collision_filter", "filter_player_and_husk_trigger")

		known = false

		for _, actor in ipairs(actors or {}) do
			if Actor.unit(actor) == target then
				known = true

				break
			end
		end

		own_triggers[target] = known

		pc.log("client: the game's overlap %s this player, so gutter runners' leaps are judged %s", known and "finds" or "doesn't find", known and "with it" or "by shape")
	end

	return known
end

-- Whether this player is in the leap's sphere round centre: by the game's own overlap where it sees this player,
-- else by distance to an upright segment for the player.
local function in_leap_sphere(centre, target)
	if overlap_sees_trigger(target) then
		local actors = PhysicsWorld.immediate_overlap(line_of_sight_world(target), "shape", "sphere", "position", centre, "size", LEAP_RADIUS, "types", "both", "collision_filter", "filter_player_and_husk_trigger")

		for _, actor in ipairs(actors or {}) do
			if Actor.unit(actor) == target then
				return true, "overlap"
			end
		end

		return false, "overlap"
	end

	local feet = position(target)
	local nearest = Vector3(feet.x, feet.y, math.max(feet.z, math.min(feet.z + PLAYER_HEIGHT, centre.z)))

	return Vector3.distance(centre, nearest) <= LEAP_RADIUS + PLAYER_RADIUS, "shape"
end

local function node_position(unit, name)
	return Unit.world_position(unit, Unit.has_node(unit, name) and Unit.node(unit, name) or 0)
end

-- Family F: a grab or pounce judged on this screen, outside a damage frame. The answer goes out before the local
-- effects, so a problem in those can't leave the host without one.
local function judge_disabler(swing, unit, target, result, reason, distance, t)
	swing.frames = 1
	swing.past_damage = true
	swing.release_t = t + FACING_HOLD

	pc.count("client_judged")
	pc.count("client_judged_F")
	pc.count(result == "miss" and "client_miss_" .. reason or "client_" .. result)

	send_answer(swing, 1, result, 0, false, "", false, distance, 0)

	if result == "hit" then
		pc.guard("client disabler shown", pc.disablers.start, swing, unit, target)
	end

	if pc.debug then
		local status = ScriptUnit.has_extension(target, "status_system")

		pc.log("client swing=%d enemy=%s attack=%s frame=1 verdict=%s reason=%s distance=%.2f since_begin=%.3fs dodging=%s dodged_in_swing=%s family=F:%s aimed=%s%s", swing.id, swing.breed.name, swing.action_name, result, reason, distance, t - swing.begin_t,
			tostring(status ~= nil and status.is_dodging == true), tostring(swing.dodged == true), tostring(swing.kind), tostring(swing.aimed == true), swing.box_method and " sphere=" .. swing.box_method or "")
	end
end

-- Family F, the leech's grab: copy of BTCorruptorGrabAction.overlap_players (bt_corruptor_grab_action.lua:202) on this
-- screen. Each machine flies its own copy of the projectile towards a point just past where it saw the player's neck
-- when it set off (CorruptorBeamExtension._get_positions, corruptor_beam_extension.lua:133), so this one is aimed at
-- this player's real position. The grab is judged once it is within 2 m (flat) of that point, after the action's
-- grab_delay.
local function judge_grab(swing, unit, target, t)
	if not swing.arrived_t then
		local beam = ScriptUnit.has_extension(unit, "ai_beam_effect_system")
		local projectile = beam and beam.state == "projectile" and beam.projectile_unit
		local aim_point = beam and beam.aimed_at_position

		if not projectile or not aim_point or not Unit.alive(projectile) then
			return
		end

		local aimed = aim_point:unbox()

		if Vector3.length(Vector3.flat(aimed - Unit.local_position(projectile, 0))) >= GRAB_ARRIVAL then
			return
		end

		swing.arrived_t = t
		swing.aim_point = Vector3Box(aimed)
	end

	if t < swing.arrived_t + (swing.action.grab_delay or 0) then
		return
	end

	local status = ScriptUnit.has_extension(target, "status_system")
	local why = not can_take("grab", unit, target) and "untakeable" or grab_misses(swing, unit, target, status)

	judge_disabler(swing, unit, target, why and "miss" or "hit", why or "landed", Vector3.distance(position(unit), position(target)), t)
end

-- Family F, the gutter runner's pounce: copy of the in-air part of BTCrazyJumpAction.run (bt_crazy_jump_action.lua:163
-- to :317) on this screen's copy of the leap, against this player's live position, every frame. The sphere round its
-- neck pins whichever player it reaches. In its last 2.7 m it also catches its target in a wider zone (the snap),
-- unless they side-stepped it: the leap then moves away from them. A leap is aimed once, at launch, and never steers,
-- so this screen's copy flies the host's arc; the host skips the snap for a modded target (Host.lua).
local function judge_leap(swing, unit, target, t)
	-- The game tests the leap only once it is in the air (bt_crazy_jump_action.lua:137 to :163): first the gutter
	-- runner crouches where it stands for its jump delay (0.3 s), or aligns. Its copy here leaves that spot when the
	-- host's takes off, so nothing is judged before then (D57 review).
	if not swing.airborne then
		local root = Unit.local_position(unit, 0)

		if not swing.crouch_position then
			swing.crouch_position = Vector3Box(root)
		end

		if Vector3.distance(root, swing.crouch_position:unbox()) < LEAP_TAKE_OFF then
			return
		end

		swing.airborne = true

		pc.log("client swing=%d enemy=%s leap took off here %.3fs after it began", swing.id, swing.breed.name, t - swing.begin_t)
	end

	local neck = node_position(unit, "j_neck")
	local previous = swing.last_neck and swing.last_neck:unbox()

	if swing.last_neck then
		swing.last_neck:store(neck)
	else
		swing.last_neck = Vector3Box(neck)
	end

	-- A player the game's filter wouldn't take is passed over, and its target's snap fails, as the host's leap checks
	-- every frame (bt_crazy_jump_action.lua:118).
	if not can_take("pounce", unit, target) then
		if swing.aimed then
			swing.snap_failed = true
		end

		return
	end

	local inside, method = in_leap_sphere(neck, target)
	local reason = "sphere"

	swing.box_method = method

	if not inside and swing.aimed and not swing.snap_failed then
		if not swing.snapping and Vector3.length(Vector3.flat(position(target) - neck)) < SNAP_START then
			local status = ScriptUnit.has_extension(target, "status_system")

			-- Someone else already pins them (bt_crazy_jump_action.lua:180): the leap fails.
			if status and status.pounced_down then
				swing.snap_failed = true
			else
				swing.snapping = true
			end
		end

		if swing.snapping and previous then
			-- The leap aims at its target's neck (data.enemy_spine_node, bt_prepare_for_crazy_jump_action.lua:189).
			local target_neck = node_position(target, "j_neck")
			local to_target = target_neck - neck
			local velocity = neck - previous

			if Vector3.length_squared(velocity) > 0 and Vector3.dot(Vector3.normalize(velocity), Vector3.normalize(to_target)) < 0 then
				swing.snap_failed = true
				swing.snapping = false
				swing.side_stepped = true
			elseif Vector3.length(to_target) < SNAP_DISTANCE and Vector3.length(Vector3.flat(neck - target_neck)) < SNAP_SIDE then
				inside, reason = true, "snap"
			end
		end
	end

	if inside then
		judge_disabler(swing, unit, target, "hit", reason, Vector3.distance(neck, position(target)), t)
	end
end

-- Family F, every frame after LocomotionSystem.update: the hook and the grab turn the special towards the player the
-- whole time (bt_pack_master_attack_action.lua:95, bt_corruptor_grab_action.lua:165); the grab and the pounce are
-- judged as their projectile or leap reaches the player. The leech remembers a dodge at any point of its attack
-- (bt_corruptor_grab_action.lua:116).
function client.update_disabler(swing, unit, target, t, dt)
	local status = ScriptUnit.has_extension(target, "status_system")

	note_dodges(swing, status)

	if swing.kind == "pounce" then
		if not swing.past_damage then
			judge_leap(swing, unit, target, t)
		end

		return
	end

	if not swing.past_damage then
		local rotation = flat_rotation(Unit.local_position(unit, 0), Unit.local_position(target, 0))

		if rotation then
			swing.wanted:store(rotation)
		end

		if swing.kind == "grab" then
			if status and is_dodging(status) then
				swing.dodged_during_attack = true
			end

			judge_grab(swing, unit, target, t)
		end
	end

	ease_facing(swing, unit, dt)
end

-- Family E: the decision half of DamageUtils.check_ranged_block (damage_utils.lua:2773) for this player, without its
-- side effects: blocking in the inner arc with a weapon that blocks ranged attacks, or against an enemy whose attacks a
-- block stops anyway. The game checks the attacker's ai_unblockable there only on the host, so it is checked here first
-- (pc.unblockable).
local function would_shield_block(unit, target, status)
	if not status or pc.unblockable(unit) or not status:is_blocking() then
		return false
	end

	local can_block, _, improved = status:can_block(unit)

	if not can_block or not improved then
		return false
	end

	local inventory = ScriptUnit.has_extension(target, "inventory_system")
	local weapon = inventory and inventory:get_wielded_slot_item_template()
	local breed = Unit.get_data(unit, "breed")

	return weapon ~= nil and (weapon.can_block_ranged_attacks or breed and breed.blockable_ranged_attack) and true or false
end

-- Family E: the facing this screen judges an attack with: its own while it turns the enemy, else the copy's.
local function monster_rotation(swing, unit)
	if pc.facing and swing.aimed and swing.facing_ours then
		return swing.current:unbox(), "client"
	end

	return Unit.local_rotation(unit, 0), "host"
end

-- Family E1: copy of the players' half of BTMeleeOverlapAttackAction.push_close_units (bt_melee_overlap_attack_action
-- .lua:765) for this player, on this screen: one standing in front of the attack, within its push width of the line
-- ahead of it, is pushed aside unless knocked down. The host leaves modded players out of its own (question 1 of the
-- build 6 notes, D69), so this sends nothing.
local function push_aside(swing, unit, target, data)
	if type(data) ~= "table" or type(data.player_pushed_speed) ~= "number" then
		return
	end

	local forward = Quaternion.forward((monster_rotation(swing, unit)))
	local push_position = position(unit) + forward * (data.push_forward_offset or 0)
	local ahead = data.ahead_dist or 0
	local width = data.push_width or 0
	local radius = math.max(width, ahead) * 1.5
	local target_position = position(target)
	local to_target = target_position - push_position

	if Vector3.length_squared(to_target) >= radius * radius then
		return
	end

	local projected, outside = pc.geometry.closest_point_on_line(target_position, push_position, push_position + forward * ahead)
	local status = ScriptUnit.has_extension(target, "status_system")

	if outside or Vector3.length_squared(target_position - projected) >= width * width or not status or status.knocked_down then
		return
	end

	pc.hit_results.push_aside(target, data.player_pushed_speed * Vector3.normalize(to_target))
	pc.log("client swing=%d enemy=%s pushed this player aside", swing.id, swing.breed.name)
end

-- Family E1: copy of BTMeleeOverlapAttackAction.run's turning (bt_melee_overlap_attack_action.lua:498 to :536), fed
-- from this player's live state, on the screen of the player the enemy attacks. It turns towards them until the
-- attack's rotation time runs out, counted again from the end of a blended start, and a dodge stops it for good unless
-- the attack ignores dodging. Then an animation-driven attack's animation turns it (:533), so the facing goes back to
-- the host; any other keeps the facing it has (:530). An attack with its own rotation_speed lerps at it; an
-- animation-driven one without snaps, as the locomotion's lerp is off for it (:221); the others turn at T18's speed.
local function update_overlap_facing(swing, unit, target, t, dt, status)
	local attack = swing.attack

	if swing.blend_end_t and t > swing.blend_end_t then
		local rotation_time = type(attack.rotation_time) == "number" and attack.rotation_time or 0

		swing.blend_end_t = nil
		swing.rotation_timer = t + rotation_time
		swing.facing_ours = rotation_time > 0
	end

	if not swing.facing_ours then
		return
	end

	if swing.rotation_timer then
		if t < swing.rotation_timer and status and not status:is_invisible() and (attack.ignores_dodging or not is_dodging(status)) then
			local rotation = flat_rotation(Unit.local_position(unit, 0), Unit.local_position(target, 0))

			if rotation then
				swing.wanted:store(rotation)
			end
		else
			swing.rotation_timer = nil

			if swing.anim_driven then
				swing.facing_ours = false

				return
			end

			swing.wanted:store(swing.current:unbox())
		end
	end

	local speed = attack.rotation_speed or swing.anim_driven and math.huge or swing.turn_speed or ROTATION_SPEED
	local step = speed * dt
	local rotation = step >= 1 and swing.wanted:unbox() or Quaternion.lerp(swing.current:unbox(), swing.wanted:unbox(), step)

	swing.current:store(rotation)

	if pc.facing then
		Unit.set_local_rotation(unit, 0, rotation)
	end
end

-- Family E2: copy of BTMeleeSlamAction.run's turning (bt_melee_slam_action.lua:244): towards the player every frame
-- until the damage frame, unless the slam is animation-driven.
local function update_slam_facing(swing, unit, target, dt)
	if not swing.past_damage then
		local rotation = flat_rotation(Unit.local_position(unit, 0), Unit.local_position(target, 0))

		if rotation then
			swing.wanted:store(rotation)
		end
	end

	ease_facing(swing, unit, dt)
end

-- Family E: whether this player is in a box on this screen, with the game's own overlap and the attack's filter where
-- it sees this player's hit boxes, else with plain shapes (Geometry.lua).
local function in_e_box(swing, unit, target, centre, box_rotation, size, filter)
	if overlap_sees(target, filter, "dynamics") then
		swing.box_method = "overlap"

		return pc.geometry.units_in_box(Unit.world(unit), centre, box_rotation, size, filter)[target] == true
	end

	swing.box_method = "shape"

	return pc.geometry.player_in_box(position(target), centre, box_rotation, size)
end

-- Family E1: whether this player is in an overlap attack's box on this screen, with the attack's own filter.
local function in_monster_box(swing, unit, target, centre, box_rotation, size)
	return in_e_box(swing, unit, target, centre, box_rotation, size, swing.attack.hit_only_players and "filter_player_hit_box_check" or "filter_player_and_enemy_hit_box_check")
end

-- Family E4: the actor of this player's that a lord's upright cylinder (Geometry.lua, champion_cylinder) overlaps on this
-- screen, with the game's own overlap and the attack's filter where it sees this player (after the original's
-- prepare_actors_for_overlap, for an attack judged at its damage frame, bt_champion_attack_action.lua:635), else by
-- shape, where the player's middle stands in for the actor. accept, if given, is a further test of an actor's centre
-- (a spin's swept angle): any of this player's actors that passes it counts, as the original tests each actor it
-- found. Returns that actor's centre, or nil if it misses them.
local function in_e_cylinder(swing, unit, target, centre, size, rotation, filter, prepare_radius, accept)
	filter = filter or "filter_player_hit_box_check"

	if overlap_sees(target, filter, "dynamics") then
		local physics_world = World.get_data(Unit.world(unit), "physics_world")

		if prepare_radius and PhysicsWorld.prepare_actors_for_overlap then
			PhysicsWorld.prepare_actors_for_overlap(physics_world, centre, prepare_radius)
		end

		local shape = size.y - size.x > 0 and "capsule" or "sphere"
		local actors = PhysicsWorld.immediate_overlap(physics_world, "position", centre, "rotation", rotation, "size", size, "shape", shape, "types", "dynamics", "collision_filter", filter)

		swing.box_method = "overlap"

		for _, actor in ipairs(actors or {}) do
			if Actor.unit(actor) == target then
				local actor_centre = Actor.center_of_mass(actor)

				if not accept or accept(actor_centre) then
					return actor_centre
				end
			end
		end

		return nil
	end

	swing.box_method = "shape"

	-- The overlap's size.y is half the cylinder's whole height, its rounded ends included (Geometry.lua).
	if pc.geometry.player_in_capsule(position(target), centre, size.x, size.y) then
		local middle = position(target) + Vector3(0, 0, PLAYER_MIDDLE)

		if not accept or accept(middle) then
			return middle
		end
	end

	return nil
end

-- Family E2: the slam's capsule on this screen (BTMeleeSlamAction._calculate_collision and anim_cb_damage,
-- bt_melee_slam_action.lua:108 and :140), by the game's own overlap where it finds this player, else by shape, then its
-- dodge: a player with the dodge flag up (the raw flag, not the dodge count, :173) and farther from its centre on the
-- flat than its dodge_mitigation_radius escapes. Returns nil if it reaches them, else why not.
local function slam_misses(swing, unit, target, rotation)
	local action = swing.action
	local radius = action.radius or 0
	local height = action.height or 0
	local self_position = position(unit)
	local centre = self_position + Quaternion.forward(rotation) * (action.forward_offset or 0) + Vector3(0, 0, height * 0.5)
	local inside = false

	if overlap_sees(target, "filter_rat_ogre_melee_slam", "both") then
		local size = Vector3(radius, height, radius)
		local shape = size.y - size.x > 0 and "capsule" or "sphere"
		local actors = PhysicsWorld.immediate_overlap(World.get_data(Unit.world(unit), "physics_world"), "shape", shape, "position", centre, "rotation", Quaternion.look(Vector3.up(), Vector3.up()), "size", size, "types", "both", "collision_filter", "filter_rat_ogre_melee_slam")

		for _, actor in ipairs(actors or {}) do
			if Actor.unit(actor) == target then
				inside = true

				break
			end
		end

		swing.box_method = "overlap"
	else
		-- The capsule's size.y, its height, is half its whole length (Geometry.lua).
		inside = pc.geometry.player_in_capsule(position(target), centre, radius, height)
		swing.box_method = "shape"
	end

	if not inside then
		return "capsule"
	end

	local status = ScriptUnit.has_extension(target, "status_system")

	if status and status.is_dodging and Vector3.length_squared(Vector3.flat(position(target) - centre)) > (action.dodge_mitigation_radius_squared or 0) then
		return "dodged"
	end

	return nil
end

-- Family E: the distance to this player and the angle from the facing, for the answer and the log.
local function distance_and_angle(unit, target, rotation)
	local offset = position(target) - position(unit)
	local flat = Vector3.flat(offset)
	local cosine = Vector3.length_squared(flat) > 0 and Vector3.dot(Vector3.normalize(flat), Vector3.normalize(Vector3.flat(Quaternion.forward(rotation)))) or 1

	return Vector3.length(offset), math.deg(math.acos(math.max(-1, math.min(1, cosine))))
end

-- Family E: what judges this swing's window on this screen, for the log.
local function e_window(swing)
	if swing.window then
		return "arm"
	elseif swing.champion then
		return swing.champion.mode or "frame"
	elseif swing.charge then
		return "run"
	elseif swing.axe then
		return "axe"
	elseif swing.kind == "jump" then
		return "landing"
	end

	return "none"
end

-- Family E: one answer of a monster's or lord's swing on this screen, counted, sent and logged. The answer goes out
-- before the local effects, so a problem in those can't leave the host without one. final: this player's last answer
-- for the swing here, after which this screen's facing is let go once FACING_HOLD has passed (or the attack's length,
-- if it is known).
local function e_send(swing, unit, target, frame, result, reason, multiplier, improved, direction, through_block, rotation, facing, t, final)
	local status = ScriptUnit.has_extension(target, "status_system")
	local distance, angle = distance_and_angle(unit, target, rotation)

	swing.frames = math.max(swing.frames, frame)

	if final then
		swing.past_damage = true
		swing.release_t = math.max(t + FACING_HOLD, swing.end_t and swing.end_t < math.huge and swing.end_t or 0)
	end

	pc.count("client_judged")
	pc.count("client_judged_E")
	pc.count("client_judged_E_" .. tostring(swing.kind))
	pc.count(result == "miss" and "client_miss_" .. reason or "client_" .. result)

	if swing.box_method then
		pc.count("client_E_" .. swing.box_method)
	end

	if not swing.aimed then
		pc.count("client_judged_E_not_aimed")
	end

	send_answer(swing, frame, result, multiplier, improved, direction, through_block, distance, angle)

	if pc.debug then
		pc.log("client swing=%d enemy=%s attack=%s frame=%d verdict=%s reason=%s distance=%.2f angle=%.1f facing=%s since_begin=%.3fs dodging=%s effective=%s dodged_in_swing=%s family=E:%s aimed=%s turn=%s method=%s window=%s",
			swing.id, swing.breed.name, swing.action_name, frame, result, reason, distance, angle, facing, t - swing.begin_t, tostring(status ~= nil and status.is_dodging == true), tostring(status ~= nil and status:get_is_dodging() and true or false),
			tostring(swing.dodged == true), tostring(swing.kind), tostring(swing.aimed == true), tostring(swing.attack and swing.attack.rotation_speed or swing.turn_speed), tostring(swing.box_method), e_window(swing))
	end
end

-- Family E: the verdict at one frame of this screen's copy, in the node's own order. An overlap attack: the melee
-- block, then a shield's ranged block unless the attack ignores it (bt_melee_overlap_attack_action.lua:643); a slam: a
-- disabled player is hit, then the shield's block, then the melee block (bt_melee_slam_action.lua:180 to :187). The
-- answer goes out before the local effects, so a problem in those can't leave the host without one.
local function monster_verdict(swing, unit, target, frame, miss_reason, rotation, facing, t)
	local status = ScriptUnit.has_extension(target, "status_system")
	local result, reason = "hit", "landed"
	local multiplier, improved, direction, through_block

	if miss_reason then
		result, reason = "miss", miss_reason
	elseif swing.kind == "slam" and status and status:is_disabled() then
		reason = "disabled"
	elseif swing.kind == "slam" and would_shield_block(unit, target, status) then
		result, reason = "shield", "shield"
	else
		local blocked

		blocked, multiplier, improved, direction, through_block = would_block(swing, unit, target, status)

		if blocked then
			result, reason = "blocked", improved and "in arc" or "outer arc"

			if swing.kind == "overlap" and not swing.action.ignore_shield_block and would_shield_block(unit, target, status) then
				result, reason = "shield", "shield"
			end
		elseif through_block then
			reason = "through block"
		end
	end

	e_send(swing, unit, target, frame, result, reason, multiplier, improved, direction, through_block, rotation, facing, t, true)

	if result == "blocked" or result == "shield" then
		-- A slam's shield block is the shield's alone; an overlap attack's is its melee block, then the shield's.
		if not (swing.kind == "slam" and result == "shield") then
			play_block(swing, unit, status, multiplier, improved, direction)
		end

		-- Plays the shield's block here and tells the host, as the game's own call does on a client (damage_utils.lua:2821).
		if result == "shield" then
			pc.guard("client shield block", DamageUtils.check_ranged_block, unit, target, swing.action.shield_blocked_fatigue_type or "shield_blocked_slam")
		end
	end

	if result ~= "miss" then
		pc.guard("client monster results", pc.hit_results.monster, swing, unit, target, result)

		-- The chaos spawn's grab (D67): its hit_player_func grabs a player it hit or who blocked it, unless they are
		-- disabled or invisible (breed_chaos_spawn.lua:863), and this screen shows it at once (D53).
		if swing.grab and result ~= "shield" and status and not status:is_disabled() and not status:is_invisible() then
			pc.guard("client grab shown", pc.disablers.start, swing, unit, target, "spawn")
		end
	end
end

-- Family E1: an arm's window closed on this screen without reaching this player.
local function close_window(swing, unit, target, reason)
	local window = swing.window

	if window.over then
		return
	end

	window.over = true

	local rotation, facing = monster_rotation(swing, unit)

	monster_verdict(swing, unit, target, 1, reason, rotation, facing, pc.now())
end

-- Family E1: copy of BTMeleeOverlapAttackAction.weapon_sweep_overlap (bt_melee_overlap_attack_action.lua:827) on this
-- screen's copy, every frame of an attack's window: a box along its arm or weapon, from base_node_name to tip_node_name,
-- widened by how far the tip moved since the last frame. The window opens at its start_time and closes at the copy's own
-- anim_cb_attack_overlap_done (:968) or when the attack is over. It is answered once, as frame 1: when the box first
-- reaches this player, or as a miss when it closes.
local function sweep(swing, unit, target, t)
	local window = swing.window

	if t < window.start_t then
		return
	end

	if t > swing.end_t then
		close_window(swing, unit, target, "window over")

		return
	end

	if not window.base_node then
		if type(window.base_name) ~= "string" or type(window.tip_name) ~= "string" or not Unit.has_node(unit, window.base_name) or not Unit.has_node(unit, window.tip_name) then
			window.over = true
			swing.frames = 1
			swing.past_damage = true
			swing.release_t = t + FACING_HOLD

			pc.count("client_unjudged")
			pc.print("client swing=%d enemy=%s: its copy has no %s or %s, so its window isn't judged", swing.id, swing.breed.name, tostring(window.base_name), tostring(window.tip_name))
			send_answer(swing, 1, "unjudged")

			return
		end

		window.base_node = Unit.node(unit, window.base_name)
		window.tip_node = Unit.node(unit, window.tip_name)
	end

	local attack = swing.attack
	local tip = Unit.world_position(unit, window.tip_node)
	local to_old = window.tip and window.tip:unbox() - tip or Vector3.zero()

	if window.tip then
		window.tip:store(tip)
	else
		window.tip = Vector3Box(tip)
	end

	local base = Unit.world_position(unit, window.base_node)
	local half_range = (attack.range or 0) * 0.5
	local half_height = (attack.height or 0) * 0.5
	local size = Vector3(((attack.width or 0) + Vector3.length(to_old)) * 0.5, half_range, half_height)
	local base_to_tip = tip - base
	local box_rotation, up, forward

	if window.base_node == window.tip_node then
		box_rotation = Unit.local_rotation(unit, window.base_node)
		up = Quaternion.up(box_rotation) * ((attack.offset_up or 0) + half_height)
		forward = Quaternion.forward(box_rotation) * ((attack.offset_forward or 0) + half_range)
	else
		box_rotation = Quaternion.look(base_to_tip, Vector3.up())
		up = Quaternion.up(box_rotation) * (attack.offset_up or 0)
		forward = Quaternion.forward(box_rotation) * (attack.offset_forward or 0)
	end

	local centre = base + base_to_tip * 0.5 + up + forward + to_old * 0.5

	-- A player behind the enemy is passed over (:937).
	if attack.ignore_targets_behind and Vector3.dot(Vector3.normalize(position(target) - position(unit)), Quaternion.forward(Unit.local_rotation(unit, 0))) <= 0 then
		return
	end

	if in_monster_box(swing, unit, target, centre, box_rotation, size) then
		window.over = true

		local rotation, facing = monster_rotation(swing, unit)

		monster_verdict(swing, unit, target, 1, nil, rotation, facing, t)
	end
end

-- Family E (part (b)): a window that ran on this screen without reaching this player, a charge's run, a lord's lunge,
-- spin or ground wave, or a thrown axe: this player's miss.
local function e_close(swing, unit, target, reason)
	if swing.past_damage then
		return
	end

	local t = pc.now()

	if target and Unit.alive(target) and Unit.alive(unit) then
		local rotation, facing = monster_rotation(swing, unit)

		e_send(swing, unit, target, 1, "miss", reason, nil, nil, nil, nil, rotation, facing, t, true)

		return
	end

	swing.frames = math.max(swing.frames, 1)
	swing.past_damage = true
	swing.release_t = t

	send_answer(swing, 1, "miss", 0, false, "", false, 0, 0)
end

-- Family E3: the charge's test on this screen found this player close in front of the charger's copy
-- (BTChargeAttackAction._hit_player, bt_charge_attack_action.lua:553): its target or anyone else is hit, once. The
-- melee block first, unless weapons can't block the charge (the minotaur's), then a shield's, both played here as the
-- original runs both; the answer goes out before what they show (HitResults.lua).
local function charge_head(swing, unit, target, status, t)
	local action = swing.action
	local melee, multiplier, improved, direction, through_block = false, nil, nil, nil, nil

	if not action.unblockable_by_normal_blocks then
		melee, multiplier, improved, direction, through_block = would_block(swing, unit, target, status)
	end

	local shield = would_shield_block(unit, target, status)
	local result = shield and "shield" or melee and "blocked" or "hit"
	local reason = shield and "shield" or melee and (improved and "in arc" or "outer arc") or through_block and "through block" or "landed"

	swing.box_method = "distance"

	e_send(swing, unit, target, 1, result, reason, multiplier, improved, direction, through_block, Unit.local_rotation(unit, 0), "host", t, true)

	if melee then
		play_block(swing, unit, status, multiplier, improved, direction)
	end

	-- Plays the shield's block here and tells the host, as the game's own call does on a client (damage_utils.lua:2821).
	if shield then
		pc.guard("client shield block", DamageUtils.check_ranged_block, unit, target, action.shield_blocked_fatigue_type or "ogre_shove")
	end

	pc.guard("client charge results", pc.hit_results.charge, swing, unit, target, result, swing.charge.speed)
end

-- Family E3, every frame after LocomotionSystem.update: copy of BTChargeAttackAction._check_overlap
-- (bt_charge_attack_action.lua:443 to :486) between this screen's copy of the charger, as the host moves it (question 2
-- of the build 6 notes, D69), and this player, while the charge's test runs here (client.charge_cue, charge_seen). In
-- front of the charger, within head_radius (target_dodged_radius while this player's dodge counts), the hit
-- (charge_head); else within radius, a push aside, once, as frame 2, which leaves the hit to come. The copy's speed is
-- kept for the minotaur's throw, which goes at the charger's speed (_charged_at_player, :520).
local function update_charge(swing, unit, target, t, dt, status)
	local charge = swing.charge
	local root = Unit.local_position(unit, 0)

	if charge.last then
		if dt > 0 then
			charge.speed = math.lerp(charge.speed, Vector3.length(root - charge.last:unbox()) / dt, 0.5)
		end

		charge.last:store(root)
	else
		charge.last = Vector3Box(root)
	end

	if not charge.open then
		return
	end

	-- A charge can run for longer than a swing is remembered (the minotaur's runs up to 30 s at full speed).
	swing.expires = math.max(swing.expires, t + 1)

	if charge.until_t and t > charge.until_t then
		e_close(swing, unit, target, "impact over")

		return
	end

	if charge.paused then
		return
	end

	local to_target = position(target) - root
	local distance = Vector3.length(to_target)

	if distance <= 0 or not status or status:is_invisible() or Vector3.dot(to_target / distance, Quaternion.forward(Unit.local_rotation(unit, 0))) <= 0 then
		return
	end

	local action = swing.action
	local head_radius = is_dodging(status) and action.target_dodged_radius or action.head_radius

	if distance < (head_radius or 0) then
		charge_head(swing, unit, target, status, t)
	elseif not charge.pushed and distance < (action.radius or 0) then
		charge.pushed = true
		swing.box_method = "distance"

		e_send(swing, unit, target, 2, "pushed", "passed close", nil, nil, nil, nil, Unit.local_rotation(unit, 0), "host", t, false)
		pc.guard("client charge results", pc.hit_results.charge, swing, unit, target, "pushed", charge.speed)
	end
end

-- Family E3: the copy's charge cues, from the animation callback hook in Ping Compensation.lua. The charge's test
-- starts with the end of its start animation (anim_cb_charge_start_finished, bt_charge_attack_action.lua:1125) and
-- ends with the lunge's anim_cb_disable_charge_collision (:1161), or with anim_cb_charge_charging_finished for a charge
-- that never lunged (:1149). The minotaur's lunge only pauses at the first: a lunge that ends without a hit starts an
-- impact that tests again for its hit_during_impact_t (:354, charge_seen). And it has no animations of its own (it
-- leans, lunge.lean_variables), so its charging animation may still play, and fire the second cue, while it lunges,
-- when the host's node ignores the cue; so a charge without lunge animations ignores it here too, and its test ends
-- with the host's next move. Once the host's impact has reached this screen, its test runs for its own time
-- (charge_seen) and the cues no longer end or pause it, as the node's impact tests by time alone (:1000). Every cue is
-- logged, since the animations that fire them aren't in the game's Lua.
function client.charge_cue(unit, callback_name)
	local swing = by_unit[unit]
	local target = local_player_unit()

	if not swing or swing.kind ~= "charge" or swing.past_damage or target ~= swing.target then
		return
	end

	local charge = swing.charge
	local action = swing.action
	local lunge_animated = type(action.lunge) == "table" and type(action.lunge.animations) == "table"

	pc.log("client swing=%d enemy=%s charge cue %s here %.3fs after it began", swing.id, swing.breed.name, tostring(callback_name), pc.now() - swing.begin_t)

	if callback_name == "anim_cb_charge_start_finished" then
		if not charge.open then
			charge.open = true
			swing.open = true
		end
	elseif charge.open and not charge.until_t then
		if callback_name == "anim_cb_disable_charge_collision" and action.hit_during_impact_t then
			charge.paused = true
		elseif callback_name ~= "anim_cb_charge_charging_finished" or lunge_animated then
			e_close(swing, unit, target, callback_name)
		end
	end
end

-- Family E4: the points of a lord's ground wave (nav_mesh_wave), as the host sent them as its anticipation effects when
-- the attack started (BTChampionAttackAction._init_attack, bt_champion_attack_action.lua:188), just before the swing's
-- announcement: the newest of the attack's anticipation_fx, whose first point lies just ahead of this screen's copy.
local function wave_points(swing, unit, t)
	local action = swing.action
	local fx = type(action.anticipation_fx) == "string" and rawget(NetworkLookup.effects, action.anticipation_fx)
	local origin = position(unit)
	local reach = math.abs(action.offset_forward or 0) + 3

	if not fx then
		return nil
	end

	for i = #wave_fx, 1, -1 do
		local record = wave_fx[i]

		if record.fx == fx and t - record.t <= WAVE_FX_MEMORY and record.points[1] and Vector3.length(Vector3.flat(record.points[1]:unbox() - origin)) <= reach then
			table.remove(wave_fx, i)

			return record.points
		end
	end

	return nil
end

-- Family E4: what this screen needs to follow a lord's attack (BTChampionAttackAction._init_attack,
-- bt_champion_attack_action.lua:60): its turning time, and the window its mode tests in, from this screen's start of the
-- attack: a box along its movement (continuous_overlap), a sweeping cylinder (radial_cylinder) or a wave along the
-- ground (nav_mesh_wave); without a mode, it is judged at its damage frames. Returns false and why if this screen can't
-- follow it.
local function init_champion(swing, t)
	local action = swing.action
	local mode = action.mode
	local rotation_time = type(action.rotation_time) == "number" and action.rotation_time or 0
	local champion = {
		mode = mode,
		frames = 0, -- damage frames of this screen's copy so far, for an attack without a mode
		start_t = t + (type(action.overlap_start_time) == "number" and action.overlap_start_time or 0),
		end_t = t + (type(action.overlap_end_time) == "number" and action.overlap_end_time or 0),
	}

	swing.rotation_timer = t + rotation_time
	swing.facing_ours = rotation_time > 0
	swing.end_t = math.huge -- until the host's next move for the lord, or the swing's lifetime

	if mode == "continuous_overlap" then
		champion.last = Vector3Box(position(swing.unit))
		champion.last_t = t
	elseif mode == "radial_cylinder" then
		local span = champion.end_t - champion.start_t

		champion.angle_speed = span > 0 and ((action.overlap_end_angle_offset or 0) - (action.overlap_start_angle_offset or 0)) / span or 0
	elseif mode == "nav_mesh_wave" then
		champion.points = wave_points(swing, swing.unit, t)
		champion.last_index = 0

		if not champion.points then
			return false, "its wave's points never arrived"
		end
	elseif mode ~= nil then
		return false, "its mode is " .. tostring(mode)
	end

	swing.champion = champion

	return true
end

-- Family E4: copy of BTChampionAttackAction._update_rotation (bt_champion_attack_action.lua:379), fed from this
-- player's live state, on the screen of the player the lord attacks: towards them until the attack's rotation time,
-- unless within 0.3 m, stopping for good once they dodge or turn invisible, or once the attack has reached them. Then it
-- keeps the facing it last aimed at.
local function update_champion_facing(swing, unit, target, t, dt, status)
	if status and (is_dodging(status) or status:is_invisible()) then
		swing.dodged_during_attack = true
	end

	local self_position = Unit.local_position(unit, 0)
	local target_position = Unit.local_position(target, 0)

	if t < swing.rotation_timer and not swing.dodged_during_attack and not swing.champion.done and Vector3.distance_squared(self_position, target_position) > 0.09 then
		local rotation = flat_rotation(self_position, target_position)

		if rotation then
			swing.wanted:store(rotation)
		end
	end

	ease_facing(swing, unit, dt)
end

-- Family E4, continuous_overlap: copy of BTChampionAttackAction._update_overlap (bt_champion_attack_action.lua:411) on
-- this screen's copy, every frame of the window: a box along the lord's movement since the last frame, clipped to the
-- window, facing the lord's way (or its movement's, with movement_controlled_rotation), reaching ahead by the attack's
-- range, which can be a function of the window's progress. Returns whether it reached this player, and where it hit from.
local function lunge_frame(swing, unit, target, t)
	local champion = swing.champion
	local action = swing.action
	local start_t, end_t, last_t = champion.start_t, champion.end_t, champion.last_t
	local new_position = position(unit)
	local reached, from = false, nil

	if start_t < t and last_t < end_t and t > last_t then
		local old_position = champion.last:unbox()

		from = last_t < start_t and Vector3.lerp(old_position, new_position, (start_t - last_t) / (t - last_t)) or old_position

		local to = end_t < t and Vector3.lerp(old_position, new_position, (end_t - last_t) / (t - last_t)) or new_position
		local delta = to - from
		local rotation, forward

		if action.movement_controlled_rotation then
			forward = Vector3.normalize(delta)
			rotation = Quaternion.look(forward, Vector3.up())
		else
			rotation = Unit.local_rotation(unit, 0)
			forward = Quaternion.forward(rotation)
		end

		local up = Quaternion.up(rotation)
		local base_range = type(action.range) == "function" and action.range((t - start_t) / (end_t - start_t)) or tonumber(action.range) or 0
		local range = base_range + (action.movement_controlled_rotation and Vector3.length(delta) or Vector3.dot(delta, forward))
		local half_range = range * 0.5
		local half_height = (action.height or 0) * 0.5
		local centre = from + forward * ((action.offset_forward or 0) + half_range) + up * ((action.offset_up or 0) + half_height)

		reached = in_e_box(swing, unit, target, centre, rotation, Vector3((action.width or 0) * 0.5, half_range, half_height), "filter_player_hit_box_check")
	end

	champion.last:store(new_position)
	champion.last_t = t

	return reached, from
end

-- Family E4, radial_cylinder: copy of BTChampionAttackAction._update_radial_cylinder (bt_champion_attack_action.lua:655)
-- on this screen's copy, every frame of the window: the cylinder round the lord (Geometry.lua), whose swing's angle
-- turns from the lord's facing as the window opened, at the attack's own speed. This player is hit when the angle swept
-- since the last frame passes the centre of any of their actors in the cylinder (:691; by shape, their middle), by the
-- original's own maths. Returns whether it reached them.
local function radial_frame(swing, unit, target, t)
	local champion = swing.champion
	local action = swing.action
	local self_position = Unit.local_position(unit, 0)
	local self_rotation = Unit.local_rotation(unit, 0)

	if not champion.start_angle then
		local forward = Quaternion.forward(self_rotation)

		champion.start_angle = math.atan2(forward.y, forward.x) + (action.overlap_start_angle_offset or 0)
		champion.last_angle = champion.start_angle
	end

	local old_angle = champion.last_angle
	local new_angle = champion.start_angle + (t - champion.start_t) * champion.angle_speed
	local relative_angle = new_angle - old_angle

	champion.last_angle = new_angle

	-- The original also passes the distance to math.tan, which ignores it (:712).
	local radial_width = 2 * math.tan(RADIAL_CHECK_RADIUS)

	-- Whether the angle swept since the last frame passed this point, an actor's centre.
	local function swept(mass_centre)
		local offset = mass_centre - self_position
		local y = offset.y
		local x = action.direction == "clockwise" and -offset.x or offset.x
		local angle = math.atan2(y, x)
		local min_angle = (angle - radial_width - old_angle) % TWO_PI
		local max_angle = (angle + radial_width - old_angle) % TWO_PI

		if max_angle < min_angle then
			min_angle = min_angle - TWO_PI
		end

		return min_angle < 0 and relative_angle < max_angle or min_angle > 0 and min_angle < relative_angle or max_angle > 0 and max_angle < relative_angle
	end

	local centre, size, rotation = pc.geometry.champion_cylinder(action, self_position, self_rotation)

	return in_e_cylinder(swing, unit, target, centre, size, rotation, action.collision_filter, nil, swept) ~= nil
end

-- Family E4, nav_mesh_wave: copy of BTChampionAttackAction._update_nav_mesh_wave (bt_champion_attack_action.lua:514):
-- from the window's start the wave reaches its next points at the attack's wave_speed, and the boxes between the points
-- it reached since the last frame are tested. Once it has reached its last point, the original keeps testing that
-- point's box until the attack ends (its window runs num_points times wave_speed seconds, :193), so this screen does
-- too, until the attack is over here. Returns whether a box reached this player.
local function wave_frame(swing, unit, target, t)
	local champion = swing.champion
	local action = swing.action
	local points = champion.points

	if t < champion.start_t or #points == 0 then
		return false
	end

	local new_index = math.min(math.floor((t - champion.start_t) * (action.wave_speed or 0) + 1), #points)
	local start_index = math.min(champion.last_index + 1, new_index)
	local half_width = (action.width or 0) * 0.5
	local half_height = (action.height or 0) * 0.5
	local reached = false

	for i = start_index, new_index do
		local point = points[i]:unbox()
		local to = points[i + 1] and points[i + 1]:unbox() or point
		local from = points[i - 1] and points[i - 1]:unbox() or position(unit)
		local rotation = Quaternion.look(to - from, Vector3.up())
		local size = Vector3(half_width, math.max(Vector3.length(to - point), Vector3.length(from - point)), half_height)
		local centre = (to + from) * 0.5 + Quaternion.up(rotation) * half_height

		if not reached and in_e_box(swing, unit, target, centre, rotation, size, "filter_player_hit_box_check") then
			reached = true
		end
	end

	champion.last_index = new_index

	return reached
end

-- Family E4: a lord's attack reached this player on this screen: the melee block (no lord's attack tries a shield's),
-- the answer, then what it shows (HitResults.lua). One answer that reaches them per attack, as the original hits each
-- player once (hit_players). from: where it hit from.
local function champion_verdict(swing, unit, target, frame, t, from)
	local status = ScriptUnit.has_extension(target, "status_system")
	local blocked, multiplier, improved, direction, through_block = would_block(swing, unit, target, status)
	local result = blocked and "blocked" or "hit"
	local reason = blocked and (improved and "in arc" or "outer arc") or through_block and "through block" or "landed"
	local rotation, facing = monster_rotation(swing, unit)

	swing.champion.done = true

	e_send(swing, unit, target, frame, result, reason, multiplier, improved, direction, through_block, rotation, facing, t, true)

	if blocked then
		play_block(swing, unit, status, multiplier, improved, direction)
	end

	pc.guard("client lord's results", pc.hit_results.champion, swing, unit, target, result, from)
end

-- Family E4, every frame after LocomotionSystem.update: the screen of the player the lord attacks turns it, and every
-- screen tests its own player against the attack's window, if its mode has one.
local function update_champion(swing, unit, target, t, dt, status)
	local champion = swing.champion

	if swing.aimed and swing.facing_ours then
		update_champion_facing(swing, unit, target, t, dt, status)
	end

	if champion.done or swing.past_damage or not champion.mode then
		return
	end

	local mode = champion.mode
	local reached, from = false, nil

	if mode == "continuous_overlap" then
		reached, from = lunge_frame(swing, unit, target, t)
	elseif mode == "radial_cylinder" then
		if t > champion.end_t then
			e_close(swing, unit, target, "window over")

			return
		end

		if t >= champion.start_t then
			reached = radial_frame(swing, unit, target, t)
		end
	else
		reached = wave_frame(swing, unit, target, t)
	end

	if t >= champion.start_t then
		swing.open = true
	end

	if reached then
		champion_verdict(swing, unit, target, 1, t, from)
	elseif mode == "continuous_overlap" and t > champion.end_t then
		e_close(swing, unit, target, "window over")
	end
end

-- Family E4, an attack without a mode: copy of BTChampionAttackAction.anim_cb_damage (bt_champion_attack_action.lua:598)
-- at this screen's copy's damage frame: the box in front (the same as an elite's, Geometry.lua) or the upright cylinder
-- round the lord (collision_type), each damage frame a frame of the swing, until one reaches this player.
local function champion_damage_frame(swing, unit, target, t)
	local champion = swing.champion
	local action = swing.action

	if champion.done or champion.frames >= MAX_FRAMES then
		return
	end

	champion.frames = champion.frames + 1

	local rotation, facing = monster_rotation(swing, unit)
	local self_position = Unit.local_position(unit, 0)
	local reached

	if action.collision_type == "cylinder" then
		local centre, size, cylinder_rotation = pc.geometry.champion_cylinder(action, self_position, rotation)

		reached = in_e_cylinder(swing, unit, target, centre, size, cylinder_rotation, action.collision_filter, action.radius) ~= nil
	else
		local centre, box_rotation, size = pc.geometry.elite_box(action, self_position, rotation)

		reached = in_e_box(swing, unit, target, centre, box_rotation, size, "filter_player_hit_box_check")
	end

	if reached then
		champion_verdict(swing, unit, target, champion.frames, t, self_position)
	else
		e_send(swing, unit, target, champion.frames, "miss", action.collision_type == "cylinder" and "cylinder" or "box", nil, nil, nil, nil, rotation, facing, t, true)

		-- A later damage frame of the same attack (a step of its attack_sequence) can come more than FACING_HOLD later,
		-- so the swing is kept until the host's next move for the lord that isn't part of the attack
		-- (client.animation_changed) or the swing's lifetime (the review of part (b)).
		swing.release_t = math.huge
	end
end

-- Family E, the rat ogre's jump slam, at its copy's damage frame as it lands on this screen. Its target's screen judges
-- the hit as the game's generic damage frame does (family A's reach and cone, then the block,
-- animation_callback_templates.lua:175 to :216), as frame 1; every screen then throws its own player if they are within
-- the landing's catapult radius of the copy (BTJumpSlamImpactAction.catapult_player, bt_jump_slam_impact_action.lua:78),
-- as frame 2. The flight was the host's, as a gutter runner's leap is (T17), so nothing turns here.
local function jump_damage_frame(swing, unit, target, t)
	if swing.landed then
		return
	end

	swing.landed = true

	local action = swing.action
	local status = ScriptUnit.has_extension(target, "status_system")
	local rotation = Unit.local_rotation(unit, 0)

	if swing.aimed then
		local forward = Quaternion.forward(rotation)
		local offset = position(target) - position(unit)
		local in_reach, in_front = pc.geometry.single_target(offset.x, offset.y, offset.z, forward.x, forward.y, false, action, swing.breed, 0, 0, 0)
		local result, reason = "hit", "landed"
		local blocked, multiplier, improved, direction, through_block

		if not in_reach then
			result, reason = "miss", "reach"
		elseif not in_front then
			result, reason = "miss", "cone"
		else
			blocked, multiplier, improved, direction, through_block = would_block(swing, unit, target, status)

			if blocked then
				result, reason = "blocked", improved and "in arc" or "outer arc"
			elseif through_block then
				reason = "through block"
			end
		end

		swing.box_method = "reach"

		e_send(swing, unit, target, 1, result, reason, multiplier, improved, direction, through_block, rotation, "host", t, false)

		if blocked then
			play_block(swing, unit, status, multiplier, improved, direction)
		elseif result == "hit" then
			pc.guard("client hit results", pc.hit_results.hit, swing, unit, target)
		end
	end

	local caught = action.catapult_players and Vector3.length(position(target) - position(unit)) <= (action.catapult_within_radius or 0)

	swing.box_method = "radius"

	e_send(swing, unit, target, 2, caught and "pushed" or "miss", caught and "thrown" or "radius", nil, nil, nil, nil, rotation, "host", t, true)

	if caught then
		pc.guard("client jump catapult", pc.hit_results.jump_catapult, swing, unit, target)
	end
end

-- Family E, the exalted champion's axe (D68): this screen's copy of it is the thrown weapon that appeared after the
-- swing began, nearest the champion's hand.
local function claim_axe(swing)
	local unit = swing.unit

	if not Unit.alive(unit) then
		return
	end

	local hand = position(unit) + Vector3(0, 0, 2)
	local best, best_distance = nil, AXE_SEARCH

	for i = #thrown, 1, -1 do
		local record = thrown[i]

		if record.t >= swing.begin_t and Unit.alive(record.unit) then
			local distance = Vector3.distance(Unit.local_position(record.unit, 0), hand)

			if distance <= best_distance then
				best, best_distance = i, distance
			end
		end
	end

	if best then
		swing.axe.unit = thrown[best].unit
		swing.open = true

		table.remove(thrown, best)
		pc.log("client swing=%d enemy=%s: its axe appeared here %.3fs after it began, %.2f m from its hand", swing.id, swing.breed.name, pc.now() - swing.begin_t, best_distance)
	end
end

-- Family E, the axe, every frame after LocomotionSystem.update: copy of BTThrowWeaponAction.check_overlap
-- (bt_throw_weapon_action.lua:286) between this screen's copy of the axe and this player, out and back, until it is
-- gone. Within its radius on the flat (target_dodged_radius while this player's dodge counts), unless invisible, this
-- player is thrown, then hit unless they blocked; once per throw. The axe flies where the host's champion faced
-- (question 2 of the build 6 notes, D69).
local function update_axe(swing, unit, target, t, status)
	local axe = swing.axe

	if not axe.unit then
		claim_axe(swing)

		if not axe.unit then
			return
		end
	end

	if not Unit.alive(axe.unit) then
		e_close(swing, unit, target, "axe gone")

		return
	end

	swing.expires = math.max(swing.expires, t + 1)

	local action = swing.action
	local axe_position = Unit.local_position(axe.unit, 0)
	local radius = status and is_dodging(status) and action.target_dodged_radius or action.radius

	if not status or status:is_invisible() or Vector3.length(Vector3.flat(position(target) - axe_position)) >= (radius or 0) then
		return
	end

	local blocked, multiplier, improved, direction, through_block = would_block(swing, unit, target, status)
	local result = blocked and "blocked" or "hit"
	local reason = blocked and (improved and "in arc" or "outer arc") or through_block and "through block" or "landed"

	swing.box_method = "distance"

	e_send(swing, unit, target, 1, result, reason, multiplier, improved, direction, through_block, Unit.local_rotation(unit, 0), "host", t, true)

	if blocked then
		play_block(swing, unit, status, multiplier, improved, direction)
	end

	pc.guard("client axe results", pc.hit_results.axe, swing, unit, target, result, axe_position)
end

-- Family E, the axe: a thrown weapon's copy appeared on this screen (ThrownUnitHuskExtension.init,
-- thrown_unit_husk_extension.lua:8). It is kept for a moment for the swing that threw it.
function client.thrown_spawned(unit)
	local t = pc.now()

	thrown[#thrown + 1] = {
		unit = unit,
		t = t,
	}

	while thrown[1] and (#thrown > 4 or t - thrown[1].t > AXE_MEMORY) do
		table.remove(thrown, 1)
	end

	for _, swing in pairs(by_unit) do
		if swing.kind == "axe" and not swing.axe.unit and not swing.past_damage then
			claim_axe(swing)
		end
	end
end

-- Family E4: effects the host played for every client (WeaponSystem.rpc_play_fx, weapon_system.lua:867). Those without
-- sounds may be a lord's ground wave's anticipation, whose positions are the wave's points (wave_points).
function client.effects_played(vfx_array, sfx_array, position_array)
	if type(vfx_array) ~= "table" or type(position_array) ~= "table" or #vfx_array == 0 or #position_array == 0 or type(sfx_array) == "table" and #sfx_array > 0 then
		return
	end

	local points = {}

	for i = 1, #position_array do
		points[i] = Vector3Box(position_array[i])
	end

	wave_fx[#wave_fx + 1] = {
		t = pc.now(),
		fx = vfx_array[1],
		points = points,
	}

	while #wave_fx > 4 do
		table.remove(wave_fx, 1)
	end
end

-- Family E, every frame after LocomotionSystem.update: the screen of the player the enemy attacks turns it; every
-- screen pushes its own player aside where the attack does so every frame, and sweeps an arm's window, or follows the
-- part (b) kinds' windows: a charge's run, a lord's lunge, spin or wave, a thrown axe.
function client.update_monster(swing, unit, target, t, dt)
	local status = ScriptUnit.has_extension(target, "status_system")

	note_dodges(swing, status)

	local kind = swing.kind

	if kind == "charge" then
		if not swing.past_damage then
			update_charge(swing, unit, target, t, dt, status)
		end

		return
	elseif kind == "champion" then
		update_champion(swing, unit, target, t, dt, status)

		return
	elseif kind == "axe" then
		if not swing.past_damage then
			update_axe(swing, unit, target, t, status)
		end

		return
	elseif kind == "jump" then
		return
	end

	if swing.kind == "slam" then
		if swing.aimed and swing.facing_ours then
			update_slam_facing(swing, unit, target, dt)
		end

		return
	end

	if swing.aimed then
		update_overlap_facing(swing, unit, target, t, dt, status)
	end

	local continuous = swing.attack.push_units_in_the_way_continuous

	if continuous and t <= swing.end_t then
		push_aside(swing, unit, target, continuous)
	end

	if swing.window and not swing.window.over then
		sweep(swing, unit, target, t)
	end
end

-- Family E: a damage frame of this screen's copy. An overlap attack's box in front fires at anim_cb_damage and at
-- anim_cb_frenzy_damage alike (bt_melee_overlap_attack_action.lua:718), each a frame of its own, after the window's if
-- the attack has one; a slam's capsule fires once, at anim_cb_damage.
function client.monster_frame(swing, unit, callback_name)
	local target = local_player_unit()

	if target ~= swing.target or callback_name ~= "anim_cb_damage" and not (callback_name == "anim_cb_frenzy_damage" and swing.kind == "overlap") then
		return
	end

	local t = pc.now()
	local kind = swing.kind

	-- Part (b): a lord's attack with a mode has its window instead (the node's own anim_cb_damage does nothing then,
	-- bt_champion_attack_action.lua:602); a charge and a thrown axe have no damage frame.
	if kind == "champion" then
		if not swing.champion.mode then
			champion_damage_frame(swing, unit, target, t)
		end

		return
	elseif kind == "jump" then
		jump_damage_frame(swing, unit, target, t)

		return
	elseif kind == "charge" or kind == "axe" then
		return
	end

	local rotation, facing = monster_rotation(swing, unit)

	if swing.kind == "slam" then
		if swing.box_frames == 0 then
			swing.box_frames = 1

			monster_verdict(swing, unit, target, 1, slam_misses(swing, unit, target, rotation), rotation, facing, t)
		end

		return
	end

	-- After its damage_done_time the host's node stops testing unless an arm's window is still open (:540), so a damage
	-- event that late is no frame there.
	if swing.done_t and t > swing.done_t and not (swing.window and not swing.window.over) then
		pc.log("client swing=%d enemy=%s fired a damage event after its damage_done_time; not judged", swing.id, swing.breed.name)

		return
	end

	local frame = swing.box_frames + 1 + (swing.window and 1 or 0)

	if frame > MAX_FRAMES then
		return
	end

	swing.box_frames = swing.box_frames + 1

	local attack = swing.attack
	local miss_reason = nil

	-- The box in front (:722), the same box as an elite's (Geometry.lua), passing over a player behind (:937).
	if attack.ignore_targets_behind and Vector3.dot(Vector3.normalize(position(target) - position(unit)), Quaternion.forward(rotation)) <= 0 then
		miss_reason = "behind"
	else
		local centre, box_rotation, size = pc.geometry.elite_box(attack, Unit.local_position(unit, 0), rotation)

		if not in_monster_box(swing, unit, target, centre, box_rotation, size) then
			miss_reason = "box"
		end
	end

	monster_verdict(swing, unit, target, frame, miss_reason, rotation, facing, t)

	-- Some attacks push players aside at each damage frame too (:758).
	if attack.push_close_units_during_attack and attack.push_units_in_the_way then
		push_aside(swing, unit, target, attack.push_units_in_the_way)
	end
end

-- The copy's anim_cb_attack_overlap_done (bt_melee_overlap_attack_action.lua:968), from the animation callback hook in
-- Ping Compensation.lua: an arm's window is over on this screen.
function client.window_done(unit)
	local swing = by_unit[unit]
	local target = local_player_unit()

	if swing and swing.family == "E" and swing.window and not swing.window.over and target == swing.target then
		close_window(swing, unit, target, "arm")
	end
end

-- Called from the AnimationSystem.animation_callback hook when an enemy copy fires the damage frame of the swing it
-- has open at this player: anim_cb_damage (families A and C), anim_cb_frenzy_damage (B) or anim_cb_stormvermin_push (D).
function client.damage_frame(unit, callback_name)
	local swing = by_unit[unit]

	-- A monster's or lord's attack (family E) has damage frames of its own kind.
	if swing and swing.family == "E" then
		client.monster_frame(swing, unit, callback_name)

		return
	end

	-- A leech's damage frame only sends its projectile off; its grab is judged when that arrives (judge_grab).
	if swing and (FRAME_CALLBACKS[swing.family] ~= callback_name or swing.family == "F" and swing.kind ~= "hook") then
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
	local family = swing.family
	local combo = family == "B"
	-- Only the screen of the player the enemy attacks turns it; others in an elite's box see the host's facing.
	local use_our_facing = pc.facing and swing.aimed
	local rotation = use_our_facing and swing.current:unbox() or Unit.local_rotation(unit, 0)
	local in_reach, in_front, distance, reach, angle, cone, tightened

	if family == "C" then
		in_reach, distance, angle = judge_box(swing, unit, target, rotation)
		in_front, reach, cone, tightened = true, 0, 0, swing.frozen
	else
		local forward = Quaternion.forward(rotation)
		local offset = position(target) - position(unit)

		-- The game tightens the reach and cone after a dodge: family A while its facing is frozen, family B once the
		-- player has dodged during the step (target_dodged_during_attack, damage_utils.lua:2642). A shove never does.
		tightened = combo and swing.dodged_during_attack or family == "A" and swing.frozen
		in_reach, in_front, distance, reach, angle, cone = pc.geometry.single_target(offset.x, offset.y, offset.z, forward.x, forward.y, tightened, action, breed, swing.box_up, swing.box_down, swing.box_flat)
	end

	local status = ScriptUnit.has_extension(target, "status_system")
	local result, reason = "hit", "landed"
	local multiplier, improved, direction, through_block

	if not in_reach then
		result, reason = "miss", family == "C" and "box" or "reach"
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

	-- Family F: the hook is unblockable, and has its own rule after its reach and cone: the dodge, then line of sight,
	-- for a player the packmaster's node would still take.
	if family == "F" and result == "hit" then
		local why = not can_take("hook", unit, target) and "untakeable" or hook_misses(swing, unit, target, status, rotation)

		if why then
			result, reason = "miss", why
		end
	end

	pc.count("client_judged")
	pc.count(result == "miss" and "client_miss_" .. reason or "client_" .. result)

	if family == "C" or family == "D" or family == "F" then
		pc.count("client_judged_" .. family)

		if not swing.aimed then
			pc.count("client_judged_C_not_aimed")
		end
	end

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

		-- An elite's sweep still does its blocked damage and push; a single swing pushes the blocker back.
		if family == "C" then
			pc.guard("client box results", pc.hit_results.box, swing, unit, target, true)
		elseif not combo then
			pc.guard("client blocked push", pc.hit_results.blocked, swing, unit, target)
		end
	elseif result == "hit" then
		if family == "C" then
			pc.guard("client box results", pc.hit_results.box, swing, unit, target, false)
		elseif family == "D" then
			pc.guard("client shove results", pc.hit_results.shove, swing, unit, target, rotation)
		elseif family == "F" then
			-- The hook does no damage; the player is grabbed at once instead (D53).
			pc.guard("client disabler shown", pc.disablers.start, swing, unit, target)
		else
			pc.guard("client hit results", pc.hit_results.hit, swing, unit, target)
		end
	end

	if result == "hit" and swing.dodge_over_count then
		pc.count("client_hit_over_dodge_count")
	end

	if pc.debug then
		local dodging_now = status ~= nil and status.is_dodging == true
		local effective_now = status ~= nil and status:get_is_dodging() and true or false

		pc.log("client swing=%d enemy=%s attack=%s%s frame=%d verdict=%s reason=%s distance=%.2f reach=%.2f angle=%.1f cone=%.1f frozen=%s facing=%s since_begin=%.3fs dodging=%s effective=%s dodges=%s/%s dodged_in_swing=%s over_count_in_swing=%s dodgecount=%s recoil=%s family=%s aimed=%s turn=%s%s",
			swing.id, breed.name, swing.action_name, combo and "/" .. tostring(swing.step_name) or "", frame, result, reason, distance, reach, angle, cone, tostring(tightened == true), use_our_facing and "client" or "host", t - swing.begin_t,
			tostring(dodging_now), tostring(effective_now), tostring(status and status.dodge_cooldown), tostring(status and status.dodge_count), tostring(swing.dodged == true), tostring(swing.dodge_over_count == true), pc.dodgecount and "on" or "off",
			tostring(recoil_anim or "host"), family .. (swing.kind and ":" .. swing.kind or ""), tostring(swing.aimed == true), combo and "combo" or tostring(swing.turn_speed), family == "C" and " box=" .. tostring(swing.box_method) or "")
	end
end

-- The host changed this enemy's animation. Before the damage frame that means the swing was interrupted, almost
-- always by a stagger, and the player now sees the enemy stop swinging. On the host a staggered enemy's damage event
-- does nothing, so here the swing is cut at once (decision D22). The first playtests showed the damage event can still
-- fire during the blend into the stagger; damage_frame logs that instead of judging it.
local function names(list, name)
	if type(list) == "string" then
		return list == name
	end

	if type(list) == "table" then
		for i = 1, #list do
			if list[i] == name then
				return true
			end
		end
	end

	return false
end

-- Whether a table keyed by anything (a charge's animations by distance) holds this animation, alone or in a list.
local function names_any(list, name)
	if type(list) == "table" then
		for _, entry in pairs(list) do
			if names(entry, name) then
				return true
			end
		end
	end

	return false
end

-- Family E: the animations an attack plays as part of itself, whichever of them the host picked: an overlap attack's or
-- a slam's, the steps of a lord's attack_sequence (BTChampionAttackAction._next_in_sequence,
-- bt_champion_attack_action.lua:354), a charge's (BTChargeAttackAction, bt_charge_attack_action.lua:54 to :414) and a
-- throw's (BTThrowWeaponAction, bt_throw_weapon_action.lua:22, :136 and :341).
local function own_attack_anim(swing, event)
	local attack = swing.attack
	local action = swing.action

	if attack then
		if names(attack.attack_anim, event) then
			return true
		end

		if type(attack.multi_attack_anims) == "table" then
			for _, anim in pairs(attack.multi_attack_anims) do
				if anim == event then
					return true
				end
			end
		end
	end

	if swing.kind == "champion" and type(action.attack_sequence) == "table" then
		for i = 1, #action.attack_sequence do
			local step = action.attack_sequence[i]

			if type(step) == "table" and names(step.attack_anim, event) then
				return true
			end
		end
	elseif swing.kind == "charge" then
		for i = 1, #CHARGE_ANIM_FIELDS do
			if names(action[CHARGE_ANIM_FIELDS[i]], event) then
				return true
			end
		end

		if names_any(action.charging_animations, event) or type(action.lunge) == "table" and names_any(action.lunge.animations, event) then
			return true
		end
	elseif swing.kind == "axe" then
		for i = 1, #THROW_ANIM_FIELDS do
			if names(action[THROW_ANIM_FIELDS[i]], event) then
				return true
			end
		end
	end

	return names(action.attack_anim, event)
end

-- Family E3: the host's animations for a charge whose test runs on this screen. The charge stopped by a wall
-- (charge_blocked_animation), cancelled or turning round to its target is over. An impact (BTChargeAttackAction
-- ._start_impact, bt_charge_attack_action.lua:324) doesn't end the test at once: the host may have started it from its
-- own view, for the look alone (D65), while this screen's copy of the charger still trails the host's, so the test
-- runs on for CHARGE_IMPACT_GRACE, and the host books a hit that arrives during its impact (the review of part (b)).
-- The minotaur's runs on for its hit_during_impact_t if that is longer, as its node tests again for that long after an
-- impact that hit nobody (:354), which this screen can't tell from one after a hit on someone else.
local function charge_seen(swing, unit, event)
	local action = swing.action
	local charge = swing.charge

	if not charge.open or swing.past_damage then
		return
	end

	if names(action.charge_blocked_animation, event) or names(action.cancel_animation, event) or names(action.align_to_target_animation, event) then
		e_close(swing, unit, local_player_unit(), tostring(event))
	elseif names(action.impact_animation, event) and not charge.until_t then
		local grace = math.max(action.hit_during_impact_t or 0, CHARGE_IMPACT_GRACE)

		charge.paused = false
		charge.until_t = pc.now() + grace

		pc.log("client swing=%d enemy=%s: the host's charge impact (%s) reached this screen %.3fs after the swing began; its test runs on here for %.2fs", swing.id, swing.breed.name, tostring(event), pc.now() - swing.begin_t, grace)
	end
end

function client.animation_changed(go_id, anim_id)
	local swing = by_go_id[go_id]

	if not swing then
		return
	end

	local event = NetworkLookup.anims[anim_id]

	if event == swing.attack_anim then
		return
	end

	if swing.family == "E" then
		-- A charge's impact, cancel or turning round changes what its test does here.
		if swing.kind == "charge" then
			charge_seen(swing, swing.unit, event)
		end

		-- Another of the attack's own animations, the host's copy of what this screen plays (a slam is announced with the
		-- animation the host noted last, Host.lua).
		if own_attack_anim(swing, event) then
			return
		end

		-- Any other move means the attack is over. A window that had opened here (part (b): a charge's run, a lord's
		-- lunge, spin or wave, a thrown axe) ran without reaching this player: a miss.
		if swing.open and not swing.past_damage then
			e_close(swing, swing.unit, local_player_unit(), tostring(event))
			forget(swing)

			return
		end
	end

	-- Family F: a gutter runner's leap plays these as part of it, and its landing ends it here without reaching this
	-- player (bt_crazy_jump_action.lua:334): a miss, which lets the host's leap end too.
	if swing.kind == "pounce" then
		if LEAP_ANIMS[event] then
			return
		end

		if LEAP_END_ANIMS[event] and not swing.past_damage then
			swing.frames = 1
			swing.past_damage = true

			pc.count("client_judged")
			pc.count("client_judged_F")
			pc.count("client_miss_landed")
			pc.log("client swing=%d enemy=%s attack=%s frame=1 verdict=miss reason=landed (%s) since_begin=%.3fs family=F:pounce aimed=%s side_stepped=%s", swing.id, swing.breed.name, swing.action_name, tostring(event), pc.now() - swing.begin_t, tostring(swing.aimed == true), tostring(swing.side_stepped == true))
			send_answer(swing, 1, "miss", 0, false, "", false, 0, 0)
			forget(swing)

			return
		end
	end

	-- An elite whose attack shrugs off a stagger restarts the attack's wind-up (reset_attack, bt_storm_vermin_attack_action
	-- .lua:321): the swing goes on, and its damage frame comes later.
	if names(swing.action.reset_attack_animations, event) then
		pc.log("client swing=%d enemy=%s: the attack was reset (%s), the swing goes on", swing.id, swing.breed.name, tostring(event))

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

	-- A monster isn't staggered by a push (only explosions stagger it, boss_staggers, damage_utils.lua:791), and a lord's
	-- staggers follow rules of their own, so a family E swing goes on; a stagger the host does play cuts it as it arrives.
	if not swing or swing.past_damage or swing.family == "E" then
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

-- This player's hit staggered or killed the enemy on their screen (Reactions.lua), so a swing it had started is over,
-- and a shooter or a warpfire thrower stops turning here (Shots.lua, Areas.lua).
function client.reaction_started(unit, reason)
	local swing = by_unit[unit]

	if swing and not swing.past_damage then
		cut(swing, reason)
	end

	if pc.shots then
		pc.guard("client shooter reaction", pc.shots.stop_turning, unit, reason)
	end

	if pc.areas then
		pc.guard("client jet reaction", pc.areas.stop_turning, unit, reason)
	end
end

-- Family E1: the overlap attack the host chose, by its place in the action's attacks, negative in its running_attacks.
local function overlap_attack(action, index)
	if type(index) ~= "number" or index == 0 or index ~= math.floor(index) then
		return nil
	end

	local list = index > 0 and action.attacks or action.running_attacks
	local attack = type(list) == "table" and list[math.abs(index)]

	return type(attack) == "table" and attack or nil
end

-- Family E: what this screen needs to follow the attack, from its own copy of the data: an overlap attack's turning,
-- length and window (BTMeleeOverlapAttackAction._init_attack, bt_melee_overlap_attack_action.lua:161 to :259), a slam's
-- (BTMeleeSlamAction.init_attack, bt_melee_slam_action.lua:44), a lord's (init_champion). A charge, a jump slam's
-- landing and a thrown axe are never turned here (question 2 of the build 6 notes, D69). Returns false and why if this
-- screen can't follow the attack.
local function init_monster(swing, t)
	local action = swing.action
	local attack = swing.attack
	local kind = swing.kind

	swing.box_frames = 0 -- damage frames of this screen's copy so far
	swing.grab = pc.GRAB_ATTACKS[swing.action_name] == true -- the chaos spawn's grab (D67)

	if kind == "charge" then
		swing.facing_ours = false
		swing.end_t = math.huge -- until its test ends here (client.charge_cue, charge_seen)
		swing.charge = {
			open = false, -- its test runs from the copy's anim_cb_charge_start_finished
			speed = 0, -- the copy's speed here
		}

		return true
	elseif kind == "jump" then
		swing.facing_ours = false
		swing.end_t = t + JUMP_WAIT

		return true
	elseif kind == "axe" then
		swing.facing_ours = false
		swing.end_t = math.huge -- until its axe is gone here
		swing.axe = {}

		claim_axe(swing)

		return true
	elseif kind == "champion" then
		return init_champion(swing, t)
	end

	if swing.kind == "slam" then
		local anim_driven = action.anim_driven == true

		if type(action.attack_anims) == "table" then
			for _, entry in pairs(action.attack_anims) do
				if type(entry) == "table" and entry[1] == swing.attack_anim and entry[2] then
					anim_driven = true
				end
			end
		end

		swing.anim_driven = anim_driven
		swing.facing_ours = not anim_driven
		swing.end_t = t + (type(action.attack_time) == "number" and action.attack_time or 0)

		return
	end

	local anim_driven = attack.anim_driven == true
	local rotation_time = type(attack.rotation_time) == "number" and attack.rotation_time or 0
	local multi = attack.multi_attack_anims

	-- A side animation of multi_attack_anims turns the enemy itself (:170).
	if type(multi) == "table" then
		if swing.attack_anim == multi.fwd then
			anim_driven = false
		else
			anim_driven = true
			rotation_time = 0
		end
	end

	swing.anim_driven = anim_driven
	swing.rotation_timer = t + rotation_time
	swing.facing_ours = rotation_time > 0
	swing.blend_end_t = anim_driven and type(attack.blend_time) == "number" and t + attack.blend_time or nil
	swing.end_t = t + (type(attack.attack_time) == "number" and attack.attack_time or 0)

	local done = attack.damage_done_time

	if type(done) == "table" then
		done = done[swing.attack_anim]
	end

	swing.done_t = type(done) == "number" and t + done or nil

	local window = type(attack.continious_overlap) == "table" and attack.continious_overlap[swing.attack_anim]

	if type(window) == "table" then
		-- No attack in the game data uses one (6.13); its nodes would be the weapon's, not the enemy's (:233).
		if window.use_inventory_unit then
			pc.log("client swing=%d enemy=%s: its window uses an inventory unit, so the enemy's own nodes are tried", swing.id, swing.breed.name)
		end

		swing.window = {
			start_t = t + (type(window.start_time) == "number" and window.start_time or 0),
			base_name = window.base_node_name,
			tip_name = window.tip_node_name,
		}
	end
end

-- family: "A" for a single swing (BTAttackAction), "B" for one step of a frenzy combo (BTComboAttackAction), whose
-- step_name finds the step in action.combo_attacks, "C" for an elite's sweep or overhead (BTStormVerminAttackAction),
-- "D" for an elite's shove (BTStormVerminPushAction), "F" for a disabler's attack and "E" for a monster's or lord's,
-- whose step_name is its kind. Each step of a combo is announced as its own swing. aimed: whether this player is the
-- one the enemy attacks; a family C or E swing goes to every modded player (D50, D61). attack_index: a family E overlap
-- attack's place in its action's attacks.
mod:network_register("pc_swing_begin", function (sender, version, id, attacker_go_id, family, set_name, action_name, attack_anim, box_up, box_down, box_flat, damage_scale, step_name, aimed, attack_index)
	if pc.broken or pc.is_server() or not pc.in_game() or sender ~= pc.host_peer() or version ~= pc.VERSION then
		return
	end

	if type(id) ~= "number" or type(attacker_go_id) ~= "number" or not FRAME_CALLBACKS[family] or type(set_name) ~= "string" or type(action_name) ~= "string" or type(attack_anim) ~= "string" then
		return
	end

	local t = pc.now()
	local unit = Managers.state.unit_storage:unit(attacker_go_id)
	local target = local_player_unit()
	local breed = unit and Unit.alive(unit) and Unit.get_data(unit, "breed")
	local set = BreedActions[set_name]
	local action = set and set[action_name]
	local step = family == "B" and action and type(action.combo_attacks) == "table" and type(step_name) == "string" and action.combo_attacks[step_name] or nil
	local kind = family == "F" and DISABLER_KINDS[step_name] and step_name or family == "E" and E_KINDS[step_name] and step_name or nil
	local attack = kind == "overlap" and action and overlap_attack(action, attack_index) or nil

	pc.count("client_announced")

	if not breed or not target or not action or family == "B" and not step or (family == "F" or family == "E") and not kind or kind == "overlap" and not attack then
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

	-- Family C: how long the enemy tracks the player (BTStormVerminAttackAction._init_attack,
	-- bt_storm_vermin_attack_action.lua:150): a moving or step attack uses its own time, if it has one.
	local rotation_time = action.rotation_time

	if family == "C" and (action.moving_attack or names(action.step_attack_anim, attack_anim)) and action.rotation_time_step then
		rotation_time = action.rotation_time_step
	end

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
		turn_speed = pc.turn_speed(breed, action), -- families A, C, D and F: the host's turn speed during this attack (T18)
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
		-- A family C sweep, a family E attack and a family F pounce reach every modded player; the others go to their
		-- target only.
		aimed = family ~= "C" and family ~= "E" and family ~= "F" or aimed == true,
		track_until = t + (type(rotation_time) == "number" and rotation_time or 0), -- family C
		kind = kind, -- family F: hook, grab or pounce; family E: overlap or slam
		attack = attack, -- family E1: the overlap attack, from action.attacks or action.running_attacks
	}

	if family == "E" then
		local ok, ready, why = pc.guard("client monster swing", init_monster, swing, t)

		if not ok or ready == false then
			-- The host judges a swing this screen can't, as it does one whose client has gone quiet (Host.lua).
			pc.count("client_unjudged")
			pc.print("client swing=%d enemy=%s attack=%s can't be judged here: %s", id, breed.name, action_name, ok and tostring(why) or "an error")
			send_answer({ id = id }, 1, "unjudged")

			return
		end
	end

	swings[id] = swing
	by_unit[unit] = swing
	by_go_id[attacker_go_id] = swing

	-- An overlap attack can push players in front aside as it starts (bt_melee_overlap_attack_action.lua:275).
	if attack and attack.push_units_in_the_way then
		pc.guard("client push aside", push_aside, swing, unit, target, attack.push_units_in_the_way)
	end
end)

mod:hook_safe("LocomotionSystem", "update", function (self, context, t)
	if self.is_server or pc.broken then
		return
	end

	if next(by_unit) ~= nil then
		pc.guard("client facing", client.after_locomotion, t, context.dt)
	end

	if pc.reactions.active() then
		pc.guard("client reactions", pc.reactions.after_locomotion, t, context.dt)
	end

	if pc.disablers and pc.disablers.active() then
		pc.guard("client grabs", pc.disablers.after_locomotion, t)
	end

	-- Family H: the warpfire's jet on this player's screen turns the thrower by its own rule (Areas.lua), so after the
	-- engine has turned every enemy copy by the host's numbers, as the swings' facing does.
	if pc.areas and pc.areas.has_jets() then
		pc.guard("client jets", pc.areas.after_locomotion, t, context.dt)
	end

	-- Family G (D59): a ratling gunner's stream and an archer aimed at this player turn the shooter the same way (Shots.lua).
	if pc.shots and pc.shots.has_turning() then
		pc.guard("client shooters", pc.shots.after_locomotion, t, context.dt)
	end
end)

-- Family E, the exalted champion's axe (D68): every thrown weapon's copy on this screen, for the swing that threw it.
mod:hook_safe("ThrownUnitHuskExtension", "init", function (self, extension_init_context, unit, extension_init_data)
	if pc.broken or pc.is_server() or not pc.in_game() then
		return
	end

	pc.guard("client thrown weapon", client.thrown_spawned, unit)
end)

-- Family E4: the effects the host plays for every client, among them a lord's ground wave's anticipation, whose
-- positions are the wave's points (BTChampionAttackAction._init_attack, bt_champion_attack_action.lua:188).
mod:hook_safe("WeaponSystem", "rpc_play_fx", function (self, channel_id, vfx_array, sfx_array, position_array)
	if self.is_server or pc.broken or not pc.in_game() then
		return
	end

	pc.guard("client wave points", client.effects_played, vfx_array, sfx_array, position_array)
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

		host_answered = true

		pc.guard("client difficulty mods", pc.compat.on_host_reply, fingerprint, toggles, matched)
	end
end)

-- VMF's hook on PlayerManager.remove_player (vmf/scripts/mods/vmf/modules/core/network.lua:375) drops a peer from its
-- list of VMF users whenever any player of that peer is removed, and bots share the host's peer id. So each bot the
-- host removes, for example when a player joins and takes its place, cuts this client off from the host: VMF sends
-- nothing to a peer off its list, and adds one back only when one of its players is added (the build 3.2 playtest).
-- A ping from VMF itself puts the host back, because the host answers it with VMF's own pong.
local function ping_vmf()
	local vmf = get_mod("VMF")

	if vmf and type(vmf.ping_vmf_users) == "function" then
		vmf.ping_vmf_users()
		pc.count("client_vmf_ping")
		pc.log("client asked VMF to ping every player again: the host has stopped answering")
	end
end

-- While a host that has answered in this mission stays quiet, ask VMF to ping again every pc.REPING_INTERVAL, and tell
-- the player when contact goes and when it comes back, since everything is vanilla for them in between.
local function keep_in_touch(dt)
	if not host_answered then
		return
	end

	if pc.host_fresh() then
		if contact_lost then
			contact_lost = false

			pc.say("Ping Compensation is back in touch with the host: swings at you and your own hits are decided on your screen again.")
		end

		reping_timer = 0

		return
	end

	if not contact_lost then
		contact_lost = true

		pc.count("client_contact_lost")
		pc.say("Ping Compensation lost touch with the host, so the game is vanilla for you until it is back. Reconnecting...")
	end

	reping_timer = reping_timer - dt

	if reping_timer <= 0 then
		reping_timer = pc.REPING_INTERVAL

		pc.guard("client vmf ping", ping_vmf)
	end
end

-- The next update sends a hello at once, so the host hears about a changed /pingcomp attacks switch straight away.
function client.hello_now()
	hello_timer = 0
end

-- Tells the host this client runs the mod, which version, and whether its attacks switch is on. Without a recent
-- hello the host judges this player as vanilla.
function client.update(dt)
	if pc.broken then
		-- Once the mod has switched itself off, the grabs, pins and catches it showed at once that the host hasn't
		-- confirmed are undone, once, since nothing else would end them; plain pcalls, as pc.guard does nothing now.
		if not released_after_break and not pc.is_server() then
			released_after_break = true

			if pc.disablers then
				pcall(pc.disablers.release_all, "the mod switched itself off")
			end

			if pc.areas then
				pcall(pc.areas.release_catches, "the mod switched itself off")
			end
		end

		return
	end

	if pc.is_server() or not pc.in_game() then
		return
	end

	pc.guard("client reactions upkeep", pc.reactions.update, dt)
	pc.guard("client hit results upkeep", pc.hit_results.update)

	if pc.disablers then
		pc.guard("client grabs upkeep", pc.disablers.update)
	end

	if pc.shots then
		pc.guard("client shots upkeep", pc.shots.update, dt)
	end

	if pc.areas then
		pc.guard("client areas upkeep", pc.areas.update, dt)
	end

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

	keep_in_touch(dt)
end

function client.clear()
	swings = {}
	by_unit = {}
	by_go_id = {}
	recently_cut = {}
	wave_fx = {}
	thrown = {}
	hello_timer = 0
	host_answered = false
	contact_lost = false
	reping_timer = 0
	released_after_break = false
	own_hit_boxes = {}
	own_triggers = {}

	pc.forget_host()
	pc.reactions.clear()
	pc.hit_results.clear()

	if pc.disablers then
		pc.disablers.clear()
	end

	if pc.shots then
		pc.shots.clear()
	end

	if pc.areas then
		pc.areas.clear()
	end
end

function client.open_swing_count()
	local count = 0

	for _ in pairs(by_unit) do
		count = count + 1
	end

	return count
end
