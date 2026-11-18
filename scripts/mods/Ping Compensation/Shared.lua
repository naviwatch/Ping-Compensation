local mod = get_mod("Ping Compensation")

-- Host and client must run the same VERSION. Bump it whenever any message in CLAUDE.md's "Network messages" changes.
local VERSION = 14

-- Playtest builds write the debug log by default, so testers don't have to remember /pingcomp debug on. Set this to
-- false for a public release: players who want the log can still switch it on, and their choice is remembered.
local PLAYTEST_BUILD = true

local MAX_ERRORS = 5
local CHAT_INTERVAL = 0.5

local pc = {
	VERSION = VERSION,
	HELLO_INTERVAL = 1, -- seconds between a client's hellos
	PEER_EXPIRY = 4, -- seconds without a hello before the host judges that player as vanilla
	SWING_LIFETIME = 5, -- seconds a swing is remembered, on both machines
	-- Seconds between a client's requests to VMF to ping every player again while a host that has answered in this
	-- mission stays quiet. VMF drops the host from a client's user list whenever the host removes a bot (the build 3.2
	-- playtest, Client.lua).
	REPING_INTERVAL = 3,
	debug = PLAYTEST_BUILD, -- /pingcomp debug, remembered once a player sets it
	echo = false, -- /pingcomp echo, on the host: disagreements and unanswered swings also show in chat
	facing = true, -- /pingcomp facing
	dodgecount = true, -- /pingcomp dodgecount: apply the weapon's dodge count to clients, as the game does for the host
	attacks = true, -- /pingcomp attacks: this player's hits decide staggers and kills on the enemies below (D26 to D29)
	recoil = "anim", -- /pingcomp recoil off|anim|full: the enemy's recoil after this player's block (D13, D39)
	predict = true, -- /pingcomp predict: a hit on this player shows its results at once (D11)
	stagger_timing = "speed", -- /pingcomp stagger speed|end|off, on the host: how a client's stagger is shortened (D32)
	combowait = true, -- /pingcomp combowait, on the host: a frenzy combo waits for the client's answer before its next move (D15)
	COMBO_WAIT = 0.5, -- seconds a combo waits for that answer before the host goes with its own guess (D15)
	-- Family F (D52): seconds a disabler's hook, grab or leap is held open on the host past its own copy's moment, for the
	-- targeted client's answer, before the host lets it end.
	GRAB_WAIT = 0.5,
	-- Seconds a client waits for the host to confirm a grab or pin it shows at once (D53) before it undoes it.
	GRAB_CONFIRM = 2,
	-- Family F: the disabler's node and the kind of attack it is, which pc_swing_begin names in step_name.
	DISABLER_KINDS = {
		BTPackMasterAttackAction = "hook",
		BTCorruptorGrabAction = "grab",
		BTCrazyJumpAction = "pounce",
	},
	-- Family G (build 5.1, D52): the nodes whose shots a client judges on its own player, and the kind of shot. A
	-- client's results go several to a message (pc_shots), at most this often.
	SHOOTER_NODES = {
		BTRatlingGunnerShootAction = "bullet",
		BTFireProjectileAction = "arrow",
	},
	SHOT_FLUSH = 0.1,
	-- Seconds a client waits for the host to confirm a vortex's catch it shows at once (D53) before it undoes it.
	CATCH_CONFIRM = 2,
	-- T18: nodes that set an enemy's turn speed as they start and leave it set (AILocomotionExtension.set_rotation_speed),
	-- with that speed. An attack later in the same sequence turns at it on the host (Client.lua).
	TURN_SPEED_SETTERS = {
		BTPackMasterSkulkAroundAction = 5, -- bt_pack_master_skulk_around_action.lua:32
		BTPackMasterEscortRatOgreAction = 5, -- bt_pack_master_escort_rat_ogre_action.lua:27
		BTSkulkAroundAction = 5, -- bt_skulk_around_action.lua:40
		BTNinjaSkulkAction = 5, -- bt_ninja_skulk_action.lua:41
		BTNinjaApproachAction = 5, -- bt_ninja_approach_action.lua:44
	},
	DEFAULT_TURN_SPEED = 10, -- DEFAULT_ROTATION_SPEED in ai_locomotion_extension.lua
	TELEPORT_LIMIT = 2.5, -- metres the host will move its copy of an enemy to where a client saw it (D27)
	MAX_STAGGER_SPEEDUP = 3, -- fastest the host plays a client's stagger; past this it ends the stagger early (D38)
	-- Enemies whose reactions to a player's hits that player's client decides (D29, D31, D40). Every hit the client
	-- sends counts: melee, pushes, ranged, career skills, and the player's own explosions and area skills (D37).
	-- Damage over time stays with the host (T8).
	REACTION_BREEDS = {
		skaven_slave = true,
		skaven_clan_rat = true,
		skaven_clan_rat_with_shield = true,
		chaos_marauder = true,
		chaos_marauder_with_shield = true,
		chaos_fanatic = true,
		beastmen_gor = true,
		beastmen_ungor = true,
		skaven_plague_monk = true,
		chaos_berzerker = true,
		skaven_storm_vermin_with_shield = true,
		-- Build 4 (D49): the elites. The bulwark's shield runs stagger rules of its own (a stagger that builds and
		-- regenerates, then opens the shield), so its reactions stay with the host for now (T14).
		skaven_storm_vermin = true,
		skaven_storm_vermin_commander = true,
		chaos_raider = true,
		chaos_raider_tutorial = true,
		chaos_warrior = true,
		beastmen_bestigor = true,
		beastmen_standard_bearer = true,
		beastmen_standard_bearer_crater = true,
		-- Build 5 (D52): every special, and the ungor archer with them.
		skaven_pack_master = true,
		skaven_gutter_runner = true,
		skaven_ratling_gunner = true,
		skaven_warpfire_thrower = true,
		skaven_poison_wind_globadier = true,
		chaos_vortex_sorcerer = true,
		chaos_corruptor_sorcerer = true,
		beastmen_ungor_archer = true,
	},
	-- Covered breeds whose stagger animations play faster when the stagger_scale variable is raised (the calibration
	-- probe, 2026-11-14: 2x asked, 2x reached). The host plays a client's stagger of these faster (D32, D38). The other
	-- covered breeds' animations ignore the variable (Chaos enemies, gors, shielded stormvermin: 1x reached), so their
	-- client staggers end early on the host's timer instead (D42, D47), and their lengths are timed at normal speed
	-- whatever the variable says. The ungor's stagger action doesn't set scale_animation_speeds, so for ungors the host
	-- sends the variable with every stagger itself (HostReactions.lua). No covered breed's recoil responds to it.
	STAGGER_SCALE_BREEDS = {
		skaven_slave = true,
		skaven_clan_rat = true,
		skaven_clan_rat_with_shield = true,
		skaven_plague_monk = true,
		beastmen_ungor = true,
	},
	-- Build 3.1 diagnostic: the clients decided "too weak to stagger" for hundreds of hits on these. For a client's
	-- hits on them, the host still works out its own stagger, without applying it, and logs where it disagrees; both
	-- sides log what their stagger maths used for every hit on them (pc.stagger_inputs, D45). Build 4 checks the elites
	-- the same way, to show where the client's stand-in falls short for them, and build 5 the specials.
	CHECK_BREEDS = {
		skaven_pack_master = true,
		skaven_gutter_runner = true,
		skaven_ratling_gunner = true,
		skaven_warpfire_thrower = true,
		skaven_poison_wind_globadier = true,
		chaos_vortex_sorcerer = true,
		chaos_corruptor_sorcerer = true,
		beastmen_ungor_archer = true,
		skaven_plague_monk = true,
		chaos_berzerker = true,
		skaven_storm_vermin = true,
		skaven_storm_vermin_commander = true,
		chaos_raider = true,
		chaos_raider_tutorial = true,
		chaos_warrior = true,
		beastmen_bestigor = true,
		beastmen_standard_bearer = true,
		beastmen_standard_bearer_crater = true,
	},
	broken = false, -- set after repeated errors; the mod then leaves everything to vanilla
	stats = {},
}

