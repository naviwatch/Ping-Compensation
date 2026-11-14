# Build 3.2 calibration session

A session you host alone with CreatureSpawner, on the stage 1 build of 3.2 (D46). It does two things:

1. **Fills the missing timings.** The host times every recoil and stagger of a covered enemy that it decides itself, which in a solo session is all of them. A recoil is timed when you block an attack; a stagger when you hit or push the enemy.
2. **Probes animation speed.** It finds out whether recoils, and the Chaos and ungor staggers, can be played faster (D45, T9).

Send the console log afterwards, the newest file in `console_logs`. The debug log is on by default in this build, so there is nothing to switch on.

## Before you start

- Any difficulty works, because timings don't depend on it. On Legend or higher, enemies survive more hits, but heavy staggers take stronger hits.
- Fight on flat ground. Most attacks have a separate set of animations for targets above or below the enemy. Flat ground gets the main set, which is what players block most.
- `/pingcomp missing <enemy>` shows in chat what is still missing for that enemy, counting what you have timed so far. `/pingcomp missing` lists every covered enemy, and the full lists go to the console log. Use it to see when an enemy is done.
- Use `/pingcomp mark <note>` whenever you switch enemy or task, so the log is easy to follow.

## Part 1: timings

Spawn one enemy at a time, or two or three of the same kind.

**Blocks.** Hold block and let the enemy swing at you. Each block makes it recoil, and one reading per attack animation is enough. Each attack picks one of several animations at random, so about 15 to 20 blocks of each attack are needed to catch them all. Monks and savages only recoil from their single swings: a blocked frenzy flurry gives no recoil. Let the flurry pass and block the slower single swings.

**Staggers.** Hit and push the enemy from the front, the back and each side, because each direction has its own animations. Each kind of hit gives a different stagger:

- **Light:** light attacks.
- **Medium and heavy:** heavy attacks, charged attacks and pushes. A hammer or mace gets heavy staggers sooner.
- **Explosion:** bombs, the Mercenary's shout, the Slayer's leap, fire staves' explosions.
- **Ranged:** bows and handguns.
- **Pulling:** the billhook's pull special.

| Enemy | Blocks | Staggers | Notes |
|---|---|---|---|
| Ungor | normal and running attacks | every kind | Nothing timed yet |
| Gor | normal, running and headbutt attacks | every kind | Nothing timed yet |
| Shielded stormvermin | its sweep (its frenzy never recoils; the sweep's recoil is predicted from step 4, but timed now) | every kind, including hits on its shield and breaking it | Nothing timed yet |
| Savage | single swings and running attacks | every kind | Ends its recoils with the stunned cue; very few readings so far |
| Plague monk | single swings | every kind | No recoils timed yet |
| Fanatic | normal and running attacks | heavy, explosion, ranged | Recoils depend on the attack; none shipped yet |
| Marauder | running attacks; normal attacks until `missing` shows none left | heavy, explosion, ranged | |
| Shielded marauder | normal and running attacks | every kind, including on its shield | No recoils timed yet |
| Shielded clan rat | normal attacks | heavy, explosion, ranged, on and off its shield | No recoils timed yet |
| Clan rat, slave rat | (done) | heavy and ranged; for slave rats also pulling | Light, medium and explosion are done |

When `/pingcomp missing <enemy>` shows few or none missing, move on. Some animations are rare, so don't chase the last few.

## Part 2: speed probe

This changes only your own game, so do it after Part 1.

1. Spawn one of each covered enemy, then type `/pingcomp probe vars`. It writes to the log which speed variables each enemy's animations have.
2. Type `/pingcomp probe speed stagger_scale 2`. Block each enemy type about 5 times, and stagger each about 5 times with light and heavy hits. Recoils and staggers that respond will play twice as fast.
3. Type `/pingcomp probe speed reset_speed 2` and do the same again.
4. Type `/pingcomp probe off`.

Readings taken while the probe is on are logged, not learned.

Done on 2026-11-14. Only `stagger_scale` exists, and it speeds up Skaven and ungor staggers only, and no enemy's recoils (D47).

## Part 3: animation state probe (build 3.2 stage 2)

About ten minutes alone, on the stage 2 build, before testers get it (D47). It finds out whether the animation state the game sends to players who join mid-game holds the animation's time, which would let the host move a recoil or a stagger on for everyone.

1. Spawn a marauder, a clan rat and a gor. Type `/pingcomp probe vars`.
2. Type `/pingcomp probe state`. Block each enemy about 3 times, and stagger each about 3 times with light hits and 3 times with pushes.
3. Type `/pingcomp probe jump 2` and do the same again. This one is an experiment: enemies may skip, jitter or freeze for a moment. One whose animation never reaches its end is let go after 4 seconds.
4. Type `/pingcomp probe off`, then `/pingcomp missing` once, and send the log.

Use `/pingcomp mark <note>` before each step, and to note anything that looked odd.
