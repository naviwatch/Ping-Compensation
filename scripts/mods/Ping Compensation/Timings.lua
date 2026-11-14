local mod = get_mod("Ping Compensation")
local pc = mod.pc

-- Animation timings the host needs to end a client's stagger or recoil on time (D14, D32):
--   length:  a stagger animation's length at normal speed, from its start to anim_cb_push_finished.
--   cue:     a recoil animation's time from its start to anim_cb_blocked_cooldown, after which the recoil ends once its
--            timer has run out too (BTBlockedAction.run).
--   stunned: a recoil animation's time from its start to anim_cb_stunned_finished, which ends the recoil at once by
--            clearing blackboard.blocked (animation_callback_templates.lua:37). The savage's recoils end this way.
-- A recoil's timings can depend on the attack it interrupted (the marauder's and the fanatic's do, build 3.1 playtest),
-- so they are looked up by the recoil animation and the blocked attack's animation: an entry is one value for every
-- attack, or a table of values by attack (D43).
-- They are fixed properties of each animation, so they ship with the mod in DEFAULTS, rebuilt from the playtest logs
-- with Docs/rebuild_timings.py, and the shipped values are final. A machine learns only what isn't shipped, and only
-- from readings taken at normal speed; what it learns is kept with mod:set. Every reading still goes to the debug log,
-- with the speed it was taken at, for the next rebuild. /pingcomp timings writes everything known to the console log in
-- the form DEFAULTS uses. Every enemy is timed, covered or not, so the data is there when later steps cover it (D47).
-- An entry of false is an animation whose readings at normal speed split into two real lengths (the shielded clan rat's
-- stun_fwd_sword: 0.61 or 0.81 s), so no one value fits: it counts as unknown, and isn't learned either, since a machine
-- would learn a blend of the two.

local timings = {}

pc.timings = timings

timings.KINDS = { "length", "cue", "stunned" }

-- A recoil's timings are kept by the blocked attack's animation.
local BY_ATTACK = {
	cue = true,
	stunned = true,
}
-- The shortest real ones are about 0.4 s (a shield rat's stun_down) and 0.7 s (a rat's blocked_3). Shorter readings are
-- an earlier animation's callback arriving just after a new one started (0.11 to 0.17 s in the 2026-11-12 playtest).
local MIN_SECONDS = 0.3
local MAX_SECONDS = 6
local MIN_SHARE = 0.5 -- a reading under half of the value already known is taken for one of those, and ignored
local LEARN_WEIGHT = 0.3 -- how far a new reading moves a value this machine learned
local SPEED_TOLERANCE = 0.01 -- a reading counts as taken at normal speed within this much of 1
-- The saved timings move to new keys whenever the shipped ones are rebuilt from scratch, so every machine starts from
-- the new values (build 3.2). Earlier builds saved under "stagger_lengths", "stagger_lengths_2", "recoil_cues",
-- "recoil_cues_2" and "recoil_cues_3", which are no longer read.
local SETTINGS = {
	length = "stagger_lengths_3",
	cue = "recoil_cues_4",
	stunned = "recoil_stunned_1",
}