local ok_types, stagger_types = pcall(require, "scripts/utils/stagger_types")

-- Same numbers as scripts/utils/stagger_types.lua, in case require isn't available to mods.
pc.stagger_types = ok_types and type(stagger_types) == "table" and stagger_types or {
	none = 0,
	weak = 1,
	medium = 2,
	heavy = 3,
	ranged_weak = 4,
	ranged_medium = 5,
	explosion = 6,
	weakspot = 8,
	pulling = 9,
}

local stagger_names = {}

for name, value in pairs(pc.stagger_types) do
	stagger_names[value] = name
end

function pc.stagger_name(stagger_type)
	return stagger_names[stagger_type] or tostring(stagger_type)
end

-- The speed a stagger animation of this breed really plays at when the stagger_scale variable asks for `asked`.
-- Covered breeds: as asked for STAGGER_SCALE_BREEDS, normal speed for the others (the probe, D47). Every other enemy
-- (timed since 3.2 for later steps): as asked, since the probe didn't try them; a reading at any speed but 1 isn't
-- learned (Timings.lua), so a wrong guess costs nothing.
function pc.stagger_speed(breed_name, asked)
	if pc.REACTION_BREEDS[breed_name] and not pc.STAGGER_SCALE_BREEDS[breed_name] then
		return 1
	end

	return asked
