local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Client side of decision D11: when this client judges that an enemy's swing hit its player, the results show at once
-- instead of a ping later.
--   * Feedback: the game's own client code for a hit on this player runs now (PlayerUnitHealthExtension.add_damage,
--     which HealthSystem.rpc_add_damage calls when the host's damage message arrives): damage indicator, flinch,
--     rumble, the enemy's weapon sound. The host's message for that hit is then dropped, so nothing plays twice.
--   * Knockback, and the push a blocked swing gives: applied now; the host's copy is dropped.
--   * Catapults and knock-downs (build 6, D62): the player's own catapulted or knocked-down state starts now; the
--     host's copy is dropped. A catapult shown here reaches everyone else at once too: the player's own machine sends
--     it to the host, which passes it on (GenericStatusExtension.set_catapulted, generic_status_extension.lua:1660).
--   * HP bar: shows an estimate until the host's number arrives. Only the HUD sees it; everything else still reads
--     the host's HP, which stays the only real one (D7).
-- Going down and dying stay with the host (T2). Only while the host runs the same build and /pingcomp predict is on.

local hit_results = {}

pc.hit_results = hit_results

local MATCH_WINDOW = 2 -- seconds a shown hit waits for the host's damage message
local PUSH_WINDOW = 1.5 -- the same for a knockback
local RELEASE_DELAY = 0.15 -- the host's HP numbers can trail its damage message by a frame or two
local SPEED_TOLERANCE = 0.15
local STATUS_WINDOW = 2 -- seconds a catapult or knock-down shown here waits for the host's copy (D62)
-- The host works a catapult's direction out from its own positions, and a set upward speed changes its length with the
-- height between the two, so its copy is matched more loosely than a knockback.
local CATAPULT_TOLERANCE = 0.3

local pending_hits = {} -- { go_id, source, t } for hits shown here, oldest first
local pending_pushes = {} -- { speed, limit, t } for knockbacks applied here
local pending_catapults = {} -- { speed, t } for catapults shown here
local pending_knock_downs = {} -- { t } for knock-downs shown here
local estimate = {
	active = false,
	total = 0, -- the HP this client expects once the host has booked the hits shown here
	pending = 0, -- hits shown here whose damage message hasn't arrived
	expires = 0,
	release_t = nil,
}
local hud_reading = false

local function position(unit)
	return POSITION_LOOKUP[unit] or Unit.world_position(unit, 0)
end

local function raw_health(health)
	local game, id = health.game, health.health_game_object_id

	if not game or not id then
		return nil
	end

	return GameSession.game_object_field(game, id, "current_health"), GameSession.game_object_field(game, id, "current_temporary_health"), GameSession.game_object_field(game, id, "max_health")
end

-- The game's own immunity to poison (is_immune_to_damage, damage_utils.lua:37).
local POISON_TYPES = {
	aoe_poison_dot = true,
	arrow_poison = true,
	arrow_poison_dot = true,
	poison = true,
}
local POISON_SOURCES = {
	poison_dot = true,
	skaven_poison_wind_globadier = true,
}

-- What the host does to a hit's damage on a player after working it out: the low difficulties' caps and multipliers,
-- and the player's protection and damage-taken buffs (DamageUtils.apply_buffs_to_damage, only the common ones). An
-- area's damage type also gets the player's protection from areas (:2169).
local function adjusted_damage(amount, target, race, damage_type)
	local difficulty = Managers.state.difficulty
	local settings = difficulty:get_difficulty_settings()
	local rank = difficulty:get_difficulty_rank()

	if rank and rank < 3 then
		local status = ScriptUnit.has_extension(target, "status_system")
		local health = ScriptUnit.has_extension(target, "health_system")

		if status and status:is_knocked_down() then
			amount = amount * (settings.knocked_down_damage_multiplier or 1)
		end

		if health and settings.damage_percent_cap then
			amount = math.clamp(amount, 0, health:get_max_health() * settings.damage_percent_cap)
		end

		amount = amount * (settings.damage_multiplier or 1)
	end

	local buffs = ScriptUnit.has_extension(target, "buff_system")

	if buffs then
		if buffs:has_buff_perk("invulnerable") then
			return 0
		end

		if race == "skaven" then
			amount = buffs:apply_buffs_to_value(amount, "protection_skaven")
		elseif race == "chaos" or race == "beastmen" then
			amount = buffs:apply_buffs_to_value(amount, "protection_chaos")
		end

		local area_types = rawget(_G, "DAMAGE_TYPES_AOE")

		if damage_type and area_types and area_types[damage_type] then
			amount = buffs:apply_buffs_to_value(amount, "protection_aoe")
		end

		amount = buffs:apply_buffs_to_value(amount, "damage_taken")
	end

	return DamageUtils.networkify_damage(math.max(amount, 0))
