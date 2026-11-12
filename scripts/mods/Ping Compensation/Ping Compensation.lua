local mod = get_mod("Ping Compensation")

-- Enemy melee against remote players is judged on each player's own screen instead of the host's.
-- The design, its decisions and the roadmap are in Docs/Briefs/client-authoritative-melee.md.
mod:dofile("scripts/mods/Ping Compensation/Shared")
mod:dofile("scripts/mods/Ping Compensation/Timings")
mod:dofile("scripts/mods/Ping Compensation/Compat")
mod:dofile("scripts/mods/Ping Compensation/Geometry")
mod:dofile("scripts/mods/Ping Compensation/Host")
mod:dofile("scripts/mods/Ping Compensation/HostReactions")
mod:dofile("scripts/mods/Ping Compensation/Client")
mod:dofile("scripts/mods/Ping Compensation/Reactions")
mod:dofile("scripts/mods/Ping Compensation/HitResults")
mod:dofile("scripts/mods/Ping Compensation/Version")

local pc = mod.pc

-- Animation cues that the host's blackboard records for staggers. A client's copy of the enemy fires them too, and
-- Reactions.lua keeps the same record for the stagger maths it runs. On the host, the end of a stagger's push
-- animation also tells HostReactions.lua how long that animation is (D32).
local TRACKED_CALLBACKS = {
	anim_cb_push_finished = true,
	anim_cb_stagger_immune = true,
	anim_cb_blocked_cooldown = true,
}