-- Seconds, with how many readings each value came from, rebuilt from scratch for build 3.2 (D43, D47) by
-- Docs/rebuild_timings.py from the playtests of steps 2.1 and 2.2 and of builds 3 and 3.1 (2026-11-12 and -13) and
-- Lance's two calibration logs (2026-11-14: build 3.1's ungor tests and the stage 1 session), without the 2.1 and 2.2
-- hosts' recoil cues (timed from the wrong start), and with the build 3.1 logs' readings counted as taken at normal
-- speed. "lowest of N groups": that animation's readings in the older logs fell into groups a speed factor apart, from
-- staggers timed at a speed they didn't reach, and only the lowest counts. "from <enemy>": a stagger length taken from
-- an enemy whose shared lengths all agree with this one's (D47): slave rats, clan rats and ungors; marauders, shielded
-- marauders and fanatics. Not shipped: 63 stagger lengths with a single reading, and two animations whose readings at
-- normal speed split (false).
local DEFAULTS = {
	length = {
		beastmen_gor = {
			stagger_bwd = 1.08, -- 8
			stagger_bwd_2 = 0.81, -- 6
			stagger_bwd_3 = 0.81, -- 3
			stagger_bwd_4 = 0.81, -- 8
			stagger_fwd = 1.08, -- 7
			stagger_left = 1.07, -- 5
			stagger_left_heavy_2 = 1.08, -- 2
			stagger_right = 1.08, -- 8
			stagger_right_heavy_2 = 1.08, -- 6
			stun_bwd_sword = 0.81, -- 25
			stun_bwd_sword_2 = 0.81, -- 26
			stun_bwd_sword_3 = 0.81, -- 19
			stun_fwd_sword_2 = 0.78, -- 4
			stun_left_sword = 0.74, -- 8
			stun_left_sword_2 = 0.74, -- 18
			stun_right_sword = 0.74, -- 12
			stun_right_sword_2 = 0.74, -- 11
			stun_right_sword_3 = 0.74, -- 10
		},
		beastmen_ungor = {
			stagger_bwd = 0.97, -- 15
			stagger_bwd_2 = 0.91, -- 17
			stagger_bwd_3 = 0.84, -- 16
			stagger_bwd_4 = 1.04, -- 9
			stagger_bwd_5 = 0.84, -- 19
			stagger_bwd_exp = 3.57, -- 22, from skaven_slave
			stagger_bwd_exp_2 = 3.83, -- 12, from skaven_slave
			stagger_bwd_fall = 2.04, -- 2
			stagger_bwd_fall_2 = 1.41, -- 4
			stagger_bwd_heavy = 1.61, -- 14, from skaven_slave
			stagger_bwd_heavy_2 = 1.71, -- 3
			stagger_bwd_heavy_3 = 2.02, -- 8, from skaven_slave
			stagger_bwd_heavy_4 = 1.81, -- 3
			stagger_fwd = 0.99, -- 68, from skaven_slave
			stagger_fwd_2 = 1.01, -- 2, from skaven_slave
			stagger_fwd_3 = 0.98, -- 2, from skaven_slave
			stagger_fwd_4 = 1.02, -- 36, from skaven_slave
			stagger_fwd_exp = 2.42, -- 3, from skaven_slave
			stagger_fwd_exp_2 = 2.66, -- 3, from skaven_slave
			stagger_left = 0.94, -- 6
			stagger_left_2 = 0.91, -- 2
			stagger_left_3 = 0.88, -- 3
			stagger_left_4 = 1.01, -- 6
			stagger_left_exp = 3.16, -- 5, from skaven_slave
			stagger_left_exp_2 = 3.53, -- 3, from skaven_slave
			stagger_left_heavy = 1.52, -- 2, from skaven_slave
			stagger_left_heavy_3 = 1.54, -- 2
			stagger_left_heavy_4 = 2.02, -- 5, from skaven_slave
			stagger_left_heavy_5 = 1.84, -- 2
			stagger_right = 0.94, -- 3
			stagger_right_2 = 0.94, -- 2
			stagger_right_3 = 0.94, -- 7
			stagger_right_4 = 1.11, -- 5
			stagger_right_exp = 3.59, -- 3, from skaven_slave
			stagger_right_exp_2 = 3.06, -- 6, from skaven_slave
			stagger_right_heavy_3 = 1.42, -- 4, from skaven_slave
			stagger_right_heavy_4 = 1.81, -- 2
			stagger_right_heavy_5 = 1.51, -- 3, from skaven_clan_rat
			stun_bwd_sword = 0.61, -- 2
			stun_down = 0.62, -- 6, from skaven_clan_rat
			stun_fwd_sword = 0.61, -- 23
			stun_left_sword = 0.61, -- 9
			stun_left_sword_2 = 0.61, -- 7
			stun_left_sword_3 = 0.61, -- 8
			stun_right_sword = 0.61, -- 11
			stun_right_sword_2 = 0.61, -- 11
			stun_right_sword_3 = 0.61, -- 7
		},
		chaos_berzerker = {
			run_stagger_left = 0.81, -- 44
			stagger_bwd = 1.14, -- 2
			stagger_bwd_2 = 1.28, -- 10, lowest of 3 groups
			stagger_bwd_3 = 1.22, -- 25, lowest of 2 groups
			stagger_bwd_4 = 1.12, -- 14, lowest of 2 groups
			stagger_bwd_heavy = 2.52, -- 5, lowest of 2 groups
			stagger_bwd_heavy_2 = 2.85, -- 4, lowest of 2 groups
			stagger_bwd_heavy_3 = 2.59, -- 17
			stagger_bwd_heavy_4 = 2.57, -- 7, lowest of 2 groups
			stagger_bwd_light = 0.76, -- 12, lowest of 3 groups
			stagger_bwd_light_2 = 0.72, -- 11, lowest of 2 groups
			stagger_bwd_light_3 = 0.69, -- 4, lowest of 3 groups
			stagger_bwd_light_4 = 0.66, -- 9, lowest of 2 groups
			stagger_bwd_light_5 = 0.74, -- 6
			stagger_bwd_light_6 = 0.91, -- 15, lowest of 3 groups
			stagger_bwd_light_7 = 0.82, -- 6
			stagger_bwd_light_8 = 0.71, -- 3, lowest of 2 groups
			stagger_fwd_3 = 1.17, -- 4
			stagger_left = 0.86, -- 13, lowest of 2 groups
			stagger_left_2 = 1.20, -- 2, lowest of 2 groups
			stagger_left_3 = 1.38, -- 3, lowest of 2 groups
			stagger_left_4 = 1.38, -- 2, lowest of 2 groups
			stagger_left_light = 0.76, -- 16
			stagger_left_light_2 = 0.88, -- 3, lowest of 2 groups
			stagger_left_light_3 = 0.89, -- 2
			stagger_left_light_4 = 0.85, -- 2, lowest of 2 groups
			stagger_right = 1.10, -- 2
			stagger_right_3 = 1.35, -- 4, lowest of 3 groups
			stagger_right_4 = 1.23, -- 2, lowest of 2 groups
			stagger_right_5 = 1.20, -- 2
			stagger_right_heavy = 1.97, -- 2, lowest of 2 groups
			stagger_right_heavy_3 = 2.55, -- 2, lowest of 2 groups
			stagger_right_heavy_4 = 2.75, -- 2, lowest of 2 groups
			stagger_right_light_4 = 0.75, -- 4
		},
		chaos_fanatic = {
			stagger_bwd = 1.14, -- 14
			stagger_bwd_2 = 1.27, -- 9
			stagger_bwd_3 = 1.17, -- 13
			stagger_bwd_4 = 1.11, -- 12
			stagger_bwd_heavy = 2.52, -- 3
			stagger_bwd_heavy_3 = 2.48, -- 4
			stagger_bwd_heavy_4 = 2.56, -- 2
			stagger_bwd_light = 0.73, -- 59
			stagger_bwd_light_2 = 0.71, -- 84
			stagger_bwd_light_3 = 0.68, -- 63
			stagger_bwd_light_4 = 0.66, -- 61
			stagger_bwd_light_5 = 0.73, -- 78
			stagger_bwd_light_6 = 0.87, -- 64
			stagger_bwd_light_7 = 0.80, -- 86
			stagger_bwd_light_8 = 0.71, -- 67
			stagger_bwd_shield_light = 2.59, -- 9, from chaos_marauder_with_shield
			stagger_fwd = 1.18, -- 5, lowest of 2 groups
			stagger_fwd_2 = 1.20, -- 8, lowest of 2 groups
			stagger_fwd_3 = 1.11, -- 2
			stagger_fwd_4 = 1.17, -- 8, lowest of 2 groups
			stagger_fwd_heavy_3 = 2.80, -- 2, from chaos_marauder
			stagger_fwd_light = 0.74, -- 29, lowest of 6 groups
			stagger_fwd_light_2 = 0.75, -- 29, lowest of 4 groups
			stagger_fwd_light_3 = 0.72, -- 2
			stagger_fwd_light_4 = 0.97, -- 25, lowest of 3 groups
			stagger_fwd_light_5 = 0.98, -- 20, lowest of 3 groups
			stagger_fwd_light_6 = 0.97, -- 23, lowest of 3 groups
			stagger_left = 0.83, -- 2
			stagger_left_2 = 1.20, -- 22, lowest of 3 groups
			stagger_left_3 = 1.38, -- 15, lowest of 4 groups
			stagger_left_4 = 1.38, -- 12, lowest of 3 groups
			stagger_left_5 = 1.14, -- 2
			stagger_left_heavy = 2.58, -- 2
			stagger_left_heavy_4 = 2.63, -- 2
			stagger_left_light = 0.72, -- 15
			stagger_left_light_2 = 0.87, -- 13
			stagger_left_light_3 = 0.86, -- 14
			stagger_left_light_4 = 0.84, -- 11
			stagger_left_shield_light = 2.63, -- 2, from chaos_marauder_with_shield
			stagger_medium_downward_2 = 1.86, -- 3, from chaos_marauder_with_shield
			stagger_right = 1.10, -- 43, lowest of 2 groups
			stagger_right_2 = 1.34, -- 3
			stagger_right_3 = 1.34, -- 3
			stagger_right_4 = 1.23, -- 29, lowest of 3 groups
			stagger_right_5 = 1.19, -- 3
			stagger_right_heavy = 1.96, -- 3
			stagger_right_heavy_2 = 2.55, -- 4
			stagger_right_heavy_4 = 2.74, -- 3, from chaos_marauder
			stagger_right_light = 0.72, -- 13
			stagger_right_light_2 = 0.75, -- 10
			stagger_right_light_3 = 0.94, -- 18
			stagger_right_light_4 = 0.72, -- 14
			stagger_right_shield_light = 2.86, -- 8, from chaos_marauder_with_shield
			stagger_shield_light = 1.80, -- 23, from chaos_marauder_with_shield
			stagger_shield_medium = 2.31, -- 5, from chaos_marauder_with_shield
			stagger_shield_medium_break = 1.18, -- 5, from chaos_marauder_with_shield
			stagger_up_heavy_2 = 3.41, -- 2
			stun_down = 0.69, -- 7, from chaos_marauder
		},
		chaos_marauder = {
			stagger_bwd = 1.14, -- 5
			stagger_bwd_2 = 1.26, -- 2
			stagger_bwd_3 = 1.16, -- 3
			stagger_bwd_4 = 1.11, -- 3
			stagger_bwd_heavy = 2.52, -- 3, from chaos_fanatic
			stagger_bwd_heavy_3 = 2.48, -- 4, from chaos_fanatic
			stagger_bwd_heavy_4 = 2.56, -- 2, from chaos_fanatic
			stagger_bwd_light = 0.73, -- 49
			stagger_bwd_light_2 = 0.70, -- 49
			stagger_bwd_light_3 = 0.68, -- 41
			stagger_bwd_light_4 = 0.66, -- 45
			stagger_bwd_light_5 = 0.73, -- 48
			stagger_bwd_light_6 = 0.87, -- 36
			stagger_bwd_light_7 = 0.80, -- 56
			stagger_bwd_light_8 = 0.70, -- 43
			stagger_bwd_shield_light = 2.59, -- 9, from chaos_marauder_with_shield
			stagger_fwd = 1.17, -- 4, lowest of 3 groups
			stagger_fwd_2 = 1.19, -- 3
			stagger_fwd_3 = 1.12, -- 8, lowest of 2 groups
			stagger_fwd_4 = 1.18, -- 3
			stagger_fwd_heavy_3 = 2.80, -- 2
			stagger_fwd_light = 0.72, -- 2
			stagger_fwd_light_2 = 0.72, -- 3
			stagger_fwd_light_3 = 0.72, -- 2
			stagger_fwd_light_4 = 0.96, -- 2
			stagger_fwd_light_5 = 0.98, -- 24, lowest of 4 groups
			stagger_fwd_light_6 = 0.96, -- 3
			stagger_left = 0.84, -- 6, lowest of 2 groups
			stagger_left_2 = 1.20, -- 12, lowest of 2 groups
			stagger_left_3 = 1.38, -- 11, lowest of 3 groups
			stagger_left_4 = 1.38, -- 15, lowest of 3 groups
			stagger_left_5 = 1.15, -- 6, lowest of 2 groups
			stagger_left_heavy = 2.58, -- 2, from chaos_fanatic
			stagger_left_heavy_4 = 2.63, -- 2, from chaos_fanatic
			stagger_left_light = 0.72, -- 12
			stagger_left_light_2 = 0.87, -- 13
			stagger_left_light_3 = 0.87, -- 13
			stagger_left_light_4 = 0.85, -- 7
			stagger_left_shield_light = 2.63, -- 2, from chaos_marauder_with_shield
			stagger_medium_downward_2 = 1.86, -- 3, from chaos_marauder_with_shield
			stagger_right = 1.09, -- 5
			stagger_right_2 = 1.36, -- 11, lowest of 2 groups
			stagger_right_3 = 1.36, -- 7, lowest of 3 groups
			stagger_right_4 = 1.22, -- 9, lowest of 3 groups
			stagger_right_5 = 1.20, -- 7, lowest of 3 groups
			stagger_right_heavy = 1.96, -- 3, from chaos_fanatic
			stagger_right_heavy_2 = 2.55, -- 4
			stagger_right_heavy_4 = 2.74, -- 3
			stagger_right_light = 0.73, -- 21
			stagger_right_light_2 = 0.75, -- 24
			stagger_right_light_3 = 0.94, -- 14
			stagger_right_light_4 = 0.72, -- 22
			stagger_right_shield_light = 2.86, -- 8, from chaos_marauder_with_shield
			stagger_shield_light = 1.80, -- 23, from chaos_marauder_with_shield
			stagger_shield_medium = 2.31, -- 5, from chaos_marauder_with_shield
			stagger_shield_medium_break = 1.18, -- 5, from chaos_marauder_with_shield
			stagger_up_heavy_2 = 3.41, -- 2, from chaos_fanatic
			stun_down = 0.69, -- 7, lowest of 2 groups
		},
		chaos_marauder_with_shield = {
			stagger_bwd = 1.14, -- 4
			stagger_bwd_2 = 1.27, -- 7
			stagger_bwd_3 = 1.16, -- 9
			stagger_bwd_4 = 1.11, -- 3
			stagger_bwd_heavy = 2.52, -- 3, from chaos_fanatic
			stagger_bwd_heavy_3 = 2.48, -- 4, from chaos_fanatic
			stagger_bwd_heavy_4 = 2.56, -- 2, from chaos_fanatic
			stagger_bwd_light = 0.72, -- 5
			stagger_bwd_light_2 = 0.70, -- 6
			stagger_bwd_light_3 = 0.68, -- 4
			stagger_bwd_light_4 = 0.65, -- 4
			stagger_bwd_light_5 = 0.72, -- 10
			stagger_bwd_light_6 = 0.87, -- 9
			stagger_bwd_light_7 = 0.80, -- 5
			stagger_bwd_light_8 = 0.70, -- 8
			stagger_bwd_shield_light = 2.59, -- 9
			stagger_fwd = 1.17, -- 4, from chaos_marauder
			stagger_fwd_2 = 1.20, -- 6
			stagger_fwd_3 = 1.12, -- 8, from chaos_marauder
			stagger_fwd_4 = 1.18, -- 3
			stagger_fwd_heavy_3 = 2.80, -- 2, from chaos_marauder
			stagger_fwd_light = 0.73, -- 4
			stagger_fwd_light_2 = 0.74, -- 4
			stagger_fwd_light_3 = 0.73, -- 3, lowest of 2 groups
			stagger_fwd_light_4 = 0.96, -- 2
			stagger_fwd_light_5 = 0.97, -- 4
			stagger_fwd_light_6 = 0.98, -- 3
			stagger_left = 0.84, -- 2
			stagger_left_2 = 1.19, -- 3
			stagger_left_3 = 1.38, -- 11, from chaos_marauder
			stagger_left_4 = 1.38, -- 15, from chaos_marauder
			stagger_left_5 = 1.13, -- 2
			stagger_left_heavy = 2.58, -- 2, from chaos_fanatic
			stagger_left_heavy_4 = 2.63, -- 2, from chaos_fanatic
			stagger_left_light = 0.72, -- 4
			stagger_left_light_2 = 0.87, -- 8
			stagger_left_light_3 = 0.87, -- 7
			stagger_left_light_4 = 0.84, -- 11
			stagger_left_shield_light = 2.63, -- 2
			stagger_medium_downward_2 = 1.86, -- 3
			stagger_right = 1.08, -- 3
			stagger_right_2 = 1.36, -- 11, from chaos_marauder
			stagger_right_3 = 1.34, -- 4
			stagger_right_4 = 1.22, -- 9, from chaos_marauder
			stagger_right_5 = 1.19, -- 2
			stagger_right_heavy = 1.96, -- 3, from chaos_fanatic
			stagger_right_heavy_2 = 2.55, -- 4, from chaos_marauder
			stagger_right_heavy_4 = 2.74, -- 3, from chaos_marauder
			stagger_right_light = 0.72, -- 4
			stagger_right_light_2 = 0.75, -- 7
			stagger_right_light_3 = 0.94, -- 5
			stagger_right_light_4 = 0.72, -- 5
			stagger_right_shield_light = 2.86, -- 8
			stagger_shield_light = 1.80, -- 23
			stagger_shield_medium = 2.31, -- 5
			stagger_shield_medium_break = 1.18, -- 5
			stagger_up_heavy_2 = 3.41, -- 2, from chaos_fanatic
			stun_down = 0.69, -- 7, from chaos_marauder
		},
		skaven_clan_rat = {
			stagger_bwd = 0.98, -- 2
			stagger_bwd_2 = 0.92, -- 208
			stagger_bwd_3 = 0.86, -- 187
			stagger_bwd_4 = 1.06, -- 146
			stagger_bwd_5 = 0.84, -- 2
			stagger_bwd_exp = 3.57, -- 48
			stagger_bwd_exp_2 = 3.82, -- 41
			stagger_bwd_fall = 2.05, -- 8
			stagger_bwd_fall_2 = 1.42, -- 12
			stagger_bwd_heavy = 1.62, -- 4
			stagger_bwd_heavy_2 = 1.72, -- 3
			stagger_bwd_heavy_3 = 2.01, -- 4
			stagger_bwd_heavy_4 = 1.82, -- 6
			stagger_fwd = 0.99, -- 43
			stagger_fwd_2 = 1.02, -- 25
			stagger_fwd_3 = 0.99, -- 18
			stagger_fwd_4 = 1.02, -- 26
			stagger_fwd_exp = 2.42, -- 4
			stagger_fwd_exp_2 = 2.66, -- 6
			stagger_left = 0.96, -- 71
			stagger_left_2 = 0.92, -- 57
			stagger_left_3 = 0.89, -- 69
			stagger_left_4 = 1.02, -- 64
			stagger_left_exp = 3.16, -- 11
			stagger_left_exp_2 = 3.52, -- 9
			stagger_left_heavy = 1.52, -- 2
			stagger_left_heavy_3 = 1.55, -- 8, from skaven_slave
			stagger_left_heavy_4 = 2.01, -- 3
			stagger_left_heavy_5 = 1.85, -- 2
			stagger_right = 0.96, -- 64
			stagger_right_2 = 0.96, -- 47
			stagger_right_3 = 0.94, -- 2
			stagger_right_4 = 1.12, -- 46
			stagger_right_exp = 3.59, -- 13
			stagger_right_exp_2 = 3.06, -- 20
			stagger_right_heavy_3 = 1.42, -- 4, from skaven_slave
			stagger_right_heavy_4 = 1.81, -- 2, from beastmen_ungor
			stagger_right_heavy_5 = 1.51, -- 3
			stun_bwd_sword = 0.61, -- 6
			stun_down = 0.62, -- 6, lowest of 4 groups
			stun_fwd_sword = 0.61, -- 58
			stun_left_sword = 0.61, -- 11
			stun_left_sword_2 = 0.61, -- 12
			stun_left_sword_3 = 0.61, -- 13
			stun_right_sword = 0.61, -- 6
			stun_right_sword_2 = 0.61, -- 12
			stun_right_sword_3 = 0.61, -- 9
		},
		skaven_clan_rat_with_shield = {
			stagger_bwd = 0.94, -- 13
			stagger_bwd_2 = 0.88, -- 7, lowest of 2 groups
			stagger_bwd_exp = 3.60, -- 6
			stagger_bwd_exp_2 = 3.60, -- 2
			stagger_bwd_fall_2 = 1.45, -- 2
			stagger_bwd_shield = 0.84, -- 8
			stagger_bwd_shield_2 = 0.84, -- 8
			stagger_bwd_shield_3 = 0.94, -- 6
			stagger_bwd_shield_light = 0.61, -- 29
			stagger_bwd_shield_up_light = 0.64, -- 64
			stagger_bwd_shield_up_light_head = 0.76, -- 7, lowest of 2 groups
			stagger_fwd = 0.96, -- 18
			stagger_left = 0.94, -- 2
			stagger_left_2 = 0.96, -- 8
			stagger_left_3 = 0.82, -- 8, lowest of 2 groups
			stagger_left_4 = 0.97, -- 2
			stagger_left_exp_2 = 3.42, -- 2
			stagger_left_heavy_3 = 1.53, -- 2
			stagger_left_shield = 0.96, -- 9
			stagger_left_shield_light = 0.61, -- 2
			stagger_left_shield_up = 0.99, -- 2
			stagger_left_shield_up_light = 0.64, -- 5
			stagger_right = 0.95, -- 3
			stagger_right_2 = 0.96, -- 4
			stagger_right_3 = 0.94, -- 4
			stagger_right_4 = 0.94, -- 2
			stagger_right_shield = 0.96, -- 7
			stagger_right_shield_light = 0.63, -- 24
			stagger_right_shield_up = 0.99, -- 4
			stagger_right_shield_up_light = 0.66, -- 13
			stagger_shield_break_bwd = 0.84, -- 3
			stagger_shield_break_left = 0.84, -- 2
			stun_bwd_sword = 0.64, -- 10
			stun_down = 0.61, -- 3
			stun_fwd_sword = false, -- split: 2 around 0.61, 11 around 0.81
			stun_left_sword = 0.64, -- 5
			stun_left_sword_2 = 0.64, -- 5
			stun_left_sword_3 = 0.64, -- 6
			stun_right_sword = 0.64, -- 6
			stun_right_sword_2 = 0.64, -- 5
			stun_right_sword_3 = 0.64, -- 3
		},
		skaven_plague_monk = {
			stagger_bwd = 1.01, -- 2
			stagger_bwd_2 = 0.91, -- 4
			stagger_right = 1.02, -- 2
			stagger_run_heavy_bwd = 0.84, -- 2
			stagger_run_heavy_bwd_2 = 0.82, -- 2
			stagger_run_light_bwd = 0.41, -- 2
			stagger_run_light_bwd_2 = 0.31, -- 6
			stun_bwd_sword = 0.68, -- 3
			stun_fwd_sword = 0.68, -- 7
			stun_left_sword = 0.64, -- 3
			stun_right_sword = 0.64, -- 4
		},
		skaven_slave = {
			stagger_bwd = 0.98, -- 6
			stagger_bwd_2 = 0.91, -- 4
			stagger_bwd_3 = 0.84, -- 6
			stagger_bwd_4 = 1.04, -- 2
			stagger_bwd_5 = 0.84, -- 9
			stagger_bwd_exp = 3.57, -- 22
			stagger_bwd_exp_2 = 3.83, -- 12
			stagger_bwd_fall = 2.05, -- 13
			stagger_bwd_fall_2 = 1.42, -- 11
			stagger_bwd_heavy = 1.61, -- 14
			stagger_bwd_heavy_2 = 1.72, -- 10
			stagger_bwd_heavy_3 = 2.02, -- 8
			stagger_bwd_heavy_4 = 1.82, -- 8
			stagger_fwd = 0.99, -- 68
			stagger_fwd_2 = 1.01, -- 2
			stagger_fwd_3 = 0.98, -- 2
			stagger_fwd_4 = 1.02, -- 36
			stagger_fwd_exp = 2.42, -- 3
			stagger_fwd_exp_2 = 2.66, -- 3
			stagger_left = 0.94, -- 3
			stagger_left_2 = 0.91, -- 2
			stagger_left_3 = 0.87, -- 2
			stagger_left_4 = 1.02, -- 102
			stagger_left_exp = 3.16, -- 5
			stagger_left_exp_2 = 3.53, -- 3
			stagger_left_heavy = 1.52, -- 2
			stagger_left_heavy_3 = 1.55, -- 8
			stagger_left_heavy_4 = 2.02, -- 5
			stagger_left_heavy_5 = 1.85, -- 7
			stagger_right = 0.94, -- 2
			stagger_right_2 = 0.95, -- 84
			stagger_right_3 = 0.95, -- 98
			stagger_right_4 = 1.12, -- 101
			stagger_right_exp = 3.59, -- 3
			stagger_right_exp_2 = 3.06, -- 6
			stagger_right_heavy_3 = 1.42, -- 4
			stagger_right_heavy_4 = 1.81, -- 2, from beastmen_ungor
			stagger_right_heavy_5 = 1.51, -- 3, from skaven_clan_rat
			stun_bwd_sword = 0.62, -- 130, lowest of 4 groups
			stun_down = 0.62, -- 6, from skaven_clan_rat
			stun_fwd_sword = 0.61, -- 34
			stun_left_sword = 0.61, -- 4
			stun_left_sword_2 = 0.61, -- 4
			stun_left_sword_3 = 0.61, -- 3
			stun_right_sword = 0.61, -- 3
			stun_right_sword_2 = 0.61, -- 3
			stun_right_sword_3 = 0.61, -- 4
		},
		skaven_storm_vermin_commander = {
			stagger_bwd_2 = 0.81, -- 3
			stagger_bwd_4 = 0.81, -- 5
			stun_bwd_sword = 0.81, -- 12
			stun_bwd_sword_2 = 0.81, -- 11
			stun_bwd_sword_3 = 0.81, -- 9
			stun_fwd_sword = 0.78, -- 3
			stun_left_sword_2 = 0.74, -- 4
			stun_right_sword_3 = 0.75, -- 4
		},
		skaven_storm_vermin_with_shield = {
			stagger_bwd_open = 1.01, -- 5
			stagger_bwd_shield_up_light = 0.60, -- 36
			stagger_bwd_shield_up_light_2 = 0.60, -- 25
			stagger_bwd_shield_up_light_head = 0.58, -- 2
			stagger_left_shield_up_light = 0.60, -- 6
			stagger_right_shield_up_light = 0.60, -- 3
			stun_bwd_open = 0.78, -- 45
			stun_fwd_open = 0.81, -- 2
			stun_left_open = 0.81, -- 10
			stun_right_open = 0.74, -- 8
		},
	},
	cue = {
		beastmen_ungor = {
			blocked = 0.91, -- 22
			blocked_2 = 0.74, -- 29
			blocked_3 = 0.61, -- 31
		},
		chaos_fanatic = {
			blocked = {
				attack_move = 2.34, -- 4
				attack_move_2 = 2.04, -- 3
				attack_move_3 = 1.28, -- 6
				attack_move_4 = 1.64, -- 2
				attack_pounce = 0.94, -- 2
				attack_pounce_2 = 1.44, -- 1
				attack_pounce_3 = 0.94, -- 2
				attack_pounce_4 = 1.21, -- 5
				attack_pounce_5 = 1.28, -- 2
				attack_pounce_6 = 1.64, -- 4
				attack_pounce_7 = 0.94, -- 3
			},
		},
		chaos_marauder = {
			blocked = {
				attack_move = 2.34, -- 5
				attack_move_2 = 2.04, -- 3
				attack_move_3 = 1.27, -- 2
				attack_move_4 = 1.64, -- 3
				attack_pounce = 0.95, -- 16
				attack_pounce_2 = 1.44, -- 5
				attack_pounce_3 = 0.95, -- 8
				attack_pounce_4 = 1.22, -- 3
				attack_pounce_5 = 1.27, -- 3
				attack_pounce_6 = 1.64, -- 2
				attack_pounce_7 = 0.95, -- 5
				attack_run = 2.34, -- 2
				attack_run_3 = 1.21, -- 5
			},
		},
		chaos_marauder_with_shield = {
			blocked = {
				attack_pounce = 0.94, -- 3
				attack_pounce_2 = 1.44, -- 1
				attack_pounce_3 = 0.94, -- 3
				attack_pounce_4 = 1.21, -- 1
				attack_pounce_5 = 1.27, -- 3
				attack_pounce_6 = 1.64, -- 1
				attack_pounce_7 = 0.94, -- 1
				attack_run = 0.94, -- 6
				attack_run_2 = 1.21, -- 1
				attack_run_3 = 1.21, -- 3
			},
		},
		skaven_clan_rat = {
			blocked = 0.81, -- 136
			blocked_2 = 1.01, -- 168
			blocked_3 = 0.68, -- 166
		},
		skaven_slave = {
			blocked = 0.82, -- 23
			blocked_2 = 1.02, -- 16
			blocked_3 = 0.68, -- 17
		},
		skaven_storm_vermin_commander = {
			blocked = 0.88, -- 3
		},
	},
	stunned = {
		beastmen_gor = {
			blocked = {
				attack_1h = 1.40, -- 1
				attack_1h_2 = 1.41, -- 1
				attack_1h_3 = 1.40, -- 2
				attack_punch = 1.30, -- 1
				attack_run = 1.40, -- 1
				attack_step = 1.40, -- 2
				attack_step_2 = 1.40, -- 3
				attack_step_head = 1.40, -- 2
			},
			blocked_2 = 1.40, -- 21
		},
		beastmen_ungor = {
			blocked = 2.40, -- 17
			blocked_2 = 2.40, -- 14
			blocked_3 = 2.40, -- 14
		},
		chaos_berzerker = {
			blocked = {
				attack_pounce = 1.09, -- 1, lowest of 2 groups
				attack_pounce_2 = 2.13, -- 2
			},
			blocked_2 = {
				attack_lunge = 1.51, -- 1, lowest of 2 groups
				attack_pounce = 1.62, -- 2
				attack_pounce_2 = 2.13, -- 4
			},
			blocked_3 = {
				attack_pounce = 1.62, -- 4
				attack_pounce_2 = 2.13, -- 9
			},
		},
		chaos_fanatic = {
			blocked = {
				attack_move = 2.35, -- 4
				attack_move_2 = 2.06, -- 3
				attack_move_3 = 1.29, -- 6
				attack_move_4 = 1.66, -- 2
				attack_pounce = 0.95, -- 2
				attack_pounce_2 = 1.45, -- 1
				attack_pounce_3 = 0.95, -- 2
				attack_pounce_4 = 1.22, -- 5
				attack_pounce_5 = 1.29, -- 2
				attack_pounce_6 = 1.65, -- 4
				attack_pounce_7 = 0.96, -- 3
			},
		},
		chaos_marauder = {
			blocked = {
				attack_move = 2.35, -- 5
				attack_move_2 = 2.05, -- 3
				attack_move_3 = 1.28, -- 2
				attack_move_4 = 1.65, -- 3
				attack_pounce = 0.95, -- 3
				attack_pounce_2 = 1.45, -- 3
				attack_pounce_3 = 0.95, -- 2
				attack_pounce_4 = 1.22, -- 1
				attack_pounce_5 = 1.29, -- 2
				attack_pounce_6 = 1.65, -- 1
				attack_pounce_7 = 0.95, -- 2
				attack_run = 2.35, -- 2
				attack_run_3 = 1.22, -- 5
			},
		},
		chaos_marauder_with_shield = {
			blocked = {
				attack_pounce = 0.95, -- 3
				attack_pounce_2 = 1.45, -- 1
				attack_pounce_3 = 0.95, -- 3
				attack_pounce_4 = 1.22, -- 1
				attack_pounce_5 = 1.29, -- 3
				attack_pounce_6 = 1.66, -- 1
				attack_pounce_7 = 0.95, -- 1
				attack_run = 0.95, -- 6
				attack_run_2 = 1.22, -- 1
				attack_run_3 = 1.22, -- 3
			},
		},
		skaven_clan_rat = {
			blocked = 0.82, -- 8
			blocked_2 = 1.02, -- 2
			blocked_3 = 0.69, -- 2, lowest of 2 groups
		},
		skaven_clan_rat_with_shield = {
			blocked = 2.40, -- 6
			blocked_2 = {
				attack_pounce = 2.00, -- 1
			},
			blocked_3 = 1.57, -- 6
		},
		skaven_plague_monk = {
			blocked = {
				attack_pounce = 0.97, -- 7
			},
			blocked_2 = {
				attack_pounce = 0.97, -- 9
			},
			blocked_3 = {
				attack_pounce = 0.97, -- 6
			},
		},
		skaven_slave = {
			blocked = 0.82, -- 9
			blocked_2 = 1.02, -- 3
			blocked_3 = false, -- split: 9 around 0.69, 2 around 0.73
		},
		skaven_storm_vermin_with_shield = {
			blocked = 1.24, -- 3
			blocked_2 = 1.32, -- 2
		},
	},
}

