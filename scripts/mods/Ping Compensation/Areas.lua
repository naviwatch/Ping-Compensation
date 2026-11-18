local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Family H (build 5.1, D52, D55, D58, D59): enemy areas judged from the live position of the player they reach, on that
-- player's own screen, and their damage ticks counted there too. The host leaves a modded player out of its own test
-- and books what that player's client reports (pc_area), as vanilla would have for them.
--   * Globadier's gas (AreaDamageExtension, template globadier_area_dot_damage, area_damage_templates.lua:8): the client
--     ticks on its own copy of the cloud's timer (area_damage_extension.lua:331). At each tick while its player is
--     inside, by the template's own test (:34), it shows the tick's damage at once and reports it; the host books it
--     with the template's own do_damage. The impact, which hurts those within a smaller radius once, is judged and
--     shown when the cloud starts on this screen (rpc_area_damage).
--   * Warpfire thrower's jet (BTWarpfireThrowerShootAction._close_range_attack, bt_warpfire_thrower_shoot_action.lua:339):
--     every modded player's screen sweeps its own copy on the jet's own cooldown and judges only its own player, with
--     vanilla's rule read from its own copy of the jet's target (T19). Only the target's screen turns the thrower,
--     towards the player's live position by the node's own rule (D10's facing). A hit starts this screen's own copy of
--     the jet's burning at once and is reported, so the host gives its own copy of the burning, which every other
--     client sees.
--   * Warpfire's ground fire (DamageBlobExtension.check_overlap, damage_blob_extension.lua:603): the client rebuilds the
--     fire's line from the effects the host sends, starts its own copy of the fire's burning when its player steps in
--     and ends it when they step out, and reports both, for the host's in_liquid and its own copy of the burning.
--   * Both burnings run on every machine, but only the host's tick deals damage (buff_function_templates.lua:1405 and
--     :1792). Each tick of a burning on this client's own player is shown at once and reported, and the host books it;
--     the host's own ticks deal no damage to a modded player, and this client drops the host's copy of those burnings
--     for its own player.
--   * Blightstormer's vortex (VortexExtension._update_attract_players, vortex_extension.lua:512): the client runs the
--     pull and the catch for its own player against its copy of the vortex. A catch shows at once (D53) and is
--     undone if the host refuses it or never confirms it.

local areas = {}

pc.areas = areas

local GAS_TEMPLATES = {
	globadier_area_dot_damage = true,
}
-- The burning buffs whose ticks this mod moves to the burning player's own screen (D58): the ground fire's
-- (damage_blob_templates.lua:11) and the jet's (breed_skaven_warpfire_thrower.lua:265). A thrower's own buff_name is
-- added when its action is found, since a mutator can swap in another (mutator_elite_specials.lua:52).
local BURNS = {
	warpfire_thrower_ground_base = true,
	warpfire_thrower_face_base = true,
	warpfire_thrower_face_base_mutator = true,
}
-- Their tick functions (BuffFunctionTemplates.functions, buff_function_templates.lua:1401 and :1788), and which burning
-- each ticks.
local BURN_UPDATES = {
	update_moving_through_warpfire = "fire",
	update_warpfirethrower_in_face = "jet",
}
local PLAYER_RADIUS = 0.35 -- about a player's width, for judging by shape
local PLAYER_HEIGHT = 1.8
local MIN_VORTEX_HEIGHT_DIFF = -0.5 -- VortexExtension.attract (vortex_extension.lua:734)
local JET_LINGER = 1 -- seconds a jet is kept past its firing time, unless its shooting ends first
local TICK_MEMORY = 2 -- seconds the host still books a reported tick whose cloud, fire or thrower has just gone
local POWER_BLOCK_DOT = math.cos(math.pi * 2 / 3) -- is_grail_knight_blocking (buff_function_templates.lua:91)

local function unit_of(go_id)
	return type(go_id) == "number" and Managers.state.unit_storage:unit(go_id) or nil
end

local function go_of(unit)
	return unit and Managers.state.unit_storage:go_id(unit) or nil
end

local jet_actions = {} -- breed name -> the action of its BTWarpfireThrowerShootAction, or false

local function jet_action(breed)
	if not breed then
		return nil
	end

	local cached = jet_actions[breed.name]

	if cached ~= nil then
		return cached or nil
	end

	local node = pc.find_node(pc.tree_of(breed), function (candidate)
		return candidate[1] == "BTWarpfireThrowerShootAction" and type(candidate.action_data) == "table"
	end)
	local action = node and node.action_data or false

	jet_actions[breed.name] = action

	if action and type(action.buff_name) == "string" then
		BURNS[action.buff_name] = true
	end

	return action or nil
end

-- Host ---------------------------------------------------------------------------------------------------------------

local jet_skip = nil -- during a warpfire's sweep: the modded players it leaves out, whose own screens judge the jet (T19)
local jets_sent = {} -- warpfire thrower unit -> { target, players = { [player unit] = peer } } for its firing now
local tick_sources = {} -- network id -> what the host last booked a tick from, for a tick that arrives once it has gone

-- The cloud's own test, as its template worked it out from where the host sees every player: the modded players'
-- entries go, for its ticks and its impact alike, since their own screens judge both (D58).
local function filter_gas(buffer)
	local kept = {}

	for i = 1, #buffer do
		local entry = buffer[i]

		if pc.host.client_judges(entry.unit) then
			pc.count("host_gas_left_to_client")
		else
			kept[#kept + 1] = entry
		end
	end

	return kept
end

-- The impact this player's screen saw (AreaDamageExtension.start_area_damage, area_damage_extension.lua:163), booked
-- as the cloud's own template books it.
local function book_gas_impact(player_unit, cloud)
	local extension = cloud and ScriptUnit.has_extension(cloud, "area_damage_system")

	if not extension or not GAS_TEMPLATES[extension.area_damage_template] then
		return "no cloud"
	end

	local damage = extension.aoe_init_damage

	if type(damage) ~= "number" or damage <= 0 then
		return "no impact damage here"
	end

	local template = AreaDamageTemplates.templates[extension.area_damage_template]

	pc.host.booking = true

	template.server.do_damage({
		unit = player_unit,
		damage = damage,
		damage_source = extension.damage_source,
	}, cloud, extension.source_attacker_unit, extension._custom_data_table)

	pc.host.booking = false
	pc.count("host_gas_impacts")

	return "booked"
end

-- The ground fire this player's screen saw them step into or out of, booked as check_overlap would have
-- (damage_blob_extension.lua:613): in_liquid and the host's own copy of the burning, which reaches every other client.
-- Its ticks deal no damage here (the burning hook below); the player's own screen reports them.
local function book_fire(player_unit, blob, inside)
	local extension = blob and ScriptUnit.has_extension(blob, "area_damage_system")

	if not extension or type(extension.player_units_inside) ~= "table" or not extension.buff_template_name then
		return "no fire"
	end

	local status = ScriptUnit.extension(player_unit, "status_system")
	local buffs = ScriptUnit.extension(player_unit, "buff_system")
	local inside_id = extension.player_units_inside[player_unit]
	local outcome = "nothing to change"

	pc.host.booking = true

	if inside and not inside_id and not buffs:has_buff_type(extension.buff_template_type) then
		if status.in_liquid_unit ~= blob then
			StatusUtils.set_in_liquid_network(player_unit, true, blob)
		end

		extension.player_units_inside[player_unit] = extension.buff_system:add_buff(player_unit, extension.buff_template_name, blob, true)
		outcome = "set on fire"

		pc.count("host_fire_entered")
	elseif not inside and inside_id then
		if status.in_liquid_unit == blob then
			StatusUtils.set_in_liquid_network(player_unit, false)
		end

		extension.buff_system:remove_server_controlled_buff(player_unit, inside_id)
		extension.player_units_inside[player_unit] = nil
		outcome = "out of the fire"

		pc.count("host_fire_left")
	end

	pc.host.booking = false

	return outcome
end

-- The jet's hit this player's screen saw: the buff the host's sweep would have given (bt_warpfire_thrower_shoot_action.lua:410),
-- which reaches every other client. Its tick deals no damage here; the player's own screen reports it.
local function book_jet(player_unit, thrower)
	local action = thrower and jet_action(Unit.get_data(thrower, "breed"))

	if not thrower or not HEALTH_ALIVE[thrower] or not action or not action.buff_name then
		return "the thrower is gone"
	end

	pc.host.booking = true
	Managers.state.entity:system("buff_system"):add_buff(player_unit, action.buff_name, thrower)
	pc.host.booking = false
	pc.count("host_jet_hits")

	return "set on fire"
end

-- One tick of a burning on this player, as the burning's own apply function works it out (apply_moving_through_warpfire
-- and apply_warpfirethrower_in_face, buff_function_templates.lua:1354 and :1734): by difficulty and the player's armour,
-- with the source's damage buffs for the ground fire.
local function burn_damage(template_name, player_unit, source_unit, with_source_buffs)
	local template = BuffUtils.get_buff_template(template_name)
	local sub_buff = template and template.buffs and template.buffs[1]
	local by_difficulty = sub_buff and sub_buff.difficulty_damage
	local damage_table = by_difficulty and by_difficulty[Managers.state.difficulty:get_difficulty()]
	local breed = Unit.get_data(player_unit, "breed")
	local damage = damage_table and damage_table[breed and breed.armor_category or 1]

	if type(damage) ~= "number" then
		return nil
	end

	if with_source_buffs and source_unit and ALIVE[source_unit] then
		local source_buffs = ScriptUnit.has_extension(source_unit, "buff_system")

		if source_buffs then
			damage = source_buffs:apply_buffs_to_value(damage, "damage_dealt")
		end
	end

	return damage, sub_buff.damage_type or "warpfire_ground"
