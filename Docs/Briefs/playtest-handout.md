# Ping Compensation: playtest handout

For the mod's developers and playtesters. This describes **build 3**, made on 2026-11-13. It is updated with every build that changes what you see or what to test.

The full design is in [client-authoritative-melee.md](client-authoritative-melee.md). It is not needed for testing.

## What the mod does

In the normal game the host decides whether an enemy's swing hits you, using a picture of you that is out of date by your ping. That is why a block or dodge that looked fine on your screen can still fail. It is also why, on someone else's game, everything you do to enemies shows up a moment late: their stagger, their death, their recoil from your block.

This mod moves those decisions to your own game. When an enemy's swing lands **on your screen**, your game checks whether you were in reach, whether the enemy was facing you and whether your block was up, then tells the host the result. When **your** hit or blast lands on an enemy, your game works out whether it staggers or kills it, shows that at once, and tells the host. The host accepts both.

On your own screen the mod also turns the enemy that is swinging at you, using the game's normal turning rules but your real position. Dodging still makes it lose track of you, as in the normal game.

## What changed in this build

Changes since build 2.2:

- **Frenzy combos are judged on your screen.** Every blow of a plague monk's, savage's or shielded stormvermin's frenzy now counts the way you saw it, as single swings already did.
- **Your hits decide staggers and kills on plague monks, savages and shielded stormvermin**, as they already did on trash.
- **Your explosions and area skills show their staggers and kills at once**: bombs, exploding projectiles such as fireballs, weapons whose hits explode, and career skills that make a blast, such as the Mercenary's shout and the Slayer's leap. This covers every enemy listed under "Shown on your screen at once".
- **The recoil after your block now plays at once, with the movement left to the host** (`recoil anim`), the setting both previous playtests preferred. `full` and `off` are still there to compare.
- **Staggers you cause play up to 3 times as fast on the host** (up from 1.5), so other players see far fewer of them cut short at the end. At the last playtest's ping almost none were.
- **Fixed: restarting a mission in the middle of a fight could crash the host's game.** The crash was in the game's own code: an enemy's swing landing while the restart was already under way. The mod now prevents it.
- **Fixed: on the host, a marauder's recoil after a client's block could last up to half a second too long**, because the host had measured that recoil's timing wrongly. Timings measured on earlier builds are discarded again, and built-in stagger timings for many more animations, shielded marauders among them, are added.

## What is covered in this build

Judged on your screen:

- Swings from slave rats, clan rats (with or without shields), marauders (with or without shields), fanatics, gors and ungors.
- The single swings and the frenzy combos of plague monks and savages.
- The frenzy combo of shielded stormvermin.

Shown on your screen at once:

- **Staggers and kills from your hits and blasts**, whatever caused them (melee, pushes, shield bashes, arrows, bolts, bullets, beams, career-skill charges and shots, bombs and other explosions, area career skills), on slave rats, clan rats and marauders (with or without shields), fanatics, gors, ungors, plague monks, savages and shielded stormvermin.
- **The recoil after your block**, for every single swing in the first list. A blocked frenzy blow has no recoil, in the normal game either.
- **Hit results** when any swing in the first list hits you: the health drop, damage indicator, flinch, rumble, hit sound and knockback.

Still exactly like the normal game, so a moment late when you aren't the host:

- Staggers and kills on elites other than shielded stormvermin, on specials, monsters and lords.
- Damage over time and lingering areas: burning, bleeding, poison, gas and fire patches.
- Explosions you didn't set off yourself, such as an enemy's bomb or a barrel.
- Elite sweeps, overheads and shoves, including the shielded stormvermin's.
- Monsters, lords and disablers (packmaster, assassin, leech).
- Anything aimed at the host's own hero, a bot, or a player without the mod.

## What to expect

- **Blocks and dodges count the way you saw them**, for frenzy blows too.
- **A plague monk's frenzy can pause for a moment at the end of a blow.** Its next blow depends on whether you blocked or were hit, so the host waits up to half a second for your game's answer before choosing it. Report it if the pause is noticeable.
- **An enemy you stagger reels back the instant your hit lands**, and its next move follows straight on. Plague monks, savages, shielded stormvermin, gors and ungors are the exception at first: their stagger lengths aren't built in yet, so until the host has measured them, a pause of about a ping can follow their staggers.
- **A light hit at the very start of a frenzy can break it.** Plague monks and savages ignore light staggers while frenzying, but your game only learns a frenzy has started a moment after the host. A stagger it shows in that moment counts.
- **An enemy you kill drops the instant your hit or blast lands.**
- **The enemy recoils the instant you block**, for as long as it would in the normal game.
- **A hit on you is felt at once.** The health bar shows an estimate straight away and settles on the host's exact number a moment later. A small jump in the bar when that happens is expected.
- **Other players see your staggers and kills a moment late.** On their screens an enemy you staggered may jump a short way, because it starts its stagger from where you saw it, and it staggers faster than normal.
- **Chained dodges wear out** after as many quick dodges as your weapon allows.
- **Backing away from a swing is easier than in the normal game**, more so with a high ping. Report whether it feels too easy.
- **With Deathwish on, your staggers follow Deathwish's rules**, once your game has switched its own Deathwish on, which it says in chat.
- **If your enemy data differs from the host's**, you get a warning in chat saying what differs, and your staggers and kills show a moment late, as in the normal game, until it matches. Blocks, dodges, recoils and hits on you still show at once.