end

-- AiUtils.damage_target (ai_utils.lua:258) as far as this client can follow it. The crowd scaling comes from the
-- host with the swing. Of the host's damage buffs (DamageUtils.apply_buffs_to_damage) only the common ones are
-- applied, so this is an estimate, and the bar settles on the host's number when it arrives.
local function estimate_damage(swing, attacker, target, damage)
	local action = swing.action
	local amount = DamageUtils.calculate_damage(damage or swing.damage or action.damage, target, attacker)

	if type(amount) ~= "number" then
		return 0
	end

	return adjusted_damage(amount * (swing.damage_scale or 1), target, swing.breed.race)
end

local function start_estimate(health, amount, t)
	local current, temporary = raw_health(health)

	if not current then
		return
	end

	if not estimate.active then
		estimate.active = true
		estimate.total = current + temporary
		estimate.pending = 0
	end

	estimate.total = math.max(estimate.total - amount, 0)
	estimate.pending = estimate.pending + 1
	estimate.expires = t + MATCH_WINDOW
	estimate.release_t = nil
end

local function release_estimate(t)
	estimate.pending = math.max(estimate.pending - 1, 0)

	if estimate.pending == 0 then
		estimate.release_t = t + RELEASE_DELAY
	end
end

-- The HP the HUD shows, split the way the host takes damage: temporary health first (player_unit_health_extension.lua:780).
-- Returns nil when the HUD should show the host's numbers.
local function shown_health(health)
	local t = pc.now()

	if t > estimate.expires or estimate.release_t and t > estimate.release_t then
		estimate.active = false

		return nil
	end

	local current, temporary, max_health = raw_health(health)

	if not current then
		return nil
	end

	local shortfall = current + temporary - estimate.total

	if shortfall <= 0 then
		return nil
	end

	local from_temporary = math.min(shortfall, temporary)

	return math.max(current - (shortfall - from_temporary), 0), temporary - from_temporary, max_health
end

-- A knockback the host's copy of will arrive for: applied now, and noted so that copy is dropped.
local function push_velocity(target, velocity, limit, t)
	local speed = Vector3.length(velocity)

	if speed <= 0 then
		return
	end

	local status = ScriptUnit.has_extension(target, "status_system")

	if status and status:is_disabled() then
		return
	end

	local locomotion = ScriptUnit.has_extension(target, "locomotion_system")

	if not locomotion then
		return
	end

	locomotion:add_external_velocity(velocity, limit)

	pending_pushes[#pending_pushes + 1] = {
		speed = speed,
		limit = limit,
		t = t,
	}

	pc.count("client_push_shown")
end

local function push(target, speed, limit, direction, t)
	if not speed or speed <= 0 then
		return
	end

	push_velocity(target, speed * direction, limit, t)
end

-- D62: the player's own catapulted state, now, as the host's StatusUtils.set_catapulted_network would start it a ping
-- later. Its own setter tells the host, which passes it on to everyone else. Returns whether it was shown. any_speed:
-- the host's copy is dropped whatever its speed, for a throw at the speed the thrower had at the hit (the minotaur's
-- charge, BTChargeAttackAction._charged_at_player, bt_charge_attack_action.lua:520), which the host's booking a ping
-- later doesn't have.
function hit_results.catapult(target, velocity, t, any_speed)
	local status = ScriptUnit.has_extension(target, "status_system")

	-- The setter does nothing for a disabled player (generic_status_extension.lua:1620).
	if not status or status:is_disabled() then
		return false
	end

	status:set_catapulted(true, velocity)

	pending_catapults[#pending_catapults + 1] = {
		speed = Vector3.length(velocity),
		t = t,
		any_speed = any_speed == true,
	}

	pc.count("client_catapult_shown")

	return true
end

-- D62: the player's own knocked-down state (a charge's, StatusUtils.set_charged_network, status_utils.lua:168), now.
-- It ends by itself (player_character_state_charged.lua:93). Returns whether it was shown.
function hit_results.knock_down(target, t)
	local status = ScriptUnit.has_extension(target, "status_system")

	if not status then
		return false
	end

	status:set_charged(true, t)

	pending_knock_downs[#pending_knock_downs + 1] = {
		t = t,
	}

	pc.count("client_knock_down_shown")

	return true
end

