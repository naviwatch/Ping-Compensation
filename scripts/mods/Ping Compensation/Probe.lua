local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Tools for the calibration sessions Lance hosts alone (D46, D47).
--
-- /pingcomp probe, on the host, on the host's own staggers and recoils of any enemy (not a client's). Their animation
-- state machines aren't in the game's Lua, so what speeds an animation up is tried in game:
--   probe vars                   For one living enemy of each type, which of VARIABLES its animation state machine
--                                has, with their values (Unit.animation_find_variable).
--   probe speed <variable> <x>   Sets that variable to x just before and just after each animation starts, then logs
--                                how long the animation took to its cue against its timing at normal speed ("probe ...
--                                reached=..."). The variable goes back to its old value when the enemy's next reaction
--                                starts, or after RESTORE_AFTER. The 2026-11-14 session found that the covered enemies
--                                have only stagger_scale and move_speed, and that stagger_scale speeds up Skaven and
--                                ungor staggers only, and no enemy's recoils (D47).
--   probe state                  Logs the animation state the game sends to players who join mid-game
--                                (Unit.animation_get_state): as each animation starts, every STATE_EVERY seconds, and
--                                at its cue. It shows whether that state carries the animation's time (D47), which
--                                would let the host move an animation on for everyone.
--   probe jump <x>               Experimental: every frame, each value of that state that grew since the last frame
--                                (one that may be a time) grows x - 1 times as much again, and the state is set back
--                                (Unit.animation_set_state); the time to the cue is logged as for speed. If the cue
--                                never comes, the enemy is let go after GIVE_UP seconds.
--   probe off
-- Readings taken under speed and jump aren't learned. Only the host's own copy is changed, so players joined to that
-- session don't see it.
--
-- /pingcomp missing [enemy], on either side: the timings still missing for each covered enemy, or for one enemy of any
-- type, from its own animation lists. A summary per enemy goes to chat and every animation to the console log. Without
-- an enemy, the other enemy types get one summary line in chat, and their lists go to the console log too (D47).

local probe_tools = {}

pc.probe_tools = probe_tools

-- Animation variable names worth trying: the networked ones the game's enemies use (stagger_scale, reset_speed), the
-- ones it sets on units locally, and a few guesses.
local VARIABLES = {
	"stagger_scale",
	"reset_speed",
	"move_speed",
	"attack_speed",
	"movement_scale",
	"anim_speed",
	"animation_speed",
	"speed",
	"speed_scale",
	"anim_scale",
	"time_scale",
	"playback_speed",
	"blocked_scale",
	"stun_scale",
	"attack_time",
	"dodge_time",
}
local RESTORE_AFTER = 6 -- seconds a variable the probe set stays set
local MAX_FACTOR = 5
local STATE_EVERY = 0.1 -- seconds between the state lines of probe state and probe jump
local GIVE_UP = 4 -- seconds a traced reaction waits for its cue
local MAX_VALUES = 64 -- state values written per line
local MAX_STEP = 0.25 -- a state value that grows more than this in one frame isn't taken for a time

local setting = nil -- { mode = "speed" | "state" | "jump", variable = name, factor = number } while a probe is on
local changed = {} -- enemy unit -> { index, old, t } for a variable the probe set on it
local traces = {} -- enemy unit -> the reaction probe state or jump follows, until its cue

local function find_variable(unit, name)
	if not Unit.alive(unit) or not Unit.has_animation_state_machine(unit) then
		return nil
	end

	local ok, index = pcall(Unit.animation_find_variable, unit, name)

	return ok and index or nil
end

local function get_variable(unit, index)
	if not Unit.animation_get_variable then
		return nil
	end

	local ok, value = pcall(Unit.animation_get_variable, unit, index)

	return ok and type(value) == "number" and value or nil
end

local function restore(unit)
	local record = changed[unit]

	changed[unit] = nil

	if record and record.old and Unit.alive(unit) then
		pcall(Unit.animation_set_variable, unit, record.index, record.old)
	end
end

local function set_on(unit)
	local index = find_variable(unit, setting.variable)

	if not index then
		return false
	end

	if not changed[unit] then
		changed[unit] = {
			index = index,
			old = get_variable(unit, index),
		}
	end

	changed[unit].t = pc.now()

	return (pcall(Unit.animation_set_variable, unit, index, setting.factor))
end

local function pack(...)
	return select("#", ...), { ... }
end

-- The unit's animation state as the game sends it to a player joining mid-game (ai_locomotion_extension.lua:83), or
-- nil. values.n is how many there are.
local function get_state(unit)
	if not Unit.animation_get_state or not Unit.alive(unit) or not Unit.has_animation_state_machine(unit) then
		return nil
	end

	local count, result = pack(pcall(Unit.animation_get_state, unit))

	if not result[1] then
		return nil
	end

	local values = {
		n = count - 1,
	}

	for i = 2, count do
		values[i - 1] = result[i]
	end

	return values
end

local function format_state(values)
	if not values then
		return "none"
	end

	local parts = {}

	for i = 1, math.min(values.n, MAX_VALUES) do
		local value = values[i]

		if type(value) == "number" then
			parts[i] = value == math.floor(value) and string.format("%.0f", value) or string.format("%.4f", value)
		else
			parts[i] = tostring(value)
		end
	end

	return string.format("(%d) %s%s", values.n, table.concat(parts, ","), values.n > MAX_VALUES and ",..." or "")
end

local function log_state(trace, what, values)
	pc.log("probe state enemy=%s kind=%s anim=%s mode=%s %s at=%.3f values=%s", tostring(trace.breed_name), trace.kind, tostring(trace.anim), trace.mode, what, pc.now() - trace.t, format_state(values))
end

-- probe jump: every value that grew since the last frame by a small amount, as a time would, grows (factor - 1) times
-- as much again, and the state is set back. Returns the values as set, or nil if the engine refused them.
local function jump(unit, trace, values)
	local previous = trace.previous
	local moved = false

	for i = 1, values.n do
		local value, before = values[i], previous[i]

		if type(value) == "number" and type(before) == "number" and value ~= math.floor(value) and value > before and value - before < MAX_STEP then
			local new = value + (trace.factor - 1) * (value - before)

			-- A value that stays between 0 and 1 may be a blend weight or a share of the animation: kept within 1.
			if before >= 0 and value <= 1 then
				new = math.min(new, 1)
			end

			values[i] = new
			moved = true
		end
	end

	if moved then
		local ok, problem = pcall(Unit.animation_set_state, unit, unpack(values, 1, values.n))

		if not ok then
			log_state(trace, "set_state failed (" .. tostring(problem) .. ")", values)

			return nil
		end

		trace.jumps = (trace.jumps or 0) + 1
	end

	return values
end

-- A reaction the probe moved on whose cue never came: what the cue would have done, so the enemy doesn't stay stuck.
local function let_go(unit, kind)
	local blackboard = BLACKBOARDS[unit]

	if not blackboard then
		return
	end

	if kind == "length" then
		blackboard.stagger_anim_done = true
	else
		blackboard.anim_cb_blocked_cooldown = true
	end
end

-- Called before BTStaggerAction.enter and BTBlockedAction.enter on the host for an enemy's own (not a client's)
-- reaction: a variable set before the animation starts is what a state picks up as it starts.
function probe_tools.before_reaction(unit)
	if changed[unit] then
		restore(unit)
	end

	traces[unit] = nil

	if setting and setting.mode == "speed" then
		set_on(unit)
	end
