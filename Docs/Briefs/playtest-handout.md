# Ping Compensation: playtest handout

For the other developer on the mod and for anyone playtesting it. This describes **build step 2**, made on 2026-11-11. It is updated whenever a new build changes what you see or what to test.

The full design is in [client-authoritative-melee.md](client-authoritative-melee.md). You don't need it to test.

## What the mod does

In the normal game the host decides whether an enemy's swing hits you, using a picture of you that is out of date by your ping. That is why a block or dodge that looked fine on your screen can still fail. It is also why, when you play on someone else's game, everything you do to enemies shows up a moment late: their stagger, their death, their recoil from your block.

This mod moves those decisions to your own game. When an enemy's swing lands **on your screen**, your game checks whether you were in reach, whether the enemy was facing you and whether your block was up, then tells the host the result. When **your** attack or push lands on an enemy, your game works out whether it staggers or kills it, shows that at once, and tells the host. The host accepts both.

On your own screen the mod also turns the enemy that is swinging at you, using the game's normal turning rules but your real position. Dodging still makes it lose track of you, as in the normal game.

## What changed in this build

Thank you for the step 1.1 session. Blocks and dodges felt right, and you told us attacks and pushes still felt delayed. This build is about that.

- **Your attacks, pushes, shots and career skills stagger trash on your screen at once.** The enemy reels back the moment your hit lands, and it moves the way it would in the normal game. The host then plays the same stagger for everyone else. A stagger you cause also stops that enemy's swing at you. This includes shielded clan rats and marauders.
- **Your kills on trash happen on your screen at once**, melee or ranged. If your game reckons your hit kills the enemy, it drops straight away. The host makes sure it dies there too.
- **No pause after a stagger you cause.** The host plays your stagger a little faster, so the enemy's next move reaches you just as its stagger ends on your screen.
- **After you block a swing, the enemy recoils at once on your screen**, with its push-back movement. The host plays the same recoil for everyone else.
- **When a swing hits you, you feel it at once**: the health drop, the damage indicator, the flinch, the controller rumble, the hit sound and the knockback.
- **Three new switches to compare against step 1**: `/pingcomp attacks`, `/pingcomp recoil` and `/pingcomp predict`, and one for the host, `/pingcomp stagger` (see "Commands").
- `/pingcomp stats` and `/pingcomp version` now also write what they show into your console log.

## What is covered in this build

Judged on your screen, as before:

- Swings from slave rats, clan rats (with or without shields), marauders (with or without shields), fanatics, gors and ungors.
- The ordinary single swings of plague monks and savages.

New in this build, shown on your screen at once:

- **Staggers and kills from your hits**, whatever hit them (melee, pushes, shield bashes, arrows, bolts, bullets, beams, career-skill charges and shots), on slave rats, clan rats and marauders (with or without shields), fanatics, gors and ungors.
- **The recoil after your block**, for every swing in the first list.
- **Hit results** when any swing in the first list hits you.

Still exactly like the normal game, so a moment late when you aren't the host:

- Staggers and kills on elites, specials, monsters and lords.
- Staggers and kills from explosions and other area damage: bombs, fireball blasts, the Mercenary's shout and other area career skills, and damage over time such as burning and bleeding.
- Plague monk and savage frenzy combos, and elite sweeps, overheads and shoves.
- Monsters, lords and disablers (packmaster, assassin, leech).
- Anything aimed at the host's own hero, a bot, or a player without the mod.

## What to expect

- **Blocks and dodges count the way you saw them**, as in step 1.1.
- **An enemy you stagger reels back the instant your hit lands**, and its next move follows straight on. The host learns how long each stagger animation is as you play, and remembers it between sessions, so in your first games with this build some staggers may still be followed by a pause of about a ping.
- **An enemy you kill drops the instant your hit lands.**
- **The enemy recoils the instant you block.** It too may pause briefly before attacking again.
- **A hit on you is felt at once.** The health bar shows an estimate straight away and settles on the host's exact number a moment later. A small jump in the bar when that happens is expected.
- **Other players see your staggers and kills a moment late.** On their screens an enemy you staggered may jump a short way, because it starts its stagger from where you saw it, and it staggers a little faster than normal.
- **Chained dodges wear out** after as many quick dodges as your weapon allows, as in step 1.1.
- **Backing away from a swing is easier than in the normal game**, more so with a high ping. We want to know whether it feels too easy.

## Before you play

1. Use the build Lance gives you. Everyone in the lobby who wants the mod, the host included, needs the same one. The host must have it, or nothing changes for anyone.
2. Once everyone is in the keep or a mission, type `/pingcomp version` in chat. Every player should show the same text in square brackets. `Mod not found.` means that player has no mod, has it switched off, or is on an older build.
3. Type `/pingcomp debug on`. Do this on every computer, once per game start. It resets when the game restarts or the mods are reloaded.

## Commands

All of them are typed into the game's chat. Every switch goes back to its default when the game restarts.