end

-- What a reported tick comes from, by its unit: a gas cloud, a ground fire, or a warpfire thrower for its jet's burning.
local function tick_source(unit)
	local extension = ScriptUnit.has_extension(unit, "area_damage_system")

	if extension and GAS_TEMPLATES[extension.area_damage_template] then
		return {
			kind = "gas",
			damage = extension.aoe_dot_damage,
			damage_type = "damage_over_time",
			damage_source = extension.damage_source,
		}
	elseif extension and extension.buff_template_name and type(extension.player_units_inside) == "table" then
		local source = extension.get_source_attacker_unit and extension:get_source_attacker_unit()
		local breed = source and ALIVE[source] and Unit.get_data(source, "breed")

		return {
			kind = "fire",
			template_name = extension.buff_template_name,
			source = source,
			source_buffs = true,
			damage_source = breed and breed.name or "dot_debuff",
		}
	end

	local breed = Unit.get_data(unit, "breed")
	local action = jet_action(breed)

	if action and action.buff_name then
		return {
			kind = "jet",
			template_name = action.buff_name,
			damage_source = breed.name,
		}
	end

	return nil
end

-- One tick this player's screen showed (D58): a gas cloud's, booked with its template's own do_damage
-- (area_damage_templates.lua:55); a ground fire's or a jet's burning, booked as the burning's own tick would have been
-- (buff_function_templates.lua:1413 and :1810). A tick whose source has just gone is still booked for a moment, with
-- the player standing in for the attacker, as the game does for a fire whose blob has gone (:1407).
local function book_tick(player_unit, unit, go_id)
	local t = pc.now()
	local source = unit and Unit.alive(unit) and tick_source(unit) or nil

	if source then
		source.t = t
		tick_sources[go_id] = source
	else
		source = tick_sources[go_id]

		if not source or t - source.t > TICK_MEMORY then
			pc.count("host_ticks_lost")

			return "its source is gone"
		end

		unit = nil

		pc.count("host_ticks_late")
	end

	if source.kind == "gas" and unit then
		local extension = ScriptUnit.extension(unit, "area_damage_system")
		local template = AreaDamageTemplates.templates[extension.area_damage_template]

		if type(source.damage) ~= "number" then
			return "no damage here"
		end

		pc.host.booking = true

		template.server.do_damage({
			unit = player_unit,
			damage = source.damage,
			damage_source = source.damage_source,
		}, unit, extension.source_attacker_unit, extension._custom_data_table)

		pc.host.booking = false
		pc.count("host_gas_ticks")

		return string.format("gas tick of %.1f booked", source.damage)
	end

	local damage, damage_type = source.damage, source.damage_type

	if source.kind ~= "gas" then
		damage, damage_type = burn_damage(source.template_name, player_unit, source.source, source.source_buffs)
	end

	if type(damage) ~= "number" then
		return "no damage here"
	elseif source.kind ~= "gas" and not HEALTH_ALIVE[player_unit] then
		return "the player is dead"
	end

	pc.host.booking = true
	DamageUtils.add_damage_network(player_unit, unit or player_unit, damage, "torso", damage_type, nil, Vector3(1, 0, 0), source.damage_source, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 1)
	pc.host.booking = false
	pc.count("host_" .. source.kind .. "_ticks")

	return string.format("%s tick of %.1f booked%s", source.kind, damage, unit and "" or " (its source has gone)")
end

-- The vortex's catch this player's screen saw, booked as _update_attract_players would have
-- (vortex_extension.lua:623), while the vortex is still there and can take them.
local function book_catch(player_unit, vortex)
	local blackboard = vortex and BLACKBOARDS[vortex]
	local vortex_data = blackboard and blackboard.vortex_data
	local template = vortex_data and vortex_data.vortex_template
	local status = ScriptUnit.extension(player_unit, "status_system")
	local breed = BLACKBOARDS[player_unit] and BLACKBOARDS[player_unit].breed

	if not template or not HEALTH_ALIVE[vortex] then
		return "the vortex is gone"
	elseif vortex_data.players_inside[player_unit] or status:is_in_vortex() then
		return "already inside"
	elseif not breed or not breed.vortexable or not status:is_valid_vortex_target() then
		return "can't be caught now"
	end

	pc.host.booking = true

	local caught = StatusUtils.set_in_vortex_network(player_unit, true, vortex)

	pc.host.booking = false

	if not caught then
		return "the game refused it"
	end

	vortex_data.players_inside[player_unit] = {
		vortex_eject_height = ConflictUtils.random_interval(template.player_eject_height),
		vortex_eject_time = pc.now() + template.player_in_vortex_max_duration,
	}
	vortex_data.num_players_inside = vortex_data.num_players_inside + 1

	pc.count("host_vortex_catches")

	return "booked"
end

local AREA_KINDS = {
	tick = true,
	impact = true,
	fire = true,
	jet = true,
	vortex = true,
}