-- Family E: an overlap attack's push aside of a player in front of it (BTMeleeOverlapAttackAction.push_close_units,
-- bt_melee_overlap_attack_action.lua:820), which the host leaves this player out of (question 1 of the build 6 notes,
-- D69). Applied whatever /pingcomp predict says, as a shot's push is, since nothing else would apply it.
function hit_results.push_aside(target, velocity)
	local locomotion = not pc.broken and ScriptUnit.has_extension(target, "locomotion_system")

	if locomotion then
		locomotion:add_external_velocity(velocity)
		pc.count("client_pushed_aside")
	end
end

-- An overlap attack's push away from the enemy, or its catapult (BTMeleeOverlapAttackAction.push_player,
-- bt_melee_overlap_attack_action.lua:619), from this screen's positions. Returns what it did, for the log.
local function shove(unit, target, speed, speed_z, catapult, t)
	if not speed then
		return "none"
	end

	local velocity = speed * Vector3.normalize(position(target) - position(unit))

	if speed_z then
		Vector3.set_z(velocity, speed_z)
	end

	if catapult then
		return hit_results.catapult(target, velocity, t) and "catapult" or "none"
	end

	push_velocity(target, velocity, nil, t)

	return "push"
end

local function showing()
	return pc.predict and not pc.broken and pc.host_fresh()
end

-- The hit's feedback and HP estimate, as the host's damage message would show them. damage: the attack's own number
-- to estimate from, if not the swing's. Returns the estimate.
local function show_damage(swing, unit, target, damage, direction, t)
	local health = ScriptUnit.has_extension(target, "health_system")

	if not health then
		return 0
	end

	local action = swing.action
	local amount = estimate_damage(swing, unit, target, damage)

	if amount > 0 then
		health:add_damage(unit, amount, "torso", action.damage_type or "cutting", position(target), direction, swing.breed.name, nil, unit, action.hit_react_type or "light", false, false, false, 1, "n/a", 1, 1)

		pending_hits[#pending_hits + 1] = {
			go_id = swing.go_id,
			source = swing.breed.name,
			t = t,
		}

		start_estimate(health, amount, t)
		pc.count("client_hit_shown")
		pc.count("client_hit_estimate_sum", amount)
	end

	return amount
end

-- Called by Client.lua at a damage frame judged "hit", after the answer has gone out.
function hit_results.hit(swing, unit, target)
	if not showing() then
		return
	end

	local action = swing.action
	local direction = Vector3.normalize(position(target) - position(unit))
	local t = pc.now()
	local amount = show_damage(swing, unit, target, nil, direction, t)

	push(target, action.player_push_speed, action.max_player_push_speed, direction, t)
	pc.log("client swing=%d hit shown at once: estimate=%.1f push=%s", swing.id, amount, tostring(action.player_push_speed))
end

-- Called by Client.lua at an elite's sweep or overhead (family C) judged "hit" or "blocked": what the box test does to
-- this player (bt_storm_vermin_attack_action.lua:420), as the host will book it. The damage, or through a block the
-- blocked damage, the push, which a block doesn't stop, and from build 6 the catapult (D62).
function hit_results.box(swing, unit, target, blocked)
	if not showing() then
		return
	end

	local action = swing.action
	local direction = Vector3.normalize(position(target) - position(unit))
	local t = pc.now()
	local damage = nil
	local amount = 0

	if action.damage then
		if not blocked then
			damage = swing.damage or action.damage
		elseif action.blocked_damage then
			damage = action.blocked_damage
		end
	end

	if damage then
		amount = show_damage(swing, unit, target, damage, direction, t)
	end

	if action.push then
		push(target, action.player_push_speed, action.max_player_push_speed, direction, t)
	end

	-- The catapult (BTStormVerminAttackAction.catapult_enemy, bt_storm_vermin_attack_action.lua:531), through a block
	-- too, unless the player is knocked down.
	local catapulted = false
	local status = ScriptUnit.has_extension(target, "status_system")

	if action.catapult and action.shove_speed and status and not status.knocked_down then
		local velocity = direction * action.shove_speed

		if action.shove_z_speed then
			Vector3.set_z(velocity, action.shove_z_speed)
		end

		catapulted = hit_results.catapult(target, velocity, t)
	end

	pc.log("client swing=%d box %s shown at once: estimate=%.1f push=%s catapult=%s", swing.id, blocked and "block" or "hit", amount, tostring(action.push and action.player_push_speed), tostring(catapulted))
end