| Command | What it does |
|---|---|
| `/pingcomp version` | Lists the build each connected player is running. Only you see the list. |
| `/pingcomp debug on` or `off` | Writes one line per judged swing, stagger, kill and recoil into your console log. On the host it also shows a chat line when the host would have judged a swing differently, or when a client never answered. |
| `/pingcomp stats` | Shows totals since the mission started: swings judged, hits, blocks, your staggers and kills, and so on. |
| `/pingcomp attacks on` or `off` | Clients only. On, the default, shows your staggers and kills on trash at once. Off leaves them to the host, a moment late, as in step 1.1. |
| `/pingcomp recoil full`, `anim` or `off` | Clients only. The enemy's recoil after your block. `full`, the default, plays it and its movement at once. `anim` plays the animation at once but moves the enemy where the host has it. `off` waits for the host, as in step 1.1. |
| `/pingcomp predict on` or `off` | Clients only. On, the default, shows a hit on you at once. Off waits for the host, as in step 1.1. |
| `/pingcomp stagger speed`, `end` or `off` | Host only. How the host shortens a stagger a client caused, so that client sees no pause after it. `speed`, the default, plays it faster. `end` cuts it short instead. `off` leaves it its full length, so the client sees a pause. |
| `/pingcomp dodgecount on` or `off` | Clients only. On, the default, applies your weapon's dodge count, as the game always has for the host. Off ignores it, as the normal game does for clients. |
| `/pingcomp facing on` or `off` | Clients only. Leave it on. Off is only for comparing and makes you much harder to hit than in the normal game. |
| `/pingcomp mark <note>` | Writes a marker into your console log, for example `/pingcomp mark that rat hit me through my block`. |

## What to test

Any difficulty works. Champion or higher is best, because enemies track and commit to swings more. A higher ping makes every effect easier to see.

**As a client (not the host)**

1. **Push.** Push single clan rats, marauders and gors. Do they reel back the moment your push lands? Does their movement look right, and is there any jump when the host's version catches up?
2. **Attack.** Hit single trash enemies with light and heavy attacks. Same questions as for the push.
3. **After the stagger.** Watch what the enemy does once its stagger ends. Does it carry straight on, or stand still for a moment first? It may pause in your first few fights with this build while the host learns the animations; tell us if it still does after that.
4. **Interrupt a swing.** Stagger an enemy with a push or an attack during its wind-up. The swing should stop on your screen and do nothing.
5. **Kill.** Kill trash with your melee weapon, including headshots and kills through a crowd. Do they drop at once? Does any enemy you saw die keep fighting, get back up, or die twice?
6. **Ranged and career skills.** Shoot trash with your ranged weapon, and use a career skill that charges, dashes or shoots through them. Their staggers and kills should show at once too.
7. **Shields.** Push and hit shielded clan rats and marauders, from the front and from behind. A hit taken on the shield should knock them back but do no damage. Break a shield with a heavy attack and check the enemy fights on without it.
8. **Horde.** Push-attack and cleave through a horde for a few minutes. Look for enemies that freeze, slide, jump back to an earlier spot, or play a stagger twice.
9. **Block recoil.** Block single swings. The enemy should recoil the instant you block. Then compare `/pingcomp recoil anim` and `/pingcomp recoil off`, and tell us which felt best. Go back to `full` afterwards.
10. **After the recoil.** Watch how long the enemy pauses after its recoil before it swings again. Tell us if it feels too long or too short.
11. **Take a hit on purpose.** Stand still and let a swing land. You should lose health, flinch and feel the knockback at once. Then try `/pingcomp predict off` to compare, and turn it back on afterwards.
12. **Late block and dodge**, as in step 1.1. If your block was up or you were out of reach when the swing landed on your screen, it should never count as a hit.
13. **Chained back dodges with a shield.** Most shields allow only 2 quick dodges, so this is the weapon where your dodge count shows. Dodge backwards several times in a row away from a swinging enemy, then try the same with `/pingcomp dodgecount off`, and tell us which felt right. Turn it back on afterwards.
14. **Elites and explosions.** Stagger elites, and throw a bomb or use an area skill into trash. These are not covered yet, so they should behave like step 1.1: their staggers show a moment late.
15. **Compare with attacks off.** Play a minute with `/pingcomp attacks off`, then back on. Does on feel better?

**As the host**

16. **Watch a client fighting.** Their staggers, kills and the recoils from their blocks should look normal, if a moment late. Staggers they cause play a little faster on your screen; tell us if that looks wrong. Note any enemy that jumps a long way, freezes, or dies without being hit.
17. **Compare the stagger settings.** Ask a client to push enemies while you try `/pingcomp stagger end` and then `/pingcomp stagger off`. With `off` the client should see a pause after each stagger. Go back to `speed` afterwards.
18. **Your own fights** should feel exactly like the normal game.
19. **A bot or a player without the mod** in the lobby should play exactly like the normal game.

**Everyone**

20. At the end of the mission, before you leave, type `/pingcomp stats`.
21. Anything that crashes, freezes or throws a red error message in chat is important. Note what you were doing.

## When something looks wrong