## Before you play

1. Use the build you were given. Everyone in the lobby who wants the mod, the host included, needs the same one. The host must have it, or nothing changes for anyone.
2. Every player should run the same mods that change enemies or weapons. In the last playtest one client's enemy data differed from the host's for most of the session, so that client's staggers and kills fell back to the host. If you get the "enemy data differs" warning, compare your mod lists before you go on.
3. If the host plays with Deathwish, every player needs "Cata 3 & Deathwish" installed and enabled. Difficulty mods only need to be enabled; only the host switches Deathwish on, with `/deathwish` in the keep as usual. Onslaught needs nothing on clients.
4. Once everyone is in the keep or a mission, type `/pingcomp version` in chat. Every player should show the same text in square brackets and "Enemy data matches yours". `Mod not found.` means that player has no mod, has it switched off, or is on an older build.
5. Leave the debug log on. Playtest builds switch it on by default, and the mod remembers your choice, so if you ever turned it off with `/pingcomp debug off`, turn it back on with `/pingcomp debug on`.

## Commands

All of them are typed into the game's chat. Every switch goes back to its default when the game restarts.

| Command | What it does |
|---|---|
| `/pingcomp version` | Lists the build each connected player is running. Only you see the list. |
| `/pingcomp debug on` or `off` | Writes one line per judged swing, stagger, kill, recoil, blast and timing into your console log. On by default in playtest builds, and remembered between games. |
| `/pingcomp echo on` or `off` | Host only. Also shows a chat line when the host would have judged a swing differently, or when a client never answered. Off by default. |
| `/pingcomp stats` | Shows totals since the mission started: swings judged, hits, blocks, your staggers, kills and blasts, and so on. |
| `/pingcomp timings` | Writes every stagger and recoil timing your game knows to your console log. |
| `/pingcomp attacks on` or `off` | Clients only. On, the default, shows your staggers and kills at once. Off leaves them to the host, a moment late, as in step 1.1. |
| `/pingcomp recoil anim`, `full` or `off` | Clients only. The enemy's recoil after your block. `anim`, the default, plays the animation at once and moves the enemy where the host has it. `full` also plays its movement at once. `off` waits for the host, as in step 1.1. |
| `/pingcomp predict on` or `off` | Clients only. On, the default, shows a hit on you at once. Off waits for the host, as in step 1.1. |
| `/pingcomp stagger speed`, `end` or `off` | Host only. How the host shortens a stagger a client caused, so that client sees no pause after it. `speed`, the default, plays it faster. `end` cuts it short instead. `off` leaves it its full length, so the client sees a pause. |
| `/pingcomp combowait on` or `off` | Host only. On, the default, a plague monk's frenzy waits up to half a second for the client's answer before choosing its next blow. Off chooses at once, from the host's older picture of the client's block. |
| `/pingcomp dodgecount on` or `off` | Clients only. On, the default, applies your weapon's dodge count, as the game always has for the host. Off ignores it, as the normal game does for clients. |
| `/pingcomp facing on` or `off` | Clients only. Leave it on. Off is only for comparing and makes you much harder to hit than in the normal game. |
| `/pingcomp mark <note>` | Writes a marker into your console log, for example `/pingcomp mark that rat hit me through my block`. |

## What to test

Any difficulty works. Champion or higher is best, because enemies track and commit to swings more. A higher ping makes every effect easier to see. Play at least one mission where beastmen appear: the last playtest had none, so gors and ungors are still untested.

**As a client (not the host)**