-- Called by Client.lua for a monster's or lord's attack judged "hit", "blocked" or "shield" on this player (family E,
-- D61): what the host will book for it, at once. An overlap attack (BTMeleeOverlapAttackAction.hit_player,
-- bt_melee_overlap_attack_action.lua:638): the damage or the blocked damage, and the push or catapult unless the player
-- is knocked down; after a shield's ranged block only the push. A slam (BTMeleeSlamAction.anim_cb_damage,
-- bt_melee_slam_action.lua:169): the damage, or the push back after a block with its blocked damage, or after a shield's
-- block the push alone.
function hit_results.monster(swing, unit, target, result)
	if not showing() then
		return
	end

	local action = swing.action
	local direction = Vector3.normalize(position(target) - position(unit))
	local t = pc.now()
	local status = ScriptUnit.has_extension(target, "status_system")
	local knocked_down = status ~= nil and status.knocked_down
	local amount = 0
	local moved = "none"

	if swing.kind == "slam" then
		if result == "hit" then
			amount = show_damage(swing, unit, target, nil, direction, t)
		else
			if action.player_push_speed_blocked then
				push_velocity(target, action.player_push_speed_blocked * direction, nil, t)

				moved = "push"
			end

			if result == "blocked" and action.blocked_damage then
				amount = show_damage(swing, unit, target, action.blocked_damage, direction, t)
			end
		end
	else
		local attack = swing.attack

		if result == "hit" then
			amount = show_damage(swing, unit, target, nil, direction, t)

			if not knocked_down then
				moved = shove(unit, target, attack.player_push_speed, attack.player_push_speed_z, attack.catapult_player, t)
			end
		elseif result == "blocked" then
			if action.blocked_damage then
				amount = show_damage(swing, unit, target, action.blocked_damage, direction, t)
			end

			if not knocked_down then
				moved = shove(unit, target, attack.player_push_speed_blocked, attack.player_push_speed_blocked_z, attack.catapult_player, t)
			end
		else
			moved = shove(unit, target, attack.player_push_speed_blocked, attack.player_push_speed_blocked_z, false, t)
		end
	end

	pc.log("client swing=%d %s %s shown at once: estimate=%.1f moved=%s", swing.id, tostring(swing.kind), result, amount, moved)
end

-- Family E3: BTChargeAttackAction._push_player (bt_charge_attack_action.lua:531) on this player, from this screen's
-- positions: pushed away from the charger, harder after a block, or for the minotaur's other targets thrown
-- (catapult_on_push_other_targets). aimed: whether this player is the charge's target. Returns what it did, for the log.
local function charge_push(unit, target, action, aimed, blocked, t)
	local speed = action.dodge_past_push_speed

	if not speed then
		return "none"
	end

	local velocity = speed * Vector3.normalize(position(target) - position(unit))

	if not aimed and action.catapult_on_push_other_targets then
		Vector3.set_z(velocity, action.catapult_on_push_z or 3)

		return hit_results.catapult(target, velocity, t) and "catapult" or "none"
	end

	if blocked and action.blocked_velocity_scale then
		velocity = velocity * action.blocked_velocity_scale
	end

	push_velocity(target, velocity, nil, t)

	return "push"
end

