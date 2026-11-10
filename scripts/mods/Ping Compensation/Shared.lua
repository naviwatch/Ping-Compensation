local mod = get_mod("Ping Compensation")

-- Host and client must run the same VERSION. Bump it whenever pc_hello, pc_swing_begin or pc_swing_answer changes.
local VERSION = 5

local MAX_ERRORS = 5
local CHAT_INTERVAL = 0.5

local pc = {
	VERSION = VERSION,
	HELLO_INTERVAL = 1, -- seconds between a client's hellos
	PEER_EXPIRY = 4, -- seconds without a hello before the host judges that player as vanilla
	SWING_LIFETIME = 5, -- seconds a swing is remembered, on both machines
	debug = false, -- /pingcomp debug
	facing = true, -- /pingcomp facing
	broken = false, -- set after repeated errors; the mod then leaves everything to vanilla
	stats = {},
}

mod.pc = pc

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

-- Chat line for the local player only. Rate-limited, so a horde can't flood the chat.
function pc.chat(format, ...)
	local t = pc.clock()

	if t >= next_chat_time then
		next_chat_time = t + CHAT_INTERVAL

		mod:echo("%s", format_message(format, ...))
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
