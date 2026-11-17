local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Client side of decision D11: when this client judges that an enemy's swing hit its player, the results show at once
-- instead of a ping later.
--   * Feedback: the game's own client code for a hit on this player runs now (PlayerUnitHealthExtension.add_damage,
--     which HealthSystem.rpc_add_damage calls when the host's damage message arrives): damage indicator, flinch,
--     rumble, the enemy's weapon sound. The host's message for that hit is then dropped, so nothing plays twice.
--   * Knockback, and the push a blocked swing gives: applied now; the host's copy is dropped.
--   * HP bar: shows an estimate until the host's number arrives. Only the HUD sees it; everything else still reads
--     the host's HP, which stays the only real one (D7).
-- Going down and dying stay with the host (T2). Only while the host runs the same build and /pingcomp predict is on.

local hit_results = {}

pc.hit_results = hit_results

local MATCH_WINDOW = 2 -- seconds a shown hit waits for the host's damage message
local PUSH_WINDOW = 1.5 -- the same for a knockback
local RELEASE_DELAY = 0.15 -- the host's HP numbers can trail its damage message by a frame or two
local SPEED_TOLERANCE = 0.15

local pending_hits = {} -- { go_id, source, t } for hits shown here, oldest first
local pending_pushes = {} -- { speed, limit, t } for knockbacks applied here
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

local function push(target, speed, limit, direction, t)
	if not speed or speed <= 0 then
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

	locomotion:add_external_velocity(speed * direction, limit)

	pending_pushes[#pending_pushes + 1] = {
		speed = speed,
		limit = limit,
		t = t,
	}

	pc.count("client_push_shown")
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
-- blocked damage, and the push, which a block doesn't stop. A catapult still comes from the host, a ping late.
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

	pc.log("client swing=%d box %s shown at once: estimate=%.1f push=%s", swing.id, blocked and "block" or "hit", amount, tostring(action.push and action.player_push_speed))
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

function hit_results.update()
	local t = pc.now()

	while pending_hits[1] and t - pending_hits[1].t > MATCH_WINDOW do
		table.remove(pending_hits, 1)
		pc.count("client_hit_never_booked")
	end

	while pending_pushes[1] and t - pending_pushes[1].t > PUSH_WINDOW do
		table.remove(pending_pushes, 1)
	end
end

function hit_results.clear()
	pending_hits = {}
	pending_pushes = {}
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