end

-- Called after the host's own stagger (kind "length") or recoil (kind "cue") of an enemy has started. probe speed sets
-- the variable again, in case the state reads it as it plays; probe state and jump start following the animation's
-- state. Returns the factor its readings are taken at, or nil if they are taken at normal speed (no probe, probe
-- state, or an enemy without that variable).
function probe_tools.reaction_entered(unit, kind, anim, breed_name)
	if not setting then
		return nil
	end

	if setting.mode == "speed" then
		if not set_on(unit) then
			return nil
		end

		pc.log("probe start enemy=%s kind=%s anim=%s variable=%s factor=%.2f", tostring(breed_name), kind, tostring(anim), setting.variable, setting.factor)

		return setting.factor
	end

	local now = pc.now()
	local trace = {
		kind = kind,
		anim = anim,
		breed_name = breed_name,
		mode = setting.mode,
		factor = setting.factor,
		t = now,
		next_log = now + STATE_EVERY,
	}

	trace.previous = get_state(unit)
	traces[unit] = trace

	log_state(trace, "start", trace.previous)

	return setting.mode == "jump" and setting.factor or nil
end

-- A probed reaction reached a cue: how long it took, against the timing of that animation at normal speed.
function probe_tools.reaction_timed(unit, kind, breed_name, anim, elapsed, after, factor)
	local normal = pc.timings.get(kind, breed_name, anim, after)
	local reached = normal and elapsed > 0 and normal / elapsed or nil
	local how = setting and (setting.mode == "jump" and "jump" or setting.variable) or "?"

	pc.count("probe_readings")
	pc.log("probe %s enemy=%s anim=%s after=%s variable=%s factor=%.2f took=%.3fs normal=%s reached=%s", kind, tostring(breed_name), tostring(anim), tostring(after), tostring(how), factor, elapsed,
		normal and string.format("%.3fs", normal) or "unknown", reached and string.format("%.2f", reached) or "unknown")