end

mod.pc = pc

-- Every mod message sent and received is counted per mission, by name (D56), to show the network load once every
-- enemy type is covered (T10). Every other file registers and sends through these, since this one loads first.
local network_send = mod.network_send
local network_register = mod.network_register

mod.network_send = function (self, name, ...)
	pc.count("msg_sent_" .. tostring(name))

	return network_send(self, name, ...)
end

mod.network_register = function (self, name, callback)
	return network_register(self, name, function (...)
		pc.count("msg_received_" .. tostring(name))

		return callback(...)
	end)
end

-- A breed's behaviour tree (BreedBehaviors[breed.behavior]): each node is a table whose first entry is the node's class
-- and whose action_data is its action table.
function pc.tree_of(breed)
	local behaviors = rawget(_G, "BreedBehaviors")

	return behaviors and breed and breed.behavior and behaviors[breed.behavior] or nil
end

-- The first node in the tree that matches(node), and the node it sits in.
function pc.find_node(node, matches, parent, depth)
	depth = depth or 0

	if type(node) ~= "table" or depth > 30 then
		return nil
	end

	if type(node[1]) == "string" and matches(node) then
		return node, parent
	end

	for i = 2, #node do
		local found, found_parent = pc.find_node(node[i], matches, node, depth + 1)

		if found then
			return found, found_parent
		end
	end

	return nil
end

local turn_speeds = {} -- action table -> the speed the host turns an enemy at while it runs that action (T18)

-- T18: the speed the host turns an enemy at during this attack. The host's locomotion keeps whatever speed a node set
-- last (locomotion_templates_ai.lua:156). In a sequence, every run passes through each earlier node, so an attack
-- there turns at the speed the last speed-setting node before it sets: the packmaster's hook after its skulking
-- (skaven_packmaster_behavior.lua:60), the warpfire thrower's shooting likewise. Anything else turns at the default:
-- staggers, recoils and the other nodes that change the speed put it back when they end. From the client's own copy of
-- the tree, as Lance asked ("The client should use it's own data for this, not rely on the host").
function pc.turn_speed(breed, action)
	if type(action) ~= "table" then
		return pc.DEFAULT_TURN_SPEED
	end

	local cached = turn_speeds[action]

	if cached then
		return cached
	end

	local speed = pc.DEFAULT_TURN_SPEED
	local node, parent = pc.find_node(pc.tree_of(breed), function (candidate)
		return candidate.action_data == action
	end)

	if node and parent and parent[1] == "BTSequence" then
		for i = 2, #parent do
			local sibling = parent[i]

			if sibling == node then
				break
			end

			local set = type(sibling) == "table" and pc.TURN_SPEED_SETTERS[sibling[1]]

			if set then
				speed = set
			end
		end
	end

	turn_speeds[action] = speed

	return speed
end

local saved_debug = mod:get("debug")

if type(saved_debug) == "boolean" then
	pc.debug = saved_debug
end

local error_counts = {}
local next_chat_time = 0

function pc.network()
	return Managers.state and Managers.state.network
end

function pc.in_game()
	local network = pc.network()

	return network ~= nil and Managers.player ~= nil and network:game() ~= nil
end

function pc.is_server()
	return Managers.player ~= nil and Managers.player.is_server == true
end

-- Game time is the clock the game's own attack code runs on. It only exists during a mission.
function pc.now()
	return Managers.time:time("game") or 0
end

-- Hellos use the main clock, so they keep their rhythm whatever game time does.
function pc.clock()
	return Managers.time:time("main") or 0
end

function pc.host_peer()
	local network = pc.network()
	local lobby = network and network:lobby()
	local session_host = network and network:game_session_host()

	if session_host and session_host ~= "0" then
		return session_host
	end

	return lobby and lobby:lobby_host()
