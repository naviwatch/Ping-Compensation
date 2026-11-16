local mod = get_mod("Ping Compensation")

local geometry = {}

local DEFAULT_CONE = 0.866 -- cosine of 30 degrees
local DEFAULT_DODGED_CONE = 0.95 -- cosine of about 18 degrees
local DEFAULT_DODGED_RADIUS = 0.75
local PLAYER_RADIUS = 1

local function degrees(cosine)
	return math.deg(math.acos(math.max(-1, math.min(1, cosine))))
end

-- The reach and facing test for single-target swings (family A), on plain numbers.
--
-- It copies DamageUtils.check_distance and DamageUtils.check_infront (scripts/helpers/damage_utils.lua:2626 and
-- :2666). Those can't run on a client because they read the host's AI blackboard. If a game patch changes them,
-- change this to match.
--
-- dx, dy, dz: the target's position minus the attacker's.
-- fx, fy: the attacker's forward vector.
-- frozen: true while a dodge has frozen the attacker's facing, which is when the game tightens the test.
-- box_up, box_down, box_flat: only used by attacks flagged use_box_range.
--
-- Returns in_reach, in_front, distance, reach, angle and cone. The last four are for the debug log, with the angles
-- in degrees.
function geometry.single_target(dx, dy, dz, fx, fy, frozen, action, breed, box_up, box_down, box_flat)
	local flat_length_squared = dx * dx + dy * dy
	local radius = PLAYER_RADIUS

	if frozen then
		radius = radius * (action.player_dodged_radius or breed.player_dodged_radius or DEFAULT_DODGED_RADIUS)
	end

	local in_reach, distance, reach

	if action.use_box_range then
		reach = (box_flat or 0) + radius
		distance = math.sqrt(flat_length_squared)
		in_reach = dz < (box_up or 0) and dz > (box_down or 0) and flat_length_squared < reach * reach
	else
		reach = (action.weapon_reach or breed.weapon_reach or breed.radius or 0) + radius
		distance = math.sqrt(flat_length_squared + dz * dz)
		in_reach = distance <= reach
	end

	local default_cone = DEFAULT_CONE

	if frozen then
		default_cone = action.player_dodged_cone or breed.player_dodged_cone or DEFAULT_DODGED_CONE
	end

	local cone_cosine = breed.weapon_reach_cone or default_cone
	local cosine = 0

	if flat_length_squared > 0 then
		cosine = (dx * fx + dy * fy) / math.sqrt(flat_length_squared)
	end

	return in_reach, cosine > cone_cosine, distance, reach, degrees(cosine), degrees(cone_cosine)
end

-- Family C: the box an elite's sweep or overhead hits at its damage frame, built from the enemy's position and facing
-- as BTStormVerminAttackAction.anim_cb_damage builds it (bt_storm_vermin_attack_action.lua:374). If a game patch
-- changes that, change this to match. Returns the box's centre, rotation and half-size.
function geometry.elite_box(action, position, rotation)
	local range = action.range or 0
	local height = action.height or 0
	local half_range = range * 0.5
	local half_height = height * 0.5
	local size = Vector3((action.width or 0) * 0.5, half_range, half_height)
	local forward = Quaternion.rotate(rotation, Vector3.forward()) * ((action.offset_forward or 0) + half_range)
	local up = Vector3.up() * (half_height + (action.offset_up or 0))

	return position + forward + up, rotation, size
end

-- The units whose player hit boxes lie in that box, by the game's own query (the same filter the enemy's damage frame
-- uses), as a set.
function geometry.units_in_box(world, centre, rotation, size)
	local physics_world = World.get_data(world, "physics_world")
	local actors = PhysicsWorld.immediate_overlap(physics_world, "position", centre, "rotation", rotation, "size", size, "shape", "oobb", "types", "dynamics", "collision_filter", "filter_player_hit_box_check")
	local units = {}

	for _, actor in ipairs(actors or {}) do
		local unit = Actor.unit(actor)

		if unit then
			units[unit] = true
		end
	end

	return units
end

local PLAYER_BOX_RADIUS = 0.35 -- about the width of a player's hit boxes
local PLAYER_BOX_HEIGHT = 1.8

-- The same box test on plain shapes, for when the overlap can't see this player's own hit boxes: an upright cylinder
-- for the player, standing at feet, against the box. Returns whether they meet.
function geometry.player_in_box(feet, centre, rotation, size)
	local offset = feet - centre
	local x = Vector3.dot(offset, Quaternion.right(rotation))
	local y = Vector3.dot(offset, Quaternion.forward(rotation))
	local bottom = offset.z
	local top = offset.z + PLAYER_BOX_HEIGHT

	return math.abs(x) <= size.x + PLAYER_BOX_RADIUS and math.abs(y) <= size.y + PLAYER_BOX_RADIUS and top >= -size.z and bottom <= size.z
end

mod.pc.geometry = geometry