mod:network_register("pc_area", function (sender, version, kind, go_id, inside)
	-- A host that has switched itself off judges its own areas again, so a client's report would count twice; a catch
	-- gets no answer, so the client undoes it.
	if pc.broken or not pc.is_server() or not pc.in_game() or version ~= pc.VERSION or not AREA_KINDS[kind] or type(go_id) ~= "number" or type(inside) ~= "boolean" then
		return
	end

	local player = Managers.player:player_from_peer_id(sender)
	local player_unit = player and player.player_unit

	if not player_unit or not Unit.alive(player_unit) then
		return
	end

	-- A client the host doesn't count as fresh has been judged here meanwhile.
	if pc.host.client_judges(player_unit) ~= sender then
		pc.count("host_area_ignored_stale")

		return
	end

	local unit = unit_of(go_id)
	local ok, outcome

	if kind == "tick" then
		ok, outcome = pc.guard("host tick report", book_tick, player_unit, unit, go_id)
	elseif kind == "impact" then
		ok, outcome = pc.guard("host gas impact", book_gas_impact, player_unit, unit)
	elseif kind == "fire" then
		ok, outcome = pc.guard("host fire report", book_fire, player_unit, unit, inside)
	elseif kind == "jet" then
		ok, outcome = pc.guard("host jet report", book_jet, player_unit, unit)
	else
		ok, outcome = pc.guard("host vortex catch", book_catch, player_unit, unit)

		mod:network_send("pc_reaction_ack", sender, pc.VERSION, "catch", go_id, ok and outcome == "booked" and "applied" or "rejected")
	end

	pc.host.booking = false
	pc.count("host_area_reports")
	pc.count("host_area_" .. kind)

	pc.log("host area=%s go=%d target=%s inside=%s outcome=%s", kind, go_id, pc.host.player_name(sender), tostring(inside), ok and tostring(outcome) or "error")
end)

-- A warpfire thrower starts firing (_attack_fire), or turns to a new target while it fires (_aim_at_target,
-- bt_warpfire_thrower_shoot_action.lua:473): every modded player is told, with its target, aimed for that target,
-- whose own screen turns the thrower. Every modded player's own screen judges the jet for them from now on (T19).
-- retarget: a new target while it fires. One that isn't a live unit yet keeps the earlier announcement, since the
-- players' screens still run the jet from it, and is announced once it is (D57 review).
function areas.announce_jet(unit, blackboard, retarget)
	local target = blackboard and blackboard.target_unit
	local network = pc.network()
	local go_id = network:unit_game_object_id(unit)
	local target_go_id = target and Unit.alive(target) and network:unit_game_object_id(target)

	for thrower in pairs(jets_sent) do
		if not Unit.alive(thrower) or not HEALTH_ALIVE[thrower] then
			jets_sent[thrower] = nil
		end
	end

	if not go_id or not target_go_id then
		if not retarget then
			jets_sent[unit] = nil
		end

		return
	end

	if retarget then
		pc.count("host_jets_retargeted")
	end

	local players = {}
	local sent = 0

	for _, player in pairs(Managers.player:human_players()) do
		local player_unit = player.player_unit
		local peer = player_unit and Unit.alive(player_unit) and pc.host.client_judges(player_unit)

		if peer then
			players[player_unit] = peer
			sent = sent + 1

			mod:network_send("pc_aim", peer, pc.VERSION, go_id, "jet", "", target_go_id, player_unit == target)
		end
	end

	jets_sent[unit] = {
		target = target,
		players = players,
	}

	if sent > 0 then
		local target_peer = pc.host.client_judges(target)

		pc.count("host_jets_aimed", sent)
		pc.log("host jet go=%d target=%s sent to %d modded players", go_id, target_peer and pc.host.player_name(target_peer) or "not modded", sent)
	end
end

function areas.jet_retarget(unit, blackboard)
	local record = jets_sent[unit]

	if record and blackboard and blackboard.target_unit ~= record.target then
		areas.announce_jet(unit, blackboard, true)
	end
end

-- The modded players the host's own sweep leaves out: those this firing was announced to, while the host still counts
-- them as fresh. A player who turned fresh since is judged by the host's sweep, since nobody told their screen.
function areas.jet_skips(unit)
	local record = jets_sent[unit]
	local skip = nil

	if not record then
		return nil
	end

	for player_unit, peer in pairs(record.players) do
		if Unit.alive(player_unit) and pc.host.client_judges(player_unit) == peer then
			skip = skip or {}
			skip[player_unit] = true
		end
	end

	return skip
end