for _, kind in ipairs(timings.KINDS) do
	DEFAULTS[kind] = DEFAULTS[kind] or {}
end

local function valid_seconds(seconds)
	return type(seconds) == "number" and seconds == seconds and seconds >= MIN_SECONDS and seconds <= MAX_SECONDS
end

local function load(kind)
	local saved = mod:get(SETTINGS[kind])
	local clean = {}

	if type(saved) ~= "table" then
		return clean
	end

	for breed_name, by_anim in pairs(saved) do
		if type(breed_name) == "string" and type(by_anim) == "table" then
			local values = {}

			for anim, entry in pairs(by_anim) do
				if type(anim) == "string" then
					if BY_ATTACK[kind] and type(entry) == "table" then
						local by_attack = {}

						for attack, seconds in pairs(entry) do
							if type(attack) == "string" and valid_seconds(seconds) then
								by_attack[attack] = seconds
							end
						end

						values[anim] = by_attack
					elseif not BY_ATTACK[kind] and valid_seconds(entry) then
						values[anim] = entry
					end
				end
			end

			clean[breed_name] = values
		end
	end

	return clean
end

local measured = {}
local dirty = {}

for _, kind in ipairs(timings.KINDS) do
	local ok, values = pcall(load, kind)

	measured[kind] = ok and values or {}

	if not ok then
		pc.print("could not read the saved %s: %s", SETTINGS[kind], tostring(values))
	end