1. **Frenzy combos.** Block, dodge and back away from plague monk, savage and shielded stormvermin frenzies. Every blow should count the way you saw it. Does a monk's frenzy pause noticeably between blows?
2. **Stagger and kill monks, savages and shielded stormvermin.** Push and hit them, during their frenzies and outside them. Light hits shouldn't break a frenzy once it is under way; heavy hits and pushes should, as in the normal game. Do they react the moment your hit lands, and is there a jump when the host's version catches up?
3. **Blasts.** Throw bombs into trash, shoot exploding projectiles, and use area career skills such as the Mercenary's shout or the Slayer's leap. Staggers and kills should show the instant the blast goes off. Look for enemies at the edge of a blast that react twice, late, or not at all.
4. **Push, attack and kill trash**, as before. Do enemies reel back or drop the moment your hit lands? Does any enemy you saw die keep fighting, get back up, or die twice?
5. **After the stagger.** Once a stagger you caused ends, does the enemy carry straight on, or stand still for a moment first? Only the enemies named under "What to expect" should pause, and only in your first fights.
6. **Block recoil.** Block single swings from every trash enemy you meet, a marauder ten or more times in a row. No recoil should end early. If one does, type `/pingcomp mark` at once. Then compare `/pingcomp recoil full` and `/pingcomp recoil off`, and report which one setting felt best. Go back to `anim` afterwards.
7. **Shields.** Push and hit shielded clan rats, marauders and stormvermin, from the front and from behind. A hit taken on the shield should knock them back but do no damage.
8. **Horde.** Push-attack and cleave through a horde for a few minutes. Look for enemies that freeze, slide, jump back to an earlier spot, or play a stagger twice.
9. **Take a hit on purpose**, from a single swing and from a frenzy blow. You should lose health, flinch and feel the knockback at once.
10. **Chained back dodges with a shield.** Most shields allow only 2 quick dodges. Dodge backwards several times in a row away from a swinging enemy, then try the same with `/pingcomp dodgecount off`, and report which felt right. Turn it back on afterwards.

**As the host**

11. **Watch a client fighting.** Their staggers, kills, blasts and the recoils from their blocks should look normal, if a moment late. Staggers they cause play faster on your screen, now up to 3 times as fast; report it if that looks wrong. Note any enemy that jumps a long way, freezes, or dies without being hit.
12. **Compare the frenzy wait.** While a client fights a plague monk, try `/pingcomp combowait off` and ask whether the frenzy felt different. Go back to `on` afterwards.
13. **Restart a mission in the middle of a fight**, with the command or mod you normally use for it. The game should not crash.
14. **Your own fights**, and a bot or a player without the mod, should play exactly like the normal game.

**Everyone**

15. At the end of the mission, before you leave, type `/pingcomp stats` and then `/pingcomp timings`. The mod also writes both to the log when a mission ends or the game closes normally, but not when the game is closed with Alt+F4, so type them anyway.
16. At least once, close the game normally from the menu right after a mission ends, and send that log.
17. **Deathwish.** With Deathwish on, every client should see in chat that Deathwish was switched on for them too, and `/pingcomp version` should show "Enemy data matches yours" for every player. No player, host or client, should see an "enemy data differs" warning when the host switches Deathwish on.
18. Anything that crashes, freezes or throws a red error message in chat is important. Note what you were doing.

## When something looks wrong

Type `/pingcomp mark` and a few words straight away, for example `/pingcomp mark rat staggered twice`. It puts a line in your log at that moment, which makes the problem much faster to find.

## What to send back

**Every player sends this, clients as well as the host.** The host's log shows what the host did; only a client's log shows what that client saw, which is most of what this build changes. The last playtest's client logs never arrived, so several of its questions are still open.

**1. Your console log.**