Type `/pingcomp mark` and a few words straight away, for example `/pingcomp mark rat staggered twice`. It puts a line in your log at that moment, which makes the problem much faster to find.

## What to send back to Lance

Please send all of this after a session.

**1. Your console log.**

- Press `Win + R`, paste `%APPDATA%\Fatshark\Vermintide 2\console_logs` and press Enter.
- The game writes one file per launch, named like `console-2026-11-10-19.30.12-….log`. The date and time in the name are in UTC, so sort the folder by "Date modified" and take the newest one, or the one from the session you are reporting.
- If you restarted the game during the session, send every file from that session.
- The files are 0.5 to 1 MB each. Zip them if you like.
- On Linux or Steam Deck the folder is inside the game's Proton prefix: `steamapps/compatdata/552500/pfx/drive_c/users/steamuser/AppData/Roaming/Fatshark/Vermintide 2/console_logs`.

**2. If the game crashed:** say so, say what you were doing, and also send the newest file from `%APPDATA%\Fatshark\Vermintide 2\crash_dumps` if there is one from that time.

**3. A few facts.** Copy this and fill it in:

```
Name in game:
Host or client:
Who hosted:
Rough ping to the host, if you know it:
Mission and difficulty:
Career and melee weapon:
Was /pingcomp debug on for the whole session? (yes/no)
What /pingcomp version showed for each player:
Did your staggers and kills feel instant? Anything odd about them?
Did enemies pause after your staggers? Did that go away after a while?
Did ranged hits, career skills and shielded enemies feel the same as melee?
Host only: which stagger setting looked best (speed, end, off)?
Which recoil setting felt best (full, anim, off)?
Did predict on feel better than off?
Did you try dodgecount off with a shield? Which felt right?
What felt wrong, and roughly when (or the text of your /pingcomp mark notes):
What felt better than the normal game:
```

**4. A video clip, if you can.** For "it looked wrong" moments a short recording is the most useful thing there is. It is optional.

The log only helps if `/pingcomp debug on` was typed before the fight. Without it the log still shows errors and crashes, but not the individual swings.

A note on privacy: the console log contains your Steam name and ID, your PC's hardware, and your Windows user folder name. Send it to Lance directly, not to a public channel.

## Known limits of this build

- After a recoil you caused, the enemy can pause briefly before its next move reaches your screen. After a stagger you caused, it can pause in your first few games with this build, until the host has learned the stagger animations.
- Elites, specials, monsters and lords, explosions, area damage and damage over time still work as in the normal game (see "What is covered").
- Your game's damage reckoning doesn't include every damage bonus the host knows about. When it falls short, a kill shows a moment late, as in the normal game. When it overshoots, the enemy dies anyway: the host finishes it off and credits you.
- How hard an enemy is already staggered by other players' hits is only partly known to your game, so your stagger can come out slightly different from what the host would have chosen. Yours is the one that counts.
- If your game freezes or your connection stalls for more than 4 seconds, the host treats you as having no mod until you are back.
- A few enemy types (ungor archers in melee) normally can't hit you without a clear line of sight. That rule is not applied to swings judged on your screen.
- If the mod hits repeated internal errors, it switches itself off until the next mission and says so in chat. The game carries on as normal. Please send the log if you see that message.

## For the developer

- The code lives in `scripts/mods/Ping Compensation/`: `Shared.lua` (constants, switches, helpers, the error guard), `Geometry.lua` (the reach and facing maths), `Host.lua` (announcing and booking swings), `HostReactions.lua` (applying a client's staggers, kills and recoils, and shortening a client's stagger), `Client.lua` (judging swings), `Reactions.lua` (the client's own staggers, kills and recoils, and the host's echo), `HitResults.lua` (instant results of a hit on you), `Version.lua`, and `Ping Compensation.lua` (the shared animation-event hook, the commands and the lifecycle).
- The host keeps the stagger animation lengths it has measured in the mod's saved settings, under `stagger_lengths`.
- `CLAUDE.md` lists every hook with its file and line in the decompiled source, the network messages, and the rules for this repo.
- The message version is `VERSION = 6` in `Shared.lua`. This build changed `pc_hello`, `pc_swing_begin` and `pc_swing_answer` and added `pc_hello_reply`, `pc_stagger`, `pc_kill` and `pc_reaction_ack`, so a step 1.1 build can't play with this one.
- Build with `./build.bat < /dev/null` in Git Bash, or `.\build.bat` in PowerShell.
- Debug lines in the log start with `[PingComp]`. On a client: `client swing=… verdict=…` per judged swing (now ending `recoil=` with the recoil it played), `client stagger=… type=… anim=…` and `client kill=…` for the player's own hits, `client stagger=…` or `client recoil=… ended: …` when the screen hands the enemy back to the host, with whether the host's echo arrived, and `client swing=… hit shown at once: estimate=…`. On the host: `host swing=… answer=… outcome=…` per answer, `host stagger=… applied=… moved=… timing=… speed=… lead=… length=…`, `host swing=… recoil=… moved=… ends_early_by=…`, and `host kill=…`. Every `/pingcomp` command typed is logged as `[PingComp] command …`.