-- The one place where both sides meet the game's damage frame. An enemy's attack animation fires anim_cb_damage on
-- every machine that plays it: on the host, where vanilla judges the swing, and on each client, where vanilla does
-- nothing with it.
--
-- This is a mod:hook, so an error in here would crash the game. Everything except the call to the original runs
-- through pc.guard, which catches errors and logs them.
mod:hook("AnimationSystem", "animation_callback", function (func, self, unit, callback_name, param)
	-- pc.host, pc.client and pc.reactions are only missing if one of the files above failed to load.
	if pc.broken or not pc.host or not pc.client or not pc.reactions then
		return func(self, unit, callback_name, param)
	end

	if callback_name ~= "anim_cb_damage" then
		if TRACKED_CALLBACKS[callback_name] then
			if not self.is_server then
				pc.guard("client animation cue", pc.reactions.animation_callback, unit, callback_name)
			elseif callback_name == "anim_cb_push_finished" and pc.host_reactions then
				pc.guard("host stagger length", pc.host_reactions.push_finished, unit)
			elseif callback_name == "anim_cb_blocked_cooldown" and pc.host_reactions then
				pc.guard("host recoil cue", pc.host_reactions.recoil_cue, unit)
			end
		end

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

-- Whether this machine hosted the last mission. Once the game is closing the network is gone and every machine
-- looks like a client, so the summary written then uses this.
local hosted_last = nil

local USAGE = "Usage: /pingcomp version | stats | timings | debug on|off | attacks on|off | recoil off|anim|full | predict on|off | stagger speed|end|off | echo on|off | facing on|off | dodgecount on|off | mark <note>"

local SWITCH_VALUES = {
	on = true,
	["true"] = true,
	["1"] = true,
	off = false,
	["false"] = false,
	["0"] = false,
}

-- What a switch means, said when someone changes it, so nobody mistakes a comparison mode for the normal game.
local SWITCH_NOTES = {
	facing = {
		[false] = "Off is only for comparing. The enemy's facing on your screen then trails behind you, which makes you much harder to hit than in the normal game.",
	},
	dodgecount = {
		[true] = "Your weapon's dodge count applies to you, as it always has for the host.",
		[false] = "Off ignores your weapon's dodge count, as the normal game does for players who aren't hosting.",
	},
	debug = {
		[true] = "Every judged swing, stagger, kill, recoil and timing goes to your console log. Kept for your next games too.",
		[false] = "Nothing but errors, commands and summaries goes to your console log. Kept for your next games too.",
	},
	echo = {
		[true] = "On the host, swings judged differently from the host and swings never answered also show in chat.",
		[false] = "Those lines only go to the console log.",
	},
	attacks = {
		[true] = "Your hits stagger and kill trash on your screen at once, and the host follows.",
		[false] = "Off leaves your hits to the host, as in step 1: staggers and kills show a ping late.",
	},
	predict = {
		[true] = "A hit on you shows its feedback, knockback and HP drop at once.",
		[false] = "Off waits for the host before showing a hit on you, as in step 1.",
	},
	recoil = {
		off = "Off: after your block, the enemy recoils when the host says so, a ping late.",
		anim = "Anim: the enemy's recoil plays at once, but it moves where the host has it.",
		full = "Full: the enemy's recoil plays at once and moves on your screen.",
	},
	stagger_timing = {
		speed = "Speed: on the host, a stagger a client caused plays faster, so its next move reaches that client as the stagger ends there. Past 1.5x, or for ungors, it ends early instead.",
		["end"] = "End: on the host, a stagger a client caused ends early by that client's ping, cutting its animation short for everyone else.",
		off = "Off: on the host, a stagger a client caused runs its full length, so that client sees the enemy pause for about a ping afterwards.",
	},
}

-- Switches with a word for a value instead of on|off: the chat word, the field in pc, the allowed values.
local CHOICES = {
	recoil = {
		field = "recoil",
		values = {
			off = true,
			anim = true,
			full = true,
		},
	},
	stagger = {
		field = "stagger_timing",
		values = {
			speed = true,
			["end"] = true,
			off = true,
		},
	},
}

local function switch(name, value)
	if value ~= nil then
		local wanted = SWITCH_VALUES[value]

		if wanted == nil then
			pc.say("Usage: /pingcomp %s on|off", name)

			return
		end

		pc[name] = wanted
	end

	pc.say("Ping Compensation %s is %s.", name, pc[name] and "on" or "off")

	local note = value ~= nil and SWITCH_NOTES[name] and SWITCH_NOTES[name][pc[name]]

	if note then
		pc.say("%s", note)
	end

	pc.print("switch %s=%s role=%s", name, tostring(pc[name]), role())

	-- The debug log stays as the player left it, so a tester who switched it on (or off) needn't do it again.
	if name == "debug" and value ~= nil then
		mod:set("debug", pc.debug)
	end

	-- The host decides who judges a player's hits from that player's hello, so it hears about this straight away.
	if name == "attacks" then
		pc.client.hello_now()
	end
end

local function choice_switch(name, value)
	local choice = CHOICES[name]
	local field = choice.field

	if value ~= nil then
		if not choice.values[value] then
			local names = {}

			for allowed in pairs(choice.values) do
				names[#names + 1] = allowed
			end

			table.sort(names)
			pc.say("Usage: /pingcomp %s %s", name, table.concat(names, "|"))

			return
		end

		pc[field] = value
	end

	pc.say("Ping Compensation %s is %s.", name, pc[field])

	if value ~= nil then
		pc.say("%s", SWITCH_NOTES[field][pc[field]])
	end

	pc.print("switch %s=%s role=%s", name, pc[field], role())
end

local function stat(name)
	return pc.stats[name] or 0
end

-- Everything here also goes to the console log (pc.say), because some players' VMF settings send echoes to chat only.
-- to_chat false writes the same lines to the console log only.
-- as_host: which side's lines to write, if not this machine's role now.
local function print_stats(to_chat, as_host)
	local out = to_chat == false and pc.print or pc.say
	local host = as_host

	if host == nil then
		host = pc.is_server()
	end

	out("Ping Compensation stats since the mission started (%s, message version %d):", host and "host" or "client", pc.VERSION)

	if host then
		local answer_count = stat("host_answer_time_n")
		local average = answer_count > 0 and stat("host_answer_time_sum") / answer_count * 1000 or 0
		local teleports = stat("host_teleports")

		out("Swings announced %d, answered %d: hit %d, blocked %d, miss %d, cut short %d, not judged %d.", stat("host_announced"), stat("host_answers"), stat("host_hit"), stat("host_blocked"), stat("host_miss"), stat("host_cut"), stat("host_unjudged"))
		out("Host would have judged differently %d. Never answered %d. Average answer time %.0f ms.", stat("host_disagree"), stat("host_unanswered"), average)
		local modded, matching = pc.host.modded_peer_count()

		out("Judged by the host after a client went quiet %d. Answers ignored %d, rejected %d. Modded clients now: %d, %d of them with your enemy data.", stat("host_judged_quiet_client"), stat("host_ignored"), stat("host_rejected"), modded, matching)
		out("Client staggers received %d, applied %d, own animation %d, overtaken %d, refused %d, never entered %d. Host staggers left to clients %d, followed by no client stagger or kill %d.", stat("host_stagger_received"), stat("host_stagger_applied"), stat("host_stagger_own_animation"), stat("host_stagger_overtaken"), stat("host_stagger_refused"), stat("host_stagger_not_entered"), stat("host_stagger_left_to_client"), stat("host_left_to_client_unanswered"))
		out("Client kills received %d, finished off here %d, already dead here %d.", stat("host_kill_received"), stat("host_kill_finished"), stat("host_kill_already_dead"))
		out("Client recoils applied %d, own animation %d, refused %d, never entered %d, cue brought forward %d, early cues ignored %d, leftover cues cleared %d. Moved to the client's spot %d times, average %.2f m.", stat("host_recoil_applied"), stat("host_recoil_own_animation"), stat("host_recoil_refused"), stat("host_recoil_not_entered"), stat("host_recoil_cue_brought_forward"), stat("host_recoil_early_cue_ignored"), stat("host_recoil_stale_cue_cleared"), teleports, teleports > 0 and stat("host_teleport_distance_sum") / teleports or 0)

		local sped_up = stat("host_stagger_sped_up")

		out("Client staggers sped up %d (average %.2fx), ended early %d, timer only (length not yet known) %d.", sped_up, sped_up > 0 and stat("host_stagger_speed_sum") / sped_up or 0, stat("host_stagger_ended_early"), stat("host_stagger_timer_only"))

		for name, value in pairs(pc.stats) do
			local breed_name = string.match(name, "^host_unanswered_(.+)$")

			if breed_name then
				out("Never answered, %s: %d.", breed_name, value)
			end
		end
	else
		local shown = stat("client_hit_shown")

		out("Swings announced %d, judged %d: hit %d, blocked %d, out of reach %d, outside the cone %d.", stat("client_announced"), stat("client_judged"), stat("client_hit"), stat("client_blocked"), stat("client_miss_reach"), stat("client_miss_cone"))
		out("Cut short %d, %d of them by your own push and %d by your stagger, kill or recoil. Pushes taken on a shield %d. Damage events after a cut %d.", stat("client_cut"), stat("client_cut_pushed"), stat("client_cut_by_reaction"), stat("client_push_on_shield"), stat("client_damage_after_cut"))
		out("Hits during a swing where a dodge was over your dodge count %d. Could not judge %d. Open right now %d.", stat("client_hit_over_dodge_count"), stat("client_unjudged"), pc.client.open_swing_count())
		out("Your staggers %d, kills %d, recoils %d, shields broken %d. Hits that didn't stagger %d. Host agreed %d, refused %d. Echoes dropped %d, host changes held back %d (replayed %d), no echo %d.", stat("client_stagger"), stat("client_kill"), stat("client_recoil"), stat("client_shield_broken"), stat("client_hit_no_stagger"), stat("client_ack_applied"), stat("client_ack_rejected"), stat("client_echo_dropped"), stat("client_held_back"), stat("client_held_replayed"), stat("client_echo_timeout"))
		out("Hits on you shown at once %d (average estimate %.1f), host copies dropped %d, never booked %d. Knockbacks shown %d, host copies dropped %d.", shown, shown > 0 and stat("client_hit_estimate_sum") / shown or 0, stat("client_hit_message_dropped"), stat("client_hit_never_booked"), stat("client_push_shown"), stat("client_push_message_dropped"))
		out("Host runs this build: %s. Enemy data: %s.", pc.host_fresh() and "yes" or "no (nothing is shown early)", pc.compat.state())
	end

	local lengths, own_lengths = pc.timings.count("length")
	local cues, own_cues = pc.timings.count("cue")

	out("Timings known: stagger lengths %d (%d measured here, %d this mission, %d readings ignored), recoil cues %d (%d measured here, %d this mission, %d readings ignored). /pingcomp timings writes them to the console log.", lengths, own_lengths, stat("timings_measured_length"), stat("timings_ignored_length"), cues, own_cues, stat("timings_measured_cue"), stat("timings_ignored_cue"))
	out("Switches: debug %s, attacks %s, recoil %s, predict %s, stagger %s, echo %s, facing %s, dodgecount %s.%s", pc.debug and "on" or "off", pc.attacks and "on" or "off", pc.recoil, pc.predict and "on" or "off", pc.stagger_timing, pc.echo and "on" or "off", pc.facing and "on" or "off", pc.dodgecount and "on" or "off", pc.broken and " The mod has switched itself off after errors." or "")
end

local SWITCHES = {
	debug = true,
	echo = true,
	attacks = true,
	predict = true,
	facing = true,
	dodgecount = true,
}

-- Words testers have typed for a command, mapped to the command.
local ALIASES = {
	attack = "attacks",
	dodge = "dodgecount",
}

-- Where a switch has an effect. Typed on the other side, it still changes, but the player is told it does nothing there.
local SWITCH_ROLE = {
	attacks = "client",
	recoil = "client",
	predict = "client",
	facing = "client",
	dodgecount = "client",
	stagger = "host",
	echo = "host",
}

local function note_role(action)
	local needed = SWITCH_ROLE[action]

	if needed and needed ~= role() then
		pc.say("Note: '%s' only does something on the %s's game. On yours it has no effect.", action, needed)
	end
end

mod:command("pingcomp", mod:localize("pingcomp_command_description"), function (...)
	local args = {}

	for i = 1, select("#", ...) do
		args[i] = tostring((select(i, ...)))
	end

	local action = args[1] and string.lower(args[1])
	local value = args[2] and string.lower(args[2])

	action = ALIASES[action] or action

	-- Nothing else in the log shows what someone typed, and testers' typos are worth seeing.
	pc.print("command /pingcomp %s role=%s", table.concat(args, " "), role())

	if action == "version" then
		if not mod:is_enabled() then
			-- VMF still runs commands for a disabled mod but drops its replies, so everyone would look like they
			-- don't have it.
			mod:echo("Ping Compensation is disabled.")
		else
			pc.version.start()
		end
	elseif SWITCHES[action] then
		switch(action, value)
		note_role(action)
	elseif CHOICES[action] then
		choice_switch(action, value)
		note_role(action)
	elseif action == "stats" then
		print_stats()
	elseif action == "timings" then
		-- After a playtest these lines are copied into DEFAULTS in Timings.lua.
		pc.timings.dump()

		local lengths, own_lengths = pc.timings.count("length")
		local cues, own_cues = pc.timings.count("cue")

		pc.say("Wrote %d stagger lengths (%d measured here) and %d recoil cues (%d measured here) to the console log.", lengths, own_lengths, cues, own_cues)
	elseif action == "mark" then
		-- A line testers can drop into their log at the moment something looked wrong.
		local note = table.concat(args, " ", 2)

		pc.print("MARK role=%s game_time=%.3f note=%s", role(), pc.now(), note)
		mod:echo("Marked in the console log: %s", note ~= "" and note or "(no note)")
	else
		if action then
			pc.say("Ping Compensation doesn't know '%s'.", args[1])
		end

		pc.say("%s", USAGE)
	end
end)

local function clear()
	pc.version.clear()
	pc.host.clear()
	pc.client.clear()
	pc.compat.clear()
	pc.timings.save()
end

-- Hooks stop running when the mod is disabled, so a swing that hasn't reached the host's damage frame yet simply
-- goes back to vanilla judging. A difficulty mod this client switched on to match its host goes off again.
mod.on_disabled = function ()
	pc.compat.restore("Ping Compensation is disabled")
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
	pc.guard("difficulty mods", pc.compat.update, dt)

	if pc.in_game() then
		hosted_last = pc.is_server()
	end
end

-- A fallback for players who don't type /pingcomp stats or /pingcomp timings: the same lines go to the console log,
-- not the chat, when a mission or the keep ends and when the game closes. The commands still work as before. A game
-- killed with Alt+F4 never gets here, but with the debug log on every event is in the log as it happens.
local summarised = nil -- the stats as last written, so the game closing right after a mission doesn't repeat them

local function stats_key()
	local names = {}

	for name, value in pairs(pc.stats) do
		names[#names + 1] = name .. "=" .. tostring(value)
	end

	table.sort(names)

	return table.concat(names, ",")
end

local function write_summary(reason)
	if next(pc.stats) == nil then
		return
	end

	local key = stats_key()

	if key == summarised then
		return
	end

	summarised = key

	pc.print("summary written because %s:", reason)
	print_stats(false, hosted_last)

	if (pc.stats.timings_measured_length or 0) + (pc.stats.timings_measured_cue or 0) > 0 then
		pc.timings.dump()
	end
end

-- VMF calls this when the mods reload and when the game closes.
mod.on_unload = function (exit_game)
	if exit_game then
		pc.guard("exit summary", write_summary, "the game is closing")
	end

	pc.timings.save()
end

-- Nothing may leak from one mission into the next.
mod.on_game_state_changed = function (status, state_name)
	if state_name == "StateIngame" then
		if status == "exit" then
			pc.guard("mission summary", write_summary, "the mission or keep ended")
		end

		clear()

		if status == "enter" then
			pc.reset_stats()
			pc.reset_errors()
		end
	end
end