local function without_skipped_hits(hits, skip)
	local kept = {}

	for i = 1, #hits do
		local hit = hits[i]
		local actor = type(hit) == "table" and hit.actor
		local unit = actor and Actor.unit(actor)

		if unit and skip[unit] then
			pc.count("host_jet_left_out")
		else
			kept[#kept + 1] = hit
		end
	end

	return kept
end

-- The host's own tick of a modded player's burning deals no damage: their own screen ticks it and reports it. A jet's
-- burning only if this firing was announced to them, since otherwise the host's own sweep gave it and their screen
-- knows nothing of it (areas.jet_skips).
function areas.host_burn_tick(kind, unit, buff)
	local peer = pc.host.client_judges(unit)

	if not peer then
		return false
	end

	if kind == "jet" then
		local record = buff.attacker_unit and jets_sent[buff.attacker_unit]

		if not record or record.players[unit] ~= peer then
			pc.count("host_burn_ticks_own_sweep")

			return false
		end
	end

	pc.count("host_burn_ticks_left_to_client")
	pc.log("host burn tick target=%s buff=%s: left to their screen", pc.host.player_name(peer), tostring(buff.buff_template_name))

	return true
end

local hidden = {} -- side -> its full list of players and bots, while the vortex's own test runs without the modded ones

-- The vortex's own test leaves out every modded player it hasn't caught or thrown out: their own screens pull and catch
-- them. One it holds stays in, so the host still throws them out as in vanilla.
function areas.vortex_filter(vortex_data)
	local inside = vortex_data.players_inside or {}
	local ejected = vortex_data.players_ejected or {}

	for _, side in ipairs(Managers.state.side:sides()) do
		local units = side.PLAYER_AND_BOT_UNITS
		local kept = nil

		for i = 1, #units do
			local unit = units[i]

			if pc.host.client_judges(unit) and not inside[unit] and not ejected[unit] then
				kept = kept or {}
			end
		end

		if kept then
			for i = 1, #units do
				local unit = units[i]

				if not (pc.host.client_judges(unit) and not inside[unit] and not ejected[unit]) then
					kept[#kept + 1] = unit
				end
			end

			hidden[side] = units
			side.PLAYER_AND_BOT_UNITS = kept
		end
	end
end

function areas.vortex_restore()
	for side, units in pairs(hidden) do
		side.PLAYER_AND_BOT_UNITS = units
	end

	hidden = {}
end

function areas.host_clear()
	jet_skip = nil
	jets_sent = {}
	tick_sources = {}
	areas.vortex_restore()
end

-- Client -------------------------------------------------------------------------------------------------------------

local clouds = {} -- gas cloud unit -> { go_id, timer, life, ticks, hits } once it has started on this screen
local fires = {} -- ground fire unit -> { radius, life, points, inside, go_id, buff_name, buff_type, own }
local jets = {} -- warpfire thrower unit -> its jet while it fires, on every modded player's screen (T19)
local vortices = {} -- vortex unit -> its husk extension
local vortex_state = {} -- vortex unit -> { near, pulled, caught }
local catches = {} -- vortex network id -> the catch this screen shows until the host confirms it
local own_burns = {} -- buff id -> true for this screen's own copies of the fires' burnings, which have no end time

local function judging()
	return not pc.broken and not pc.is_server() and pc.host_fresh()
end

local function report(kind, go_id, inside)
	local host_peer = pc.host_peer()

	if host_peer and go_id then
		mod:network_send("pc_area", host_peer, pc.VERSION, kind, go_id, inside and true or false)
	end
end

-- The game's own poison test for a player (area_damage_templates.lua:33).
local function poisonable(target)
	local breed = Unit.get_data(target, "breed")

	return breed ~= nil and (breed.poison_resistance or 0) < 100
end

-- A tick or an impact shown at once (HitResults.lua): its feedback and the HP estimate, as the host's damage message
-- would show them. Returns the estimate.
local function show(attacker, go_id, damage_source, source_attacker, damage, damage_type)
	local ok, amount = pc.guard("client area shown", pc.hit_results.area, attacker, go_id, damage_source, source_attacker, damage, damage_type)

	return ok and amount or 0
end

-- Gas: the cloud's impact as it starts on this screen, from the same rpc_area_damage the host's own impact sent. The
-- radius of the impact is the throw's or the suicide's own (bt_throw_poison_globe_action.lua:174, ai_utils.lua:469),
-- from this client's copy of the globadier's actions: a thrown globe is a projectile, a suicide's gas isn't.
local function impact_radius(extension, unit)
	local source = Breeds[extension.damage_source]
	local initial = nil

	if source and ScriptUnit.has_extension(unit, "projectile_locomotion_system") then
		local node = pc.find_node(pc.tree_of(source), function (candidate)
			return candidate[1] == "BTThrowPoisonGlobeAction" and type(candidate.action_data) == "table"
		end)

		initial = node and node.action_data.initial_radius
	end

	return initial or extension.radius
end

function areas.cloud_started(extension)
	local unit = extension.unit

	if not GAS_TEMPLATES[extension.area_damage_template] or not extension.damage_players then
		return
	end

	local go_id = go_of(unit)

	clouds[unit] = {
		go_id = go_id,
		timer = 0, -- the host's damage_timer, as this screen's copy of it runs (area_damage_extension.lua:325)
		life = 0, -- and its life_timer
		ticks = 0,
		hits = 0,
	}

	local target = pc.local_player_unit()

	if not target or not judging() or type(extension.aoe_init_damage) ~= "number" or extension.aoe_init_damage <= 0 or not poisonable(target) then
		return
	end

	local radius = impact_radius(extension, unit)
	local distance = Vector3.distance(POSITION_LOOKUP[target], Unit.local_position(unit, 0))

	if radius and distance < radius then
		report("impact", go_id, true)

		local estimate = show(unit, go_id, extension.damage_source, extension.source_attacker_unit, extension.aoe_init_damage, "damage_over_time")

		pc.count("client_gas_impacts")
		pc.log("client area=impact go=%s distance=%.2f radius=%.2f: hit, estimate=%.1f", tostring(go_id), distance, radius, estimate)
	end
end

-- One tick of the cloud on this screen: this player, if inside by the template's own test (area_damage_templates.lua:34),
-- is shown the tick at once and the host is told.
local function tick_cloud(unit, extension, cloud)
	local target = pc.local_player_unit()

	if not target or not judging() or not extension.damage_players or not poisonable(target) then
		return
	end

	local distance = Vector3.distance(POSITION_LOOKUP[target], Unit.local_position(unit, 0))

	if distance >= extension.radius then
		return
	end

	cloud.hits = cloud.hits + 1

	report("tick", cloud.go_id, true)

	local estimate = show(unit, cloud.go_id, extension.damage_source, extension.source_attacker_unit, extension.aoe_dot_damage, "damage_over_time")

	pc.count("client_gas_ticks")
	pc.log("client area=gas go=%s tick=%d distance=%.2f radius=%.2f estimate=%.1f", tostring(cloud.go_id), cloud.ticks, distance, extension.radius, estimate)
end

-- Every frame of a cloud that has started on this screen, after its own update (D58): the host's timer, run on this
-- screen's copy. The host's tick comes when its damage_timer has reached aoe_dot_damage_interval, checked before each
-- frame's time is added, and none once its life is over (area_damage_templates.lua:11 to :20, area_damage_extension.lua:309
-- to :332): the first one interval after the start, then one every interval, with the cloud's frames.
function areas.cloud_update(extension, dt)
	local unit = extension.unit
	local cloud = clouds[unit]

	if not cloud or not extension.area_damage_started or type(dt) ~= "number" then
		return
	end

	local interval = extension.aoe_dot_damage_interval
	local due = type(interval) == "number" and type(extension.life_time) == "number" and cloud.life <= extension.life_time and cloud.timer >= interval

	if due then
		cloud.timer = 0
	end

	cloud.timer = cloud.timer + dt
	cloud.life = cloud.life + dt

	if due then
		cloud.ticks = cloud.ticks + 1

		tick_cloud(unit, extension, cloud)
	end
end

-- Ground fire: the line from its first live blob to its last, as the host tests it (damage_blob_extension.lua:606), with
-- the blobs rebuilt from the effects (add_damage_blob_fx below). Returns whether this player is within the blob radius
-- of it on the flat, and whether their height is within that radius of the blob vanilla's own index would pick (:625);
-- nil while the fire has no live blob, when the host's test doesn't run either (:505), so nothing changes.
local function fire_test(fire, position, t)
	local points = fire.points

	while points[1] and points[1].dies < t do
		table.remove(points, 1)
	end

	local count = #points

	if count == 0 then
		return nil
	end

	local first = points[1].position:unbox()
	local last = points[count].position:unbox()
	local nearest = Geometry.closest_point_on_line(position, first, last)

	if Vector3.length_squared(Vector3.flat(position - nearest)) >= fire.radius * fire.radius then
		return false, false
	end

	local index = math.clamp(math.floor(0.5 + Vector3.distance(first, nearest) * count) + 1, 1, count)

	return true, fire.radius > math.abs(position.z - points[index].position:unbox().z)
end

-- This screen's own copy of the fire's burning on its player (D58), as the host's check_overlap would add its own
-- (damage_blob_extension.lua:640), without sending anything: BuffExtension.add_buff only adds it here.
local function start_fire_burn(target, unit, fire)
	local buffs = ScriptUnit.has_extension(target, "buff_system")

	if not buffs or not fire.buff_name then
		return false
	end

	local id, added = buffs:add_buff(fire.buff_name, {
		attacker_unit = unit,
	})

	if not added or added == 0 then
		return false
	end

	fire.own = id
	own_burns[id] = true

	pc.count("client_burns_started")

	return true
end

local function end_fire_burn(target, fire)
	local buffs = fire.own and target and Unit.alive(target) and ScriptUnit.has_extension(target, "buff_system")

	if buffs then
		buffs:remove_buff(fire.own)
	end

	if fire.own then
		own_burns[fire.own] = nil
	end

	fire.own = nil
end

-- Each frame, as check_overlap runs for the host's own players (damage_blob_extension.lua:613): a player not burning
-- from this fire starts burning once they are in its line and not already burning from another fire; a player burning
-- from it stops once they are out of the line on the flat. A burning of this fire's that the host gave before this
-- screen judged it counts as this fire's (the host's own message ends it).
local function update_fires(target, t)
	local position = POSITION_LOOKUP[target]
	local buffs = ScriptUnit.has_extension(target, "buff_system")

	for unit, fire in pairs(fires) do
		if not Unit.alive(unit) then
			end_fire_burn(target, fire)

			fires[unit] = nil
		else
			local flat, height = fire_test(fire, position, t)
			local burn = buffs and fire.buff_type and buffs:get_buff_type(fire.buff_type)
			local go_id = fire.go_id or go_of(unit)

			if flat == nil then
				-- No live effect: nothing changes, as on the host.
			elseif fire.inside and not flat then
				fire.inside = false

				end_fire_burn(target, fire)
				report("fire", go_id, false)
				pc.count("client_fire_left")
				pc.log("client area=fire go=%s inside=false points=%d", tostring(go_id), #fire.points)
			elseif not fire.inside and flat and height then
				local adopted = burn ~= nil and burn.attacker_unit == unit
				local started = not adopted and burn == nil and start_fire_burn(target, unit, fire)

				if adopted or started then
					fire.inside = true

					report("fire", go_id, true)
					pc.count("client_fire_entered")
					pc.log("client area=fire go=%s inside=true points=%d burning=%s", tostring(go_id), #fire.points, adopted and "the host's" or "this screen's own")
				end
			end
		end
	end
end

-- While this screen doesn't judge, its own copies of the fires' burnings go and the host is told it is out of them,
-- which it heeds only if it still counts this client as fresh; otherwise it judges the fire itself and gives its own.
-- quietly: at the end of a mission, when there is nobody to tell.
local function release_fires(target, quietly)
	for unit, fire in pairs(fires) do
		if fire.own then
			end_fire_burn(target, fire)
			pc.count("client_burns_released")
		end

		if fire.inside and not quietly then
			report("fire", fire.go_id or go_of(unit), false)
		end

		fire.inside = false
	end
end

-- Jet: the thrower's wanted facing by its shooting node (_calculate_wanted_target_position and _aim_at_target,
-- bt_warpfire_thrower_shoot_action.lua:491 and :444), towards the point halfway to this player.
local function jet_wanted_rotation(unit, target)
	local unit_position = Unit.world_position(unit, Unit.has_node(unit, "c_spine") and Unit.node(unit, "c_spine") or 0)
	local target_position = POSITION_LOOKUP[target] + Vector3.up()
	local offset = target_position - unit_position
	local length = Vector3.length(offset)
	local mid = unit_position + offset * 0.5

	mid.z = mid.z + length * 0.01

	if length < 2 then
		mid = target_position
	end

	local flat = Vector3.flat(mid - POSITION_LOOKUP[unit])

	if Vector3.length_squared(flat) < 0.0001 then
		return nil
	end

	return Quaternion.look(Vector3.normalize(flat), Vector3.up())
end

-- A thrower fires, or turns to a new target while it fires (T19): every modded player's screen keeps its jet, and only
-- its target's turns the thrower.
function areas.jet_aimed(go_id, target_go_id, aimed)
	local unit = unit_of(go_id)
	local target = unit_of(target_go_id)
	local own = pc.local_player_unit()
	local breed = unit and Unit.alive(unit) and Unit.get_data(unit, "breed")
	local action = jet_action(breed)

	if not action or not own or not judging() or not target or not Unit.alive(target) then
		return
	end

	local t = pc.now()
	local to_target = Vector3.flat(POSITION_LOOKUP[target] - POSITION_LOOKUP[unit])
	local jet = jets[unit]
	-- When the host's jet may sweep (warpfire_face_timer, bt_warpfire_thrower_shoot_action.lua:161 and :186), from this
	-- screen's view of the target's distance, and at the first firing its facing.
	local face_t = t + Vector3.length(to_target) * 0.08

	if not jet then
		local forward = Vector3.flat(Quaternion.forward(Unit.local_rotation(unit, 0)))
		local dot = Vector3.length_squared(to_target) > 0 and Vector3.length_squared(forward) > 0 and Vector3.dot(Vector3.normalize(to_target), Vector3.normalize(forward)) or 1

		face_t = face_t + (dot < 0 and math.abs(dot) or 0)
		jet = {
			go_id = go_id,
			action = action,
			cooldown_t = 0, -- the host's close_attack_cooldown (:421), 0 when it starts firing (:247)
			ends_t = t + (action.firing_time or 5) + JET_LINGER,
			turn_speed = pc.turn_speed(breed, action),
			sweeps = 0,
			hits = 0,
			t = t,
		}
		jets[unit] = jet

		pc.count("client_jets_announced")
	else
		pc.count("client_jets_retargeted")
	end

	local was_aimed = jet.aimed

	jet.target = target
	jet.aimed = aimed == true and target == own
	jet.face_t = face_t

	if jet.aimed and not was_aimed then
		jet.rotation = QuaternionBox(Unit.local_rotation(unit, 0))

		pc.count("client_jets_aimed")
	end

	pc.log("client jet go=%d target=%s aimed=%s", go_id, tostring(target_go_id), tostring(jet.aimed))
end

function areas.has_jets()
	return next(jets) ~= nil
end

-- The host's other animations for the thrower end its shooting here: its leave plays attack_shoot_end
-- (bt_warpfire_thrower_shoot_action.lua:97), and a stagger or a new turn plays its own.
local JET_ANIMS = {
	attack_shoot = true,
	attack_shoot_start = true,
}

local function end_jet(unit, jet, why)
	jets[unit] = nil

	pc.count("client_jets_ended")
	pc.log("client jet go=%d ended (%s): sweeps=%d hits=%d after %.2fs", jet.go_id, why, jet.sweeps, jet.hits, pc.now() - jet.t)
end

function areas.animation_changed(go_id, anim_id)
	local unit = unit_of(go_id)
	local jet = unit and jets[unit]
	local event = jet and NetworkLookup.anims[anim_id]

	if jet and not JET_ANIMS[event] then
		end_jet(unit, jet, tostring(event))
	end
end

-- This player's hit staggered or killed the thrower on their screen (Reactions.lua): its shooting is over here, as it
-- will be on the host once the hit arrives.
function areas.stop_turning(unit, reason)
	local jet = jets[unit]

	if jet then
		end_jet(unit, jet, tostring(reason))
	end
end

-- Whether the jet's swept sphere, along the gun's flat forward from just behind the muzzle (:350), reaches this
-- player's body by shape: an upright segment for the player.
local function jet_reaches(muzzle, forward, length, radius, position)
	local start = muzzle - forward * 0.5
	local offset = Vector3.flat(position - start)
	local along = Vector3.dot(offset, forward)

	if along < -radius or along > length + 0.5 + radius then
		return false
	end

	local side = offset - forward * along

	if Vector3.length(Vector3.flat(side)) > radius + PLAYER_RADIUS then
		return false
	end

	return muzzle.z >= position.z - radius and muzzle.z <= position.z + PLAYER_HEIGHT + radius
end

-- One sweep of this screen's copy of the jet, for this player only (T19). Vanilla's rule (:396 to :410): a player in the
-- swept sphere burns if the jet's target is nearly straight ahead of the gun, unless the target blocks with a shield
-- and the power-block perk and this player then blocks the jet; the target's position, block and perks are this
-- screen's copy of them. A hit starts this screen's own copy of the burning, whose first tick comes at once (D58).
local function sweep_jet(unit, jet, own, target)
	local action = jet.action
	local inventory = ScriptUnit.has_extension(unit, "ai_inventory_system")
	local breed = Unit.get_data(unit, "breed")
	local gun = inventory and breed and breed.default_inventory_template and inventory:get_unit(breed.default_inventory_template)

	if not gun or not Unit.alive(gun) or not Unit.has_node(gun, action.muzzle_node or "p_fx") then
		return
	end

	local muzzle_node = Unit.node(gun, action.muzzle_node or "p_fx")
	local muzzle = Unit.world_position(gun, muzzle_node)
	local forward = Vector3.flat(Quaternion.forward(Unit.world_rotation(gun, muzzle_node)))

	if Vector3.length_squared(forward) < 0.0001 then
		return
	end

	forward = Vector3.normalize(forward)
	jet.sweeps = jet.sweeps + 1

	if not jet_reaches(muzzle, forward, action.close_attack_range or 15, action.hit_radius or 0.4, POSITION_LOOKUP[own]) then
		return
	end

	local to_target = Vector3.flat(POSITION_LOOKUP[target] - muzzle)
	local distance = Vector3.length(to_target)
	local dot = distance > 0 and Vector3.dot(Vector3.normalize(to_target), forward) or 1
	local valid = dot > 0.99 or distance < (action.aim_rotation_override_distance or 3) and dot > 0.55

	if not valid then
		pc.count("client_jet_off_target")
		pc.log("client jet go=%d reached you, but its target wasn't straight ahead: dot=%.3f distance=%.2f", jet.go_id, dot, distance)

		return
	end

	local target_buffs = ScriptUnit.has_extension(target, "buff_system")
	local target_status = ScriptUnit.has_extension(target, "status_system")
	local blocking, shield_block = false, false

	if target_status then
		blocking, shield_block = target_status:is_blocking()
	end

	if target_buffs and target_buffs:has_buff_perk("power_block") and blocking and shield_block and not pc.unblockable(unit) and DamageUtils.check_ranged_block(unit, own, "blocked_berzerker") then
		pc.count("client_jet_blocked")
		pc.log("client jet go=%d blocked with a shield", jet.go_id)

		return
	end

	local buffs = ScriptUnit.has_extension(own, "buff_system")
	local _, added = nil, 0

	if buffs and action.buff_name then
		_, added = buffs:add_buff(action.buff_name, {
			attacker_unit = unit,
		})
	end

	jet.hits = jet.hits + 1

	if added and added > 0 then
		pc.count("client_burns_started")
	end

	report("jet", jet.go_id, true)
	pc.count("client_jet_hits")
	pc.log("client jet go=%d hit you: distance=%.2f dot=%.3f aimed=%s burning=%s", jet.go_id, distance, dot, tostring(jet.aimed == true), added and added > 0 and "started" or "already")
end

-- Every frame after LocomotionSystem.update, which has just turned the thrower by the host's numbers: on its target's
-- screen it turns by its shooting node's rule from this player's live position, at the turn speed its skulking left it
-- (T18); on every modded player's screen its jet sweeps on its own cooldown (T19).
function areas.after_locomotion(t, dt)
	local own = pc.local_player_unit()

	for unit, jet in pairs(jets) do
		local target = jet.target

		if not Unit.alive(unit) or not HEALTH_ALIVE[unit] or not own or not judging() then
			end_jet(unit, jet, "gone")
		elseif t > jet.ends_t then
			end_jet(unit, jet, "firing time over")
		elseif not target or not Unit.alive(target) then
			end_jet(unit, jet, "its target is gone")
		else
			if jet.aimed and jet.rotation then
				local wanted = jet_wanted_rotation(unit, own)

				if wanted then
					local current = jet.rotation:unbox()
					local lerped = pc.shots.rotate_from_to(current, wanted, jet.action.radial_speed_feet_shooting or math.pi * 1.9, dt)
					local rotation = Quaternion.lerp(current, lerped, math.min(jet.turn_speed * dt, 1))

					jet.rotation:store(rotation)

					if pc.facing then
						Unit.set_local_rotation(unit, 0, rotation)
					end
				end
			end

			local distance = Vector3.distance(POSITION_LOOKUP[unit], POSITION_LOOKUP[target])

			-- The host sweeps while its target is within close range, its cooldown has passed and the face timer has
			-- run out (_close_range_attack_check, :333, and :179).
			if t > jet.cooldown_t and t > jet.face_t and distance < (jet.action.close_attack_range or 15) then
				jet.cooldown_t = t + (jet.action.close_attack_cooldown or 0.3)

				sweep_jet(unit, jet, own, target)
			end
		end
	end
end

-- The jet's tick checks the burning player's own power block again (update_warpfirethrower_in_face,
-- buff_function_templates.lua:1797): a player with the perk facing the thrower (is_grail_knight_blocking, :77) who
-- blocks the jet takes no damage from that tick.
local function power_blocks(unit, source)
	local buffs = ScriptUnit.has_extension(unit, "buff_system")

	if not buffs or not buffs:has_buff_perk("power_block") or not source or not Unit.alive(source) then
		return false
	end

	local game = pc.network():game()
	local go_id = go_of(unit)
	local forward = game and go_id and GameSession.game_object_field(game, go_id, "aim_direction")
	local to_source = Vector3.flat(POSITION_LOOKUP[source] - POSITION_LOOKUP[unit])
	local distance = Vector3.length(to_source)
	local facing = distance < 0.0001 or forward ~= nil and Vector3.dot(forward, to_source / distance) > POWER_BLOCK_DOT

	return facing and not pc.unblockable(source) and DamageUtils.check_ranged_block(source, unit, "blocked_berzerker") == true
end

-- A tick of a burning on this client's own player (D58), after the game's own tick has played its sound here: the
-- damage the host's tick would have dealt is shown at once and reported. The ground fire's only while this screen
-- has the player in that fire; any copy counts, this screen's own or the host's.
function areas.client_burn_tick(kind, unit, buff, params)
	if unit ~= pc.local_player_unit() or not judging() or not HEALTH_ALIVE[unit] then
		return
	end

	local source = params and params.attacker_unit

	if kind == "fire" then
		local fire = source and fires[source]

		if not fire or not fire.inside then
			pc.count("client_burn_ticks_outside")

			return
		end
	elseif power_blocks(unit, source) then
		pc.count("client_burn_ticks_blocked")
		pc.log("client burn=jet tick blocked with a shield")

		return
	end

	local go_id = source and Unit.alive(source) and go_of(source)
	local damage = type(buff.damage) == "table" and buff.damage[buff.armor_type or 1]

	if not go_id or type(damage) ~= "number" then
		pc.count("client_burn_ticks_lost")

		return
	end

	report("tick", go_id, true)

	local estimate = show(source, go_id, buff.damage_source, nil, damage, buff.template.damage_type or "warpfire_ground")

	pc.count("client_burn_ticks")
	pc.count("client_burn_ticks_" .. kind)
	pc.log("client burn=%s go=%d tick: damage=%.1f estimate=%.1f", kind, go_id, damage, estimate)
end

-- The host's copy of a burning this screen ticks itself (BuffSystem.rpc_add_buff, buff_system.lua:417). Returns true to
-- drop it: this screen has started its own copy, or will. Its server-controlled removal then finds nothing here
-- (rpc_remove_server_controlled_buff, :437), so it needs no dropping.
function areas.buff_message(unit_id, template_id)
	if not judging() then
		return false
	end

	local name = NetworkLookup.buff_templates[template_id]

	if not name or not BURNS[name] then
		return false
	end

	local own = pc.local_player_unit()

	if not own or Managers.state.unit_storage:unit(unit_id) ~= own then
		return false
	end

	pc.count("client_burn_echo_dropped")

	return true
end

-- Vortex: its sizes from what the host syncs (vortex_extension.lua:497 to :503).
local function vortex_sizes(unit, template)
	local game = pc.network():game()
	local go_id = go_of(unit)

	if not game or not go_id then
		return nil
	end

	local inner_p = GameSession.game_object_field(game, go_id, "inner_radius_percentage") or 1
	local height_p = GameSession.game_object_field(game, go_id, "height_percentage") or 1
	local inner = inner_p * template.full_inner_radius

	return inner, math.max(template.min_outer_radius, template.full_outer_radius * inner_p), height_p * template.max_height, go_id
end

-- A catch this screen shows at once (D53), as the host's status message would (StatusSystem.rpc_status_change_bool
-- calls set_in_vortex), until the host confirms or refuses it.
local function show_catch(unit, go_id, target, status, t)
	status:set_in_vortex(true, unit)

	catches[go_id] = {
		vortex = unit,
		target = target,
		t = t,
		deadline = t + pc.CATCH_CONFIRM,
	}

	report("vortex", go_id, true)
	pc.count("client_vortex_caught")
	pc.log("client area=vortex go=%d caught: shown at once", go_id)
