local mod = get_mod("Ping Compensation")

-- Host and client must run the same VERSION. Bump it whenever any message in CLAUDE.md's "Network messages" changes.
local VERSION = 9

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
	},
	-- Breeds whose stagger animations ignore the stagger_scale variable, though their stagger actions set
	-- scale_animation_speeds (build 3: 68-78% of the speed asked, about normal speed). The host ends their client
	-- staggers early on the timer instead (D42), and their stagger lengths are measured at normal speed.
	FIXED_SPEED_STAGGER_BREEDS = {
		chaos_marauder = true,
		chaos_marauder_with_shield = true,
		chaos_fanatic = true,
		chaos_berzerker = true,
	},
	-- Breeds whose recoil cue isn't a fixed property of the recoil animation: the fanatic's one recoil (blocked)
	-- reached its cue 0.95 to 2.37 s in, depending on the swing that was blocked (build 3 playtest). The host doesn't
	-- bring their cue forward to a shipped or learned time (D14); it waits for the animation's own cue, which never
	-- cuts the recoil short and leaves the blocker about a ping of extra recoil. The timing lines name the blocked
	-- attack's animation, to find out whether the cue follows it.
	VARIABLE_CUE_BREEDS = {
		chaos_fanatic = true,
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

mod.pc = pc

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
