local mod = get_mod("Ping Compensation")

local REPLY_TIMEOUT = 3
local MAX_VERSION_LENGTH = 100
local BUILD_INFO_PATH = "scripts/mods/Ping Compensation/BuildInfo"

-- build.bat writes BuildInfo just before compiling because game Lua can't run git. Other builds don't have the file.
local build_info = Application.can_get("lua", BUILD_INFO_PATH) and mod:dofile(BUILD_INFO_PATH) or {}
local local_version = string.format("%s (%s)", build_info.commit or "unknown", build_info.branch or "unknown")

local next_request_id = 0
local request

-- list the host first, then everyone else by name
local function print_report()
	local players = request.players

	-- cleared first so an error while printing can't repeat every frame from update
	request = nil

	table.sort(players, function (a, b)
		if a.is_host ~= b.is_host then
			return a.is_host
		end

		return a.name < b.name
	end)

	local mod_name = mod:get_readable_name()

	for i = 1, #players do
		local player = players[i]
		local version = player.version and "[" .. player.version .. "]" or "Mod not found."
		local data = ""

		-- Builds from step 2.1 on also send their enemy data fingerprint (Compat.lua).
		if type(player.fingerprint) == "string" then
			local own = mod.pc.compat.fingerprint()

			data = player.fingerprint == own and " Enemy data matches yours." or " Enemy data differs from yours: " .. mod.pc.compat.differences(own, player.fingerprint) .. "."
		end

		mod.pc.say("[%s] [%s] %s%s", player.name, mod_name, version, data)
	end
end

local function start_request()
	local player_manager = Managers.player
	local human_players = player_manager and player_manager:human_players()

	if not human_players or not next(human_players) then
		mod.pc.say("No players found yet. Try again from the keep or a mission.")
		return
	end

	local my_peer_id = Network.peer_id()
	local host_peer_id = player_manager.is_server and my_peer_id or mod.pc.host_peer()
	local players = {}
	local players_by_peer = {}
	local waiting = 0

	for _, human_player in pairs(human_players) do
		local peer_id = human_player.peer_id
		local is_local = peer_id == my_peer_id
		local player = {
			name = human_player:name(),
			is_host = peer_id == host_peer_id,
			version = is_local and local_version or nil,
		}

		players[#players + 1] = player
		players_by_peer[peer_id] = player
		waiting = is_local and waiting or waiting + 1
	end

	next_request_id = next_request_id + 1
	request = {
		id = next_request_id,
		players = players,
		players_by_peer = players_by_peer,
		waiting = waiting,
		time_left = REPLY_TIMEOUT,
	}

	if waiting == 0 then
		print_report()
	else
		-- only reaches players with this mod enabled; anyone who stays silent is reported as not having it
		mod:network_send("pc_version_request", "others", request.id)
	end
end

mod:network_register("pc_version_request", function (sender, request_id)
	if type(request_id) == "number" then
		mod:network_send("pc_version_reply", sender, request_id, local_version, mod.pc.compat.fingerprint())
	end
end)

mod:network_register("pc_version_reply", function (sender, request_id, version, fingerprint)
	local player = request and request_id == request.id and request.players_by_peer[sender]

	if not player or player.version or type(version) ~= "string" or #version > MAX_VERSION_LENGTH then
		return
	end

	player.version = version
	player.fingerprint = type(fingerprint) == "string" and #fingerprint <= MAX_VERSION_LENGTH and fingerprint or nil
	request.waiting = request.waiting - 1

	if request.waiting == 0 then
		print_report()
	end
end)

-- /pingcomp version, dispatched from the main script
mod.pc.version = {
	start = start_request,
	update = function (dt)
		if request then
			request.time_left = request.time_left - dt

			if request.time_left <= 0 then
				print_report()
			end
		end
	end,
	clear = function ()
		request = nil
	end,
}