end

local function undo_catch(go_id, record, why)
	catches[go_id] = nil

	local status = Unit.alive(record.target) and ScriptUnit.has_extension(record.target, "status_system")

	if status and status.in_vortex_unit == record.vortex then
		status:set_in_vortex(false, nil)
	end

	pc.count("client_vortex_undone")
	pc.log("client area=vortex go=%d catch undone: %s", go_id, why)
end

-- The pull and the catch, for this player, as _update_attract_players runs them on the host (vortex_extension.lua:548
-- to :631), from this player's live position against this screen's copy of the vortex.
local function update_vortex(unit, extension, target, status, locomotion, breed, t)
	local template = extension.vortex_template

	if not template or not template.player_attractable then
		return
	end

	local inner, outer, vortex_height, go_id = vortex_sizes(unit, template)

	if not inner then
		return
	end

	local state = vortex_state[unit] or {}

	vortex_state[unit] = state

	local suck = POSITION_LOOKUP[unit] - POSITION_LOOKUP[target]
	local height = -suck.z

	Vector3.set_z(suck, 0)

	local distance = Vector3.length(suck)
	local near = distance < outer + 2

	if near ~= (state.near == true) and (near or status.near_vortex_unit == unit) then
		status:set_near_vortex(near, unit)
	end

	state.near = near

	if catches[go_id] then
		return
	end

	-- Thrown out (the host's own messages do that), a player isn't pulled or caught again for a while: the host's
	-- players_ejected bliss time (vortex_extension.lua:598), here at its longest.
	if status:is_in_vortex() then
		state.held = status.in_vortex_unit == unit

		return
	elseif state.held then
		state.held = false
		state.bliss_until = t + 0.5 + (template.player_ejected_bliss_time or 0)
	end

	if state.bliss_until and (t < state.bliss_until or status:is_catapulted()) then
		return
	end

	local valid = breed.vortexable and status:is_valid_vortex_target()

	if valid and distance < outer and MIN_VORTEX_HEIGHT_DIFF <= height and height < vortex_height then
		if inner < distance then
			local k = math.clamp(1 - (distance - inner) / math.max(outer - inner, 0.001), 0, 1)
			local speed = template.player_attract_speed * k * k

			if distance > 0 then
				locomotion:add_external_velocity(Vector3.normalize(suck) * speed)
			end

			if not state.pulled then
				state.pulled = true

				pc.count("client_vortex_pulled")
				pc.log("client area=vortex go=%d pulling: distance=%.2f inner=%.2f outer=%.2f", go_id, distance, inner, outer)
			end
		else
			show_catch(unit, go_id, target, status, t)
		end
	else
		state.pulled = false
	end
end

local function update_vortices(target, t)
	local status = ScriptUnit.has_extension(target, "status_system")
	local locomotion = ScriptUnit.has_extension(target, "locomotion_system")
	local breed = Unit.get_data(target, "breed")

	if not status or not locomotion or not breed then
		return
	end

	for unit, extension in pairs(vortices) do
		if not Unit.alive(unit) then
			vortices[unit] = nil
			vortex_state[unit] = nil
		else
			update_vortex(unit, extension, target, status, locomotion, breed, t)
		end
	end
end

function areas.update(dt)
	if pc.is_server() then
		return
	end

	local t = pc.now()

	for go_id, record in pairs(catches) do
		if t > record.deadline then
			if record.confirmed then
				catches[go_id] = nil
			else
				pc.count("client_vortex_timeout")
				undo_catch(go_id, record, "the host never confirmed it")
			end
		end
	end

	local target = pc.local_player_unit()

	if not target or not judging() then
		release_fires(target)

		return
	end

	if next(fires) ~= nil then
		update_fires(target, t)
	end

	if next(vortices) ~= nil then
		update_vortices(target, t)
	end
end

function areas.acknowledged(go_id, result)
	local record = catches[go_id]

	if not record then
		return
	end

	if result == "applied" then
		record.confirmed = true

		pc.count("client_vortex_applied")
	else
		pc.count("client_vortex_refused")
		undo_catch(go_id, record, "the host refused it")
	end
end

-- StatusSystem.rpc_status_change_bool from the host (Disablers.lua passes it on). Returns true to drop it: the echo of
-- a catch this screen shows. The host's later message that throws the player out goes through.
function areas.status_message(status_id, status_bool, game_object_id, other_object_id)
	if next(catches) == nil or not status_bool or NetworkLookup.statuses[status_id] ~= "in_vortex" then
		return false
	end

	local record = catches[other_object_id]

	if not record or Managers.state.unit_storage:unit(game_object_id) ~= record.target then
		return false
	end

	record.confirmed = true

	pc.count("client_vortex_confirmed")
	pc.log("client area=vortex go=%d catch confirmed by the host after %.3fs", other_object_id, pc.now() - record.t)

	return true
end

function areas.clear()
	-- This screen's own copies of the fires' burnings have no end time of their own, so they go with everything else.
	-- Not through pc.guard, which does nothing once the mod has switched itself off.
	pcall(release_fires, pc.local_player_unit(), true)

	own_burns = {}
	clouds = {}
	fires = {}
	jets = {}
	vortices = {}
	vortex_state = {}
	catches = {}
end

-- Both sides -----------------------------------------------------------------------------------------------------------

-- The gas templates' host side: their test leaves modded players to their own screens (filter_gas), for the ticks and
-- the impact alike (D58).
local function hook_gas_template(name)
	local templates = rawget(_G, "AreaDamageTemplates")
	local template = templates and templates.templates and templates.templates[name]
	local server = template and template.server

	if not server or type(server.update) ~= "function" then
		return
	end

	mod:hook(server, "update", function (func, damage_source, unit, radius, damage, ...)
		local updated, buffer = func(damage_source, unit, radius, damage, ...)

		if updated and type(buffer) == "table" and #buffer > 0 and not pc.broken and pc.is_server() then
			local ok, kept = pc.guard("host gas", filter_gas, buffer)

			if ok and kept then
				return updated, kept
			end
		end

		return updated, buffer
	end)
end

for name in pairs(GAS_TEMPLATES) do
	hook_gas_template(name)
end

-- Client: a cloud starts on this screen (rpc_area_damage); its impact is judged now, its ticks from here on.
mod:hook_safe("AreaDamageExtension", "start_area_damage", function (self)
	if not self.is_server and not pc.broken then
		pc.guard("client gas start", areas.cloud_started, self)
	end
end)

-- Client: each frame of a cloud that has started here runs the host's tick timer on this screen (areas.cloud_update).
mod:hook_safe("AreaDamageExtension", "update", function (self, unit, input, dt)
	if not self.is_server and not pc.broken and clouds[self.unit] then
		pc.guard("client gas tick", areas.cloud_update, self, dt)
	end
end)

mod:hook_safe("AreaDamageExtension", "destroy", function (self)
	clouds[self.unit] = nil
end)

-- Host: the jet's sweep leaves the modded players it was announced to out (the sweep hook below), and a thrower's firing
-- or new target is announced to every modded player (T19).
mod:hook("BTWarpfireThrowerShootAction", "_close_range_attack", function (func, self, unit, attack_pattern_data, blackboard, action, t)
	if pc.broken or not pc.is_server() then
		return func(self, unit, attack_pattern_data, blackboard, action, t)
	end

	local ok, skip = pc.guard("host jet filter", areas.jet_skips, unit)

	jet_skip = ok and skip or nil

	-- The skip goes whatever happens in there, so no other sweep ever leaves anyone out.
	local called, message = pcall(func, self, unit, attack_pattern_data, blackboard, action, t)

	jet_skip = nil

	if not called then
		error(message, 0)
	end
end)

mod:hook_safe("BTWarpfireThrowerShootAction", "_attack_fire", function (self, unit, warpfire_data, action, blackboard, t)
	if pc.broken or not pc.is_server() or not pc.in_game() then
		return
	end

	pc.guard("host jet aim", areas.announce_jet, unit, blackboard)
end)

mod:hook_safe("BTWarpfireThrowerShootAction", "_aim_at_target", function (self, unit, target_unit, attack_pattern_data, blackboard)
	if pc.broken or not pc.is_server() or not pc.in_game() or not jets_sent[unit] then
		return
	end

	pc.guard("host jet target", areas.jet_retarget, unit, blackboard)
end)

-- Host: while jet_skip is set, a warpfire's sweep is running (bt_warpfire_thrower_shoot_action.lua:357), and its sweep
-- for characters' triggers (its 7th argument) leaves out the modded players whose own screens judge the jet. A mod:hook
-- on an engine function the whole game calls (the camera sweeps every frame), so every other call goes straight
-- through, and its own work runs through pc.guard.
mod:hook(PhysicsWorld, "linear_sphere_sweep", function (func, ...)
	local skip = jet_skip

	if not skip or select(7, ...) ~= "filter_character_trigger" then
		return func(...)
	end

	local hits = func(...)

	if type(hits) ~= "table" then
		return hits
	end

	local ok, kept = pc.guard("host jet sweep", without_skipped_hits, hits, skip)

	if ok and kept then
		return kept
	end

	return hits
end)

-- Both: a tick of a burning this mod moves to the burning player's screen (D58). On the host, a modded player's tick
-- deals no damage (their screen reports it); on a client, the tick on its own player is shown and reported, after the
-- game's own tick has played its sound. The game looks these up by name for every tick (buff_extension.lua:794), so
-- the table entries are hooked. mod:hooks, so everything except the original call runs through pc.guard.
-- Only this player's own unit: buff ids count per unit (buff_extension.lua:1588), so another player's burning can
-- carry the same id as this screen's own copy (D57 review).
local function release_own_burn(unit, buff)
	if not own_burns[buff.id] or unit ~= pc.local_player_unit() then
		return
	end

	own_burns[buff.id] = nil

	local buffs = ScriptUnit.has_extension(unit, "buff_system")

	if buffs then
		buffs:queue_remove_buff(buff.id)
	end
end

local function hook_burn_update(functions, name, kind)
	if type(functions[name]) ~= "function" then
		return
	end

	mod:hook(functions, name, function (func, unit, buff, params, world)
		if type(buff) ~= "table" or not BURNS[buff.buff_template_name] then
			return func(unit, buff, params, world)
		end

		if pc.broken then
			-- A mod that has switched itself off leaves nothing of its own behind: this screen's own copy of a fire's
			-- burning, which has no end time, goes at its next tick (removed at the buffs' next update,
			-- buff_extension.lua:737), and the host's comes again.
			pcall(release_own_burn, unit, buff)

			return func(unit, buff, params, world)
		end

		if pc.is_server() then
			local ok, skip = pc.guard("host burn tick", areas.host_burn_tick, kind, unit, buff)

			if ok and skip then
				return params.t + (buff.template.time_between_dot_damages or 0.75)
			end

			return func(unit, buff, params, world)
		end

		local next_t = func(unit, buff, params, world)

		pc.guard("client burn tick", areas.client_burn_tick, kind, unit, buff, params)

		return next_t
	end)
end

do
	local templates = rawget(_G, "BuffFunctionTemplates")
	local functions = templates and templates.functions

	if type(functions) == "table" then
		for name, kind in pairs(BURN_UPDATES) do
			hook_burn_update(functions, name, kind)
		end
	end
end

-- Client: the host's copy of a burning this screen ticks itself is dropped for its own player (areas.buff_message).
mod:hook("BuffSystem", "rpc_add_buff", function (func, self, channel_id, unit_id, buff_template_name_id, attacker_unit_id, server_buff_id, send_to_sender)
	if not self.is_server and not pc.broken then
		local ok, drop = pc.guard("client burn echo", areas.buff_message, unit_id, buff_template_name_id)

		if ok and drop then
			return
		end
	end

	return func(self, channel_id, unit_id, buff_template_name_id, attacker_unit_id, server_buff_id, send_to_sender)
end)

-- Host: the ground fire's own test leaves modded players to their reports.
mod:hook("DamageBlobExtension", "check_overlap", function (func, self, unit, target_unit, ...)
	if not pc.broken and pc.host.client_judges(target_unit) then
		return
	end

	return func(self, unit, target_unit, ...)
end)

-- Host: the vortex's own test leaves out the modded players it isn't holding (areas.vortex_filter).
mod:hook("VortexExtension", "_update_attract_players", function (func, self, unit, blackboard, vortex_data, ...)
	if pc.broken or not pc.is_server() or type(vortex_data) ~= "table" then
		return func(self, unit, blackboard, vortex_data, ...)
	end

	pc.guard("host vortex filter", areas.vortex_filter, vortex_data)

	-- The full player lists come back whatever happens in there.
	local called, message = pcall(func, self, unit, blackboard, vortex_data, ...)

	areas.vortex_restore()

	if not called then
		error(message, 0)
	end
end)

-- Client: the ground fire's effects, from which its line is rebuilt here, and the vortices this screen tests against.
mod:hook_safe("DamageBlobHuskExtension", "init", function (self, extension_init_context, unit, extension_init_data)
	local name = type(extension_init_data) == "table" and extension_init_data.damage_blob_template_name
	local template = name and DamageBlobTemplates.templates[name]

	if template and template.apply_buff_to_player and template.create_blobs then
		fires[unit] = {
			radius = template.blob_radius,
			life = template.blob_life_time,
			separation = template.blob_separation_dist or 0,
			points = {},
			inside = false,
			buff_name = template.buff_template_name,
			buff_type = template.buff_template_type,
		}
	end
end)

-- The host places a blob each time its fire has moved blob_separation_dist from the last one, and an effect, the only
-- thing that reaches this screen, each time it has moved fx_separation_dist (damage_blob_extension.lua:264 and :285;
-- 2 m and 0.8 m for the warpfire's). So an effect stands in for a blob only once it is that far from the last one
-- kept, and the line ends where the host's does (D57 review).
mod:hook_safe("DamageBlobHuskExtension", "add_damage_blob_fx", function (self, position, life_time_percentage)
	local fire = fires[self.unit]

	if not fire then
		return
	end

	fire.go_id = fire.go_id or go_of(self.unit)

	if fire.last_kept and Vector3.distance_squared(fire.last_kept:unbox(), position) < fire.separation * fire.separation then
		return
	end

	fire.last_kept = Vector3Box(position)
	fire.points[#fire.points + 1] = {
		position = Vector3Box(position),
		dies = pc.now() + (type(life_time_percentage) == "number" and life_time_percentage or 1) * fire.life,
	}
end)

mod:hook_safe("DamageBlobHuskExtension", "destroy", function (self)
	local fire = fires[self.unit]

	-- The host's blob takes its buffs back as it goes (damage_blob_extension.lua:177), and this screen its own copy.
	if fire then
		if fire.inside then
			pc.count("client_fire_left")
		end

		if fire.own and not pc.broken then
			pc.guard("client fire end", end_fire_burn, pc.local_player_unit(), fire)
		end
	end

	fires[self.unit] = nil
end)

mod:hook_safe("VortexHuskExtension", "init", function (self, extension_init_context, unit)
	vortices[unit] = self
end)

mod:hook_safe("VortexHuskExtension", "destroy", function (self)
	vortices[self.unit] = nil
	vortex_state[self.unit] = nil
end)
