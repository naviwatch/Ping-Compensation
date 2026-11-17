local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Host side. The host still runs every enemy. For a swing aimed at a remote player who runs this mod it:
--   1. announces the swing to that player when the attack starts,
--   2. skips its own hit test when its copy of the swing reaches the damage frame,
--   3. books whatever the player's client answers: damage for a hit, the block for a block, nothing for a miss.
-- Families: A, single swings (BTAttackAction); B, frenzy combo steps (BTComboAttackAction); C, elites' sweeps and
-- overheads (BTStormVerminAttackAction), which reach every modded player near their box; D, elites' shoves
-- (BTStormVerminPushAction); F, disablers (D52): the packmaster's hook (BTPackMasterAttackAction), the leech's grab
-- (BTCorruptorGrabAction) and the gutter runner's pounce (BTCrazyJumpAction), which reaches every modded player.
-- Bots, the host's own hero and players without the mod never get a record here, so they stay vanilla.

local host = {
	suppress = nil, -- the swing whose vanilla hit test is being skipped right now
	box_skip = nil, -- family C: the player units the next box overlap leaves out, during an elite's damage frame
	leap_skip = nil, -- family F: the player units the next leap overlap leaves out, during a gutter runner's leap
	booking = false, -- true while the host books what a client reported, so the damage-alone log leaves it out (D56)
}

pc.host = host

local MAX_FRAMES = 8
local MAX_DIRECTION_LENGTH = 16
local MAX_ANIMATION_LENGTH = 64
local RESULTS = {
	hit = true,
	blocked = true,
	miss = true,
	cut = true,
	unjudged = true,
}