end

-- On a client: the main-clock time of the host's last reply to a hello. Nothing is predicted on this screen unless the
-- host runs the same build, because only then does the host apply what this client decides.
local host_heard = nil

function pc.heard_host()
	host_heard = pc.clock()
end

function pc.forget_host()
	host_heard = nil
end

function pc.host_fresh()
	return host_heard ~= nil and pc.clock() - host_heard <= pc.PEER_EXPIRY
end

-- The damage one hit of an attack deals before the game's own scaling, as the game's damage frame works it out: family
-- A's from the attack (AnimationCallbackTemplates.server.anim_cb_damage), family B's from the combo step if it has
-- its own (BTComboAttackAction.anim_cb_frenzy_damage, bt_combo_attack_action.lua:553).
function pc.attack_damage(action, combo_step)
	local damage_table = combo_step and combo_step.difficulty_damage

	if damage_table then
		return Managers.state.difficulty:get_difficulty_value_from_table(damage_table)
	end

	return action.damage
end

-- The block cost of an attack: a combo step's own, else the attack's (bt_combo_attack_action.lua:541).
function pc.fatigue_type(action, combo_step)
	local fatigue_type = combo_step and combo_step.fatigue_type or action.fatigue_type

	if type(fatigue_type) == "table" then
		fatigue_type = Managers.state.difficulty:get_difficulty_value_from_table(fatigue_type)
	end

	if not fatigue_type or not PlayerUnitStatusSettings.fatigue_point_costs[fatigue_type] then
		fatigue_type = "blocked_attack"
	end

	return fatigue_type
end

function pc.local_player_unit()
	local player = Managers.player and Managers.player:local_player()
	local unit = player and player.player_unit

	return unit and Unit.alive(unit) and unit or nil
end

-- An attacker with the ai_unblockable perk (the "Crushing" grudge mark, buff_settings_grudge_marks.lua:437) can't be
-- blocked. The game checks it only on the host (DamageUtils.check_block and check_ranged_block, damage_utils.lua:2738
-- and :2790), so a client that runs a block on its own screen checks it first (D57 review).
function pc.unblockable(attacker)
	local buffs = attacker and Unit.alive(attacker) and ScriptUnit.has_extension(attacker, "buff_system")

	return buffs and buffs:has_buff_perk("ai_unblockable") == true or false
end

local function format_message(format, ...)
	local ok, message = pcall(string.format, format, ...)

	return ok and message or tostring(format)
end

-- Always written to the console log, whatever the debug switch says.
function pc.print(format, ...)
	print("[PingComp] " .. format_message(format, ...))
end

-- Written to the console log only while /pingcomp debug is on.
function pc.log(format, ...)
	if pc.debug then
		print("[PingComp] " .. format_message(format, ...))
	end
end

-- Chat line for the local player that also goes to the console log, because some players' VMF settings send echoes
-- to chat only, and the log is what testers send back.
function pc.say(format, ...)
	local message = format_message(format, ...)

	mod:echo("%s", message)
	print("[PingComp] " .. message)
end

-- Chat line for the local player only, also logged. Rate-limited, so a horde can't flood the chat.
function pc.chat(format, ...)
	local t = pc.clock()

	if t >= next_chat_time then
		next_chat_time = t + CHAT_INTERVAL

		pc.say(format, ...)
	end
end

function pc.count(name, amount)
	pc.stats[name] = (pc.stats[name] or 0) + (amount or 1)
end

function pc.reset_stats()
	pc.stats = {}
end

-- cjson refuses NaN and infinity, and VMF then drops the whole message without a word.
function pc.finite(value, decimals)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return 0
	end

	local scale = 10 ^ (decimals or 2)

	return math.floor(value * scale + 0.5) / scale
end

local function buffed(extension, stat)
	if not extension or type(extension.apply_buffs_to_value) ~= "function" then
		return nil
	end

	local ok, value = pcall(extension.apply_buffs_to_value, extension, 1, stat)

	return ok and type(value) == "number" and value or nil
end

local function has_buff(extension, method, name)
	if not extension or type(extension[method]) ~= "function" then
		return "?"
	end

	local ok, value = pcall(extension[method], extension, name)

	return ok and tostring(value == true) or "?"
end

local function number_text(value)
	return type(value) == "number" and value == value and string.format("%.2f", value) or "-"
end

local function action_name(action)
	return type(action) == "table" and tostring(action.name) or "none"
end

