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
-- uses: an elite's, or a monster's overlap attack's own, bt_melee_overlap_attack_action.lua:895), as a set.
function geometry.units_in_box(world, centre, rotation, size, filter)
	local physics_world = World.get_data(world, "physics_world")
	local actors = PhysicsWorld.immediate_overlap(physics_world, "position", centre, "rotation", rotation, "size", size, "shape", "oobb", "types", "dynamics", "collision_filter", filter or "filter_player_hit_box_check")
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

-- One axis of the box test below: narrows the stretch of the player's core segment, from enter to leave (0 to 1 along
-- it), that lies within half of the box's centre on that axis. from and step are the segment's start and length on the
-- axis. Returns nil once nothing is left.
local function clip_axis(from, step, half, enter, leave)
	if math.abs(step) < 1e-6 then
		if math.abs(from) > half then
			return nil
		end

		return enter, leave
	end

	local a = (-half - from) / step
	local b = (half - from) / step

	if a > b then
		a, b = b, a
	end

	enter = math.max(enter, a)
	leave = math.min(leave, b)

	if enter > leave then
		return nil
	end

	return enter, leave
end

-- The same box test on plain shapes, for when the overlap can't see this player's own hit boxes: the player as an
-- upright capsule standing at feet, PLAYER_BOX_HEIGHT tall and PLAYER_BOX_RADIUS wide, against the box along the box's
-- own three axes, so that a tilted box is tested right too: a monster's arm window, which lies along the arm
-- (BTMeleeOverlapAttackAction.weapon_sweep_overlap, bt_melee_overlap_attack_action.lua:869). The capsule's core segment
-- is clipped against the box widened by the radius. For an upright box, such as an elite's, that is the same test as an
-- upright cylinder from the feet to PLAYER_BOX_HEIGHT against the box. Returns whether they meet.
function geometry.player_in_box(feet, centre, rotation, size)
	local start = feet + Vector3(0, 0, PLAYER_BOX_RADIUS) - centre
	local rise = PLAYER_BOX_HEIGHT - 2 * PLAYER_BOX_RADIUS
	local right = Quaternion.right(rotation)
	local forward = Quaternion.forward(rotation)
	local up = Quaternion.up(rotation)
	local enter, leave = clip_axis(Vector3.dot(start, right), rise * right.z, size.x + PLAYER_BOX_RADIUS, 0, 1)

	if enter then
		enter, leave = clip_axis(Vector3.dot(start, forward), rise * forward.z, size.y + PLAYER_BOX_RADIUS, enter, leave)
	end

	if enter then
		enter = clip_axis(Vector3.dot(start, up), rise * up.z, size.z + PLAYER_BOX_RADIUS, enter, leave)
	end

	return enter ~= nil
end

-- Family E, a monster's slam (BTMeleeSlamAction._calculate_collision, bt_melee_slam_action.lua:108), for when the
-- overlap can't see this player: an upright capsule round centre, radius wide, that reaches half_height above and below
-- centre, its rounded ends included. The game treats a capsule's size.y so, as the half_height - radius > 0 test before
-- each capsule overlap shows (bt_melee_slam_action.lua:153, action_geiser.lua:100), and the slam passes its whole height
-- there. With half_height no more than radius it is a sphere. The player is the upright capsule of player_in_box, and two
-- upright capsules meet when their core segments come within the sum of their radii. Returns whether they meet.
function geometry.player_in_capsule(feet, centre, radius, half_height)
	local core = math.max(half_height - radius, 0)
	local player_low = feet.z + PLAYER_BOX_RADIUS
	local player_high = feet.z + PLAYER_BOX_HEIGHT - PLAYER_BOX_RADIUS
	local gap = math.max(centre.z - core - player_high, player_low - (centre.z + core), 0)
	local flat = Vector3.length(Vector3.flat(feet - centre))
	local reach = radius + PLAYER_BOX_RADIUS

	return flat * flat + gap * gap <= reach * reach
end

-- Family E4, a lord's attack (build 6 part (b)): the upright cylinder it hits at its damage frame or sweeps round in a
-- spin, built from the enemy's position and facing as BTChampionAttackAction._calculate_cylinder_collision builds it
-- (bt_champion_attack_action.lua:734). Returns its centre, the size the overlap takes (the radius, half the height, the
-- radius: with half the height no more than the radius it is a sphere, :633) and the overlap's rotation, whose forward
-- is the enemy's up. player_in_capsule tests the same shape. If a game patch changes the original, change this.
function geometry.champion_cylinder(action, position, rotation)
	local radius = action.radius or 0
	local half_height = (action.height or 0) * 0.5
	local forward = Quaternion.forward(rotation)
	local up = Quaternion.up(rotation)
	local right = Quaternion.right(rotation)
	local centre = position + forward * (radius + (action.offset_forward or 0)) + up * (half_height + (action.offset_up or 0)) + right * (action.offset_right or 0)

	return centre, Vector3(radius, half_height, radius), Quaternion.look(up, Vector3.up())
end

-- The squared distance between the segments p1 to q1 and p2 to q2, at their nearest points.
local function segment_distance_squared(p1, q1, p2, q2)
	local d1 = q1 - p1
	local d2 = q2 - p2
	local r = p1 - p2
	local a = Vector3.dot(d1, d1)
	local e = Vector3.dot(d2, d2)
	local f = Vector3.dot(d2, r)
	local s, t

	if a <= 1e-8 and e <= 1e-8 then
		return Vector3.dot(r, r)
	elseif a <= 1e-8 then
		s = 0
		t = math.clamp(f / e, 0, 1)
	else
		local c = Vector3.dot(d1, r)

		if e <= 1e-8 then
			t = 0
			s = math.clamp(-c / a, 0, 1)
		else
			local b = Vector3.dot(d1, d2)
			local denominator = a * e - b * b

			s = denominator > 1e-8 and math.clamp((b * f - c * e) / denominator, 0, 1) or 0
			t = (b * s + f) / e

			if t < 0 then
				t = 0
				s = math.clamp(-c / a, 0, 1)
			elseif t > 1 then
				t = 1
				s = math.clamp((b - c) / a, 0, 1)
			end
		end
	end

	local gap = p1 + d1 * s - (p2 + d2 * t)

	return Vector3.dot(gap, gap)
end

-- Build 6.1: a sphere radius wide swept from a to b (the troll's vomit, the stormfiend's beam), for when the game's own
-- sweep can't see this player: the player is the upright capsule of player_in_box, and two capsules meet when their core
-- segments come within the sum of their radii. Returns whether they meet.
function geometry.player_near_segment(feet, a, b, radius)
	local low = feet + Vector3(0, 0, PLAYER_BOX_RADIUS)
	local high = feet + Vector3(0, 0, PLAYER_BOX_HEIGHT - PLAYER_BOX_RADIUS)
	local reach = radius + PLAYER_BOX_RADIUS

	return segment_distance_squared(low, high, a, b) <= reach * reach
end

-- Copy of the local closest_point_on_line in bt_melee_overlap_attack_action.lua:17: the point of the segment p1 to p2
-- nearest p, and whether p lies beyond either end.
function geometry.closest_point_on_line(p, p1, p2)
	local diff = p - p1
	local dir = p2 - p1
	local dot1 = Vector3.dot(diff, dir)

	if dot1 <= 0 then
		return p1, dot1 < 0
	end

	local dot2 = Vector3.dot(dir, dir)

	if dot2 <= dot1 then
		return p2, dot2 < dot1
	end

	return p1 + dir * (dot1 / dot2), false
end

mod.pc.geometry = geometry