end

-- Called at every cue of the host's own staggers and recoils: the state as it reached its cue, and the end of its trace.
function probe_tools.cue_reached(unit, kind)
	local trace = traces[unit]

	if not trace then
		return
	end

	traces[unit] = nil

	log_state(trace, string.format("cue=%s jumps=%d", kind, trace.jumps or 0), get_state(unit))
end

local function living_enemies()
	local by_breed = {}

	for unit, blackboard in pairs(BLACKBOARDS) do
		local breed = blackboard and blackboard.breed

		if breed and breed.name and not breed.is_player and not by_breed[breed.name] and Unit.alive(unit) and HEALTH_ALIVE[unit] then
			by_breed[breed.name] = unit
		end
	end

	return by_breed
end

local function sorted_keys(t)
	local keys = {}

	for key in pairs(t) do
		keys[#keys + 1] = key
	end

	table.sort(keys)

	return keys
end

local function probe_vars()
	local by_breed = living_enemies()
	local breeds = sorted_keys(by_breed)

	for _, breed_name in ipairs(breeds) do
		local unit = by_breed[breed_name]
		local has, lacks = {}, {}

		for _, name in ipairs(VARIABLES) do
			local index = find_variable(unit, name)

			if index then
				local value = get_variable(unit, index)

				has[#has + 1] = string.format("%s=%s", name, value and string.format("%.2f", value) or "?")
			else
				lacks[#lacks + 1] = name
			end
		end

		pc.print("probe vars enemy=%s has: %s; lacks: %s", breed_name, #has > 0 and table.concat(has, ", ") or "none", #lacks > 0 and table.concat(lacks, ", ") or "none")
		pc.print("probe vars enemy=%s state=%s", breed_name, format_state(get_state(unit)))
	end

	pc.say("Probe: checked the animation variables of %d enemy types (%s). See the console log.", #breeds, #breeds > 0 and table.concat(breeds, ", ") or "spawn some enemies first")
end

local function stop()
	setting = nil

	for unit in pairs(changed) do
		restore(unit)
	end

	traces = {}
end

function probe_tools.command(args)
	local what = args[2] and string.lower(args[2])

	if not pc.is_server() then
		pc.say("The probe only runs on the host's game.")

		return
	end

	if what == "vars" then
		probe_vars()
	elseif what == "speed" then
		local variable = args[3] and string.lower(args[3])
		local factor = tonumber(args[4])

		if not variable or not factor or factor <= 0 or factor > MAX_FACTOR then
			pc.say("Usage: /pingcomp probe speed <variable> <factor>, for example /pingcomp probe speed stagger_scale 2")

			return
		end

		stop()

		setting = {
			mode = "speed",
			variable = variable,
			factor = factor,
		}

		pc.say("Probe on: your own recoils and staggers play with %s set to %.2f. /pingcomp probe off stops it.", variable, factor)
	elseif what == "state" then
		stop()

		setting = {
			mode = "state",
		}

		pc.say("Probe on: the animation state of your own recoils and staggers goes to the console log. /pingcomp probe off stops it.")
	elseif what == "jump" then
		local factor = tonumber(args[3])

		if not factor or factor <= 1 or factor > MAX_FACTOR then
			pc.say("Usage: /pingcomp probe jump <factor>, for example /pingcomp probe jump 2")

			return
		end

		stop()

		setting = {
			mode = "jump",
			factor = factor,
		}

		pc.say("Probe on (experimental): your own recoils and staggers jump ahead through their animation state, %.2f times as fast. /pingcomp probe off stops it.", factor)
	elseif what == "off" then
		stop()

		pc.say("Probe off.")
	else
		pc.say("Usage: /pingcomp probe vars | speed <variable> <factor> | state | jump <factor> | off")
	end
end

function probe_tools.update()
	local t = pc.now()

	for unit, record in pairs(changed) do
		if not Unit.alive(unit) then
			changed[unit] = nil
		elseif record.t and t - record.t > RESTORE_AFTER then
			restore(unit)
		end
	end

	for unit, trace in pairs(traces) do
		if not Unit.alive(unit) then
			traces[unit] = nil
		elseif t - trace.t > GIVE_UP then
			traces[unit] = nil

			log_state(trace, string.format("no cue within %.1fs, jumps=%d", GIVE_UP, trace.jumps or 0), get_state(unit))

			if trace.mode == "jump" then
				let_go(unit, trace.kind)
			end
		else
			local values = get_state(unit)

			if values and trace.mode == "jump" and trace.previous then
				values = jump(unit, trace, values)

				if not values then
					traces[unit] = nil
				end
			end

			if values then
				trace.previous = values

				if t >= trace.next_log then
					trace.next_log = t + STATE_EVERY

					log_state(trace, "during", values)
				end
			end
		end
	end
end

function probe_tools.clear()
	changed = {}
	traces = {}
end

-- Every enemy type with stagger or recoil animations, covered or not, sorted.
local function timing_breeds()
	local list = {}

	for name, breed in pairs(Breeds) do
		if type(breed) == "table" and breed.name == name and not breed.is_player then
			local staggers, recoils = pc.reactions.timing_animations(breed)

			if next(staggers) ~= nil or #recoils > 0 then
				list[#list + 1] = name
			end
		end
	end

	table.sort(list)

	return list
end

-- What one enemy type still lacks. A stagger animation lacks its length; a recoil animation after an attack lacks both
-- its cue and its stunned cue (either one ends the recoil on time). Every animation goes to the console log, and a
-- summary to chat if to_chat. Returns the stagger and recoil counts missing and in all.
local function missing_of(breed_name, to_chat)
	local breed = Breeds[breed_name]
	local staggers, recoils, attacks = pc.reactions.timing_animations(breed)
	local by_type = {}
	local stagger_total, stagger_missing = 0, 0

	for anim, stagger_type in pairs(staggers) do
		stagger_total = stagger_total + 1

		if not pc.timings.get("length", breed_name, anim) then
			stagger_missing = stagger_missing + 1
			by_type[stagger_type] = by_type[stagger_type] or {}
			table.insert(by_type[stagger_type], anim)
		end
	end

	local type_counts = {}

	for _, stagger_type in ipairs(sorted_keys(by_type)) do
		local list = by_type[stagger_type]

		table.sort(list)
		type_counts[#type_counts + 1] = string.format("%s %d", pc.stagger_name(stagger_type), #list)
		pc.print("missing enemy=%s stagger=%s (%d): %s", breed_name, pc.stagger_name(stagger_type), #list, table.concat(list, ", "))
	end

	local recoil_total, recoil_missing = 0, 0
	local attack_counts = {}

	for _, attack in ipairs(attacks) do
		local missing_here = 0

		for _, attack_anim in ipairs(attack.anims) do
			local lacking = {}

			for _, recoil in ipairs(recoils) do
				recoil_total = recoil_total + 1

				if not pc.timings.get("cue", breed_name, recoil, attack_anim) and not pc.timings.get("stunned", breed_name, recoil, attack_anim) then
					recoil_missing = recoil_missing + 1
					missing_here = missing_here + 1
					lacking[#lacking + 1] = recoil
				end
			end

			if #lacking > 0 then
				pc.print("missing enemy=%s recoil after=%s (%s): %s", breed_name, attack_anim, attack.name, table.concat(lacking, ", "))
			end
		end

		if missing_here > 0 then
			attack_counts[#attack_counts + 1] = string.format("%s %d", attack.name, missing_here)
		end
	end

	pc.print("missing enemy=%s summary: staggers %d of %d missing, recoils %d of %d missing", breed_name, stagger_missing, stagger_total, recoil_missing, recoil_total)

	if to_chat then
		pc.say("%s: staggers %d of %d missing%s; recoils %d of %d missing%s.", breed_name, stagger_missing, stagger_total, #type_counts > 0 and " (" .. table.concat(type_counts, ", ") .. ")" or "", recoil_missing, recoil_total,
			#attack_counts > 0 and " (" .. table.concat(attack_counts, ", ") .. ")" or "")
	end

	return stagger_missing, stagger_total, recoil_missing, recoil_total
end

-- /pingcomp missing [enemy]: what each covered enemy still lacks, or one enemy of any type; the others in one line.
function probe_tools.missing(filter)
	if filter then
		local breed = Breeds[filter]

		if type(breed) ~= "table" or breed.is_player then
			pc.say("'%s' isn't an enemy type. Covered enemies: %s.", tostring(filter), table.concat(sorted_keys(pc.REACTION_BREEDS), ", "))

			return
		end

		missing_of(filter, true)

		return
	end

	local others, stagger_missing, stagger_total, recoil_missing, recoil_total = 0, 0, 0, 0, 0

	for _, breed_name in ipairs(timing_breeds()) do
		local covered = pc.REACTION_BREEDS[breed_name] == true
		local a, b, c, d = missing_of(breed_name, covered)

		if not covered then
			others = others + 1
			stagger_missing = stagger_missing + a
			stagger_total = stagger_total + b
			recoil_missing = recoil_missing + c
			recoil_total = recoil_total + d
		end
	end

	pc.say("Other enemies (%d types): staggers %d of %d missing; recoils %d of %d missing. Their lists are in the console log.", others, stagger_missing, stagger_total, recoil_missing, recoil_total)
end