-- What the game's stagger maths (DamageUtils.calculate_stagger_player and do_stagger_calculation, damage_utils.lua:868
-- and :574) reads for one hit, besides the game data the enemy-data fingerprint covers: the hit, the attacker's and
-- the enemy's buffs, and the enemy's stagger state. state is the host's blackboard, or a client's stand-in for it,
-- whose attack_action holds the attack the enemy is in (the maths itself reads action). Both sides log it for every
-- hit on pc.CHECK_BREEDS, so their lines for one hit can be compared (D45).
function pc.stagger_inputs(target_unit, state, attacker_unit, damage_profile, target_index, hit_zone_name, power_level, boost_curve_multiplier, is_critical_strike, blocked, damage_source, t)
	local attacker_alive = attacker_unit ~= nil and Unit.alive(attacker_unit)
	local attacker_buffs = attacker_alive and ScriptUnit.has_extension(attacker_unit, "buff_system") or nil
	local target_buffs = target_unit and Unit.alive(target_unit) and ScriptUnit.has_extension(target_unit, "buff_system") or nil
	local target_settings = type(damage_profile) == "table" and (damage_profile.targets and damage_profile.targets[target_index] or damage_profile.default_target) or nil
	local range = nil

	if target_settings and attacker_alive then
		local ok, value = pcall(ActionUtils.get_range_scalar_multiplier, damage_profile, target_settings, attacker_unit, target_unit)

		range = ok and value or nil
	end

	local health = target_unit and ScriptUnit.has_extension(target_unit, "health_system")
	local ok_health, hp = pcall(function ()
		return health and health:current_health_percent()
	end)
	local immune = state and state.stagger_immune_time
	local heavy_immune = state and state.heavy_stagger_immune_time
	local difficulty = Managers.state.difficulty and Managers.state.difficulty:get_difficulty()

	return string.format("power=%s boost=%s crit=%s zone=%s target=%s blocked=%s source=%s attacker[impact=%s push=%s counter_push=%s potion=%s push_increase=%s] enemy[vulnerability=%s resistance=%s range=%s hp=%s accumulated=%s count=%s anim_done=%s immune_left=%s heavy_immune_left=%s action=%s attack=%s difficulty=%s]",
		number_text(power_level), number_text(boost_curve_multiplier), tostring(is_critical_strike == true), tostring(hit_zone_name), tostring(target_index), tostring(blocked == true), tostring(damage_source),
		number_text(buffed(attacker_buffs, "power_level_impact")), number_text(buffed(attacker_buffs, "push_power")), number_text(buffed(attacker_buffs, "counter_push_power")),
		has_buff(attacker_buffs, "has_buff_perk", "potion_armor_penetration"), has_buff(attacker_buffs, "has_buff_type", "push_increase"),
		number_text(buffed(target_buffs, "impact_vulnerability")), number_text(buffed(target_buffs, "stagger_resistance")), number_text(range), number_text(ok_health and hp or nil),
		number_text(state and state.stagger or 0), tostring(state and state.stagger_count or 0), tostring(state and state.stagger_anim_done), number_text(immune and t and immune - t), number_text(heavy_immune and t and heavy_immune - t),
		action_name(state and state.action), action_name(state and state.attack_action), tostring(difficulty))
end

local function error_handler(message)
	return tostring(message) .. "\n" .. Script.callstack()
end

-- Runs fn(...) and never lets an error escape. Handlers created with mod:hook use this for everything except their
-- call to the original function, because an error inside a mod:hook handler crashes the game.
-- After MAX_ERRORS in one place the mod switches itself off: clients stop saying hello, the host stops announcing
-- swings, and everything goes back to vanilla rules.
function pc.guard(name, fn, ...)
	if pc.broken then
		return false
	end

	local ok, a, b, c = xpcall(fn, error_handler, ...)

	if ok then
		return true, a, b, c
	end

	local count = (error_counts[name] or 0) + 1

	error_counts[name] = count

	print(string.format("[PingComp] ERROR in %s (%d): %s", name, count, tostring(a)))

	if count == 1 then
		mod:echo("Ping Compensation hit an error in '%s'. Please send your console log to the mod's developers.", name)
	end

	if count >= MAX_ERRORS then
		pc.broken = true

		mod:echo("Ping Compensation switched itself off after repeated errors. The game carries on with vanilla rules.")
	end

	return false
end

function pc.reset_errors()
	error_counts = {}
	pc.broken = false
end
