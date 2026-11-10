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

mod.pc.geometry = geometry
