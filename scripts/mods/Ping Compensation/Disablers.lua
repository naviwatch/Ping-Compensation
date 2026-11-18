local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Client side of D53. When a disabler's hook, grab or pounce lands on this player's screen (Client.lua, family F), this
-- client puts its own player in the grabbed or pinned state at once, the way the host's status message would a round
-- trip later: it calls the same status setter the message's handler calls (StatusSystem.rpc_status_change_bool), so the
-- player's own character state machine, camera and animations do what they always do. Then:
--   * the host's own copy of that message (the echo) is dropped, because the setter would play the grab again, and so
--     is a leech's second "start_beam", which would draw the beam twice;
--   * a gutter runner is moved onto the player and held there every frame until the host's pin arrives, because a
--     pinned player moves with the gutter runner (GenericStatusExtension.set_pounced_down, generic_status_extension
--     .lua:1104), and the host's copy is still flying;
--   * if the host refuses (the special died or was staggered there first) or nothing confirms it within
--     pc.GRAB_CONFIRM, the client undoes it with the game's own release statuses.
-- The next steps (the drag, the hoist, the drain, the release) come from the host as in vanilla.

local disablers = {}

pc.disablers = disablers

-- The status each kind's echo carries (BTPackMasterInitialPullAction.enter, BTCorruptorGrabAction.run,
-- BTTargetPouncedAction.enter).
local ECHO_STATUS = {
	hook = "pack_master_pulling",
	grab = "chaos_corruptor_grabbed",
	pounce = "pounced_down",
}

local shown = {} -- swing id -> what this screen shows
local by_unit = {} -- special unit -> the same record

local function position(unit)
	return POSITION_LOOKUP[unit] or Unit.world_position(unit, 0)
end

local function forget(record)
	shown[record.id] = nil

	if by_unit[record.unit] == record then
		by_unit[record.unit] = nil
	end
end

function disablers.active()
	return next(shown) ~= nil
end

-- Client.lua: the swing's hook, grab or pounce landed on this screen, and its answer has gone to the host.
function disablers.start(swing, unit, target)
	local status = ScriptUnit.has_extension(target, "status_system")

	if not status or not Unit.alive(unit) or not Unit.alive(target) then
		return
	end

	local t = pc.now()
	local kind = swing.kind
	local record = {
		id = swing.id,
		kind = kind,
		unit = unit,
		go_id = swing.go_id,
		target = target,
		breed_name = swing.breed.name,
		started_t = t,
		deadline = t + pc.GRAB_CONFIRM,
		confirmed = false,
	}

	shown[record.id] = record
	by_unit[unit] = record

	if kind == "pounce" then
		-- The host's pounce teleports the gutter runner onto the player before it pins them (bt_target_pounced_action
		-- .lua:52). The player's own state then plays its jump_attack on both (player_character_state_pounced_down.lua:28).
		record.position = Vector3Box(position(target))
		Unit.set_local_position(unit, 0, record.position:unbox())
		status:set_pounced_down(true, unit)
	elseif kind == "hook" then
		status:set_pack_master("pack_master_pulling", true, unit)
	else
		status:set_grabbed_by_corruptor("chaos_corruptor_grabbed", true, unit)

		-- What the host's next message does on every machine (AISystem.rpc_set_corruptor_beam_state): the beam from the
		-- leech to the player, in place of the projectile.
		local beam = ScriptUnit.has_extension(unit, "ai_beam_effect_system")

		if beam and beam.set_state then
			beam:set_state("start_beam", target)

			record.beam = true
		end
	end

	pc.count("client_grab_shown")
	pc.log("client grab=%d enemy=%s kind=%s shown at once", record.id, record.breed_name, kind)
end

-- The game's own way out of each state, as the host's release messages do it (BTPackMasterAttackAction.leave,
-- BTCorruptorGrabAction.leave, BTTargetPouncedAction.leave).
local function undo(record, reason)
	local target = record.target
	local unit = record.unit
	local status = Unit.alive(target) and ScriptUnit.has_extension(target, "status_system")

	if status then
		if record.kind == "hook" then
			if status.pack_master_grabber == unit then
				status:set_pack_master("pack_master_pulling", false, unit)
			end
		elseif record.kind == "grab" then
			if status.grabbed_by_corruptor and status.corruptor_unit == unit then
				status:set_grabbed_by_corruptor("chaos_corruptor_released", false, unit)
			end
		elseif status.pounced_down and status.pouncer_unit == unit then
			status:set_pounced_down(false, unit)
		end
	end

	local beam = record.beam and Unit.alive(unit) and ScriptUnit.has_extension(unit, "ai_beam_effect_system")

	if beam and beam.set_state then
		beam:set_state("stop_beam", target)
	end

	forget(record)

	pc.count("client_grab_undone")
	pc.log("client grab=%d enemy=%s kind=%s undone: %s, after %.3fs", record.id, record.breed_name, record.kind, reason, pc.now() - record.started_t)
