local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Host side. The host still runs every enemy. For a swing aimed at a remote player who runs this mod it:
--   1. announces the swing to that player when the attack starts,
--   2. skips its own hit test when its copy of the swing reaches the damage frame,
--   3. books whatever the player's client answers: damage for a hit, the block for a block, nothing for a miss.
-- Bots, the host's own hero and players without the mod never get a record here, so they stay vanilla.

local host = {
	suppress = nil, -- the swing whose vanilla hit test is being skipped right now
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
local by_attacker = {} -- enemy unit -> its newest record
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

-- Runs after BTAttackAction.enter, once per attack, on the host.
local function announce(unit, blackboard)
	local target = blackboard.attacking_target
	local action = blackboard.action
	local breed = blackboard.breed

	-- The vanilla damage frame does nothing without action.damage, and monsters and lords stay vanilla for now.
	if not target or not action or not action.damage or not breed or breed.boss or not blackboard.attack_anim then
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

	local t = pc.now()

	next_id = next_id + 1

	local swing = {
		id = next_id,
		peer = peer,
		attacker = unit,
		attacker_go_id = attacker_go_id,
		target = target,
		action = action,
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
	by_attacker[unit] = swing

	local box_up, box_down, box_flat = 0, 0, 0

	if action.use_box_range then
		box_up = blackboard.attack_range_up or 0
		box_down = blackboard.attack_range_down or 0
		box_flat = blackboard.attack_range_flat or 0
	end

	local ok, scale = pcall(damage_scale, action, target)

	pc.count("host_announced")
	mod:network_send("pc_swing_begin", peer, pc.VERSION, swing.id, attacker_go_id, "A", set_name, action.name, blackboard.attack_anim, box_up, box_down, box_flat, pc.finite(ok and scale or 1, 3))
end

-- What vanilla would have decided at this frame. Nothing here has side effects.
local function would_have_judged(swing, blackboard, unit)
	if blackboard.attack_aborted then
		return "aborted"
	end

	local target = swing.target
	local action = swing.action

	if not Unit.alive(target) or blackboard.has_line_of_sight == false then
		return "miss"
	end

	if not DamageUtils.check_distance(action, blackboard, unit, target) or not DamageUtils.check_infront(unit, target) then
		return "miss"
	end

	if not action.unblockable then
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

-- Called from the AnimationSystem.animation_callback hook when an enemy's anim_cb_damage fires on the host.
-- Returns the swing whose vanilla hit test must be skipped, or nil to leave this frame to vanilla.
-- Everything here is plain table work, so it can't realistically fail halfway.
function host.before_damage_frame(unit)
	local swing = by_attacker[unit]

	if not swing or swing.host_judged then
		return nil
	end

	local blackboard = BLACKBOARDS[unit]

	if not blackboard or blackboard ~= swing.blackboard or blackboard.active_node ~= BTAttackAction or blackboard.action ~= swing.action or blackboard.attacking_target ~= swing.target then
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

	local ok, verdict = pcall(would_have_judged, swing, blackboard, unit)

	swing.would[frame] = ok and verdict or "unknown"

	return swing
end

-- The enemy that swung is no longer a networked unit on the host, which takes far longer than an answer normally
-- does. The hit still counts (decision D5), credited to the enemy's type. The game does the same for damage whose
-- attacker has gone: the victim stands in as the attacker unit and the damage source carries the name.
local function book_hit_without_attacker(swing)
	local target = swing.target
	local action = swing.action
	local damage = DamageUtils.calculate_damage(action.damage, target, nil)
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

		AiUtils.damage_target(target, attacker, action, action.damage)

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

	local fatigue_type = action.fatigue_type

	if type(fatigue_type) == "table" then
		fatigue_type = Managers.state.difficulty:get_difficulty_value_from_table(fatigue_type)
	end

	if not fatigue_type or not PlayerUnitStatusSettings.fatigue_point_costs[fatigue_type] then
		fatigue_type = "blocked_attack"
	end

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

		if not matched and record.matched ~= false then
			pc.say("%s's enemy data differs from yours (%s), for example a difficulty mod that one of you doesn't run. Their hits are decided here until it matches.", player_name(sender), pc.compat.differences(own, fingerprint))
		elseif matched and record.matched == false then
			pc.say("%s's enemy data matches yours again. Their hits are decided on their screen.", player_name(sender))
		end

		record.t = pc.clock()
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

	if result == "hit" then
		outcome = book_hit(swing, through_block)
	elseif result == "blocked" then
		local recoil = recoil_anim ~= "" and {
			anim = recoil_anim,
			position = has_position and Vector3(x, y, z) or nil,
			yaw = yaw,
			frame_t = swing.frame_t[frame],
		} or nil

		outcome = book_block(swing, multiplier, improved, direction, recoil)
	end

	local t = pc.now()
	local frame_t = swing.frame_t[frame]
	local would = swing.would[frame] or "n/a"

	pc.count("host_answers")
	pc.count("host_" .. result)

	if frame_t then
		pc.count("host_answer_time_sum", t - frame_t)
		pc.count("host_answer_time_n")
	end

	-- A cut-short swing never reached the client's damage frame, so it has no verdict to compare.
	local disagree = would ~= "n/a" and would ~= "unknown" and result ~= "cut" and result ~= "unjudged" and would ~= result
		and not (would == "aborted" and result == "miss")

	if disagree then
		pc.count("host_disagree")
	end

	if pc.debug then
		local ping = pc.network():ping_by_peer(sender)

		pc.log("host swing=%d enemy=%s attack=%s frame=%d answer=%s host_would=%s outcome=%s answer_after=%s ping=%s client_distance=%.2f client_angle=%.1f", swing.id, swing.breed_name, tostring(swing.action.name), frame, result, would, outcome,
			frame_t and string.format("%.3fs", t - frame_t) or "n/a", type(ping) == "number" and string.format("%.0fms", ping * 1000) or "n/a", distance, angle)

	end

	if disagree and pc.echo then
		pc.chat("swing %d (%s): client says %s, host would have said %s", swing.id, swing.breed_name, result, would)
	end
end)

mod:hook_safe("BTAttackAction", "enter", function (self, unit, blackboard, t)
	if pc.broken or not pc.is_server() or not pc.in_game() then
		return
	end

	announce(unit, blackboard)
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

function host.update()
	host.suppress = nil

	if not pc.is_server() or not pc.in_game() then
		return
	end

	pc.guard("host reactions update", pc.host_reactions.update)

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
		end
	end
end

function host.clear()
	peers = {}
	mismatched = {}
	swings = {}
	by_attacker = {}
	host.suppress = nil

	pc.host_reactions.clear()
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