end

-- An entry is a number, or for a recoil's timings a table by the blocked attack's animation.
local function lookup(by_breed, breed_name, anim, attack)
	local by_anim = by_breed[breed_name]
	local entry = by_anim and by_anim[anim]

	if type(entry) == "table" then
		return attack ~= nil and entry[attack] or nil
	end

	return entry
end

-- The timing for this breed's animation, and for a recoil the attack it interrupted: the shipped value, else what this
-- machine has learned, else nil. The second value says whether DEFAULTS decides it: true for a shipped value, and for
-- an animation whose readings split (nil then).
function timings.get(kind, breed_name, anim, attack)
	local shipped = lookup(DEFAULTS[kind], breed_name, anim, attack)

	if shipped then
		return shipped, true
	elseif shipped == false then
		return nil, true
	end

	return lookup(measured[kind], breed_name, anim, attack), false
end

-- One reading on this machine: seconds from the animation's start to its cue, for a stagger played faster multiplied
-- back to normal speed. after: for a recoil, the blocked attack's animation. speed: how fast the animation was asked to
-- play (1 for normal). Every reading is logged; only one taken at normal speed, of a timing that isn't shipped, is
-- learned.
function timings.learn(kind, breed_name, anim, seconds, after, speed)
	if not SETTINGS[kind] or type(breed_name) ~= "string" or type(anim) ~= "string" or type(seconds) ~= "number" then
		return
	end

	speed = type(speed) == "number" and speed > 0 and speed or 1

	local attack = BY_ATTACK[kind] and type(after) == "string" and after or nil
	local known, shipped = timings.get(kind, breed_name, anim, attack)
	local reading = string.format("timing %s breed=%s anim=%s seconds=%.3f%s speed=%.2f", kind, breed_name, anim, seconds, attack and " after=" .. attack or "", speed)

	if not valid_seconds(seconds) or known and seconds < known * MIN_SHARE then
		pc.count("timings_ignored_" .. kind)
		pc.log("%s ignored: not this animation's own (known %s)", reading, known and string.format("%.3f", known) or "none")

		return
	end

	pc.count("timings_read_" .. kind)

	if shipped then
		if known then
			pc.log("%s shipped=%.3f", reading, known)
		else
			pc.log("%s not learned: its readings split (DEFAULTS)", reading)
		end

		return
	end

	if math.abs(speed - 1) > SPEED_TOLERANCE then
		pc.log("%s not learned: not at normal speed", reading)

		return
	end

	if BY_ATTACK[kind] and not attack then
		pc.log("%s not learned: the blocked attack isn't known", reading)

		return
	end

	local by_anim = measured[kind][breed_name]

	if not by_anim then
		by_anim = {}
		measured[kind][breed_name] = by_anim
	end

	local value = known and known + (seconds - known) * LEARN_WEIGHT or seconds

	if attack then
		local by_attack = type(by_anim[anim]) == "table" and by_anim[anim] or {}

		by_attack[attack] = value
		by_anim[anim] = by_attack
	else
		by_anim[anim] = value
	end

	dirty[kind] = true

	pc.count("timings_measured_" .. kind)
	pc.log("%s learned=%.3f", reading, value)
