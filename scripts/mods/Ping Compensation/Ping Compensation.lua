local mod = get_mod("Ping Compensation")

-- Enemy melee against remote players is judged on each player's own screen instead of the host's.
-- The design, its decisions and the roadmap are in Docs/Briefs/client-authoritative-melee.md.
mod:dofile("scripts/mods/Ping Compensation/Shared")
mod:dofile("scripts/mods/Ping Compensation/Geometry")
mod:dofile("scripts/mods/Ping Compensation/Host")
mod:dofile("scripts/mods/Ping Compensation/Client")
mod:dofile("scripts/mods/Ping Compensation/Version")

local pc = mod.pc

-- The one place where both sides meet the game's damage frame. An enemy's attack animation fires anim_cb_damage on
-- every machine that plays it: on the host, where vanilla judges the swing, and on each client, where vanilla does
-- nothing with it.
--
-- This is a mod:hook, so an error in here would crash the game. Everything except the call to the original runs
-- through pc.guard, which catches errors and logs them.
mod:hook("AnimationSystem", "animation_callback", function (func, self, unit, callback_name, param)
	-- pc.host and pc.client are only missing if one of the files above failed to load.
	if callback_name ~= "anim_cb_damage" or pc.broken or not pc.host or not pc.client then
		return func(self, unit, callback_name, param)
	end

	if not self.is_server then
		-- Client: judge the swing now, on what this player sees, and send the result.
		pc.guard("client damage frame", pc.client.damage_frame, unit)

		return func(self, unit, callback_name, param)
	end

	-- Host: if this swing was announced to a modded client, let vanilla do its bookkeeping but skip its hit test.
	local ok, swing = pc.guard("host damage frame", pc.host.before_damage_frame, unit)

	if not ok or not swing then
		return func(self, unit, callback_name, param)
	end

	pc.host.suppress = swing

	func(self, unit, callback_name, param)

	pc.host.suppress = nil
end)

local function role()
	return pc.is_server() and "host" or "client"
end

local function switch(name, value)
	if value == "on" then
		pc[name] = true
	elseif value == "off" then
		pc[name] = false
	elseif value ~= nil then
		mod:echo("Usage: /pingcomp %s on|off", name)

		return
	end

	mod:echo("Ping Compensation %s is %s.", name, pc[name] and "on" or "off")
	pc.print("switch %s=%s role=%s", name, tostring(pc[name]), role())
end

local function stat(name)
	return pc.stats[name] or 0
end

local function print_stats()
	mod:echo("Ping Compensation stats since the mission started (%s, message version %d):", role(), pc.VERSION)

	if pc.is_server() then
		local answer_count = stat("host_answer_time_n")
		local average = answer_count > 0 and stat("host_answer_time_sum") / answer_count * 1000 or 0

		mod:echo("Swings announced %d, answered %d: hit %d, blocked %d, miss %d, cut short %d, not judged %d.", stat("host_announced"), stat("host_answers"), stat("host_hit"), stat("host_blocked"), stat("host_miss"), stat("host_cut"), stat("host_unjudged"))
		mod:echo("Host would have judged differently %d. Never answered %d. Average answer time %.0f ms.", stat("host_disagree"), stat("host_unanswered"), average)
		mod:echo("Judged by the host after a client went quiet %d. Answers ignored %d, rejected %d. Modded clients now: %d.", stat("host_judged_quiet_client"), stat("host_ignored"), stat("host_rejected"), pc.host.modded_peer_count())

		for name, value in pairs(pc.stats) do
			local breed_name = string.match(name, "^host_unanswered_(.+)$")

			if breed_name then
				mod:echo("Never answered, %s: %d.", breed_name, value)
			end
		end
	else
		mod:echo("Swings announced %d, judged %d: hit %d, blocked %d, out of reach %d, outside the cone %d.", stat("client_announced"), stat("client_judged"), stat("client_hit"), stat("client_blocked"), stat("client_miss_reach"), stat("client_miss_cone"))
		mod:echo("Cut short %d. Could not judge %d. Open right now %d.", stat("client_cut"), stat("client_unjudged"), pc.client.open_swing_count())
	end

	mod:echo("Switches: debug %s, facing %s.%s", pc.debug and "on" or "off", pc.facing and "on" or "off", pc.broken and " The mod has switched itself off after errors." or "")
end

mod:command("pingcomp", mod:localize("pingcomp_command_description"), function (action, ...)
	if action == "version" then
		if not mod:is_enabled() then
			-- VMF still runs commands for a disabled mod but drops its replies, so everyone would look like they
			-- don't have it.
			mod:echo("Ping Compensation is disabled.")
		else
			pc.version.start()
		end
	elseif action == "debug" then
		switch("debug", ...)
	elseif action == "facing" then
		switch("facing", ...)
	elseif action == "stats" then
		print_stats()
	elseif action == "mark" then
		-- A line testers can drop into their log at the moment something looked wrong.
		local note = table.concat({ ... }, " ")

		pc.print("MARK role=%s game_time=%.3f note=%s", role(), pc.now(), note)
		mod:echo("Marked in the console log: %s", note ~= "" and note or "(no note)")
	else
		mod:echo("Usage: /pingcomp version | debug on|off | stats | facing on|off | mark <note>")
	end
end)

local function clear()
	pc.version.clear()
	pc.host.clear()
	pc.client.clear()
end

-- Hooks stop running when the mod is disabled, so a swing that hasn't reached the host's damage frame yet simply
-- goes back to vanilla judging.
mod.on_disabled = function ()
	clear()
end

-- VMF calls this every frame, even while the mod is disabled.
mod.update = function (dt)
	if not mod:is_enabled() then
		return
	end

	pc.host.update()
	pc.client.update(dt)
	pc.version.update(dt)
end

-- Nothing may leak from one mission into the next.
mod.on_game_state_changed = function (status, state_name)
	if state_name == "StateIngame" then
		clear()

		if status == "enter" then
			pc.reset_stats()
			pc.reset_errors()
		end
	end
end