- Press `Win + R`, paste `%APPDATA%\Fatshark\Vermintide 2\console_logs` and press Enter.
- The game writes one file per launch, named like `console-2026-11-10-19.30.12-….log`. The date and time in the name are in UTC, so sort the folder by "Date modified" and take the newest one, or the one from the session you are reporting.
- If you restarted the game during the session, send every file from that session.
- The files are 1 to 10 MB each. Zip them if you like.
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
Did blocks and dodges against frenzy combos count the way you saw them?
Did a plague monk's frenzy pause noticeably between blows?
Did staggers and kills from your hits and blasts feel instant? Anything odd about them?
Did enemies pause after your staggers or recoils? Which enemies?
Did any recoil end early, so the enemy came straight back at you?
Which one recoil setting felt best (anim, full or off)?
Host only: did faster staggers look wrong? Did combowait off feel different?
Host only: did restarting a mission mid-fight work?
Did you try dodgecount off with a shield? Which felt right?
What felt wrong, and roughly when (or the text of your /pingcomp mark notes):
What felt better than the normal game:
```

**4. A video clip, if you can.** For "it looked wrong" moments a short recording is the most useful thing there is. It is optional.

The log is most useful with the debug log on, which is the default. Without it the log still shows errors, crashes and the summary written at the end of each mission, but not the individual swings.

A note on privacy: the console log contains your Steam name and ID, your PC's hardware, and your Windows user folder name. Send it directly to the developers, not to a public channel.

## Known limits of this build

- After a stagger you caused on a plague monk, savage, shielded stormvermin, gor, ungor or shielded marauder, the enemy can pause briefly in your first fights, until the host has measured those stagger animations.
- After you block a fanatic, gor, ungor, plague monk or savage, the enemy can stay in its recoil a little longer than normal, until the host has measured that recoil animation.
- A blast is worked out on your game and on the host's from slightly different pictures of where the enemies are. An enemy right at the edge that only the host's blast reached gets the host's stagger, a moment late.
- Elites other than shielded stormvermin, specials, monsters and lords, damage over time and lingering areas still work as in the normal game (see "What is covered").
- Your game's damage reckoning doesn't include every damage bonus the host knows about. When it falls short, a kill shows a moment late, as in the normal game. When it overshoots, the enemy dies anyway: the host finishes it off and credits you.
- How hard an enemy is already staggered by other players' hits is only partly known to your game, so your stagger can come out slightly different from what the host would have chosen. Yours is the one that counts.
- If your game freezes or your connection stalls for more than 4 seconds, the host treats you as having no mod until you are back.
- Difficulty mods other than Deathwish that change enemies, such as Dutch Spice, aren't supported yet. With one of them, the enemy data check leaves your staggers and kills to the host.
- Weapon balance mods must be the same on every player's game, because your game works out your hits with its own weapon data. This isn't checked.
- A few enemy types (ungor archers in melee) normally can't hit you without a clear line of sight. That rule is not applied to swings judged on your screen.
- If the mod hits repeated internal errors, it switches itself off until the next mission and says so in chat. The game carries on as normal. Please send the log if you see that message.

## For developers

- The code lives in `scripts/mods/Ping Compensation/`: `Shared.lua` (constants, switches, helpers, the error guard), `Geometry.lua` (the reach and facing maths), `Host.lua` (announcing and booking swings, and the frenzy wait), `HostReactions.lua` (applying a client's staggers, kills and recoils, and shortening a client's stagger), `Client.lua` (judging swings and frenzy blows), `Reactions.lua` (the client's own staggers, kills and recoils, and the host's echo), `Blasts.lua` (the client's own explosions and area skills, on both sides), `HitResults.lua` (instant results of a hit on you), `Timings.lua`, `Compat.lua` (difficulty mods and the enemy-data check), `Version.lua`, and `Ping Compensation.lua` (the shared animation-event hook, the commands and the lifecycle).
- Each game keeps the stagger lengths and recoil timings it has measured in the mod's saved settings, under `stagger_lengths_2` and `recoil_cues_3`, and uses them before the built-in ones in `Timings.lua`. Older builds used `stagger_lengths`, `recoil_cues` and `recoil_cues_2`, which are no longer read.
- `CLAUDE.md` lists every hook with its file and line in the decompiled source, the network messages, and the rules for this repo.
- The message version is `VERSION = 8` in `Shared.lua`. Build 3 adds the frenzy step to `pc_swing_begin` and a new message, `pc_blast`, so it can't play with 2.2 or earlier.
- Build with `./build.bat < /dev/null` in Git Bash, or `.\build.bat` in PowerShell.
- Debug lines in the log start with `[PingComp]`. On a client: `client swing=… verdict=…` per judged swing (`attack=frenzy_attack/attack_2` for a frenzy blow), `client stagger=… type=… anim=…` and `client kill=…` for the player's own hits, `client blast template=… enemies=… kills=…` per blast, `client stagger=…` or `client recoil=… ended: …` when the screen hands the enemy back to the host, and `client swing=… hit shown at once: estimate=…`. On the host: `host swing=… answer=… outcome=…` per answer (with `combo_wait=` when a frenzy waited for it), `host stagger=… applied=… timing=… speed=… lead=… length=…`, `host stagger=… speed asked=… reached=…` when a sped-up stagger reaches its end, `host swing=… recoil=…`, `host blast template=… staggered … enemies itself`, `host skipped stagger enemy=… profile=… no client stagger or kill followed`, and `host kill=…`. On both: `timing length …` and `timing cue …` per measurement, ending `ignored` for a reading taken for a stray cue, and `enemy data breed=… enemy=… actions=…`, one line per enemy type, so two players' logs show which enemies' data differ. Every `/pingcomp` command typed is logged as `[PingComp] command …`.