local peers = {} -- peer id -> { t = main-clock time of that client's last hello, attacks = its /pingcomp attacks switch }
local mismatched = {} -- peer id -> true once we've said their build differs
local swings = {} -- swing id -> record
local by_attacker = {} -- enemy unit -> its newest record of families A, B and D
local boxes = {} -- enemy unit -> its newest family C attack: { action, blackboard, swings = { one per modded player } }
local leaps = {} -- gutter runner unit -> its newest leap (family F): { blackboard, jump_data, swings = { one per modded player } }
local action_sets = {} -- action table -> name of the BreedActions set it lives in, or false
local next_id = 0

local function peer_is_fresh(peer)
	local record = peers[peer]

	return record ~= nil and pc.clock() - record.t <= pc.PEER_EXPIRY
end

-- Whether that player's client decides what their hits do to the enemies in pc.REACTION_BREEDS (D26 to D29). Their
-- client makes the same check from the host's replies, so both sides agree on who decides.
function host.peer_decides_attacks(peer)
	return peer_is_fresh(peer) and peers[peer].attacks == true and peers[peer].matched == true
end

-- The peer whose own screen judges what reaches this player unit, if any: a remote human player whose client has said
-- hello in the last pc.PEER_EXPIRY seconds. Families G and H (Shots.lua, Areas.lua) leave such players out of the
-- host's own tests, as the other families do.
function host.client_judges(unit)
	local owner = unit and Managers.player:unit_owner(unit)
	local peer = owner and owner.remote and not owner.bot_player and owner.peer_id

	return peer and peer_is_fresh(peer) and peer or nil
end

-- The enemy's damage against this target is scaled down by how many enemies surround the target. Only the host has
-- the slot data, so the client gets the number for its HP estimate (D11).
local function damage_scale(action, target)
	local diminishing = action.diminishing_damage
	local slot_extension = ScriptUnit.has_extension(target, "ai_slot_system")

	if not diminishing or not slot_extension or not slot_extension.has_slots_attached then
		return 1
	end

	local slots = slot_extension.delayed_num_occupied_slots
	local entry = slots and slots > 0 and diminishing[math.min(slots, 9)]

	return entry and entry.damage or 1
end

-- An enemy's attack table doesn't always live under its own breed name: a stormvermin commander, for one, uses the
-- plain stormvermin's set. The client needs the set's name to find the same table in its own copy of the data.
local function action_set_name(action, breed)
	local cached = action_sets[action]

	if cached ~= nil then
		return cached or nil
	end

	local name = action.name
	local found = false
	local own = name and BreedActions[breed.name]

	if own and own[name] == action then
		found = breed.name
	elseif name then
		for set_name, set in pairs(BreedActions) do
			if set[name] == action then
				found = set_name

				break
			end
		end
	end

	action_sets[action] = found

	return found or nil
end

-- Whether the enemy is still in the combo step this swing announced (family B). The same step name can come round
-- again in a later combo, so its start time tells them apart.
local function in_combo_step(swing, blackboard)
	local combo = blackboard and blackboard.combo_attack_data

	return combo ~= nil and blackboard.active_node == BTComboAttackAction and blackboard.action == swing.action and combo.current_attack_name == swing.step_name
		and combo.attack_start_time == swing.step_start_t and combo.attacking_target == swing.target
end

-- One swing aimed at, or reaching, one modded player.
local function new_swing(unit, blackboard, family, action, breed, target, peer, attacker_go_id, set_name, attack_anim, t, step, step_name)
	local combo = blackboard.combo_attack_data

	next_id = next_id + 1

	local swing = {
		id = next_id,
		peer = peer,
		family = family,
		attacker = unit,
		attacker_go_id = attacker_go_id,
		target = target,
		action = action,
		set_name = set_name,
		step = step, -- family B: the combo step, which has its own damage, block cost and follow-ups
		step_name = step_name,
		attack_anim = attack_anim, -- for the log lines of the recoil that a block of it causes
		step_start_t = combo and step and combo.attack_start_time or nil,
		damage = pc.attack_damage(action, step),
		blackboard = blackboard,
		breed_name = breed.name,
		start_t = t,
		expires = t + pc.SWING_LIFETIME,
		frames = 0, -- damage frames the host's own copy has reached
		frame_t = {},
		would = {}, -- what the host would have judged at each of those frames, for the debug log
		answers = {}, -- the client's answer per damage frame
		answered = false,
		host_judged = false,
	}

	swings[swing.id] = swing

	return swing
end

-- aimed: whether the swing's player is the one the enemy attacks, whose screen turns the enemy. Only a family C swing
-- also reaches players it isn't aimed at.
local function send_begin(swing, blackboard, aimed)
	local action = swing.action
	local box_up, box_down, box_flat = 0, 0, 0

	if action.use_box_range then
		box_up = blackboard.attack_range_up or 0
		box_down = blackboard.attack_range_down or 0
		box_flat = blackboard.attack_range_flat or 0
	end

	local ok, scale = pcall(damage_scale, action, swing.target)

	pc.count("host_announced")

	if swing.family ~= "A" then
		pc.count("host_announced_" .. swing.family)
	end

	mod:network_send("pc_swing_begin", swing.peer, pc.VERSION, swing.id, swing.attacker_go_id, swing.family, swing.set_name, action.name, swing.attack_anim, box_up, box_down, box_flat, pc.finite(ok and scale or 1, 3), swing.step_name or "", aimed and true or false)
end

-- Runs once per attack, on the host: after BTAttackAction.enter for family A, after every
-- BTComboAttackAction._start_attack for family B, whose combos announce each step as its own swing, and after
-- BTStormVerminPushAction.enter for family D, an elite's shove.
local function announce(unit, blackboard, family, step_name)
	local action = blackboard.action
	local breed = blackboard.breed
	local combo = blackboard.combo_attack_data
	local attack_anim = blackboard.attack_anim
	local target, step

	if family == "B" then
		step = action and action.combo_attacks and action.combo_attacks[step_name]
		target = combo and combo.attacking_target

		if not step or not combo or combo.current_attack_name ~= step_name then
			return
		end
	else
		target = blackboard.attacking_target
	end

	-- A shove plays its animation without writing it to the blackboard; the host noted it as it played (D47).
	if family == "D" then
		attack_anim = pc.host_reactions.last_attack_anim(unit)
	end

	-- The vanilla damage frame does nothing without action.damage, and monsters and lords stay vanilla for now.
	if not target or not action or not action.damage or not breed or breed.boss or not attack_anim then
		return
	end

	local owner = Managers.player:unit_owner(target)
	local peer = owner and owner.remote and not owner.bot_player and owner.peer_id

	if not peer or not peer_is_fresh(peer) then
		return
	end

	local attacker_go_id = pc.network():unit_game_object_id(unit)
	local set_name = action_set_name(action, breed)

	if not attacker_go_id or not set_name then
		return
	end

	local swing = new_swing(unit, blackboard, family, action, breed, target, peer, attacker_go_id, set_name, attack_anim, pc.now(), step, step_name)

	by_attacker[unit] = swing

	send_begin(swing, blackboard, true)
end

-- Family C (D49, D50): an elite's sweep or overhead hits every player in a box in front of the enemy at its damage
-- frame (BTStormVerminAttackAction.anim_cb_damage, bt_storm_vermin_attack_action.lua:374). Every modded player gets a
-- swing of their own when the attack starts, wherever they are, and their own screen judges whether the box reaches
-- them (a far-off player's answer is a miss). So the host never judges a modded player's part in a sweep: its own box
-- test leaves them all out (the PhysicsWorld.immediate_overlap hook) and still hits bots, the host's own hero and
-- players without the mod. Runs after BTStormVerminAttackAction.enter.
local function announce_box(unit, blackboard)
	local action = blackboard.action
	local breed = blackboard.breed
	local attack_anim = pc.host_reactions.last_attack_anim(unit)

	boxes[unit] = nil

	-- The game's damage frame reaches the node only with action.damage (animation_callback_templates.lua:141).
	if not action or not action.damage or not breed or breed.boss or not attack_anim or blackboard.attacking_target_is_ai_breed then
		return
	end

	local attacker_go_id = pc.network():unit_game_object_id(unit)
	local set_name = action_set_name(action, breed)

	if not attacker_go_id or not set_name then
		return
	end

	local aimed_at = blackboard.attacking_target
	local group = {
		action = action,
		blackboard = blackboard,
		swings = {},
	}
	local t = pc.now()

	for _, player in pairs(Managers.player:human_players()) do
		local peer = player.remote and not player.bot_player and player.peer_id
		local player_unit = player.player_unit

		if peer and peer_is_fresh(peer) and player_unit and Unit.alive(player_unit) then
			local swing = new_swing(unit, blackboard, "C", action, breed, player_unit, peer, attacker_go_id, set_name, attack_anim, t)

			swing.group = group
			swing.aimed = player_unit == aimed_at
			group.swings[#group.swings + 1] = swing

			send_begin(swing, blackboard, swing.aimed)
		end
	end

	if #group.swings > 0 then
		boxes[unit] = group
	end
end

-- Family F: who the disabler is after, as each node records it in enter.
local function disabler_target(blackboard, kind)
	if kind == "hook" then
		return blackboard.drag_target_unit
	elseif kind == "grab" then
		return blackboard.corruptor_target
	end

	return blackboard.jump_data and blackboard.jump_data.target_unit
end

-- Family F (D52): a disabler's hook, grab or pounce, announced after the node's enter. The hook and the grab go to
-- their target, whose own screen judges them. A pounce goes to every modded player, because the sphere round the
-- gutter runner's neck catches whichever player it flies into (bt_crazy_jump_action.lua:415), aimed only for its
-- target, whose screen also judges the snap of its last 2.7 m.
local function announce_disabler(unit, blackboard, kind)
	local action = blackboard.action
	local breed = blackboard.breed
	local target = disabler_target(blackboard, kind)

	if kind == "pounce" then
		leaps[unit] = nil
	end

	if not action or not breed or breed.boss or not target then
		return
	end

	local attacker_go_id = pc.network():unit_game_object_id(unit)
	local set_name = action_set_name(action, breed)

	if not attacker_go_id or not set_name then
		return
	end

	local t = pc.now()
	local attack_anim = type(action.attack_anim) == "string" and action.attack_anim or kind

	if kind ~= "pounce" then
		local owner = Managers.player:unit_owner(target)
		local peer = owner and owner.remote and not owner.bot_player and owner.peer_id

		if not peer or not peer_is_fresh(peer) then
			return
		end

		local swing = new_swing(unit, blackboard, "F", action, breed, target, peer, attacker_go_id, set_name, attack_anim, t, nil, kind)

		swing.kind = kind
		by_attacker[unit] = swing

		send_begin(swing, blackboard, true)

		return
	end

	local group = {
		blackboard = blackboard,
		jump_data = blackboard.jump_data,
		swings = {},
		by_target = {},
	}

	for _, player in pairs(Managers.player:human_players()) do
		local peer = player.remote and not player.bot_player and player.peer_id
		local player_unit = player.player_unit

		if peer and peer_is_fresh(peer) and player_unit and Unit.alive(player_unit) then
			local swing = new_swing(unit, blackboard, "F", action, breed, player_unit, peer, attacker_go_id, set_name, attack_anim, t, nil, kind)

			swing.kind = kind
			swing.group = group
			swing.aimed = player_unit == target
			group.swings[#group.swings + 1] = swing
			group.by_target[player_unit] = swing

			send_begin(swing, blackboard, swing.aimed)
		end
	end

	if #group.swings == 0 then
		return
	end

	leaps[unit] = group

	-- In its last 2.7 m the host's leap would also catch its target in a wider zone than the sphere, the snap
	-- (bt_crazy_jump_action.lua:177), from where the host sees them. A modded target's own screen judges that, so the
	-- host's copy never snaps at them.
	if group.by_target[target] then
		group.jump_data.snap_failed = true
	end
end

-- Family F: what the packmaster's damage frame and BTPackMasterAttackAction.attack_success
-- (bt_pack_master_attack_action.lua:110) would have decided, for the debug log. Nothing here has side effects.
local function hook_would(swing, blackboard, unit)
	if blackboard.attack_aborted then
		return "aborted"
	end

	local target = swing.target
	local action = swing.action

	if not Unit.alive(target) or not DamageUtils.check_distance(action, blackboard, unit, target) or not DamageUtils.check_infront(unit, target) then
		return "miss"
	end

	local status = ScriptUnit.has_extension(target, "status_system")

	if status and (status:get_is_dodging() or status:is_invisible()) then
		local position = POSITION_LOOKUP[unit]
		local dodge_position = POSITION_LOOKUP[target]
		local direction = Vector3.normalize(Vector3.flat(dodge_position - position))
		local forward = Quaternion.forward(Unit.local_rotation(unit, 0))
		local angle = math.deg(math.acos(math.clamp(Vector3.dot(direction, forward), -1, 1)))

		if angle > action.dodge_angle or Vector3.distance_squared(position, dodge_position) >= action.dodge_distance * action.dodge_distance then
			return "miss"
		end
	end

	return PerceptionUtils.pack_master_has_line_of_sight_for_attack(blackboard.physics_world, unit, target) and "hit" or "miss"
end

-- Family F: what BTCorruptorGrabAction.grab_player (bt_corruptor_grab_action.lua:221) would have decided once the
-- host's own projectile arrived, without its grab_delay, for the debug log. Nothing here has side effects.
local function grab_would(swing, blackboard, unit)
	local target = swing.target
	local action = swing.action
	local self_position = POSITION_LOOKUP[unit]
	local target_position = POSITION_LOOKUP[target]

	if not self_position or not target_position or not blackboard.projectile_target_position then
		return "miss"
	end

	local target_distance_squared = Vector3.distance_squared(blackboard.projectile_target_position:unbox(), target_position)
	local status = blackboard.target_unit_status_extension
	local physics_world = World.physics_world(blackboard.world)

	if not action.ignore_dodge and blackboard.target_dodged or status and status:is_invisible() then
		local direction = Vector3.normalize(Vector3.flat(target_position - self_position))
		local forward = Quaternion.forward(Unit.local_rotation(unit, 0))
		local angle = math.deg(math.acos(math.clamp(Vector3.dot(direction, forward), -1, 1)))

		if Vector3.distance_squared(self_position, target_position) < action.min_dodge_angle_squared and angle <= action.dodge_angle or target_distance_squared < action.dodge_distance * action.dodge_distance then
			return PerceptionUtils.is_position_in_line_of_sight(unit, self_position, target_position, physics_world) and "hit" or "miss"
		end

		return "miss"
	elseif not not action.ignore_dodge and Vector3.distance_squared(self_position, target_position) > action.max_distance_squared or target_distance_squared > 25 then
		return "miss"
	end

	return PerceptionUtils.is_position_in_line_of_sight(unit, self_position + Vector3.up(), target_position + Vector3.up(), physics_world) and "hit" or "miss"
end

-- What vanilla would have decided at this frame. Nothing here has side effects.
local function would_have_judged(swing, blackboard, unit)
	if blackboard.attack_aborted then
		return "aborted"
	end

	local target = swing.target
	local action = swing.action
	local combo = swing.family == "B"

	-- A frenzy combo's damage frame checks neither line of sight nor unblockable (bt_combo_attack_action.lua:524), and
	-- a shove doesn't check line of sight (bt_storm_vermin_push_action.lua:99).
	if not Unit.alive(target) or swing.family == "A" and blackboard.has_line_of_sight == false then
		return "miss"
	end

	if not DamageUtils.check_distance(action, blackboard, unit, target) or not DamageUtils.check_infront(unit, target) then
		return "miss"
	end

	if combo or not action.unblockable then
		local status = ScriptUnit.has_extension(target, "status_system")

		if status and status:is_blocking() then
			local direction = action.attack_directions and action.attack_directions[blackboard.attack_anim]
			local buff_extension = ScriptUnit.has_extension(target, "buff_system")
			local invulnerable = buff_extension and buff_extension:has_buff_perk("invulnerable")
			local can_block = status:can_block(unit, direction)

			if can_block and not invulnerable then
				return "blocked"
			end
		end
	end

	return "hit"
end

-- D15 with /pingcomp combowait off: the follow-up of a combo step goes by what the host would have judged, as soon as
-- vanilla would choose it. A step whose block cuts it short does so at the host's damage frame, as in vanilla.
local function apply_guess(swing, blackboard, verdict)
	if swing.guessed or not in_combo_step(swing, blackboard) then
		return
	end

	swing.guessed = true

	local combo = blackboard.combo_attack_data

	if verdict == "hit" then
		combo.successful_hit = true
	elseif verdict == "blocked" then
		blackboard.blocked = false
		combo.blocked = true
	end
end

-- Whether the next move after this combo step depends on whether it landed or was blocked (two plague monk steps, in
-- the current game data). A step that a block cuts short (block_interrupts) needs no wait: the answer cuts it when it
-- arrives.
local function follow_up_depends(step)
	return step.next_hit ~= nil and step.next_hit ~= step.next or step.next_blocked ~= nil and step.next_blocked ~= step.next
end

-- Family C: what vanilla's box test would do at this frame for each player the attack was sent to, without its
-- effects: "hit", "blocked" or "miss" by player unit. The overlap goes through the hook below before host.box_skip is
-- set, so it sees everyone.
local function box_would(unit, blackboard, group)
	local centre, rotation, size = pc.geometry.elite_box(group.action, Unit.local_position(unit, 0), Unit.local_rotation(unit, 0))
	local inside = pc.geometry.units_in_box(Unit.world(unit), centre, rotation, size)
	local verdicts = {}

	for i = 1, #group.swings do
		local swing = group.swings[i]
		local target = swing.target
		local verdict = "miss"

		if Unit.alive(target) and inside[target] then
			verdict = "hit"

			local status = ScriptUnit.has_extension(target, "status_system")

			if status and status:is_blocking() and not group.action.unblockable then
				local direction = group.action.attack_directions and group.action.attack_directions[swing.attack_anim]
				local buff_extension = ScriptUnit.has_extension(target, "buff_system")
				local invulnerable = buff_extension and buff_extension:has_buff_perk("invulnerable")

				if status:can_block(unit, direction) and not invulnerable then
					verdict = "blocked"
				end
			end
		end

		verdicts[target] = verdict
	end

	return verdicts
end

-- Family C at the host's damage frame: notes the frame on each player's swing, and sets host.box_skip to the players
-- whose screens judge it. Returns the group, or nil to leave the whole frame to vanilla.
local function box_frame(unit, blackboard)
	local group = boxes[unit]

	if not group or blackboard ~= group.blackboard or blackboard.active_node ~= BTStormVerminAttackAction or blackboard.action ~= group.action then
		return nil
	end

	local ok, verdicts = pcall(box_would, unit, blackboard, group)
	local t = pc.now()
	local skip = nil

	for i = 1, #group.swings do
		local swing = group.swings[i]

		if not swing.host_judged and swing.frames < MAX_FRAMES then
			if peer_is_fresh(swing.peer) then
				local frame = swing.frames + 1

				swing.frames = frame
				swing.frame_t[frame] = t
				swing.expires = math.max(swing.expires, t + pc.SWING_LIFETIME)
				swing.would[frame] = ok and verdicts[swing.target] or "unknown"

				skip = skip or {}
				skip[swing.target] = true
			else
				-- That client has gone quiet, so the host's box test reaches them as in vanilla.
				swing.host_judged = true

				pc.count("host_judged_quiet_client")
			end
		end
	end

	if not skip then
		return nil
	end

	host.box_skip = skip

	return group
end

-- Called from the AnimationSystem.animation_callback hook when an enemy's anim_cb_damage (families A and C),
-- anim_cb_frenzy_damage (family B) or anim_cb_stormvermin_push (family D) fires on the host. Returns the swing whose
-- vanilla hit test must be skipped (for family C, the attack's group, with host.box_skip set), or nil to leave this
-- frame to vanilla. Everything here is plain table work, so it can't realistically fail halfway.
function host.before_damage_frame(unit, callback_name)
	if callback_name == "anim_cb_damage" and boxes[unit] then
		local blackboard = BLACKBOARDS[unit]

		if blackboard and blackboard.active_node == BTStormVerminAttackAction then
			return box_frame(unit, blackboard)
		end
	end

	local swing = by_attacker[unit]

	if not swing or swing.host_judged then
		return nil
	end

	local blackboard = BLACKBOARDS[unit]

	if not blackboard or blackboard ~= swing.blackboard then
		return nil
	end

	if swing.family == "B" then
		if callback_name ~= "anim_cb_frenzy_damage" or not in_combo_step(swing, blackboard) then
			return nil
		end
	elseif swing.family == "D" then
		if callback_name ~= "anim_cb_stormvermin_push" or blackboard.active_node ~= BTStormVerminPushAction or blackboard.action ~= swing.action or blackboard.attacking_target ~= swing.target then
			return nil
		end
	elseif swing.family == "F" then
		-- Only the hook has a damage frame, the generic one (animation_callback_templates.lua:132, whose target is the
		-- drag target here). A leech's damage frame only sends its projectile off, which goes on as in vanilla.
		if swing.kind ~= "hook" or callback_name ~= "anim_cb_damage" or blackboard.active_node ~= BTPackMasterAttackAction or blackboard.action ~= swing.action or blackboard.drag_target_unit ~= swing.target then
			return nil
		end
	elseif callback_name ~= "anim_cb_damage" or blackboard.active_node ~= BTAttackAction or blackboard.action ~= swing.action or blackboard.attacking_target ~= swing.target then
		return nil
	end

	if not peer_is_fresh(swing.peer) then
		-- The client has gone quiet for longer than PEER_EXPIRY, so this swing goes back to the host's own judgment.
		swing.host_judged = true

		pc.count("host_judged_quiet_client")

		return nil
	end

	local t = pc.now()
	local frame = swing.frames + 1

	swing.frames = frame
	swing.frame_t[frame] = t
	swing.expires = math.max(swing.expires, t + pc.SWING_LIFETIME)

	local ok, verdict = pcall(swing.family == "F" and hook_would or would_have_judged, swing, blackboard, unit)

	swing.would[frame] = ok and verdict or "unknown"

	-- Without the combo wait, a step whose block cuts it short goes by the host's own verdict now, as in vanilla.
	if swing.family == "B" and not pc.combowait and swing.step.block_interrupts and swing.would[frame] == "blocked" then
		apply_guess(swing, blackboard, "blocked")
	end

	return swing
end

-- D15: called before BTComboAttackAction.run. Returns true while the combo step's next move must wait for the
-- client's answer. Vanilla chooses it once the step's animation ends (attack_finished), from whether the step landed
-- or was blocked; here that is only known once the answer arrives, a round trip after the host's damage frame. With
-- /pingcomp combowait on the enemy holds the end of its animation until then, for at most pc.COMBO_WAIT, and then
-- goes with what the host would have judged. Damage and blocks always follow the answer.
function host.combo_hold(unit, blackboard, t)
	local swing = by_attacker[unit]

	if not swing or swing.family ~= "B" or not blackboard.attack_finished or swing.frames == 0 or swing.answers[1] or swing.host_judged or not follow_up_depends(swing.step) then
		return false
	end

	if blackboard ~= swing.blackboard or not in_combo_step(swing, blackboard) then
		return false
	end

	if pc.combowait then
		if not swing.wait_t then
			swing.wait_t = t

			pc.count("host_combo_waited")
		end

		if t - swing.wait_t < pc.COMBO_WAIT then
			return true
		end

		pc.count("host_combo_wait_ran_out")
		pc.log("host swing=%d enemy=%s combo step=%s: no answer within %.1fs, its next move goes by the host's guess (%s)", swing.id, swing.breed_name, tostring(swing.step_name), pc.COMBO_WAIT, tostring(swing.would[1]))
	end

	if not swing.guessed then
		pc.count("host_combo_guessed")
	end

	apply_guess(swing, blackboard, swing.would[1])

	return false
end

-- Family F: the disabler's hook or grab whose answer is still due, or nil.
local function waiting_disabler(unit, blackboard, kind)
	local swing = by_attacker[unit]

	if not swing or swing.family ~= "F" or swing.kind ~= kind or swing.host_judged or swing.answered or blackboard ~= swing.blackboard then
		return nil
	end

	return swing
end

-- Family F, called before BTPackMasterAttackAction.run: once the host's own copy of the hook has reached its damage
-- frame, the attack doesn't time out (bt_pack_master_attack_action.lua:105) until the target's answer arrives, for at
-- most pc.GRAB_WAIT. The answer comes a round trip after that frame, and a hit makes run go on to the pull.
function host.hook_hold(unit, blackboard, t)
	local swing = waiting_disabler(unit, blackboard, "hook")

	if not swing or swing.frames == 0 or t - swing.frame_t[1] >= pc.GRAB_WAIT then
		return
	end

	if blackboard.attack_time_ends and t + 0.05 > blackboard.attack_time_ends then
		blackboard.attack_time_ends = t + 0.05

		if not swing.grab_wait_t then
			swing.grab_wait_t = t

			pc.count("host_grab_waited")
		end
	end
end

-- Family F, called before BTCorruptorGrabAction.overlap_players: vanilla grabs once the host's own copy of the leech's
-- projectile is within 2 m of where it aimed (bt_corruptor_grab_action.lua:202). A modded target's screen judges that
-- with its own copy instead, so here the host only notes when its copy arrived, for the hold and the log. Returns true
-- to skip vanilla's test.
function host.grab_overlap(unit, blackboard, t)
	local swing = by_attacker[unit]

	if not swing or swing.family ~= "F" or swing.kind ~= "grab" or swing.host_judged or blackboard ~= swing.blackboard or blackboard.corruptor_target ~= swing.target then
		return false
	end

	if not peer_is_fresh(swing.peer) then
		-- That client has gone quiet, so the grab is the host's again.
		swing.host_judged = true

		pc.count("host_judged_quiet_client")

		return false
	end

	if swing.frames == 0 and blackboard.projectile_target_position and blackboard.projectile_position then
		local to_target = blackboard.projectile_target_position:unbox() - blackboard.projectile_position:unbox()

		if Vector3.length(Vector3.flat(to_target)) < 2 then
			local ok, verdict = pcall(grab_would, swing, blackboard, unit)

			swing.frames = 1
			swing.frame_t[1] = t
			swing.would[1] = ok and verdict or "unknown"
			swing.expires = math.max(swing.expires, t + pc.SWING_LIFETIME)
		end
	end

	return true
end

-- Family F, called before BTCorruptorGrabAction.run: once the host's own projectile has arrived, the attack doesn't
-- end with its animation (bt_corruptor_grab_action.lua:139) until the target's answer arrives, for at most
-- pc.GRAB_WAIT. Returns true while vanilla mustn't see that the animation has ended.
function host.grab_hold(unit, blackboard, t)
	local swing = waiting_disabler(unit, blackboard, "grab")

	if not swing or swing.frames == 0 or t - swing.frame_t[1] >= pc.GRAB_WAIT then
		return false
	end

	if not swing.grab_wait_t then
		swing.grab_wait_t = t

		pc.count("host_grab_waited")
	end

	return true
end

-- Family F, called around BTCrazyJumpAction.check_colliding_players: the modded players this leap was sent to, which
-- its sphere leaves out because their own screens judge it, or nil.
function host.leap_skip_for(unit)
	local group = leaps[unit]

	if not group then
		return nil
	end

	local skip = nil

	for i = 1, #group.swings do
		local swing = group.swings[i]

		if not swing.host_judged then
			if peer_is_fresh(swing.peer) then
				skip = skip or {}
				skip[swing.target] = true
			else
				-- That client has gone quiet, so the host's sphere reaches them as in vanilla.
				swing.host_judged = true

				pc.count("host_judged_quiet_client")
			end
		end
	end

	return skip
end

local function leap_answer_due(group)
	for i = 1, #group.swings do
		local swing = group.swings[i]

		if not swing.answered and not swing.host_judged then
			return true
		end
	end

	return false
end

-- Family F, called before BTCrazyJumpAction.run. Returns true when a modded player's screen said the leap pinned them:
-- run then ends the leap as vanilla does when its own test finds a player, and BTTargetPouncedAction teleports the
-- gutter runner onto them and pins them (bt_target_pounced_action.lua:15). Otherwise, once the leap has landed, it
-- doesn't end (bt_crazy_jump_action.lua:322) while an answer is still due, for at most pc.GRAB_WAIT.
function host.leap_before(unit, blackboard, t)
	local group = leaps[unit]
	local data = blackboard.jump_data

	if not group or blackboard ~= group.blackboard or not data or data ~= group.jump_data or group.left then
		return false
	end

	if group.pounce then
		data.target_unit = group.pounce
		blackboard.target_unit = group.pounce
		group.pounce = nil

		return true
	end

	if data.state == "landing" and data.land_time then
		group.land_t = group.land_t or t

		if t - group.land_t < pc.GRAB_WAIT and t + 0.05 > data.land_time and leap_answer_due(group) then
			data.land_time = t + 0.05

			if not group.waited then
				group.waited = true

				pc.count("host_grab_waited")
			end
		end
	end

	return false
end

-- The enemy that swung is no longer a networked unit on the host, which takes far longer than an answer normally
-- does. The hit still counts (decision D5), credited to the enemy's type. The game does the same for damage whose
-- attacker has gone: the victim stands in as the attacker unit and the damage source carries the name.
local function book_hit_without_attacker(swing)
	local target = swing.target
	local action = swing.action
	local damage = DamageUtils.calculate_damage(swing.damage, target, nil)
	local diminishing = action.diminishing_damage
	local slot_extension = ScriptUnit.has_extension(target, "ai_slot_system")

	if diminishing and slot_extension and slot_extension.has_slots_attached then
		local slots = slot_extension.delayed_num_occupied_slots
		local entry = slots and slots > 0 and diminishing[math.min(slots, 9)]

		if entry and entry.damage then
			damage = damage * entry.damage
		end
	end

	DamageUtils.add_damage_network(target, target, damage, "torso", action.damage_type, nil, Vector3(0, 0, -1), swing.breed_name, nil, nil, nil, action.hit_react_type, nil, nil, nil, nil, nil, true, 1)
end

local function book_hit(swing, through_block)
	local target = swing.target
	local attacker = swing.attacker
	local action = swing.action

	if not Unit.alive(target) then
		return "target gone"
	end

	-- Same enemy, alive or freshly dead, as long as it still has the network id it started the swing with.
	-- A pooled unit that has been recycled into a new enemy has a new id.
	if Unit.alive(attacker) and pc.network():unit_game_object_id(attacker) == swing.attacker_go_id then
		local blackboard = BLACKBOARDS[attacker]
		local same_enemy = blackboard ~= nil and blackboard == swing.blackboard

		if same_enemy and through_block then
			blackboard.hit_through_block = true
		end

		if swing.family == "B" then
			-- What BTComboAttackAction.anim_cb_frenzy_damage does for a hit (bt_combo_attack_action.lua:551): the step
			-- landed, which can change its next move, then the damage. Only while the enemy is still in that step.
			if same_enemy and in_combo_step(swing, blackboard) then
				blackboard.combo_attack_data.successful_hit = true

				local dialogue = ScriptUnit.has_extension(target, "dialogue_system")
				local surrounding = Managers.state.entity:system("surrounding_aware_system")

				if dialogue and dialogue.context and surrounding then
					pcall(surrounding.add_system_event, surrounding, attacker, "enemy_attack", DialogueSettings.armor_hit_broadcast_range, "attack_tag", "frenzy_attack_damage", "target_name", dialogue.context.player_profile)
				end
			end

			AiUtils.damage_target(target, attacker, action, swing.damage)

			return "booked"
		end

		AiUtils.damage_target(target, attacker, action, swing.damage)

		-- Vanilla calls this straight after the damage. It only makes sense while the enemy is still in that attack.
		if same_enemy and blackboard.active_node == BTAttackAction and blackboard.action == action and blackboard.attacking_target == target then
			blackboard.active_node:attack_success(attacker, blackboard)
		end

		return "booked"
	end

	local ok, message = pcall(book_hit_without_attacker, swing)

	if not ok then
		pc.print("host swing=%d could not book a hit without its attacker: %s", swing.id, tostring(message))

		return "failed"
	end

	return "booked without attacker"
end

-- recoil: what the client played for the enemy's recoil, or nil if it left the recoil to the host (D13).
local function book_block(swing, multiplier, improved, direction, recoil)
	local target = swing.target
	local attacker = swing.attacker
	local action = swing.action
	local reactions = pc.host_reactions

	if not Unit.alive(target) then
		reactions.recoil_refused(swing, recoil, "target gone")

		return "target gone"
	end

	local network = pc.network()

	if not Unit.alive(attacker) or network:unit_game_object_id(attacker) ~= swing.attacker_go_id then
		reactions.recoil_refused(swing, recoil, "attacker gone")

		return "attacker gone"
	end

	local fatigue_type = pc.fatigue_type(action, swing.step)
	local status = ScriptUnit.has_extension(target, "status_system")
	local target_go_id = Managers.state.unit_storage:go_id(target)
	local fatigue_type_id = NetworkLookup.fatigue_types[fatigue_type]

	-- The client has already played its own block. Show it on the host, then to every other client, which is what
	-- DamageUtils.check_block does, minus the message back to the blocker.
	if status and target_go_id and fatigue_type_id then
		status:blocked_attack(fatigue_type, attacker, multiplier, improved, direction)
		network.network_transmit:send_rpc_clients_except("rpc_player_blocked_attack", swing.peer, target_go_id, fatigue_type_id, swing.attacker_go_id, multiplier, improved, direction, false)
	end

	local blackboard = BLACKBOARDS[attacker]
	local recoil_outcome = "no recoil"

	-- A blocked combo step has no recoil. What BTComboAttackAction.anim_cb_frenzy_damage does for a block
	-- (bt_combo_attack_action.lua:544): the step was blocked, which can cut it short and changes its next move. Only
	-- while the enemy is still in that step.
	if swing.family == "B" then
		reactions.recoil_refused(swing, recoil, "a combo step has no recoil")

		if blackboard and blackboard == swing.blackboard and HEALTH_ALIVE[attacker] and in_combo_step(swing, blackboard) then
			blackboard.blocked = false
			blackboard.combo_attack_data.blocked = true

			return "booked, the combo step was blocked"
		end

		return "booked, the combo had moved on"
	end

	if blackboard and blackboard == swing.blackboard and HEALTH_ALIVE[attacker] then
		if blackboard.active_node == BTAttackAction and blackboard.action == action and blackboard.attacking_target == target then
			blackboard.active_node:attack_blocked(attacker, blackboard, direction)
		end

		-- The enemy's recoil. If it has already started another swing, this cancels that swing (decision D13).
		-- One that is already recoiling or staggered gets no new recoil, here or in vanilla.
		if not action.no_block_stagger and not blackboard.stagger and not blackboard.blocked then
			blackboard.blocked = true
			recoil_outcome = reactions.recoil_booked(swing, blackboard, recoil)
		else
			reactions.recoil_refused(swing, recoil, "already recoiling or staggered")
		end
	else
		reactions.recoil_refused(swing, recoil, "enemy dead or recycled")
	end

	return "booked, " .. recoil_outcome
end

-- Whether the enemy that swung is still the one that started the swing: alive or freshly dead, with the network id
-- it had. A pooled unit recycled into a new enemy has a new id.
local function same_attacker(swing)
	local attacker = swing.attacker

	return Unit.alive(attacker) and pc.network():unit_game_object_id(attacker) == swing.attacker_go_id
end

-- Family C: what the box test does for one player it reached (bt_storm_vermin_attack_action.lua:420), for that
-- player's answer: the damage or, through a block, the blocked damage, the guard-break line, the catapult (which also
-- damages a player who didn't block, bt_storm_vermin_attack_action.lua:531) and the push. A block itself is booked
-- first by book_block.
local function book_box(swing, blocked, through_block)
	local target = swing.target
	local attacker = swing.attacker
	local action = swing.action

	if not Unit.alive(target) then
		return "target gone"
	end

	if not same_attacker(swing) then
		if blocked then
			return "attacker gone"
		end

		local ok, message = pcall(book_hit_without_attacker, swing)

		if not ok then
			pc.print("host swing=%d could not book a hit without its attacker: %s", swing.id, tostring(message))

			return "failed"
		end

		return "booked without attacker"
	end

	local blackboard = BLACKBOARDS[attacker]

	if through_block and blackboard and blackboard == swing.blackboard then
		blackboard.hit_through_block = true
	end

	if action.damage then
		if not blocked then
			AiUtils.damage_target(target, attacker, action, action.damage)
		elseif action.blocked_damage then
			AiUtils.damage_target(target, attacker, action, action.blocked_damage)
		end

		if blocked and action.fatigue_type == "complete" then
			pcall(function ()
				SurroundingAwareSystem.add_event(target, "breaking_hit", DialogueSettings.grabbed_broadcast_range, "profile_name", ScriptUnit.extension(target, "dialogue_system").context.player_profile)
			end)
		end
	end

	if action.catapult and blackboard then
		BTStormVerminAttackAction.catapult_enemy(attacker, blackboard, action, target, blocked)
	end

	local push_speed = action.push and action.player_push_speed
	local status = ScriptUnit.has_extension(target, "status_system")
	local locomotion = ScriptUnit.has_extension(target, "locomotion_system")

	if push_speed and status and not status.knocked_down and locomotion then
		local direction = Vector3.normalize(POSITION_LOOKUP[target] - POSITION_LOOKUP[attacker])

		locomotion:add_external_velocity(push_speed * direction, action.max_player_push_speed)
	end

	return blocked and "blocked damage booked" or "booked"
end

-- Family D: what an elite's shove does after its reach and cone test (bt_storm_vermin_push_action.lua:104): the
-- damage, the pushed state and the knockback along the enemy's facing.
local function book_shove(swing)
	local target = swing.target
	local attacker = swing.attacker
	local action = swing.action

	if not Unit.alive(target) then
		return "target gone"
	end

	if not same_attacker(swing) then
		local ok, message = pcall(book_hit_without_attacker, swing)

		if not ok then
			pc.print("host swing=%d could not book a shove without its attacker: %s", swing.id, tostring(message))

			return "failed"
		end

		return "booked without attacker"
	end

	AiUtils.damage_target(target, attacker, action, action.damage)

	local status = ScriptUnit.has_extension(target, "status_system")
	local locomotion = ScriptUnit.has_extension(target, "locomotion_system")

	if status and not status:is_disabled() and locomotion then
		StatusUtils.set_pushed_network(target, true)

		if action.impact_push_speed then
			locomotion:add_external_velocity(Quaternion.forward(Unit.local_rotation(attacker, 0)) * action.impact_push_speed, action.max_impact_push_speed)
		end
	end

	return "booked"
end

-- Family F: a hook, grab or pounce that landed on its target's screen (D52), where it already shows (D53). The
-- disabler goes on as vanilla does when its own test finds the player: the pull, the grab or the pin. Only while it
-- still can here: alive, not staggered and still in that attack. Either way the client hears of it, and undoes what it
-- showed if the host refused.
local function book_disabler(swing)
	local attacker = swing.attacker
	local target = swing.target
	local blackboard = BLACKBOARDS[attacker]
	local refused = nil

	if not Unit.alive(target) then
		refused = "target gone"
	elseif not same_attacker(swing) or not HEALTH_ALIVE[attacker] then
		refused = "the special is dead"
	elseif not blackboard or blackboard ~= swing.blackboard then
		refused = "the special is gone"
	elseif blackboard.stagger then
		refused = "the special is staggered"
	elseif swing.kind == "hook" then
		if blackboard.active_node ~= BTPackMasterAttackAction or blackboard.action ~= swing.action or blackboard.drag_target_unit ~= target or blackboard.attack_aborted then
			refused = "the hook was over"
		else
			-- What the damage frame and attack_success do for a hook that lands (animation_callback_templates.lua:216,
			-- bt_pack_master_attack_action.lua:110): the damage (none, for the packmaster), then run goes on to the pull.
			AiUtils.damage_target(target, attacker, swing.action, swing.action.damage)

			blackboard.attack_success = true
		end
	elseif swing.kind == "grab" then
		if blackboard.active_node ~= BTCorruptorGrabAction or blackboard.action ~= swing.action or blackboard.corruptor_target ~= target or blackboard.grabbed_unit or blackboard.attack_aborted then
			refused = "the grab was over"
		else
			-- What grab_player does for a grab that lands (bt_corruptor_grab_action.lua:274); run grabs the player next.
			blackboard.grabbed_unit = target
			blackboard.attack_success = true
		end
	else
		local group = swing.group

		if not group or leaps[attacker] ~= group or group.left or group.pounced or blackboard.jump_data ~= group.jump_data then
			refused = "the leap was over"
		else
			group.pounce = target
			group.pounced = true
		end
	end

	mod:network_send("pc_reaction_ack", swing.peer, pc.VERSION, "grab", swing.id, refused and "rejected" or "applied")
	pc.count(refused and "host_grab_refused" or "host_grab_booked")

	return refused and "refused: " .. refused or "booked"
end

local function valid_answer(id, frame, result, multiplier, improved, direction, through_block, distance, angle, recoil_anim, has_position, x, y, z, yaw)
	return type(id) == "number" and type(frame) == "number" and frame >= 1 and frame <= MAX_FRAMES and frame == math.floor(frame)
		and RESULTS[result] == true and type(multiplier) == "number" and multiplier == multiplier and multiplier >= 0 and multiplier <= 100
		and type(improved) == "boolean" and type(direction) == "string" and #direction <= MAX_DIRECTION_LENGTH
		and type(through_block) == "boolean" and type(distance) == "number" and type(angle) == "number"
		and type(recoil_anim) == "string" and #recoil_anim <= MAX_ANIMATION_LENGTH and type(has_position) == "boolean"
		and type(x) == "number" and type(y) == "number" and type(z) == "number" and type(yaw) == "number"
		and x == x and y == y and z == z and yaw == yaw
end

local function player_name(peer)
	local player = Managers.player and Managers.player:player_from_peer_id(peer)

	return player and player:name() or tostring(peer)
end

host.player_name = player_name

-- fingerprint: the client's fingerprint of its enemy data (Compat.lua). Only a client whose enemy data is the host's
-- decides its own hits (D34); the host and that player are told when that changes.
mod:network_register("pc_hello", function (sender, version, attacks, fingerprint)
	if not pc.is_server() then
		return
	end

	if version == pc.VERSION then
		local own = pc.compat.fingerprint()
		local matched = type(fingerprint) == "string" and fingerprint == own
		local record = peers[sender] or {}
		local now = pc.clock()

		-- Their hits are decided here from the first hello that differs. The warning waits, because a difficulty mod
		-- switched here takes a hello or two to be switched on their side as well.
		if matched then
			if record.warned then
				pc.say("%s's enemy data matches yours again. Their hits are decided on their screen.", player_name(sender))
			end

			record.differs_since = nil
			record.warned = nil
		else
			record.differs_since = record.differs_since or now

			if not record.warned and now - record.differs_since >= pc.compat.WARN_AFTER then
				record.warned = true

				pc.say("%s's enemy data differs from yours (%s), for example a difficulty mod that one of you doesn't run. Their hits are decided here until it matches.", player_name(sender), pc.compat.differences(own, fingerprint))
			end
		end

		record.t = now
		record.attacks = attacks == true
		record.matched = matched
		peers[sender] = record

		-- The client predicts nothing until it hears this: only a host with the same build applies what it decides.
		-- It also learns the host's fingerprint and difficulty mods, and whether its own fingerprint matched.
		mod:network_send("pc_hello_reply", sender, pc.VERSION, own, pc.compat.active_toggles(), matched)
	elseif not mismatched[sender] then
		mismatched[sender] = true

		local player = Managers.player and Managers.player:player_from_peer_id(sender)
		local name = player and player:name() or tostring(sender)

		pc.say("%s runs a different build of Ping Compensation, so the game judges them as vanilla. Compare builds with /pingcomp version.", name)
	end
end)

mod:network_register("pc_swing_answer", function (sender, version, id, frame, result, multiplier, improved, direction, through_block, distance, angle, recoil_anim, has_position, x, y, z, yaw)
	if not pc.is_server() or not pc.in_game() or version ~= pc.VERSION then
		return
	end

	if not valid_answer(id, frame, result, multiplier, improved, direction, through_block, distance, angle, recoil_anim, has_position, x, y, z, yaw) then
		pc.count("host_rejected")
		pc.print("host rejected a malformed answer from %s", player_name(sender))

		return
	end

	local swing = swings[id]

	-- Unknown swing, someone else's swing, one the host already judged itself, or a second answer for the same frame.
	if not swing or swing.peer ~= sender or swing.host_judged or swing.answers[frame] then
		pc.count("host_ignored")

		return
	end

	swing.answers[frame] = result
	swing.answered = true

	local outcome = "nothing to book"

	-- What follows books what the client reported, which the damage-alone log leaves out (host.damage_alone).
	host.booking = true

	if result == "hit" then
		if swing.family == "C" then
			outcome = book_box(swing, false, through_block)
		elseif swing.family == "D" then
			outcome = book_shove(swing)
		elseif swing.family == "F" then
			outcome = book_disabler(swing)
		else
			outcome = book_hit(swing, through_block)
		end
	elseif result == "blocked" and swing.family ~= "F" then
		-- A disabler's hook, grab or pounce can't be blocked, so a client never says so.
		local recoil = recoil_anim ~= "" and {
			anim = recoil_anim,
			position = has_position and Vector3(x, y, z) or nil,
			yaw = yaw,
			frame_t = swing.frame_t[frame],
		} or nil

		-- For the log line of a recoil left to the host (HostReactions.recoil_ended).
		swing.blocked_frame_t = swing.frame_t[frame]
		outcome = book_block(swing, multiplier, improved, direction, recoil)

		-- An elite's sweep still does its blocked damage, catapult and push after a block.
		if swing.family == "C" then
			outcome = outcome .. ", " .. book_box(swing, true, false)
		end
	end

	host.booking = false

	local t = pc.now()
	local frame_t = swing.frame_t[frame]
	local would = swing.would[frame] or "n/a"

	pc.count("host_answers")
	pc.count("host_" .. result)

	if frame_t then
		pc.count("host_answer_time_sum", t - frame_t)
		pc.count("host_answer_time_n")
	end

	-- The combo step held the end of its animation for this answer (D15).
	if swing.wait_t and not swing.guessed then
		pc.count("host_combo_wait_sum", t - swing.wait_t)
		pc.count("host_combo_wait_n")
	end

	-- A cut-short swing never reached the client's damage frame, so it has no verdict to compare.
	local disagree = would ~= "n/a" and would ~= "unknown" and result ~= "cut" and result ~= "unjudged" and would ~= result
		and not (would == "aborted" and result == "miss")

	if disagree then
		pc.count("host_disagree")
	end

	if pc.debug then
		local ping = pc.network():ping_by_peer(sender)

		pc.log("host swing=%d enemy=%s attack=%s%s frame=%d answer=%s host_would=%s outcome=%s answer_after=%s ping=%s client_distance=%.2f client_angle=%.1f%s", swing.id, swing.breed_name, tostring(swing.action.name), swing.step_name and "/" .. swing.step_name or "", frame, result, would, outcome,
			frame_t and string.format("%.3fs", t - frame_t) or "n/a", type(ping) == "number" and string.format("%.0fms", ping * 1000) or "n/a", distance, angle,
			swing.wait_t and string.format(" combo_wait=%s", swing.guessed and "ran out" or string.format("%.3fs", t - swing.wait_t)) or swing.grab_wait_t and string.format(" grab_wait=%.3fs", t - swing.grab_wait_t) or "")

	end

	if disagree and pc.echo then
		pc.chat("swing %d (%s): client says %s, host would have said %s", swing.id, swing.breed_name, result, would)
	end
end)

mod:hook_safe("BTAttackAction", "enter", function (self, unit, blackboard, t)
	if pc.broken or not pc.is_server() or not pc.in_game() then
		return
	end

	-- BTAttackAction.leave clears blackboard.attack_anim before a recoil begins, and recoil cues are looked up and
	-- measured by the attack that was blocked (Timings.lua, D43).
	pc.host_reactions.note_attack(unit, blackboard.attack_anim)
	announce(unit, blackboard, "A")
end)

-- Family B: every step of a frenzy combo starts here, the first from enter and the rest from run.
mod:hook_safe("BTComboAttackAction", "_start_attack", function (self, unit, blackboard, t, action, attack_name)
	if pc.broken or not pc.is_server() or not pc.in_game() then
		return
	end

	announce(unit, blackboard, "B", attack_name)
end)

-- Family C (D49): an elite's sweep or overhead starts here, with its animation already played and noted.
mod:hook_safe("BTStormVerminAttackAction", "enter", function (self, unit, blackboard, t)
	if pc.broken or not pc.is_server() or not pc.in_game() then
		return
	end

	announce_box(unit, blackboard)
end)

-- Family D (D49): an elite's shove.
mod:hook_safe("BTStormVerminPushAction", "enter", function (self, unit, blackboard, t)
	if pc.broken or not pc.is_server() or not pc.in_game() then
		return
	end

	announce(unit, blackboard, "D")
end)

-- Family F (D52): a disabler's hook, grab or pounce starts here.
for node_name, kind in pairs(pc.DISABLER_KINDS) do
	mod:hook_safe(node_name, "enter", function (self, unit, blackboard, t)
		if pc.broken or not pc.is_server() or not pc.in_game() then
			return
		end

		announce_disabler(unit, blackboard, kind)
	end)
end

-- Family F: the hook's answer is waited for (host.hook_hold). Runs everything but the original through pc.guard.
mod:hook("BTPackMasterAttackAction", "run", function (func, self, unit, blackboard, t, dt)
	if not pc.broken then
		pc.guard("host hook wait", host.hook_hold, unit, blackboard, t)
	end

	return func(self, unit, blackboard, t, dt)
end)

-- Family F: a modded target's screen judges the leech's grab, so vanilla's test is skipped (host.grab_overlap).
mod:hook("BTCorruptorGrabAction", "overlap_players", function (func, self, unit, t, dt, blackboard)
	if not pc.broken then
		local ok, skip = pc.guard("host grab test", host.grab_overlap, unit, blackboard, t)

		if ok and skip then
			return
		end
	end

	return func(self, unit, t, dt, blackboard)
end)

-- Family F: the grab's answer is waited for (host.grab_hold): vanilla's run mustn't see that the attack's animation
-- has ended until then.
mod:hook("BTCorruptorGrabAction", "run", function (func, self, unit, blackboard, t, dt)
	if pc.broken or not blackboard.attack_finished then
		return func(self, unit, blackboard, t, dt)
	end

	local ok, hold = pc.guard("host grab wait", host.grab_hold, unit, blackboard, t)

	if not ok or not hold then
		return func(self, unit, blackboard, t, dt)
	end

	blackboard.attack_finished = false

	local result = func(self, unit, blackboard, t, dt)

	blackboard.attack_finished = true

	return result
end)

-- Family F: the leap's sphere leaves out the modded players its swings went to (host.leap_skip, used up by the overlap
-- hook below).
mod:hook("BTCrazyJumpAction", "check_colliding_players", function (func, self, unit, blackboard, pos)
	if pc.broken then
		return func(self, unit, blackboard, pos)
	end

	local ok, skip = pc.guard("host leap filter", host.leap_skip_for, unit)

	if not ok or not skip then
		return func(self, unit, blackboard, pos)
	end

	host.leap_skip = skip

	local hit_unit = func(self, unit, blackboard, pos)

	host.leap_skip = nil

	return hit_unit
end)

-- Family F: a pounce a modded player's screen saw ends the leap with them as its target, as vanilla's run does when its
-- own test finds a player (bt_crazy_jump_action.lua:203), and a leap whose answers are due is held (host.leap_before).
mod:hook("BTCrazyJumpAction", "run", function (func, self, unit, blackboard, t, dt)
	if pc.broken or not leaps[unit] then
		return func(self, unit, blackboard, t, dt)
	end

	local ok, pounce = pc.guard("host leap wait", host.leap_before, unit, blackboard, t)

	if ok and pounce then
		return "done"
	end

	return func(self, unit, blackboard, t, dt)
end)

-- Family F: the leap is over, whichever way, so a later answer can't pin anyone.
mod:hook_safe("BTCrazyJumpAction", "leave", function (self, unit, blackboard, t, reason, destroy)
	local group = leaps[unit]

	if group and group.blackboard == blackboard then
		group.left = true
	end
end)

local function without_skipped(actors, skip)
	local kept = {}

	for i = 1, #actors do
		local unit = Actor.unit(actors[i])

		if not unit or not skip[unit] then
			kept[#kept + 1] = actors[i]
		end
	end

	return kept, #kept
end

-- Family C: while host.box_skip is set, an elite's box test is running (bt_storm_vermin_attack_action.lua:393), and
-- its overlap leaves out the players whose own screens judge the swing. Only that one overlap, the one that looks for
-- player hit boxes (its 13th argument): host.box_skip is cleared as it is used. Family F: the same with host.leap_skip
-- for a gutter runner's leap test (bt_crazy_jump_action.lua:418), whose sphere looks for players' triggers (its 11th
-- argument). A mod:hook on an engine function the whole game calls, so every other call goes straight through, and
-- its own work runs through pc.guard.
mod:hook(PhysicsWorld, "immediate_overlap", function (func, ...)
	local skip = nil

	if host.box_skip and select(13, ...) == "filter_player_hit_box_check" then
		skip = host.box_skip
		host.box_skip = nil
	elseif host.leap_skip and select(11, ...) == "filter_player_and_husk_trigger" then
		skip = host.leap_skip
		host.leap_skip = nil
	else
		return func(...)
	end

	local actors, count = func(...)

	if type(actors) ~= "table" then
		return actors, count
	end

	local ok, kept, kept_count = pc.guard("host box filter", without_skipped, actors, skip)

	if ok then
		return kept, kept_count
	end

	return actors, count
end)

-- D15: while the step's next move waits for the client's answer, vanilla's run must not see that the step's
-- animation has ended. This is a mod:hook, so everything except the original call runs through pc.guard.
mod:hook("BTComboAttackAction", "run", function (func, self, unit, blackboard, t, dt)
	if pc.broken or not blackboard.attack_finished then
		return func(self, unit, blackboard, t, dt)
	end

	local ok, hold = pc.guard("host combo wait", host.combo_hold, unit, blackboard, t)

	if not ok or not hold then
		return func(self, unit, blackboard, t, dt)
	end

	blackboard.attack_finished = false

	local result = func(self, unit, blackboard, t, dt)

	blackboard.attack_finished = true

	return result
end)

-- While a swing is in host.suppress, vanilla's own damage frame stops at its reach test and never gets to the block
-- or the damage. Its bookkeeping before that point (cooldown, "the swing has passed") still runs.
mod:hook("DamageUtils", "check_distance", function (func, action, blackboard, attacker, target)
	local swing = host.suppress

	if swing and swing.attacker == attacker and swing.target == target and swing.action == action then
		return false
	end

	return func(action, blackboard, attacker, target)
end)

-- D56: damage the host books on a modded player that didn't come from that player's own report. Every attack the
-- mod doesn't judge on the player's screen yet shows up here (monsters until build 6, damage over time, falls), and so
-- does what follows a grab a client reported, such as the packmaster's drag and the leech's drain: the attacker's
-- action tells them apart. So one session's logs show every gap that is left.
function host.damage_alone(unit, attacker, amount, damage_type, source)
	local peer = host.client_judges(unit)

	if not peer or type(amount) ~= "number" or amount <= 0 then
		return
	end

	pc.count("host_damage_alone")
	pc.count("host_damage_alone_" .. tostring(source))

	if pc.debug then
		local breed = attacker and Unit.alive(attacker) and Unit.get_data(attacker, "breed")
		local blackboard = attacker and BLACKBOARDS[attacker]
		local action = blackboard and type(blackboard.action) == "table" and blackboard.action.name

		pc.log("host damage alone target=%s amount=%.2f type=%s source=%s attacker=%s action=%s", player_name(peer), amount, tostring(damage_type), tostring(source), breed and breed.name or attacker and "unit" or "none", tostring(action))
	end
end

-- The host books every player's damage on its own copy of their health (player_unit_health_extension.lua:530).
mod:hook_safe("PlayerUnitHealthExtension", "add_damage", function (self, attacker_unit, damage_amount, hit_zone_name, damage_type, hit_position, damage_direction, damage_source_name)
	if host.booking or pc.broken or not pc.is_server() or not pc.in_game() then
		return
	end

	pc.guard("host damage alone", host.damage_alone, self.unit, attacker_unit, damage_amount, damage_type, damage_source_name)
end)

function host.update()
	host.suppress = nil
	host.box_skip = nil
	host.leap_skip = nil
	host.booking = false

	if not pc.is_server() or not pc.in_game() then
		return
	end

	pc.guard("host reactions update", pc.host_reactions.update)
	pc.guard("host blasts update", pc.blasts.update)

	local t = pc.now()

	for id, swing in pairs(swings) do
		if t > swing.expires then
			-- The host's copy landed, the client never said anything, and the host didn't judge it either.
			if swing.frames > 0 and not swing.answered and not swing.host_judged then
				pc.count("host_unanswered")
				pc.count("host_unanswered_" .. swing.breed_name)
				pc.log("host swing=%d enemy=%s attack=%s was never answered", swing.id, swing.breed_name, tostring(swing.action.name))

				if pc.echo then
					pc.chat("swing %d (%s) was never answered by the client", swing.id, swing.breed_name)
				end
			end

			swings[id] = nil

			if by_attacker[swing.attacker] == swing then
				by_attacker[swing.attacker] = nil
			end

			local group = boxes[swing.attacker]

			if group and swing.group == group and group.swings[1] == swing then
				boxes[swing.attacker] = nil
			end

			local leap = leaps[swing.attacker]

			if leap and swing.group == leap and leap.swings[1] == swing then
				leaps[swing.attacker] = nil
			end
		end
	end
end

function host.clear()
	peers = {}
	mismatched = {}
	swings = {}
	by_attacker = {}
	boxes = {}
	leaps = {}
	host.suppress = nil
	host.box_skip = nil
	host.leap_skip = nil
	host.booking = false

	pc.host_reactions.clear()
	pc.blasts.clear()

	if pc.areas then
		pc.areas.host_clear()
	end
end

function host.modded_peer_count()
	local count, matching = 0, 0

	for peer, record in pairs(peers) do
		if peer_is_fresh(peer) then
			count = count + 1

			if record.matched then
				matching = matching + 1
			end
		end
	end

	return count, matching
end
