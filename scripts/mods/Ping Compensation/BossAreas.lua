local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Build 6.1 (D60, D66, D70, D71): the bosses' areas, judged on every modded player's screen for that player alone (D55),
-- from their live position, shown there at once (D11, D62), with their damage ticks counted there (D58). The host leaves
-- a modded player out of its own test and books what that player's client reports (pc_area), as vanilla would have.
--   * The troll's vomit (BTVomitAction, bt_vomit_action.lua): the puke point as the host works it out, from this screen's
--     copies of the troll and of its target (on the target's screen, their live position), then the 0.5 m sweep from the
--     troll's head to it while the troll pukes. Only the target's screen turns the troll. A hit starts this screen's own
--     copy of bile_troll_vomit_face_base and is reported.
--   * The stormfiend's beam (BTStormfiendShootAction with the warpfire setup): while the beam is on here, the 0.4 m sweep
--     from its copy's muzzle to the synced aim point, stopping at the first thing that isn't a character. A hit starts
--     this screen's own copy of stormfiend_warpfire_face_base and is reported.
--   * Pools and fire walls (LiquidAreaDamageExtension): the pool's grid rebuilt here from its template, its cells the
--     host's blobs, tested at this player's feet every frame. Stepping in starts this screen's own copy of the pool's
--     buff and is reported, stepping out ends it. A pool that hurts by pulses ticks on this screen's copy of its timer.
--   * Plague waves (DamageWaveExtension): a wave rolling into this player pushes them at once, again every 0.1 s while
--     they stay in front, and the first time this screen's own copy of the wave's face buff starts, reported.
-- A face buff pushes this player once, by this screen's own copy of it (D71); every other machine's later push is dropped.
-- The buffs' ticks are shown here and reported (Areas.lua's burning hook, which also drops the host's copies of them).

local boss_areas = {}

pc.boss_areas = boss_areas

local VOMIT_FILTER = "filter_enemy_ray_projectile" -- BTVomitAction.player_vomit_hit_check (bt_vomit_action.lua:262)
local VOMIT_RADIUS = 0.5
local VOMIT_MAX_HITS = 10
local VOMIT_REAIM = 0.2 -- seconds between the puke point's updates (:198, :206)
local VOMIT_CHECK_DELAY = 0.2 -- the host's first sweep, after it starts puking (:192)
local VOMIT_FACE_BUFF = "bile_troll_vomit_face_base" -- :278
local VOMIT_FACE_TYPE = "troll_bile_face" -- :277
local BEAM_FILTER = "filter_enemy_player_ray_projectile" -- BTStormfiendShootAction.shoot_hit_check (bt_stormfiend_shoot_action.lua:604)
local BEAM_RADIUS = 0.4 -- SPHERE_CAST_RADIUS (:21)
local BEAM_MAX_HITS = 10 -- SPHERE_CAST_MAX_NUM_HITS (:22)
local BEAM_FACE_BUFF = "stormfiend_warpfire_face_base" -- :634
local BEAM_FACE_TYPE = "stormfiend_warpfire_face" -- :631
local BEAM_LINGER = 1 -- seconds a beam is kept past its longest firing time, unless the host turns it off first
local PULSE_INTERVAL = 0.75 -- LiquidAreaDamageExtension.update (liquid_area_damage_extension.lua:590)
local PLAYER_POOL_ARMOR = 4 -- what _update_collision_detection files a player under (:661), which _pulse_damage reads (:791)
local POOL_REPORT_INTERVAL = 1 -- seconds between this screen's reports that its player is still in a pool with a buff
local GRID_TOLERANCE = 0.1 -- metres between the rebuilt grid's cell and the host's blob before the grid counts as off
local WAVE_DISPLACED = 0.1 -- seconds a wave leaves a player it pushed alone (AiUtils.push_intersecting_players, ai_utils.lua:1510)
local SENT_MEMORY = 10 -- seconds the host remembers which players a vomit went to, for their face buff's ticks
local PLAYER_MIDDLE = 0.9 -- metres above a player's feet, for the check of what the game's sweeps find here
-- D71 (option (c), Lance, 2026-11-24): how many times a face buff (the vomit's, a plague wave's, the grey seer's) pushes
-- this player at once. 1: only by this screen's own copy of the buff, whose apply pushes (apply_vomit_in_face,
-- buff_function_templates.lua:1219). Every other human machine's copy pushes them too, a ping or more later: the host's,
-- and each other client's through the host (player_husk_locomotion_extension.lua:81). Those late pushes are dropped
-- (HitResults.lua, expect_pushes). The plan's two (D70) would be 2, vanilla's total the number of human players. To
-- review after the playtest (T25).
local FACE_PUSHES = 1

local function unit_of(go_id)
	return type(go_id) == "number" and Managers.state.unit_storage:unit(go_id) or nil
end

local function go_of(unit)
	return unit and Managers.state.unit_storage:go_id(unit) or nil
end

local function judging()
	return not pc.broken and not pc.is_server() and pc.host_fresh()
end

local function report(kind, go_id, inside)
	local host_peer = pc.host_peer()

	if host_peer and go_id then
		mod:network_send("pc_area", host_peer, pc.VERSION, kind, go_id, inside and true or false)
	end
end

-- Whether this player's dodge counts, as Client.lua judges it: the weapon's dodge count applies while /pingcomp
-- dodgecount is on (D25).
local function own_dodge(status)
	if pc.dodgecount then
		return status:get_is_dodging() == true
	end

	return status.is_dodging == true
end

local node_actions = {} -- "<breed>/<node class>" -> the action of that node in the breed's tree, or false

local function node_action(breed, class_name, accept)
	if not breed then
		return nil
	end

	local key = breed.name .. "/" .. class_name
	local cached = node_actions[key]

	if cached ~= nil then
		return cached or nil
	end

	local node = pc.find_node(pc.tree_of(breed), function (candidate)
		return candidate[1] == class_name and type(candidate.action_data) == "table" and (not accept or accept(candidate.action_data))
	end)
	local action = node and node.action_data or false

	node_actions[key] = action

	return action or nil
end

-- Every breed that runs the node (principle 4): the troll and the troll chief.
local function vomit_action(breed)
	return node_action(breed, "BTVomitAction")
end

-- The stormfiend's shooting with the warpfire setup, its default (bt_stormfiend_shoot_action.lua:222): the stormfiend and
-- the prologue's. Deathrattler's is the ratling gun's (Shots.lua).
local function beam_action(breed)
	return node_action(breed, "BTStormfiendShootAction", function (action)
		return action.weapon_setup ~= "ratling_gun"
	end)
end

boss_areas.vomit_action = vomit_action
boss_areas.beam_action = beam_action

local function buff_sub(name)
	local template = BuffUtils.get_buff_template(name)

	return template and template.buffs and template.buffs[1] or nil
end

-- The modded players a host test leaves out, while it runs: the side's list goes back after it (restore_hidden). Plain
-- table work, so that it can't stop halfway.
local hidden_lists = {}

function boss_areas.hide_modded(side, field)
	local units = side and side[field]

	if type(units) ~= "table" then
		return false
	end

	local kept = nil

	for i = 1, #units do
		if pc.host.client_judges(units[i]) then
			kept = {}

			break
		end
	end

	if not kept then
		return false
	end

	for i = 1, #units do
		if not pc.host.client_judges(units[i]) then
			kept[#kept + 1] = units[i]
		end
	end

	hidden_lists[#hidden_lists + 1] = {
		side = side,
		field = field,
		units = units,
	}
	side[field] = kept

	return true
end

function boss_areas.restore_hidden()
	for i = #hidden_lists, 1, -1 do
		local entry = hidden_lists[i]

		entry.side[entry.field] = entry.units
		hidden_lists[i] = nil
	end
end

-- Host ---------------------------------------------------------------------------------------------------------------

local vomits_sent = {} -- troll unit -> { players = { [player unit] = peer }, t, logged } for its latest vomit

-- A troll starts its vomit (BTVomitAction.enter, bt_vomit_action.lua:19): every modded player is told, aimed for its
-- target, whose own screen turns the troll. Every modded player's own screen judges the vomit for them from now on, as
-- the warpfire's jet (T19). Not when the attack couldn't start (attack_aborted, :37).
function boss_areas.announce_vomit(unit, blackboard)
	vomits_sent[unit] = nil

	if blackboard.attack_aborted then
		return
	end

	local target = blackboard.target_unit
	local network = pc.network()
	local go_id = network:unit_game_object_id(unit)
	local target_go_id = target and Unit.alive(target) and network:unit_game_object_id(target)

	if not go_id or not target_go_id then
		return
	end

	local players = {}
	local sent = 0

	for _, player in pairs(Managers.player:human_players()) do
		local player_unit = player.player_unit
		local peer = player_unit and Unit.alive(player_unit) and pc.host.client_judges(player_unit)

		if peer then
			players[player_unit] = peer
			sent = sent + 1

			mod:network_send("pc_aim", peer, pc.VERSION, go_id, "vomit", "", target_go_id, player_unit == target)
		end
	end

	vomits_sent[unit] = {
		players = players,
		t = pc.now(),
	}

	if sent > 0 then
		local target_peer = pc.host.client_judges(target)

		pc.count("host_vomits_sent", sent)
		pc.log("host vomit go=%d target=%s sent to %d modded players", go_id, target_peer and pc.host.player_name(target_peer) or "not modded", sent)
	end
end

-- The modded players the vomit's own sweep leaves out: those it was announced to, while the host still counts them as
-- fresh. A player who turned fresh since is judged by the host's sweep, since nobody told their screen.
function boss_areas.vomit_skip(unit)
	local record = vomits_sent[unit]
	local skip = nil

	for player_unit, peer in pairs(record and record.players or {}) do
		if Unit.alive(player_unit) and pc.host.client_judges(player_unit) == peer then
			skip = skip or {}
			skip[player_unit] = true
		end
	end

	return skip
end

-- The beam's own sweep leaves out every modded player the host counts as fresh: the beam needs no announcement, since
-- its on and off reach every client already (rpc_set_stormfiend_beam) and its aim point is synced (aim_target).
function boss_areas.beam_skip()
	local skip = nil

	for _, player in pairs(Managers.player:human_players()) do
		local player_unit = player.player_unit

		if player_unit and Unit.alive(player_unit) and pc.host.client_judges(player_unit) then
			skip = skip or {}
			skip[player_unit] = true
		end
	end

	return skip
end

local sweeps_noted = {} -- enemy unit -> { [player unit] = when the host's own sweep last would have reached them }
local NOTE_INTERVAL = 2 -- seconds between those lines for one enemy and player

-- After the vomit's or the beam's own sweep ran without the modded players: those it would have reached, for the log,
-- at most every NOTE_INTERVAL for one enemy and player, since the sweeps run every frame.
local function sweep_noted(kind, unit, scope)
	local t = pc.now()
	local noted = sweeps_noted[unit] or {}

	sweeps_noted[unit] = noted

	for player_unit in pairs(scope.dropped) do
		if not noted[player_unit] or t - noted[player_unit] > NOTE_INTERVAL then
			local peer = pc.host.client_judges(player_unit)

			noted[player_unit] = t

			pc.count("host_" .. kind .. "_would")
			pc.log("host %s go=%s: the host's own sweep would have reached %s (left to their screen)", kind, tostring(go_of(unit)), peer and pc.host.player_name(peer) or "a player")
		end
	end
end

-- The vomit this player's screen saw reach them: the buff the host's sweep would have given (bt_vomit_action.lua:277 to
-- :281), which reaches every other client. Its ticks deal no damage here (Areas.lua's burning hook); the player's own
-- screen reports them.
function boss_areas.book_vomit(player_unit, troll)
	if not troll or not Unit.alive(troll) or not vomit_action(Unit.get_data(troll, "breed")) then
		return "the troll is gone"
	end

	local buffs = ScriptUnit.extension(player_unit, "buff_system")

	if buffs:has_buff_type(VOMIT_FACE_TYPE) then
		return "already covered in bile here"
	end

	pc.host.booking = true
	Managers.state.entity:system("buff_system"):add_buff(player_unit, VOMIT_FACE_BUFF, troll)
	pc.host.booking = false

	local blackboard = BLACKBOARDS[troll]

	if blackboard then
		blackboard.has_done_bile_damage = true
	end

	pc.count("host_vomit_hits")

	return "covered in bile"
end

-- The beam this player's screen saw reach them, as shoot_hit_check (bt_stormfiend_shoot_action.lua:631 to :636).
function boss_areas.book_beam(player_unit, stormfiend)
	if not stormfiend or not Unit.alive(stormfiend) or not beam_action(Unit.get_data(stormfiend, "breed")) then
		return "the stormfiend is gone"
	end

	local buffs = ScriptUnit.extension(player_unit, "buff_system")

	if buffs:has_buff_type(BEAM_FACE_TYPE) then
		return "already burning here"
	end

	pc.host.booking = true
	Managers.state.entity:system("buff_system"):add_buff(player_unit, BEAM_FACE_BUFF, stormfiend)
	pc.host.booking = false

	local blackboard = BLACKBOARDS[stormfiend]

	if blackboard then
		blackboard.has_dealt_burn_damage = true
	end

	pc.count("host_beam_hits")

	return "set on fire"
end

-- The pool this player's screen saw them step into or out of, booked as _update_collision_detection would have
-- (liquid_area_damage_extension.lua:660 to :691): in, in_liquid, the template's hit_player_function once and the buff as
-- _add_buff_helper_function gives it (server-controlled and recorded, so the pool's destroy takes it back, :352), the
-- player among its colliding units; out, all of it undone. Their own screen judges the pool from now on (the hook below).
function boss_areas.book_pool(player_unit, pool, inside)
	local extension = pool and Unit.alive(pool) and ScriptUnit.has_extension(pool, "area_damage_system")

	if not extension or not extension._liquid_area_damage_template or type(extension._colliding_units) ~= "table" then
		return "no pool"
	end

	local breed = Unit.get_data(player_unit, "breed")

	if breed and extension._immune_breeds and extension._immune_breeds[breed.name] then
		return "immune"
	end

	local status = ScriptUnit.extension(player_unit, "status_system")
	local outcome = "nothing to change"

	pc.host.booking = true

	if inside then
		outcome = extension._colliding_units[player_unit] and "still inside" or "stepped in"
		extension._colliding_units[player_unit] = PLAYER_POOL_ARMOR

		if status.in_liquid_unit ~= pool then
			StatusUtils.set_in_liquid_network(player_unit, true, pool)
		end

		if not extension._affected_player_units[player_unit] and extension._hit_player_function then
			extension._affected_player_units[player_unit] = true

			local side = Managers.state.side.side_by_unit[player_unit]
			local ok, message = pcall(extension._hit_player_function, player_unit, side and side.PLAYER_AND_BOT_UNITS or {}, extension._source_attacker_unit)

			if not ok then
				pc.print("host pool: its hit_player_function failed: %s", tostring(message))
			end
		end

		local buffs = ScriptUnit.extension(player_unit, "buff_system")

		if extension._buff_name and extension._apply_buff_to_player and not buffs:has_buff_type(extension._buff_type) then
			extension:_add_buff_helper_function(player_unit, pool, extension._buff_name, extension._buff_condition, extension._buff_system)

			if extension._buff_affected_units[player_unit] then
				outcome = outcome .. ", buff given"
			end
		end

		if outcome == "stepped in" then
			pc.count("host_pool_entered")
		end
	elseif extension._colliding_units[player_unit] then
		extension._colliding_units[player_unit] = nil

		if status.in_liquid_unit == pool then
			StatusUtils.set_in_liquid_network(player_unit, false)
		end

		if extension._buff_name and extension._buff_affected_units[player_unit] then
			extension._buff_system:remove_server_controlled_buff(player_unit, extension._buff_affected_units[player_unit])
			extension._buff_affected_units[player_unit] = nil
		end

		outcome = "stepped out"

		pc.count("host_pool_left")
	end

	pc.host.booking = false

	return outcome
end

-- The wave this player's screen saw roll into them, booked as the wave's own hit (DamageWaveExtension.on_hit_by_wave,
-- damage_wave_extension.lua:408): the face buff unless the shared record says a wave has already hit them, the impact's
-- effect, sound and state, and the dialogue, as vanilla. No push: their own screen pushed them.
function boss_areas.book_wave(player_unit, wave)
	local extension = wave and Unit.alive(wave) and ScriptUnit.has_extension(wave, "area_damage_system")

	if not extension or not extension.damage_wave_template_name or not DamageWaveExtension or type(DamageWaveExtension.on_hit_by_wave) ~= "function" then
		return "the wave is gone"
	end

	pc.host.booking = true

	local ok, message = pcall(DamageWaveExtension.on_hit_by_wave, player_unit, wave, extension)

	pc.host.booking = false

	if not ok then
		pc.print("host wave: its on_hit_by_wave failed: %s", tostring(message))

		return "failed"
	end

	pc.count("host_wave_hits")

	return "booked"
end

-- The host's own tick of a modded player's copy of these buffs deals no damage: their own screen ticks it and reports it
-- (D58). The vomit's only if that vomit was announced to them, since otherwise the host's own sweep gave it and their
-- screen knows nothing of it, as the jet's (Areas.lua).
function boss_areas.host_burn_tick(kind, unit, buff)
	local peer = pc.host.client_judges(unit)

	if not peer then
		return false
	end

	if kind == "vomit" then
		local record = buff.attacker_unit and vomits_sent[buff.attacker_unit]

		if not record or record.players[unit] ~= peer then
			pc.count("host_burn_ticks_own_sweep")

			return false
		end
	end

	pc.count("host_burn_ticks_left_to_client")
	pc.log("host burn tick target=%s buff=%s: left to their screen", pc.host.player_name(peer), tostring(buff.buff_template_name))

	return true
end

-- What a reported tick of these kinds comes from, by its unit, for Areas.lua's book_tick: a troll's vomit, a
-- stormfiend's beam, a pool's buff or pulse, a wave's face buff. Each as that buff's own tick works it out: the vomit's
-- times the troll's damage_dealt (update_vomit_in_face, buff_function_templates.lua:1237), the bile pool's times the
-- pool's buff_damage_multiplier (update_moving_through_vomit, :788), the fire wall's with its source's damage_dealt
-- (apply_moving_through_warpfire, :1380), a pulse as _pulse_damage books it (liquid_area_damage_extension.lua:793).
function boss_areas.tick_source(unit)
	local extension = ScriptUnit.has_extension(unit, "area_damage_system")

	if extension and extension._liquid_area_damage_template then
		local source = extension._source_attacker_unit
		local breed = source and ALIVE[source] and Unit.get_data(source, "breed")

		if extension._do_direct_damage_player then
			local damage_table = extension._damage_table
			local direction = extension._damage_direction

			return {
				kind = "pulse",
				damage = type(damage_table) == "table" and (damage_table[PLAYER_POOL_ARMOR] or damage_table[1]) or nil,
				damage_type = extension._damage_type,
				damage_source = extension._liquid_area_damage_template,
				source = source,
				direction = direction and Vector3Box(direction:unbox()) or nil,
			}
		elseif extension._buff_name then
			local sub = buff_sub(extension._buff_name)
			local update = sub and sub.update_func

			return {
				kind = "pool",
				template_name = extension._buff_name,
				source = source,
				source_buffs = update == "update_moving_through_warpfire",
				multiplier = update == "update_moving_through_vomit" and extension.buff_damage_multiplier or 1,
				damage_source = breed and breed.name or "dot_debuff",
			}
		end

		return nil
	elseif extension and extension.damage_wave_template_name and extension.buff_wave_impact_template_name then
		return {
			kind = "wave",
			template_name = extension.buff_wave_impact_template_name,
			damage_source = "dot_debuff",
		}
	end

	local breed = Unit.get_data(unit, "breed")

	if vomit_action(breed) then
		return {
			kind = "vomit",
			template_name = VOMIT_FACE_BUFF,
			source = unit,
			source_buffs = true,
			damage_source = breed.name,
		}
	elseif beam_action(breed) then
		return {
			kind = "beam",
			template_name = BEAM_FACE_BUFF,
			damage_source = breed.name,
		}
	end

	return nil
end

function boss_areas.host_update()
	-- A host test whose original call failed leaves its scope set, or a side's list filtered; they go here.
	pc.areas.boss_sweep = nil
	boss_areas.restore_hidden()

	if next(vomits_sent) == nil and next(sweeps_noted) == nil then
		return
	end

	local t = pc.now()

	for unit, record in pairs(vomits_sent) do
		if t - record.t > SENT_MEMORY or not Unit.alive(unit) then
			vomits_sent[unit] = nil
		end
	end

	for unit in pairs(sweeps_noted) do
		if not Unit.alive(unit) or not HEALTH_ALIVE[unit] then
			sweeps_noted[unit] = nil
		end
	end
end

function boss_areas.host_clear()
	boss_areas.restore_hidden()

	vomits_sent = {}
	sweeps_noted = {}
end

-- Client -------------------------------------------------------------------------------------------------------------

local vomits = {} -- troll unit -> its vomit on this screen, from the host's announcement until it ends here
local beams = {} -- stormfiend unit -> its beam while it is on here
local pools = {} -- pool unit -> { extension, grid, inside, own, ... } for a pool that reaches players
local waves = {} -- wave unit -> { extension, go_id, displaced_until } once its copy runs here
local hit_by_wave = false -- a wave has hit this player since the last wave went (damage_wave_extension.lua:315, :454)
local own_sweeps = {} -- player unit -> filter -> whether the game's sweep with that filter finds that unit's actors here

local function hits_unit(hits, unit)
	if type(hits) ~= "table" then
		return false
	end

	for i = 1, #hits do
		local actor = hits[i].actor
		local hit_unit = actor and Actor.unit(actor)

		if hit_unit == unit then
			return true
		end
	end

	return false
end

-- Whether the sweep the vomit or the beam uses finds this player's own actors on this machine. It is checked once per
-- player unit and filter, with a short sweep across the player's middle, and logged.
local function sweep_sees(target, filter)
	local known_here = own_sweeps[target]

	if not known_here then
		known_here = {}
		own_sweeps[target] = known_here
	end

	local known = known_here[filter]

	if known == nil then
		local middle = POSITION_LOOKUP[target] + Vector3(0, 0, PLAYER_MIDDLE)
		local across = Quaternion.right(Unit.local_rotation(target, 0))
		local hits = PhysicsWorld.linear_sphere_sweep(World.get_data(Unit.world(target), "physics_world"), middle - across, middle + across, 0.3, 10, "collision_filter", filter, "report_initial_overlap")

		known = hits_unit(hits, target)
		known_here[filter] = known

		pc.log("client: the game's sweep with %s %s this player's own actors, so what uses it is judged %s", filter, known and "finds" or "doesn't find", known and "with it" or "by shape")
	end

	return known
end

-- This screen's own copy of a face buff on its own player (D58), which sends nothing (BuffExtension.add_buff): its apply
-- plays here at once, its push included. With late_pushes, every other human machine applies its own copy too, whose
-- push reaches this player later and is dropped (D71). Returns whether it started.
local function start_face_buff(target, buff_name, attacker, late_pushes)
	local buffs = ScriptUnit.has_extension(target, "buff_system")

	if not buffs then
		return false
	end

	local _, added = buffs:add_buff(buff_name, {
		attacker_unit = attacker,
	})

	if not added or added == 0 then
		return false
	end

	pc.count("client_face_buffs_started")

	local sub = buff_sub(buff_name)
	local push_speed = sub and sub.push_speed

	if late_pushes and type(push_speed) == "number" and push_speed > 0 then
		pc.hit_results.expect_pushes(push_speed, math.max(Managers.player:num_human_players() - 1, 0))

		-- Pushes at once beyond the own copy's, away from the attacker as its apply pushes (none while FACE_PUSHES is 1).
		local locomotion = FACE_PUSHES > 1 and ScriptUnit.has_extension(target, "locomotion_system")

		if locomotion then
			local from = attacker and Unit.alive(attacker) and Unit.world_position(attacker, 0)
			local to_target = from and POSITION_LOOKUP[target] - from
			local direction = to_target and Vector3.length_squared(to_target) > 0.0001 and Vector3.normalize(to_target) or Vector3.backward()

			for _ = 2, FACE_PUSHES do
				locomotion:add_external_velocity(direction * push_speed)
			end
		end
	end

	return true
end

local function nav_world()
	return Managers.state.entity:system("ai_system"):nav_world()
end

-- BTVomitAction._position_on_navmesh (bt_vomit_action.lua:47).
local function on_navmesh(position)
	local world = nav_world()
	local success, z = GwNavQueries.triangle_from_position(world, position, 1, 1)

	if success then
		return Vector3(position.x, position.y, z)
	end

	return GwNavQueries.inside_position_from_outside_position(world, position, 3, 3, 1, 1)
end

-- BTVomitAction._get_vomit_position (:61) from this screen's copies: a ray from the troll's head to its target, its hit or
-- the target's position, put on the navmesh. Where the navmesh can't be found, the target's position stands in, so that
-- this screen still judges the vomit. Returns the point and the direction to it from the troll's head.
local function puke_point(unit, target)
	local head = Unit.world_position(unit, Unit.node(unit, "j_head"))
	local target_position = POSITION_LOOKUP[target]
	local to_target = target_position - head
	local distance = Vector3.length(to_target)
	local tested = target_position

	if distance > 0.001 then
		local physics_world = World.get_data(Unit.world(unit), "physics_world")
		local hit, hit_position = PhysicsWorld.immediate_raycast(physics_world, head, to_target / distance, distance, "closest", "collision_filter", VOMIT_FILTER)

		if hit and hit_position then
			tested = hit_position
		end
	end

	local point = on_navmesh(tested) or target_position
	local to_point = point - head

	if Vector3.length_squared(to_point) < 0.0001 then
		return point, Quaternion.forward(Unit.local_rotation(unit, 0))
	end

	return point, Vector3.normalize(to_point)
end

-- A troll starts its vomit (pc_aim, kind vomit): every modded player's screen keeps it, and only its target's turns the
-- troll.
function boss_areas.vomit_aimed(go_id, target_go_id, aimed)
	local unit = unit_of(go_id)
	local target = unit_of(target_go_id)
	local own = pc.local_player_unit()
	local breed = unit and Unit.alive(unit) and Unit.get_data(unit, "breed")
	local action = vomit_action(breed)

	if not action or not own or not judging() or not target or not Unit.alive(target) or not Unit.has_node(unit, "j_head") then
		return
	end

	local t = pc.now()
	local anims = {}

	-- The vomit plays one of these (init_attack, :100 to :112); any other animation from the host for the troll ends it.
	if type(action.attack_anims) == "table" then
		for _, anim in pairs(action.attack_anims) do
			if type(anim) == "string" then
				anims[anim] = true
			end
		end
	end

	local point, direction = puke_point(unit, target)
	local vomit = {
		go_id = go_id,
		action = action,
		target = target,
		aimed = aimed == true and target == own,
		point = Vector3Box(point),
		direction = Vector3Box(direction),
		anims = anims,
		turn_speed = pc.turn_speed(breed, action),
		t = t,
		rotation_until = t + (type(action.rotation_time) == "number" and action.rotation_time or 0),
		ends_t = t + (type(action.attack_time) == "number" and action.attack_time or 2.5),
		next_aim_t = t + VOMIT_REAIM,
		sweeps = 0,
		hits = 0,
	}

	if vomit.aimed then
		vomit.rotation = QuaternionBox(Unit.local_rotation(unit, 0))

		pc.count("client_vomits_aimed")
	end

	vomits[unit] = vomit

	pc.count("client_vomits_announced")
	pc.log("client vomit go=%d target=%s aimed=%s", go_id, tostring(target_go_id), tostring(vomit.aimed))
end

local function end_vomit(unit, vomit, why)
	vomits[unit] = nil

	pc.count("client_vomits_ended")
	pc.log("client vomit go=%d ended (%s): sweeps=%d hits=%d after %.2fs", vomit.go_id, why, vomit.sweeps, vomit.hits, pc.now() - vomit.t)
end

-- The vomit's copy fires anim_cb_vomit as it starts to puke and anim_cb_vomit_end as it stops (the host's
-- is_puking, animation_callback_templates.lua:767 and :782), from the animation callback hook in Ping Compensation.lua.
function boss_areas.vomit_cue(unit, callback_name)
	local vomit = vomits[unit]

	if not vomit then
		return
	end

	if callback_name == "anim_cb_vomit" then
		vomit.puking = true
		vomit.check_t = pc.now() + VOMIT_CHECK_DELAY
	else
		vomit.puking = false
	end
end

-- One sweep of this screen's copy of the vomit, from the troll's head to the puke point, for this player only: by the
-- game's own sweep where it finds this player's actors, else by shape. Nothing stops it (bt_vomit_action.lua:268). A
-- player not yet covered in bile gets this screen's own copy of the face buff, whose apply pushes them (D71).
local function sweep_vomit(unit, vomit, own)
	local head = Unit.world_position(unit, Unit.node(unit, "j_head"))
	local point = vomit.point:unbox()
	local reached, method

	vomit.sweeps = vomit.sweeps + 1

	if sweep_sees(own, VOMIT_FILTER) then
		local hits = PhysicsWorld.linear_sphere_sweep(World.get_data(Unit.world(unit), "physics_world"), head, point, VOMIT_RADIUS, VOMIT_MAX_HITS, "collision_filter", VOMIT_FILTER, "report_initial_overlap")

		reached, method = hits_unit(hits, own), "sweep"
	else
		reached, method = pc.geometry.player_near_segment(POSITION_LOOKUP[own], head, point, VOMIT_RADIUS), "shape"
	end

	pc.count("client_vomit_" .. method)

	if not reached then
		return
	end

	local buffs = ScriptUnit.has_extension(own, "buff_system")

	if not buffs or buffs:has_buff_type(VOMIT_FACE_TYPE) then
		return
	end

	vomit.hits = vomit.hits + 1

	local started = start_face_buff(own, VOMIT_FACE_BUFF, unit, true)

	report("vomit", vomit.go_id, true)
	pc.count("client_vomit_hits")
	pc.log("client vomit go=%d hit you: method=%s aimed=%s distance=%.2f buff=%s", vomit.go_id, method, tostring(vomit.aimed), Vector3.distance(POSITION_LOOKUP[own], head), started and "started" or "not started")
end

-- Every frame of a vomit on this screen, after LocomotionSystem.update: the puke point follows the target every 0.2 s
-- until the attack's rotation time while the troll isn't puking yet, unless the target is dodging or invisible
-- (bt_vomit_action.lua:198; on the target's screen, this player's own dodge); on the target's screen the troll turns
-- towards it the whole attack (:209), at T18's speed; while the troll pukes, from 0.2 s after it started, the sweep.
local function update_vomit(unit, vomit, own, t, dt)
	local target = vomit.target

	if not vomit.puking and t < vomit.rotation_until and t > vomit.next_aim_t and Unit.alive(target) then
		local status = ScriptUnit.has_extension(target, "status_system")
		local dodging = status and (target == own and own_dodge(status) or target ~= own and status:get_is_dodging())

		if not status or not dodging and not status:is_invisible() then
			local point, direction = puke_point(unit, target)

			vomit.point:store(point)
			vomit.direction:store(direction)
			vomit.next_aim_t = t + VOMIT_REAIM
		end
	end

	if vomit.aimed and vomit.rotation then
		local direction = vomit.direction:unbox()
		local flat = Vector3(direction.x, direction.y, 0)

		if Vector3.length_squared(flat) > 0.0001 then
			local wanted = Quaternion.look(Vector3.normalize(flat), Vector3.up())
			local rotation = Quaternion.lerp(vomit.rotation:unbox(), wanted, math.min(vomit.turn_speed * dt, 1))

			vomit.rotation:store(rotation)

			if pc.facing then
				Unit.set_local_rotation(unit, 0, rotation)
			end
		end
	end

	if vomit.puking and vomit.check_t and t > vomit.check_t then
		sweep_vomit(unit, vomit, own)
	end
end

local function longest_firing(action)
	local longest = 0

	if type(action.attack_anims_data) == "table" then
		for _, data in pairs(action.attack_anims_data) do
			if type(data) == "table" and type(data.stop_firing_t) == "number" and type(data.start_firing_t) == "number" then
				longest = math.max(longest, data.stop_firing_t - data.start_firing_t)
			end
		end
	end

	return longest > 0 and longest or 5
end

-- WeaponSystem.rpc_set_stormfiend_beam (weapon_system.lua:837): a stormfiend's beam goes on or off on the arm it names.
-- Every modded player's screen judges its own player against it while it is on here.
function boss_areas.beam_message(unit_id, arm_id, active)
	local unit = unit_of(unit_id)

	if not unit then
		return
	end

	local beam = beams[unit]

	if not active then
		if beam then
			beams[unit] = nil

			pc.log("client beam go=%d off: sweeps=%d hits=%d after %.2fs", beam.go_id, beam.sweeps, beam.hits, pc.now() - beam.t)
		end

		return
	end

	local own = pc.local_player_unit()
	local breed = Unit.alive(unit) and Unit.get_data(unit, "breed")
	local action = beam_action(breed)
	local arm = type(arm_id) == "number" and rawget(NetworkLookup.attack_arm, arm_id)
	local muzzle = action and type(action.muzzle_nodes) == "table" and arm and action.muzzle_nodes[arm]

	if not judging() or not own or type(muzzle) ~= "string" or not Unit.has_node(unit, muzzle) then
		return
	end

	local t = pc.now()

	beams[unit] = {
		go_id = unit_id,
		muzzle_node = Unit.node(unit, muzzle),
		t = t,
		ends_t = t + longest_firing(action) + BEAM_LINGER,
		sweeps = 0,
		hits = 0,
	}

	pc.count("client_beams")
end

-- One sweep of this screen's copy of the beam (shoot_hit_check, bt_stormfiend_shoot_action.lua:593), for this player
-- only: from the muzzle to the synced aim point, its hits in order, the first that isn't a character stopping it (:617).
-- Where the game's sweep doesn't find this player's actors, this player by shape against the beam up to that first
-- wall. A player not yet burning gets this screen's own copy of the face buff, whose apply pushes them on this machine
-- only (apply_warpfire_in_face, buff_function_templates.lua:1877), so nothing comes later to drop.
local function sweep_beam(unit, beam, own)
	local game = pc.network():game()

	if not game then
		return
	end

	local ok, aim = pcall(GameSession.game_object_field, game, beam.go_id, "aim_target")

	if not ok or not aim then
		return
	end

	local muzzle = Unit.world_position(unit, beam.muzzle_node)
	local hits = PhysicsWorld.linear_sphere_sweep(World.get_data(Unit.world(unit), "physics_world"), muzzle, aim, BEAM_RADIUS, BEAM_MAX_HITS, "collision_filter", BEAM_FILTER, "report_initial_overlap")
	local sees = sweep_sees(own, BEAM_FILTER)
	local reached, stop = false, nil

	beam.sweeps = beam.sweeps + 1

	for i = 1, type(hits) == "table" and #hits or 0 do
		local hit = hits[i]
		local hit_unit = hit.actor and Actor.unit(hit.actor)

		if not hit_unit or not DamageUtils.is_character(hit_unit) then
			stop = hit.position

			break
		end

		if sees and hit_unit == own then
			reached = true

			break
		end
	end

	if not sees then
		local line = aim - muzzle
		local length = Vector3.length(line)
		local finish = aim

		if stop and length > 0.001 then
			finish = muzzle + line / length * math.clamp(Vector3.dot(stop - muzzle, line / length), 0, length)
		end

		reached = pc.geometry.player_near_segment(POSITION_LOOKUP[own], muzzle, finish, BEAM_RADIUS)
	end

	pc.count(sees and "client_beam_sweep" or "client_beam_shape")

	if not reached then
		return
	end

	local buffs = ScriptUnit.has_extension(own, "buff_system")

	if not buffs or buffs:has_buff_type(BEAM_FACE_TYPE) then
		return
	end

	beam.hits = beam.hits + 1

	local started = start_face_buff(own, BEAM_FACE_BUFF, unit, false)

	report("beam", beam.go_id, true)
	pc.count("client_beam_hits")
	pc.log("client beam go=%d hit you: method=%s distance=%.2f buff=%s", beam.go_id, sees and "sweep" or "shape", Vector3.distance(POSITION_LOOKUP[own], muzzle), started and "started" or "not started")
end

function boss_areas.active()
	return next(vomits) ~= nil or next(beams) ~= nil
end

function boss_areas.has_vomits()
	return next(vomits) ~= nil
end

-- Every frame after LocomotionSystem.update, which has just turned every enemy copy by the host's numbers (Client.lua):
-- the vomits, with the troll turned on its target's screen, and the beams.
function boss_areas.after_locomotion(t, dt)
	local own = pc.local_player_unit()

	for unit, vomit in pairs(vomits) do
		if not own or not judging() or not Unit.alive(unit) or not HEALTH_ALIVE[unit] then
			end_vomit(unit, vomit, "gone")
		elseif t > vomit.ends_t then
			end_vomit(unit, vomit, "the attack is over")
		elseif HEALTH_ALIVE[own] then
			update_vomit(unit, vomit, own, t, dt)
		end
	end

	for unit, beam in pairs(beams) do
		if not own or not judging() or not Unit.alive(unit) or not HEALTH_ALIVE[unit] or t > beam.ends_t then
			beams[unit] = nil
		elseif HEALTH_ALIVE[own] then
			sweep_beam(unit, beam, own)
		end
	end
end

-- The host's other animations for a troll end its vomit here: a stagger's, its fall's, its next attack's.
function boss_areas.animation_changed(go_id, anim_id)
	local unit = unit_of(go_id)
	local vomit = unit and vomits[unit]
	local event = vomit and rawget(NetworkLookup.anims, anim_id)

	if vomit and not vomit.anims[event] then
		end_vomit(unit, vomit, tostring(event))
	end
end

-- This player's hit staggered or killed the enemy on their screen (Reactions.lua): its vomit or beam is over here, as
-- it will be on the host once the hit arrives.
function boss_areas.stop_turning(unit, reason)
	local vomit = vomits[unit]

	if vomit then
		end_vomit(unit, vomit, tostring(reason))
	end

	beams[unit] = nil
end

-- LiquidAreaDamageExtension._find_point (liquid_area_damage_extension.lua:325), on this client's navmesh.
local function find_point(position, above, below)
	local world = nav_world()
	local success, z = GwNavQueries.triangle_from_position(world, position, above or 2, below or 2)

	if success then
		return Vector3(position.x, position.y, z)
	end

	return GwNavQueries.inside_position_from_outside_position(world, position, above or 2, below or 2, 2, 0.5)
end

-- A pool appears on this screen (LiquidAreaDamageHuskExtension.init, liquid_area_damage_husk_extension.lua:5): one that
-- reaches players gets its grid rebuilt as the host's (liquid_area_damage_extension.lua:31 to :39), from the template and
-- its spawn point put on this client's navmesh. Its cells are the host's blobs, whose ids are the host's grid indices.
function boss_areas.pool_spawned(extension, unit, init_data)
	local template_name = type(init_data) == "table" and init_data.liquid_template
	local templates = rawget(_G, "LiquidAreaDamageTemplates")
	local template = template_name and templates and templates.templates[template_name]
	local hex_grid = rawget(_G, "HexGrid")

	if not template or not hex_grid or pc.is_server() then
		return
	end

	local buff_pool = template.apply_buff_to_player and template.buff_template_name ~= nil
	local pulse_pool = template.do_direct_damage_player == true

	if not buff_pool and not pulse_pool then
		return
	end

	local position = Unit.world_position(unit, 0)
	local centre = find_point(position, template.above, template.below) or position
	local max_liquid = template.max_liquid or 50
	local grid = hex_grid:new(centre, math.min(max_liquid + 10, 50), 10, template.cell_size, 1)
	local source = type(init_data) == "table" and init_data.source_unit or nil
	local multiplier = 1

	-- The bile pool's ticks are times its source's damage_dealt as the pool was made (liquid_area_damage_extension.lua:115,
	-- buff_function_templates.lua:788), for the HP estimate.
	if source and Unit.alive(source) and not Managers.player:owner(source) then
		local source_buffs = ScriptUnit.has_extension(source, "buff_system")

		if source_buffs then
			multiplier = source_buffs:apply_buffs_to_value(1, "damage_dealt")
		end
	end

	local t = pc.now()
	local difficulty = Managers.state.difficulty:get_difficulty()
	local damage_table = type(template.difficulty_direct_damage) == "table" and template.difficulty_direct_damage[difficulty]

	pools[unit] = {
		extension = extension,
		template_name = template_name,
		template = template,
		grid = grid,
		go_id = go_of(unit),
		buff_pool = buff_pool,
		pulse_pool = pulse_pool,
		pulse_damage = type(damage_table) == "table" and (damage_table[PLAYER_POOL_ARMOR] or damage_table[1]) or nil,
		next_pulse = t + (template.delay or 0),
		multiplier = multiplier,
		inside = false,
		by_cell = {}, -- this grid's index -> the host's blob id, in case the two grids don't line up
		blobs_seen = 0,
		ticks = 0,
	}

	-- The host puts a vomit's pool at its own puke point (BTVomitAction.create_aoe, bt_vomit_action.lua:289), which on the
	-- target's screen can lie a little off the stream they saw (question 5 of the build 6.1 notes, D70).
	local vomit = source and vomits[source]

	if vomit then
		pc.log("client pool go=%s from a vomit: %.2f m from this screen's puke point", tostring(pools[unit].go_id), Vector3.distance(vomit.point:unbox(), position))
	end
end

-- A blob of the pool reaches this screen (LiquidAreaDamageHuskExtension.add_damage_blob, :65). The first one says
-- whether the rebuilt grid lines up with the host's, which is logged: if it doesn't, the blobs are found by their
-- positions in this grid instead of by the host's ids.
function boss_areas.blob_added(extension, blob_id, position)
	local pool = pools[extension._unit]

	if not pool or type(blob_id) ~= "number" or not position then
		return
	end

	local grid = pool.grid
	local i, j, k = grid:find_index(position)

	pool.by_cell[grid:real_index(i, j, k)] = blob_id
	pool.blobs_seen = pool.blobs_seen + 1

	if pool.aligned == nil then
		local cell = grid:find_position(grid:ijk(blob_id))
		local offset = Vector3.length(Vector3.flat(cell - position))

		pool.aligned = offset <= GRID_TOLERANCE

		if not pool.aligned then
			pc.count("client_pool_grid_off")
		end

		pc.log("client pool go=%s template=%s: the host's first blob lies %.3f m on the flat from this screen's cell for it, so its blobs are found %s", tostring(pool.go_id), tostring(pool.template_name), offset, pool.aligned and "by the host's ids" or "by their positions")
	end
end

-- LiquidAreaDamageExtension._is_unit_colliding (liquid_area_damage_extension.lua:745) on this player's feet: the cell
-- there, or failing that 1 m up, holds a filled blob.
local function in_pool(pool, feet)
	local blobs = pool.extension._blobs
	local grid = pool.grid

	if type(blobs) ~= "table" then
		return false
	end

	for up = 0, 1 do
		local i, j, k = grid:find_index(feet + up * Vector3.up())

		if grid:is_out_of_bounds(i, j, k) then
			break
		end

		local key = grid:real_index(i, j, k)

		if pool.aligned == false then
			key = pool.by_cell[key]
		end

		local blob = key and blobs[key]

		if blob then
			if blob.full then
				return true
			end

			break
		end
	end

	return false
end

-- This screen's own copy of the pool's buff on its player (D58), as _add_buff_helper_function would give the host's
-- (liquid_area_damage_extension.lua:606): unless they already have a buff of its type, or the template's condition
-- refuses (the bile's needs no troll_bile_face, the fire wall's no stormfiend_warpfire_face, liquid_area_damage_templates
-- .lua:1270, :1276). It has no end time, so it is taken back as they step out.
local function start_pool_buff(own, unit, pool)
	local template = pool.template
	local buffs = ScriptUnit.has_extension(own, "buff_system")

	if not buffs or buffs:has_buff_type(template.buff_template_type) then
		return false
	end

	local condition = template.buff_condition_function and LiquidAreaDamageTemplates[template.buff_condition_function]

	if condition and not condition(own) then
		return false
	end

	local id, added = buffs:add_buff(template.buff_template_name, {
		attacker_unit = unit,
	})

	if not added or added == 0 then
		return false
	end

	pool.own = id

	pc.areas.own_burn(id, true)
	pc.count("client_pool_buffs_started")

	return true
end

local function end_pool_buff(own, pool)
	local buffs = pool.own and own and Unit.alive(own) and ScriptUnit.has_extension(own, "buff_system")

	if buffs then
		buffs:remove_buff(pool.own)
	end

	if pool.own then
		pc.areas.own_burn(pool.own, false)
	end

	pool.own = nil
end

-- One pulse of a pool that hurts by pulses, on this screen's copy of its timer (the host's _pulse_damage,
-- liquid_area_damage_extension.lua:774), while this player is inside: shown at once and reported. The host books it as
-- its pulse would (Areas.lua, book_tick).
local function pulse(own, pool)
	pool.ticks = pool.ticks + 1

	if type(pool.pulse_damage) ~= "number" or not HEALTH_ALIVE[own] then
		return
	end

	report("tick", pool.go_id, true)

	local ok, estimate = pc.guard("client pool pulse shown", pc.hit_results.area, nil, go_of(own), pool.template_name, pool.extension._source_attacker_unit, pool.pulse_damage, pool.template.damage_type)

	pc.count("client_pool_pulses")
	pc.log("client pool go=%s pulse=%d: damage=%.1f estimate=%.1f", tostring(pool.go_id), pool.ticks, pool.pulse_damage, ok and estimate or 0)
end

-- Each frame, as _update_collision_detection runs for the host's own players (liquid_area_damage_extension.lua:660):
-- stepping into a filled cell is reported, with this screen's own copy of the buff where the pool has one; stepping out
-- ends it and is reported. A buff from this pool that the host gave before this screen judged counts as this pool's.
-- While inside, a buff the condition refused before (the face buff ran out) starts once it allows it, and the host
-- hears again, every POOL_REPORT_INTERVAL, so its copy follows.
local function update_pool(own, unit, pool, t)
	local template = pool.template
	local breed = Unit.get_data(own, "breed")
	local inside = not (breed and template.immune_breeds and template.immune_breeds[breed.name]) and in_pool(pool, POSITION_LOOKUP[own])
	local go_id = pool.go_id or go_of(unit)

	pool.go_id = go_id

	if inside and not pool.inside then
		pool.inside = true
		pool.report_t = t + POOL_REPORT_INTERVAL

		local buffs = ScriptUnit.has_extension(own, "buff_system")
		local held = pool.buff_pool and buffs and buffs:get_buff_type(template.buff_template_type)
		local adopted = held ~= nil and held.attacker_unit == unit
		local started = pool.buff_pool and not adopted and start_pool_buff(own, unit, pool)

		report("pool", go_id, true)
		pc.count("client_pool_entered")
		pc.log("client pool go=%s template=%s inside=true buff=%s", tostring(go_id), tostring(pool.template_name), adopted and "the host's" or started and "this screen's own" or pool.buff_pool and "refused for now" or "none (pulses)")
	elseif not inside and pool.inside then
		pool.inside = false

		end_pool_buff(own, pool)
		report("pool", go_id, false)
		pc.count("client_pool_left")
		pc.log("client pool go=%s inside=false", tostring(go_id))
	elseif inside and pool.buff_pool then
		local started = not pool.own and start_pool_buff(own, unit, pool)

		if started or t > pool.report_t then
			pool.report_t = t + POOL_REPORT_INTERVAL

			report("pool", go_id, true)
		end
	end

	if pool.pulse_pool then
		while t > pool.next_pulse do
			pool.next_pulse = pool.next_pulse + PULSE_INTERVAL

			if pool.inside then
				pulse(own, pool)
			end
		end
	end
end

-- While this screen doesn't judge, its own copies of the pools' buffs go and the host is told it is out of them, which it
-- heeds only if it still counts this client as fresh. quietly: at the end of a mission, when there is nobody to tell.
local function release_pools(own, quietly)
	for unit, pool in pairs(pools) do
		if pool.own then
			end_pool_buff(own, pool)
			pc.count("client_pool_buffs_released")
		end

		if pool.inside and not quietly then
			report("pool", pool.go_id or go_of(unit), false)
		end

		pool.inside = false
	end
end

boss_areas.release_pools = release_pools

-- A wave starts to roll here (DamageWaveHuskExtension.set_running_wave, damage_wave_husk_extension.lua:145): one whose
-- template pushes players is tested against this player while its copy runs, which covers the host's running and
-- arrived states, since the host sends arrived as the wave starts to linger (damage_wave_extension.lua:494).
function boss_areas.wave_started(extension, unit)
	local template = extension.template

	if pc.is_server() or type(template) ~= "table" or type(template.player_push_data) ~= "table" then
		return
	end

	waves[unit] = {
		extension = extension,
		go_id = go_of(unit),
		pushes = 0,
	}
end

function boss_areas.wave_gone(unit)
	waves[unit] = nil
	hit_by_wave = false
end

-- AiUtils.push_intersecting_players (ai_utils.lua:1452) for this player against this screen's copy of the wave: only if
-- they are an enemy of the wave's side (its source's, or the wave's own); not while the wave leaves them alone after a
-- push; within 1.5 times the push width of a point ahead (the dodged width while this player's dodge counts); within the
-- push width of the wave's line and less than its ahead_dist in front; not knocked down. The push comes at once, with no
-- message, as a monster's push aside (HitResults.push_aside), whatever /pingcomp predict says, since nothing else would
-- push them. The first time since a wave last went, this screen's own copy of the wave's face buff starts, as
-- on_hit_by_wave would give it (damage_wave_extension.lua:428), and the host is told.
local function update_wave(own, unit, wave, t)
	local extension = wave.extension
	local data = extension.template.player_push_data

	if extension.state ~= "running" then
		return
	end

	if wave.displaced_until then
		if t > wave.displaced_until then
			wave.displaced_until = nil
		end

		return
	end

	local source = extension.source_unit
	local side_unit = HEALTH_ALIVE[source] and source or HEALTH_ALIVE[unit] and unit

	if not side_unit or not Managers.state.side:is_enemy(side_unit, own) then
		return
	end

	local self_position = Unit.local_position(unit, 0)
	local forward = Quaternion.forward(Unit.local_rotation(unit, 0))
	local push_position = self_position + forward * data.push_forward_offset
	local other = Unit.local_position(own, 0)
	local status = ScriptUnit.has_extension(own, "status_system")
	local radius = data.push_width * 1.5

	if data.dodged_width and status and own_dodge(status) then
		radius = data.dodged_width * 1.5
	end

	if radius <= Vector3.length(other - push_position) then
		return
	end

	local projected = pc.geometry.closest_point_on_line(other, self_position, self_position + forward * 3)

	if data.push_width * data.push_width <= Vector3.length_squared(other - projected) then
		return
	end

	local ahead = Vector3.distance(self_position, projected)

	if ahead >= data.ahead_dist or not status or status.knocked_down then
		return
	end

	local scaler = 1 - ahead / data.ahead_dist

	pc.hit_results.push_aside(own, data.player_pushed_speed * Vector3.normalize(other - self_position) * scaler * scaler)

	wave.displaced_until = t + WAVE_DISPLACED
	wave.pushes = wave.pushes + 1

	pc.count("client_wave_pushes")

	if hit_by_wave then
		return
	end

	hit_by_wave = true

	local template = extension.template
	local buffs = ScriptUnit.has_extension(own, "buff_system")
	local started = false

	if template.apply_impact_buff_to_player and template.buff_wave_impact_name and buffs and not buffs:has_buff_type(template.buff_wave_impact_type) then
		started = start_face_buff(own, template.buff_wave_impact_name, unit, true)
	end

	report("wave", wave.go_id or go_of(unit), true)
	pc.count("client_wave_hits")
	pc.log("client wave go=%s hit you: ahead=%.2f buff=%s", tostring(wave.go_id), ahead, started and "started" or "not started")
end

function boss_areas.update(dt)
	if pc.is_server() then
		return
	end

	local own = pc.local_player_unit()

	if not own or not judging() then
		release_pools(own)

		return
	end

	local t = pc.now()

	for unit, pool in pairs(pools) do
		if not Unit.alive(unit) then
			end_pool_buff(own, pool)

			pools[unit] = nil
		elseif HEALTH_ALIVE[own] then
			update_pool(own, unit, pool, t)
		end
	end

	for unit, wave in pairs(waves) do
		if not Unit.alive(unit) then
			waves[unit] = nil
		elseif HEALTH_ALIVE[own] then
			update_wave(own, unit, wave, t)
		end
	end
end

-- A tick of these buffs on this client's own player (D58), after the game's own tick has played its sound here: the
-- damage the host's tick would have dealt is shown at once and reported. A pool's only while this screen has the player
-- in that pool; any copy counts, this screen's own or the host's. A source that has gone is still named by the network
-- id it had at its earlier ticks, which the host books for a moment (Areas.lua, TICK_MEMORY).
local burn_sources = {} -- buff id -> the network id of its source, for this player's own buffs

function boss_areas.client_burn_tick(kind, unit, buff, params)
	if unit ~= pc.local_player_unit() or not judging() or not HEALTH_ALIVE[unit] then
		return
	end

	local source = params and params.attacker_unit
	local pool = nil

	if kind == "pool" then
		pool = source and pools[source]

		if not pool or not pool.inside then
			pc.count("client_burn_ticks_outside")

			return
		end
	end

	local go_id = source and Unit.alive(source) and go_of(source) or burn_sources[buff.id]
	local damage = type(buff.damage) == "table" and buff.damage[buff.armor_type or 1]

	if not go_id or type(damage) ~= "number" then
		pc.count("client_burn_ticks_lost")

		return
	end

	burn_sources[buff.id] = go_id

	-- The vomit's face buff is times the troll's damage_dealt as it was applied (buff_function_templates.lua:1237), the
	-- bile pool's times the pool's (:788); the fire wall's damage_dealt is in buff.damage already (:1380).
	if buff.buff_damage_multiplier then
		damage = damage * buff.buff_damage_multiplier
	elseif pool and buff.template and buff.template.update_func == "update_moving_through_vomit" then
		damage = damage * (pool.multiplier or 1)
	end

	report("tick", go_id, true)

	local ok, estimate = pc.guard("client boss area shown", pc.hit_results.area, source, go_id, buff.damage_source, nil, damage, buff.template and buff.template.damage_type or "vomit_face")

	pc.count("client_burn_ticks")
	pc.count("client_burn_ticks_" .. kind)
	pc.log("client burn=%s go=%d tick: damage=%.1f estimate=%.1f", kind, go_id, damage, ok and estimate or 0)
end

function boss_areas.clear()
	-- This screen's own copies of the pools' buffs have no end time of their own, so they go with everything else. Not
	-- through pc.guard, which does nothing once the mod has switched itself off.
	pcall(release_pools, pc.local_player_unit(), true)

	vomits = {}
	beams = {}
	pools = {}
	waves = {}
	hit_by_wave = false
	own_sweeps = {}
	burn_sources = {}
end

-- Both sides -----------------------------------------------------------------------------------------------------------

-- Host: a troll's vomit is announced to every modded player (boss_areas.announce_vomit).
mod:hook_safe("BTVomitAction", "enter", function (self, unit, blackboard, t)
	if pc.broken or not pc.is_server() or not pc.in_game() then
		return
	end

	pc.guard("host vomit announce", boss_areas.announce_vomit, unit, blackboard)
end)

-- Runs a host sweep with the modded players left out (pc.areas.boss_sweep, which Areas.lua's sweep hook reads). The scope
-- goes whatever happens in there, so that no other sweep ever leaves anyone out, and then the players it would have
-- reached are noted. Neither original returns anything.
local function sweep_without(kind, unit, filter, skip, func, ...)
	local scope = {
		filter = filter,
		units = skip,
		dropped = {},
		counter = "host_" .. kind .. "_left_out",
	}

	pc.areas.boss_sweep = scope

	local called, message = pcall(func, ...)

	pc.areas.boss_sweep = nil

	pc.guard("host " .. kind .. " noted", sweep_noted, kind, unit, scope)

	if not called then
		error(message, 0)
	end
end

-- Host: the vomit's sweep (bt_vomit_action.lua:262), a plain function called with a dot (:196), leaves out the modded
-- players it was announced to. A mod:hook, so everything except the original call runs through pc.guard.
mod:hook("BTVomitAction", "player_vomit_hit_check", function (func, unit, puke_pos, physics_world, blackboard)
	if pc.broken or not pc.is_server() or not vomits_sent[unit] then
		return func(unit, puke_pos, physics_world, blackboard)
	end

	local ok, skip = pc.guard("host vomit filter", boss_areas.vomit_skip, unit)

	if not ok or not skip then
		return func(unit, puke_pos, physics_world, blackboard)
	end

	sweep_without("vomit", unit, VOMIT_FILTER, skip, func, unit, puke_pos, physics_world, blackboard)
end)

-- Host: the beam's sweep (bt_stormfiend_shoot_action.lua:604) leaves out every modded player the host counts as fresh.
mod:hook("BTStormfiendShootAction", "shoot_hit_check", function (func, self, unit, blackboard)
	if pc.broken or not pc.is_server() then
		return func(self, unit, blackboard)
	end

	local ok, skip = pc.guard("host beam filter", boss_areas.beam_skip)

	if not ok or not skip then
		return func(self, unit, blackboard)
	end

	sweep_without("beam", unit, BEAM_FILTER, skip, func, self, unit, blackboard)
end)

-- Runs a host test with the modded players left out of a side's list (boss_areas.hide_modded): the lists come back
-- whatever happens in there, with no pc.guard, so that it happens even once the mod has switched itself off. None of
-- these originals returns anything.
local function without_hidden(func, ...)
	local called, message = pcall(func, ...)

	boss_areas.restore_hidden()

	if not called then
		error(message, 0)
	end
end

-- Host: a pool's own test of players (liquid_area_damage_extension.lua:630) runs with the fresh modded players left out
-- of every side's list, so a player the host has booked into it stays in it until their own screen reports them out.
mod:hook("LiquidAreaDamageExtension", "_update_collision_detection", function (func, self, dt, t)
	if pc.broken or not pc.is_server() then
		return func(self, dt, t)
	end

	local hidden = false

	for _, side in ipairs(Managers.state.side:sides()) do
		local ok, filtered = pc.guard("host pool filter", boss_areas.hide_modded, side, "PLAYER_AND_BOT_UNITS")

		hidden = hidden or ok and filtered
	end

	if not hidden then
		return func(self, dt, t)
	end

	without_hidden(func, self, dt, t)
end)

-- Host: a pool's pulses (_pulse_damage, :774) pass over the living modded players inside, whose own screens tick them,
-- who come back into its colliding units after it. The dead stay in, since the original takes them out itself (:809).
local function pulse_hold(extension)
	if not extension._do_direct_damage_player then
		return nil
	end

	local held = nil

	for unit, armor in pairs(extension._colliding_units) do
		if HEALTH_ALIVE[unit] and pc.host.client_judges(unit) then
			held = held or {}
			held[unit] = armor
		end
	end

	for unit in pairs(held or {}) do
		extension._colliding_units[unit] = nil
	end

	if held then
		pc.count("host_pool_pulses_left_to_client")
	end

	return held
end

mod:hook("LiquidAreaDamageExtension", "_pulse_damage", function (func, self)
	if pc.broken or not pc.is_server() or type(self._colliding_units) ~= "table" then
		return func(self)
	end

	local ok, held = pc.guard("host pool pulse", pulse_hold, self)

	if not ok or not held then
		return func(self)
	end

	-- They come back whatever happens in there. The original returns nothing.
	local called, message = pcall(func, self)

	if type(self._colliding_units) == "table" then
		for unit, armor in pairs(held) do
			self._colliding_units[unit] = armor
		end
	end

	if not called then
		error(message, 0)
	end
end)

-- Host: a wave's push of the players in front (DamageWaveExtension.update, damage_wave_extension.lua:707 and :721) runs
-- with the fresh modded players left out of the side's list that push_intersecting_players reads (ai_utils.lua:1459),
-- as build 6's push aside (D69 question 1): their own screens push them.
local function wave_side(extension, unit)
	local source = extension.source_unit
	local side_unit = HEALTH_ALIVE[source] and source or HEALTH_ALIVE[unit] and unit

	return side_unit and Managers.state.side.side_by_unit[side_unit] or nil
end

mod:hook("DamageWaveExtension", "update", function (func, self, unit, input, dt, context, t)
	if pc.broken or not self.is_launched or type(self.template) ~= "table" or not self.template.player_push_data then
		return func(self, unit, input, dt, context, t)
	end

	local ok, side = pc.guard("host wave side", wave_side, self, unit)
	local filtered = false

	if ok and side then
		ok, filtered = pc.guard("host wave filter", boss_areas.hide_modded, side, "ENEMY_PLAYER_AND_BOT_UNITS")
	end

	if not ok or not filtered then
		return func(self, unit, input, dt, context, t)
	end

	without_hidden(func, self, unit, input, dt, context, t)
end)

-- Client: a stormfiend's beam goes on or off (boss_areas.beam_message).
mod:hook_safe("WeaponSystem", "rpc_set_stormfiend_beam", function (self, channel_id, unit_id, arm_id, active)
	if self.is_server or pc.broken then
		return
	end

	pc.guard("client beam", boss_areas.beam_message, unit_id, arm_id, active)
end)

-- Client: the pools this screen tests its player against, from their husks.
mod:hook_safe("LiquidAreaDamageHuskExtension", "init", function (self, extension_init_context, unit, extension_init_data)
	if pc.broken then
		return
	end

	pc.guard("client pool", boss_areas.pool_spawned, self, unit, extension_init_data)
end)

mod:hook_safe("LiquidAreaDamageHuskExtension", "add_damage_blob", function (self, blob_id, position, is_filled)
	if not pc.broken and pools[self._unit] then
		pc.guard("client pool blob", boss_areas.blob_added, self, blob_id, position)
	end
end)

-- The host's pool takes its buffs back as it goes (liquid_area_damage_extension.lua:352), and this screen its own copy.
mod:hook_safe("LiquidAreaDamageHuskExtension", "destroy", function (self)
	local pool = pools[self._unit]

	if pool then
		if pool.own then
			pcall(end_pool_buff, pc.local_player_unit(), pool)
		end

		if pool.inside then
			pc.count("client_pool_left")
		end
	end

	pools[self._unit] = nil
end)

-- Client: the waves this screen tests its player against, while their copies run.
mod:hook_safe("DamageWaveHuskExtension", "set_running_wave", function (self, unit)
	if not pc.broken then
		pc.guard("client wave", boss_areas.wave_started, self, unit)
	end
end)

-- Any wave that goes clears the host's shared record of who a wave has hit (damage_wave_extension.lua:315), and so this
-- screen's.
mod:hook_safe("DamageWaveHuskExtension", "destroy", function (self)
	boss_areas.wave_gone(self.unit)
end)