-- Called by Client.lua for a charge (family E3, D65) that reached this player: what BTChargeAttackAction._hit_player and
-- _push_player (bt_charge_attack_action.lua:553 and :531) do to them, at once. Its target, hit or blocked with a
-- weapon, is knocked down (the bestigor's, D62) or thrown at the charger's speed on this screen (the minotaur's), and
-- takes the damage unless it blocked; after a shield's block it is only pushed. Anyone else it reached is pushed, or
-- for the minotaur thrown, and takes no damage. "pushed": it only passed close to this player, who is pushed aside.
-- speed: the charger's copy's speed here.
function hit_results.charge(swing, unit, target, result, speed)
	if not showing() then
		return
	end

	local action = swing.action
	local t = pc.now()
	local status = ScriptUnit.has_extension(target, "status_system")
	local knocked_down = status ~= nil and status.knocked_down
	local to_target = position(target) - position(unit)
	local amount = 0
	local moved = "none"

	if result == "pushed" then
		-- The radius's push has no knocked-down check (:482).
		moved = charge_push(unit, target, action, swing.aimed, false, t)
	elseif swing.aimed and result ~= "shield" then
		if result == "hit" then
			amount = show_damage(swing, unit, target, action.damage, Vector3.normalize(to_target), t)
		end

		-- BTChargeAttackAction._charged_at_player (:517), through a weapon's block too.
		if action.player_push_speed and not knocked_down then
			if action.catapult_player then
				local velocity = (speed or 0) * Vector3.normalize(to_target)

				Vector3.set_z(velocity, action.catapult_force_z or 3)

				moved = hit_results.catapult(target, velocity, t, true) and "catapult" or "none"
			else
				moved = hit_results.knock_down(target, t) and "knock-down" or "none"
			end
		end
	elseif action.player_push_speed and not knocked_down then
		moved = charge_push(unit, target, action, swing.aimed, result ~= "hit", t)
	end

	pc.log("client swing=%d charge %s shown at once: estimate=%.1f moved=%s speed=%.2f", swing.id, result, amount, moved, speed or 0)
end

-- Called by Client.lua for a lord's attack (family E4) judged "hit" or "blocked" on this player: what
-- BTChampionAttackAction._deal_damage (bt_champion_attack_action.lua:767) does to them, at once. Through a block the
-- blocked push and the blocked damage, else the damage; then the catapult with the attack's shove_speed, through a
-- block too, unless the player is knocked down or dead (_catapult_player, :872). from: where the attack hit from (the
-- lord, or the start of a lunge's box).
function hit_results.champion(swing, unit, target, result, from)
	if not showing() then
		return
	end

	local action = swing.action
	local t = pc.now()
	local direction = Vector3.normalize(position(target) - (from or position(unit)))
	local amount = 0
	local moved = "none"

	if result == "blocked" then
		if action.player_push_speed_blocked then
			push_velocity(target, action.player_push_speed_blocked * direction, nil, t)

			moved = "push"
		end

		if action.blocked_damage then
			amount = show_damage(swing, unit, target, action.blocked_damage, direction, t)
		end
	else
		amount = show_damage(swing, unit, target, nil, direction, t)
	end

	-- No lord's attack in the 6.13 data scales its throw by its own speed (impact_shove_multiplier, :777); one that did
	-- is left to the host, whose copy then plays as in vanilla.
	local status = ScriptUnit.has_extension(target, "status_system")

	if action.shove_speed and action.shove_z_speed and not action.impact_shove_multiplier and status and not status:is_knocked_down() and not status:is_dead() then
		local velocity = direction * action.shove_speed

		Vector3.set_z(velocity, action.shove_z_speed)

		if hit_results.catapult(target, velocity, t) then
			moved = "catapult"
		end
	end

	pc.log("client swing=%d lord's attack %s shown at once: estimate=%.1f moved=%s", swing.id, result, amount, moved)
end

-- Called by Client.lua when the rat ogre's jump slam lands within its catapult radius of this player on this screen:
-- BTJumpSlamImpactAction.catapult_player (bt_jump_slam_impact_action.lua:78), from where this screen's copy landed, at
-- once (D62). Returns whether it was shown.
function hit_results.jump_catapult(swing, unit, target)
	if not showing() then
		return false
	end

	local speed = swing.action.catapulted_player_speed or 0
	local angle = math.pi / 6
	local velocity = Vector3.normalize(Vector3.flat(position(target) - position(unit))) * (speed * math.cos(angle))

	Vector3.set_z(velocity, speed * math.sin(angle))

	local shown = hit_results.catapult(target, velocity, pc.now())

	pc.log("client swing=%d jump slam threw this player at once: %s", swing.id, tostring(shown))

	return shown
end

-- Called by Client.lua when the exalted champion's axe (D68) reaches this player on this screen: what
-- BTThrowWeaponAction.check_overlap (bt_throw_weapon_action.lua:286) does to them, at once. They are thrown away from
-- the axe (pushed, if the throw doesn't catapult), through a block too, then take the damage unless they blocked.
-- axe_position: this screen's copy of the axe.
function hit_results.axe(swing, unit, target, result, axe_position)
	if not showing() then
		return
	end

	local action = swing.action
	local t = pc.now()
	local feet = position(target)
	local direction = Vector3.normalize(feet - Vector3(axe_position.x, axe_position.y, feet.z))
	local velocity = (action.push_speed or 0) * direction
	local moved = "push"

	if action.push_speed_z then
		Vector3.set_z(velocity, action.push_speed_z)
	end

	if action.catapult_players then
		moved = hit_results.catapult(target, velocity, t) and "catapult" or "none"
	else
		push_velocity(target, velocity, nil, t)
	end

	local amount = 0

	if result == "hit" then
		amount = show_damage(swing, unit, target, nil, direction, t)
	end

	pc.log("client swing=%d axe %s shown at once: estimate=%.1f moved=%s", swing.id, result, amount, moved)
end

-- Called by Client.lua at an elite's shove (family D) judged "hit": the damage and the knockback along the enemy's
-- facing on this screen (bt_storm_vermin_push_action.lua:104). The pushed state comes from the host, a ping late.
function hit_results.shove(swing, unit, target, rotation)
	if not showing() then
		return
	end

	local action = swing.action
	local forward = Quaternion.forward(rotation)
	local t = pc.now()
	local amount = show_damage(swing, unit, target, nil, forward, t)

	push(target, action.impact_push_speed, action.max_impact_push_speed, forward, t)
	pc.log("client swing=%d shove shown at once: estimate=%.1f push=%s", swing.id, amount, tostring(action.impact_push_speed))
end

-- Called by Shots.lua for an enemy's bullet or arrow judged "hit" on this player (family G): the feedback and HP
-- estimate that the host's damage message would show. action_data is the shot's own (power level and damage profile,
-- bt_ratling_gunner_shoot_action.lua:601, bt_fire_projectile_action.lua:316). The push is the shot's business, since
-- the host doesn't send one for a shot this screen judged. Returns the estimate.
function hit_results.shot(shooter, shooter_go_id, breed, target, action_data, zone, direction)
	if not showing() then
		return 0
	end

	local health = ScriptUnit.has_extension(target, "health_system")
	local profile = DamageProfileTemplates[action_data.damage_profile]

	if not health or not profile then
		return 0
	end

	local target_settings = profile.targets and profile.targets[1] or profile.default_target
	local boost_curve = target_settings and BoostCurves[target_settings.boost_curve_type]
	local _, boost = ActionUtils.get_ranged_boost(shooter)
	local amount = DamageUtils.calculate_damage(DamageOutput, target, shooter, zone, action_data.power_level, boost_curve, boost, false, profile, 1, nil, breed.name)

	if type(amount) ~= "number" then
		return 0
	end

	amount = adjusted_damage(amount, target, breed.race)

	if amount > 0 then
		local t = pc.now()

		health:add_damage(shooter, amount, zone, DamageUtils.get_damage_type(profile, 1) or "cutting", position(target), direction, breed.name, nil, shooter, "light", false, false, false, 1, "n/a", 1, 1)

		pending_hits[#pending_hits + 1] = {
			go_id = shooter_go_id,
			source = breed.name,
			t = t,
		}

		start_estimate(health, amount, t)
		pc.count("client_hit_shown")
		pc.count("client_hit_estimate_sum", amount)
	end

	return amount
end

-- Called by Areas.lua for damage an area or a burning does to this player, judged on this screen (family H, D58): a gas
-- cloud's tick or impact, or a tick of the ground fire's or the jet's burning. The feedback and HP estimate that the
-- host's damage message would show (DamageUtils.add_damage_network, damage_utils.lua:1745, which the host books it
-- with). attacker: the cloud, the fire or the thrower, whose network id that message carries. Returns the estimate.
function hit_results.area(attacker, attacker_go_id, damage_source, source_attacker, damage, damage_type)
	if not showing() or type(damage) ~= "number" then
		return 0
	end

	local target = pc.local_player_unit()
	local health = target and ScriptUnit.has_extension(target, "health_system")
	local buffs = target and ScriptUnit.has_extension(target, "buff_system")

	if not health then
		return 0
	end

	if buffs and buffs:has_buff_perk("poison_proof") and (POISON_TYPES[damage_type] or POISON_SOURCES[damage_source]) then
		return 0
	end

	local source_breed = damage_source and Breeds[damage_source]
	local amount = adjusted_damage(damage, target, source_breed and source_breed.race, damage_type)

	if amount > 0 then
		local t = pc.now()
		local shown_attacker = attacker and Unit.alive(attacker) and attacker or target

		health:add_damage(shown_attacker, amount, "torso", damage_type, position(target), Vector3(1, 0, 0), damage_source, nil, source_attacker, "light", false, false, false, 1, "n/a", 1, 1)

		pending_hits[#pending_hits + 1] = {
			go_id = attacker_go_id,
			source = damage_source,
			t = t,
		}

		start_estimate(health, amount, t)
		pc.count("client_hit_shown")
		pc.count("client_hit_estimate_sum", amount)
	end

	return amount
end

-- Called by Client.lua at a damage frame judged "blocked": the push a blocked swing gives (BTAttackAction.attack_blocked).
function hit_results.blocked(swing, unit, target)
	if not showing() then
		return
	end

	local action = swing.action

	push(target, action.player_push_speed_blocked, action.max_player_push_speed, Vector3.normalize(position(target) - position(unit)), pc.now())
end

local function take_pending_hit(attacker_go_id, source, t)
	-- The same enemy first, then the same kind of enemy: the host books a hit from an enemy that has since died with
	-- the player standing in as the attacker (Host.lua, book_hit_without_attacker).
	for pass = 1, 2 do
		for i = 1, #pending_hits do
			local record = pending_hits[i]

			if t - record.t <= MATCH_WINDOW and (pass == 1 and record.go_id == attacker_go_id or pass == 2 and record.source == source) then
				table.remove(pending_hits, i)

				return true
			end
		end
	end

	return false
end

-- Returns true to drop the host's damage message: it is the copy of a hit this client has already shown.
function hit_results.damage_message(victim_go_id, attacker_go_id, damage_source_id, is_dead)
	if #pending_hits == 0 then
		return false
	end

	local target = pc.local_player_unit()

	if not target or Managers.state.unit_storage:go_id(target) ~= victim_go_id then
		return false
	end

	local t = pc.now()
	local source = NetworkLookup.damage_sources[damage_source_id]

	if not take_pending_hit(attacker_go_id, source, t) then
		return false
	end

	release_estimate(t)

	-- A hit that kills the player is left to the game, which handles the death from this message.
	if is_dead then
		return false
	end

	pc.count("client_hit_message_dropped")

	return true
end

-- Returns true to drop the host's knockback message: it is the copy of one this client has already applied.
function hit_results.push_message(game_object_id, velocity, upper_limit)
	if #pending_pushes == 0 then
		return false
	end

	local target = pc.local_player_unit()

	if not target or Managers.state.unit_storage:go_id(target) ~= game_object_id then
		return false
	end

	local t = pc.now()
	local speed = Vector3.length(velocity)

	for i = 1, #pending_pushes do
		local record = pending_pushes[i]
		local same_limit = upper_limit == nil and record.limit == nil or upper_limit ~= nil and record.limit ~= nil and math.abs(upper_limit - record.limit) < 0.01

		if t - record.t <= PUSH_WINDOW and same_limit and math.abs(speed - record.speed) <= record.speed * SPEED_TOLERANCE + 0.05 then
			table.remove(pending_pushes, i)
			pc.count("client_push_message_dropped")

			return true
		end
	end

	return false
end

-- StatusSystem.rpc_set_catapulted from the host for this player. Returns true to drop it: the copy of a catapult this
-- screen already showed (D62), which would start it again. The host sends a catapult to the hit player alone
-- (StatusUtils.set_catapulted_network, status_utils.lua:201).
function hit_results.catapult_message(unit_id, catapulted, velocity)
	if not catapulted or #pending_catapults == 0 then
		return false
	end

	local target = pc.local_player_unit()

	if not target or Managers.state.unit_storage:go_id(target) ~= unit_id then
		return false
	end

	local t = pc.now()
	local speed = velocity and Vector3.length(velocity) or 0

	for i = 1, #pending_catapults do
		local record = pending_catapults[i]

		if t - record.t <= STATUS_WINDOW and (record.any_speed or math.abs(speed - record.speed) <= record.speed * CATAPULT_TOLERANCE + 0.5) then
			table.remove(pending_catapults, i)
			pc.count("client_catapult_message_dropped")
			pc.log("client: the host's copy of a catapult shown here dropped, %.3fs later", t - record.t)

			return true
		end
	end

	return false
end

-- StatusSystem.rpc_status_change_bool from the host (Disablers.lua). Returns true to drop it: the copy of a knock-down
-- this screen already showed (D62).
function hit_results.status_message(status_id, status_bool, game_object_id)
	if not status_bool or #pending_knock_downs == 0 or NetworkLookup.statuses[status_id] ~= "charged" then
		return false
	end

	local target = pc.local_player_unit()

	if not target or Managers.state.unit_storage:go_id(target) ~= game_object_id then
		return false
	end

	local t = pc.now()

	for i = 1, #pending_knock_downs do
		local record = pending_knock_downs[i]

		if t - record.t <= STATUS_WINDOW then
			table.remove(pending_knock_downs, i)
			pc.count("client_knock_down_message_dropped")
			pc.log("client: the host's copy of a knock-down shown here dropped, %.3fs later", t - record.t)

			return true
		end
	end

	return false
end

local function expire(list, t)
	while list[1] and t - list[1].t > STATUS_WINDOW do
		table.remove(list, 1)
		pc.count("client_status_never_echoed")
	end
end

function hit_results.update()
	local t = pc.now()

	while pending_hits[1] and t - pending_hits[1].t > MATCH_WINDOW do
		table.remove(pending_hits, 1)
		pc.count("client_hit_never_booked")
	end

	while pending_pushes[1] and t - pending_pushes[1].t > PUSH_WINDOW do
		table.remove(pending_pushes, 1)
	end

	expire(pending_catapults, t)
	expire(pending_knock_downs, t)
end

function hit_results.clear()
	pending_hits = {}
	pending_pushes = {}
	pending_catapults = {}
	pending_knock_downs = {}
	estimate.active = false
	estimate.pending = 0
	estimate.release_t = nil
	hud_reading = false
end

-- The host's damage messages. Copies of hits shown here, and anything for an enemy already killed here
-- (Reactions.lua), are dropped. A mod:hook, so everything except the original call runs through pc.guard.
mod:hook("HealthSystem", "rpc_add_damage", function (func, self, channel_id, victim_go_id, victim_is_level_unit, attacker_go_id, attacker_is_level_unit, source_attacker_go_id, damage_amount, hit_zone_id, damage_type_id, hit_position, damage_direction, damage_source_id, hit_ragdoll_actor_id, hit_react_type_id, is_dead, ...)
	if not self.is_server and not victim_is_level_unit and not pc.broken then
		local ok, drop = pc.guard("client damage message", hit_results.damage_message, victim_go_id, attacker_go_id, damage_source_id, is_dead)

		if not (ok and drop) then
			ok, drop = pc.guard("client enemy damage message", pc.reactions.damage_message, victim_go_id)
		end

		if ok and drop then
			return
		end
	end

	return func(self, channel_id, victim_go_id, victim_is_level_unit, attacker_go_id, attacker_is_level_unit, source_attacker_go_id, damage_amount, hit_zone_id, damage_type_id, hit_position, damage_direction, damage_source_id, hit_ragdoll_actor_id, hit_react_type_id, is_dead, ...)
end)

-- D62: the host's copy of a catapult this screen already showed. A mod:hook, so everything except the original call
-- runs through pc.guard.
mod:hook("StatusSystem", "rpc_set_catapulted", function (func, self, channel_id, unit_id, catapulted, velocity, ...)
	if not pc.is_server() and not pc.broken and #pending_catapults > 0 then
		local ok, drop = pc.guard("client catapult message", hit_results.catapult_message, unit_id, catapulted, velocity)

		if ok and drop then
			return
		end
	end

	return func(self, channel_id, unit_id, catapulted, velocity, ...)
end)

mod:hook("LocomotionSystem", "rpc_add_external_velocity", function (func, self, channel_id, game_object_id, velocity)
	if not self.is_server and not pc.broken and #pending_pushes > 0 then
		local ok, drop = pc.guard("client knockback message", hit_results.push_message, game_object_id, velocity, nil)

		if ok and drop then
			return
		end
	end

	return func(self, channel_id, game_object_id, velocity)
end)

mod:hook("LocomotionSystem", "rpc_add_external_velocity_with_upper_limit", function (func, self, channel_id, game_object_id, velocity, upper_limit)
	if not self.is_server and not pc.broken and #pending_pushes > 0 then
		local ok, drop = pc.guard("client knockback message", hit_results.push_message, game_object_id, velocity, upper_limit)

		if ok and drop then
			return
		end
	end

	return func(self, channel_id, game_object_id, velocity, upper_limit)
end)

-- The HP estimate is only shown to the HUD: these two functions draw the player frames, and the health getters below
-- only change their answer while one of them is running.
mod:hook("UnitFramesHandler", "_sync_player_stats", function (func, self, ...)
	hud_reading = estimate.active

	local a, b, c = func(self, ...)

	hud_reading = false

	return a, b, c
end)

mod:hook("UnitFrameUI", "update_numeric_ui_health", function (func, self, ...)
	hud_reading = estimate.active

	local a, b, c = func(self, ...)

	hud_reading = false

	return a, b, c
end)

local function hud_health(health)
	if not hud_reading or not estimate.active or health.unit ~= pc.local_player_unit() then
		return nil
	end

	local ok, current, temporary, max_health = pc.guard("hp estimate", shown_health, health)

	if ok and current then
		return current, temporary, max_health
	end

	return nil
end

mod:hook("PlayerUnitHealthExtension", "current_health_percent", function (func, self)
	local current, temporary, max_health = hud_health(self)

	if current then
		return max_health > 0 and (current + temporary) / max_health or 0
	end

	return func(self)
end)

mod:hook("PlayerUnitHealthExtension", "current_permanent_health_percent", function (func, self)
	local current, _, max_health = hud_health(self)

	if current then
		return max_health > 0 and current / max_health or 0
	end

	return func(self)
end)

mod:hook("PlayerUnitHealthExtension", "current_permanent_health", function (func, self)
	local current = hud_health(self)

	if current then
		return current
	end

	return func(self)
end)

mod:hook("PlayerUnitHealthExtension", "current_temporary_health", function (func, self)
	local current, temporary = hud_health(self)

	if current then
		return temporary
	end

	return func(self)
end)
