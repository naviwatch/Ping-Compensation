local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Tools for the calibration session Lance hosts alone (D46).
--
-- /pingcomp probe, on the host: whether an enemy's recoil or stagger animation can be played faster, for the host's
-- copy of a client's recoil (D45) and for the Chaos enemies' and ungors' staggers (T9). Their animation state machines
-- aren't in the game's Lua, so it is tried in game:
--   probe vars                   For one living enemy of each covered breed, which of VARIABLES its animation state
--                                machine has, with their values (Unit.animation_find_variable).
--   probe speed <variable> <x>   On the host's own recoils and staggers of covered enemies, sets that variable to x
--                                just before and just after the animation starts, then logs how long the animation took
--                                to its cue against its timing at normal speed ("probe ... reached=..."). Readings taken
--                                this way aren't learned (Timings.lua). The variable goes back to its old value when the
--                                enemy's next reaction starts, or after RESTORE_AFTER.
--   probe off
-- Only the host's own copy is changed, so players joined to that session don't see it.
--
-- /pingcomp missing [enemy], on either side: the timings still missing for each covered enemy (or one), from its own
-- animation lists, so a calibration session can check what is left. A summary per enemy goes to chat, every animation
-- to the console log.

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

local setting = nil -- { variable = name, factor = number } while /pingcomp probe speed is on
local changed = {} -- enemy unit -> { index, old, t } for a variable the probe set on it

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

-- Called before BTStaggerAction.enter and BTBlockedAction.enter on the host for a covered enemy's own (not a
-- client's) reaction: a variable set before the animation starts is what a state picks up as it starts.
function probe_tools.before_reaction(unit)
	if changed[unit] then
		restore(unit)
	end

	if setting then
		set_on(unit)
	end
end

-- Called after the host's own stagger (kind "length") or recoil (kind "cue") of a covered enemy has started. Sets the
-- variable again, in case the state reads it as it plays, and returns the factor its readings were taken at, or nil
-- if the probe is off or the enemy has no such variable.
function probe_tools.reaction_entered(unit, kind, anim, breed_name)
	if not setting or not set_on(unit) then
		return nil
	end

	pc.log("probe start enemy=%s kind=%s anim=%s variable=%s factor=%.2f", tostring(breed_name), kind, tostring(anim), setting.variable, setting.factor)

	return setting.factor
end

-- A probed reaction reached a cue: how long it took, against the timing of that animation at normal speed.
function probe_tools.reaction_timed(unit, kind, breed_name, anim, elapsed, after, factor)
	local normal = pc.timings.get(kind, breed_name, anim, after)
	local reached = normal and elapsed > 0 and normal / elapsed or nil

	pc.count("probe_readings")
	pc.log("probe %s enemy=%s anim=%s after=%s variable=%s factor=%.2f took=%.3fs normal=%s reached=%s", kind, tostring(breed_name), tostring(anim), tostring(after), setting and setting.variable or "?", factor, elapsed,
		normal and string.format("%.3fs", normal) or "unknown", reached and string.format("%.2f", reached) or "unknown")
end

local function covered_units()
	local by_breed = {}

	for unit, blackboard in pairs(BLACKBOARDS) do
		local breed = blackboard and blackboard.breed

		if breed and pc.REACTION_BREEDS[breed.name] and not by_breed[breed.name] and Unit.alive(unit) and HEALTH_ALIVE[unit] then
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
	local by_breed = covered_units()
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
	end

	pc.say("Probe: checked the animation variables of %d enemy types (%s). See the console log.", #breeds, #breeds > 0 and table.concat(breeds, ", ") or "spawn some covered enemies first")
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

		setting = {
			variable = variable,
			factor = factor,
		}

		pc.say("Probe on: your own recoils and staggers of covered enemies play with %s set to %.2f. /pingcomp probe off stops it.", variable, factor)
	elseif what == "off" then
		setting = nil

		for unit in pairs(changed) do
			restore(unit)
		end

		pc.say("Probe off.")
	else
		pc.say("Usage: /pingcomp probe vars | speed <variable> <factor> | off")
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
end

function probe_tools.clear()
	changed = {}
end

-- /pingcomp missing [enemy]: what each covered enemy still lacks. A stagger animation lacks its length; a recoil
-- animation after a single attack lacks both its cue and its stunned cue (either one ends the recoil on time).
function probe_tools.missing(filter)
	local breeds = {}

	for breed_name in pairs(pc.REACTION_BREEDS) do
		if not filter or filter == breed_name then
			breeds[#breeds + 1] = breed_name
		end
	end

	table.sort(breeds)

	if #breeds == 0 then
		pc.say("'%s' isn't one of the covered enemies: %s.", tostring(filter), table.concat(sorted_keys(pc.REACTION_BREEDS), ", "))

		return
	end

	for _, breed_name in ipairs(breeds) do
		local breed = Breeds[breed_name]

		if breed then
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

			pc.say("%s: staggers %d of %d missing%s; recoils %d of %d missing%s.", breed_name, stagger_missing, stagger_total, #type_counts > 0 and " (" .. table.concat(type_counts, ", ") .. ")" or "", recoil_missing, recoil_total,
				#attack_counts > 0 and " (" .. table.concat(attack_counts, ", ") .. ")" or "")
		end
	end
end