end

local function sorted_union(a, b)
	local seen, keys = {}, {}

	for _, t in ipairs({ a, b }) do
		if type(t) == "table" then
			for key in pairs(t) do
				if not seen[key] then
					seen[key] = true
					keys[#keys + 1] = key
				end
			end
		end
	end

	table.sort(keys)

	return keys
end

-- Calls fn(breed_name, anim, attack, seconds, shipped) for every timing in use, sorted: the shipped ones, and the ones
-- this machine learned that no shipped one covers. attack is nil for a value that covers every attack.
local function each_known(kind, fn)
	local defaults, own = DEFAULTS[kind], measured[kind]

	for _, breed_name in ipairs(sorted_union(defaults, own)) do
		local shipped_anims, own_anims = defaults[breed_name] or {}, own[breed_name] or {}

		for _, anim in ipairs(sorted_union(shipped_anims, own_anims)) do
			local shipped, mine = shipped_anims[anim], own_anims[anim]

			if shipped == false then
				-- Its readings split: no value is used for it.
			elseif type(shipped) == "number" then
				fn(breed_name, anim, nil, shipped, true)
			elseif type(shipped) == "table" or type(mine) == "table" then
				local shipped_attacks = type(shipped) == "table" and shipped or {}
				local own_attacks = type(mine) == "table" and mine or {}

				for _, attack in ipairs(sorted_union(shipped_attacks, own_attacks)) do
					local value = shipped_attacks[attack]

					fn(breed_name, anim, attack, value or own_attacks[attack], value ~= nil)
				end
			elseif type(mine) == "number" then
				fn(breed_name, anim, nil, mine, false)
			end
		end
	end
end

timings.each_known = each_known

-- How many timings are known, and how many of those this machine measured itself.
function timings.count(kind)
	local total, own = 0, 0

	each_known(kind, function (_, _, _, _, shipped)
		total = total + 1

		if not shipped then
			own = own + 1
		end
	end)

	return total, own
end

-- /pingcomp timings: everything known, in the form DEFAULTS uses, one line per value.
function timings.dump()
	for _, kind in ipairs(timings.KINDS) do
		local breed_open, anim_open = nil, nil

		pc.print("timings %s = {", kind)

		each_known(kind, function (breed_name, anim, attack, seconds, shipped)
			if breed_name ~= breed_open then
				if anim_open then
					pc.print("timings 		},")
				end

				if breed_open then
					pc.print("timings 	},")
				end

				pc.print("timings 	%s = {", breed_name)

				breed_open, anim_open = breed_name, nil
			end

			if attack then
				if anim_open ~= anim then
					if anim_open then
						pc.print("timings 		},")
					end

					pc.print("timings 		%s = {", anim)

					anim_open = anim
				end

				pc.print("timings 			%s = %.2f,%s", attack, seconds, shipped and " -- default" or "")
			else
				if anim_open then
					pc.print("timings 		},")

					anim_open = nil
				end

				pc.print("timings 		%s = %.2f,%s", anim, seconds, shipped and " -- default" or "")
			end
		end)

		if anim_open then
			pc.print("timings 		},")
		end

		if breed_open then
			pc.print("timings 	},")
		end

		pc.print("timings },")
	end
end


function timings.save()
	for kind in pairs(dirty) do
		local ok, message = pcall(mod.set, mod, SETTINGS[kind], measured[kind])

		if not ok then
			pc.print("could not save %s: %s", SETTINGS[kind], tostring(message))
		end
	end

	dirty = {}
end