end

-- The host's acknowledgement of a grab this screen showed (Host.lua, book_disabler).
function disablers.acknowledged(id, result)
	local record = shown[id]

	if not record then
		return
	end

	if result == "applied" then
		pc.count("client_grab_applied")
	else
		pc.count("client_grab_refused")
		undo(record, "the host refused it")
	end
end

-- StatusSystem.rpc_status_change_bool from the host. Returns true to drop it: the echo of a grab or pin this screen
-- already shows. Anything else about this player and that special goes on to the game.
function disablers.status_message(status_id, status_bool, game_object_id, other_object_id)
	local unit_storage = Managers.state.unit_storage
	local special = unit_storage:unit(other_object_id)
	local record = special and by_unit[special]

	if not record or unit_storage:unit(game_object_id) ~= record.target then
		return false
	end

	local status_name = NetworkLookup.statuses[status_id]

	if status_bool and status_name == ECHO_STATUS[record.kind] and not record.confirmed then
		record.confirmed = true
		-- The host has it now: its gutter runner is on the player, and the host's next steps follow.
		record.position = nil

		pc.count("client_grab_confirmed")
		pc.log("client grab=%d enemy=%s kind=%s confirmed by the host after %.3fs", record.id, record.breed_name, record.kind, pc.now() - record.started_t)

		-- The pin's setter does nothing for a pin it already has (generic_status_extension.lua:1082), so that echo
		-- can go through; the others would play the grab again.
		return record.kind ~= "pounce"
	end

	return false
end

-- AISystem.rpc_set_corruptor_beam_state from the host. Returns true to drop the second start of a beam this screen
-- already started.
function disablers.beam_message(unit_id, state)
	local unit = Managers.state.unit_storage:unit(unit_id)
	local record = unit and by_unit[unit]

	if record and record.beam and state == "start_beam" and not record.beam_echoed then
		record.beam_echoed = true

		return true
	end

	return false
end

-- While a pin waits for the host, the host's animations for that gutter runner are from its own leap, still flying or
-- landing there. Returns true to drop them.
function disablers.holds(unit)
	local record = by_unit[unit]

	return record ~= nil and record.kind == "pounce" and record.position ~= nil
end

-- Every frame after LocomotionSystem.update, which has just moved every enemy copy by the host's numbers.
function disablers.after_locomotion(t)
	for unit, record in pairs(by_unit) do
		if record.position then
			if Unit.alive(unit) and HEALTH_ALIVE[unit] then
				Unit.set_local_position(unit, 0, record.position:unbox())
			else
				record.position = nil
			end
		end
	end
end

function disablers.update()
	if next(shown) == nil then
		return
	end

	local t = pc.now()

	for _, record in pairs(shown) do
		if t > record.deadline then
			if record.confirmed then
				forget(record)
			else
				pc.count("client_grab_timeout")
				undo(record, "the host never confirmed it")
			end
		end
	end
end

-- Once the mod has switched itself off on this screen (Client.lua), nothing else would ever end a grab or pin shown at
-- once that the host hasn't confirmed, so it is undone; one the host has confirmed is the host's to end (D57 review).
function disablers.release_all(reason)
	for _, record in pairs(shown) do
		if record.confirmed then
			forget(record)
		else
			undo(record, reason)
		end
	end
end

function disablers.clear()
	shown = {}
	by_unit = {}
end

-- The host's status messages for players. Only while this screen shows a grab; everything except the original call
-- runs through pc.guard.
mod:hook("StatusSystem", "rpc_status_change_bool", function (func, self, channel_id, status_id, status_bool, game_object_id, other_object_id)
	if not pc.broken and next(shown) ~= nil and not pc.is_server() then
		local ok, drop = pc.guard("client grab echo", disablers.status_message, status_id, status_bool, game_object_id, other_object_id)

		if ok and drop then
			return
		end
	end

	-- A vortex's catch this screen shows (Areas.lua, D53): the host's echo is dropped, and its own vortex statuses for
	-- this player are those this screen sets itself.
	if not pc.broken and pc.areas and not pc.is_server() then
		local ok, drop = pc.guard("client vortex echo", pc.areas.status_message, status_id, status_bool, game_object_id, other_object_id)

		if ok and drop then
			return
		end
	end

	return func(self, channel_id, status_id, status_bool, game_object_id, other_object_id)
end)

mod:hook("AISystem", "rpc_set_corruptor_beam_state", function (func, self, channel_id, unit_id, state, target_unit_id)
	if not pc.broken and next(shown) ~= nil and not pc.is_server() then
		local ok, drop = pc.guard("client beam echo", disablers.beam_message, unit_id, state)

		if ok and drop then
			return
		end
	end

	return func(self, channel_id, unit_id, state, target_unit_id)
end)
