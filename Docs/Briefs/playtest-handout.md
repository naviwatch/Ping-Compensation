# Ping Compensation: playtest handout

For the mod's developers and playtesters. This describes **build 4**, made on 2026-11-16. It is updated with every build that changes what you see or what to test.

## What the mod does

In the normal game the host decides whether an enemy's swing hits you, and what your hits do to enemies, from a picture of you that is a ping out of date. This mod makes those decisions on your own screen: a block or dodge counts the way you saw it, and your staggers, kills and the recoil after your block show the instant they happen. The host accepts your game's results.

**Trash** in this handout means slave rats, clan rats and marauders (with or without shields), fanatics, gors and ungors. **Elites** means stormvermin (with or without shields), maulers, Chaos warriors, bestigors, standard bearers and bulwarks.

## What's new in build 4

- **Fixed: the mod stopped working for clients mid-mission.** Whenever the host's game removed a bot, for example when a player took a bot's place, every client lost touch with the host until the next mission, and the game went back to normal for them. The build 3.2 playtest ran that way from its first seconds. Your game now reconnects by itself, and says in chat when it loses touch with the host and when it is back.
- **New: elites' sweeps, overheads and shoves are judged on your screen.** A sweep that reaches several players is judged on each player's own screen.
- **New: your hits decide elites' staggers and kills on your screen**, as for trash. Bulwarks' staggers still come from the host.
- **Build 3.2's tests carry over**, since that playtest couldn't run them.

## Before you play

1. Everyone who wants the mod uses the same build, the host included. Without it on the host, nothing changes for anyone.
2. Every player runs the same mods that change enemies or weapons. With Deathwish, every player needs "Cata 3 & Deathwish" enabled, and only the host switches it on.
3. In the keep, type `/pingcomp version`. Every player should show the same text in square brackets and "Enemy data matches yours".
4. Leave the debug log on. It is on by default in playtest builds.

## What to test

Play Champion or higher, at least one mission with beastmen and one mostly against Chaos (Righteous Stand is one). Whenever something looks wrong, type `/pingcomp mark` and a few words at once, for example `/pingcomp mark chaos warrior overhead hit me through my dodge`. It puts a line in your log at that moment.

1. **Elites' swings** (clients). Block and dodge the sweeps, overheads and shoves of every elite, and also get hit by some. Mark any swing that hit you after you dodged or blocked it on your screen, or missed when it looked like a hit.
2. **Two of you against one elite** (clients). Stand beside another player in front of an elite and block or dodge its sweep. Each of you should be judged by what your own screen showed.
3. **Elites' staggers and kills** (clients). Hit, push and kill elites, and watch the moment each stagger ends. The enemy should carry straight on. Mark any pause, with the enemy's name.
4. **Build 3.2's tests** (clients). Hit, push and block gors, ungors, shielded stormvermin, marauders, fanatics and savages, and mark any pause after a stagger. One player uses a melee weapon with the Opportunist trait (more push power against attacking enemies) on plague monks and savages while they attack, and marks any hit that should have staggered one but didn't.
5. **Losing touch** (clients). If chat says the mod lost touch with the host, mark it and note what had just happened, such as a player joining.
6. **Watching others** (host, and clients near another player). Watch the staggers and recoils other players cause. Mark any enemy that jumps, slides, freezes or reacts twice.

## What to send back

Every player sends these, clients as well as the host. The host's log shows what the host did; only a client's log shows what that client saw.

1. **Your console log.** Press `Win + R`, paste `%APPDATA%\Fatshark\Vermintide 2\console_logs` and press Enter. The game writes one file per launch: sort by "Date modified" and send every file from the session. On Linux or Steam Deck the folder is `steamapps/compatdata/552500/pfx/drive_c/users/steamuser/AppData/Roaming/Fatshark/Vermintide 2/console_logs`.
2. **If the game crashed**, say what you were doing, and send the newest file in `%APPDATA%\Fatshark\Vermintide 2\crash_dumps`.
3. **The form below.** The log already records your ping, build, role, switches, every judged swing and every timing, so the form only asks what the log can't show.
4. **A video clip**, if you can, for anything that looked wrong.

The console log contains your Steam name and ID, your PC's hardware and your Windows user name. Send it to the developers directly, not to a public channel.

## The form

Fill in your section only. Give each problem its own lines, with the enemy and roughly when, rather than one answer for all enemies.

```
EVERYONE
Name in game:
Career and melee weapon (and its trait):
Each problem (copy these four lines for every one):
  What happened:
  Which enemy:
  Roughly when (the time, or what you were doing):
  Marked with /pingcomp mark? (yes/no)

CLIENTS ONLY (skip if you hosted)
Elite swings that hit you through a dodge or block, or missed when they shouldn't have (which enemy, roughly when):
Enemies that paused after your stagger (which enemy, roughly when):
Recoils that ended too early or too late (which enemy, roughly when):
Hits on plague monks or savages that should have staggered them (roughly when):
Chat said the mod lost touch with the host (roughly when, what had just happened):

HOST ONLY (skip if you were a client)
Clients' staggers or recoils that looked wrong (which enemy, roughly when):
```

## Commands

Typed into the game's chat. Every switch goes back to its default when the game restarts, except `debug`.

| Command | What it does |
|---|---|
| `/pingcomp version` | Lists the build each connected player runs, and whether their enemy data matches yours. |
| `/pingcomp mark <note>` | Writes a marker into your console log. |
| `/pingcomp stats` | Totals since the mission started. Also written to the log when a mission ends. |
| `/pingcomp timings` | Writes the stagger and recoil timings your game knows to the log. |
| `/pingcomp missing` or `missing <enemy>` | What the timings still lack: each covered enemy and a line for the rest, or one enemy, such as `missing chaos_warrior`. |
| `/pingcomp debug on` or `off` | The per-event lines in your log. On by default in playtest builds; your choice is remembered. |
| `/pingcomp recoil anim`, `full` or `off` | Clients. The recoil after your block: `anim` (default) plays it at once, `full` its movement too, `off` waits for the host. |
| `/pingcomp attacks on` or `off` | Clients. Off leaves your staggers and kills to the host, a moment late. |
| `/pingcomp predict on` or `off` | Clients. Off waits for the host before showing a hit on you. |
| `/pingcomp dodgecount on` or `off` | Clients. On (default) applies your weapon's dodge count, as the game does for the host. |
| `/pingcomp facing on` or `off` | Clients. Leave it on; off makes you far harder to hit than in the normal game. |
| `/pingcomp stagger speed`, `end` or `off` | Host. How a client's stagger is shortened: `speed` (default) plays Skaven and ungor staggers faster and ends the others early, `end` ends all early, `off` leaves them full length. |
| `/pingcomp combowait on` or `off` | Host. On (default), a plague monk's frenzy waits up to half a second for the client's answer before its next blow. |
| `/pingcomp echo on` or `off` | Host. Also shows in chat when the host would have judged a swing differently. Off by default. |

## What is covered

- **Judged on your screen:** swings from trash, the single swings and frenzies of plague monks and savages, and elites' frenzies, sweeps, overheads and shoves.
- **Shown on your screen at once:** staggers and kills from your hits and blasts on trash, plague monks, savages and elites other than bulwarks; the enemy's recoil after your block; the results of a hit on you, with the knockback of a sweep or shove.
- **Still as in the normal game**, so a moment late when you aren't the host: everything else, including specials, disablers, monsters, lords, the bestigor's charge, the bulwark's running attacks and its staggers, damage over time, and explosions you didn't set off. Planned next: specials, then monsters and lords.

## Known limits

- A stagger or recoil whose timing isn't known yet (see the table below) can be followed by a pause of about a ping.
- No enemy's recoil can be played faster, so the host ends it early instead, and other players see its end cut short. The same goes for staggers on Chaos enemies, gors and shielded stormvermin.
- An enemy at the very edge of a blast that only the host's blast reached gets the host's stagger, a moment late.
- Your game's damage reckoning doesn't include every damage bonus the host knows about. A kill that falls short shows a moment late; one that overshoots is finished off by the host and credited to you.
- If your game freezes or your connection stalls for more than 4 seconds, the host treats you as having no mod until you are back. Chat tells you when that happens.
- Difficulty mods other than Deathwish that change enemies, such as Dutch Spice, aren't supported: your staggers and kills then come from the host. Weapon balance mods must match on every player's game; that isn't checked.
- When an elite's sweep or shove throws you or knocks you off balance, that part still comes from the host, a moment late. The hit and its knockback show at once.
- When an elite's sweep reaches you but is aimed at another player, your screen judges it with the elite facing the way the host shows it, which trails slightly.
- After repeated internal errors the mod switches itself off until the next mission and says so in chat. Send the log if you see that message.

## Timings collected so far

Every player's game times every enemy's staggers and recoils, so every playtest adds to this table. A stagger counts once its animation has a length, a recoil once it has a timing after at least one kind of swing. Enemies that share animations share their timings: slave rats, clan rats and ungors, and marauders, shielded marauders and fanatics.

<!-- tally start: written by Docs/rebuild_timings.py --handout -->
| Enemy | Staggers timed | Recoils timed |
|---|---|---|
| Bestigor | 7 of 34 | 2 of 2 |
| Chaos warrior | 3 of 21 | 1 of 1 |
| Clan rat | 47 of 74 | 3 of 3 |
| Fanatic | 52 of 83 | 1 of 1 |
| Gor | 22 of 36 | 2 of 2 |
| Marauder | 52 of 83 | 1 of 1 |
| Mauler | 7 of 83 | 2 of 2 |
| Mauler (tutorial) | 0 of 83 | 0 of 2 |
| Plague monk | 7 of 15 | 3 of 3 |
| Savage | 36 of 79 | 3 of 3 |
| Shielded clan rat | 40 of 74 | 3 of 3 |
| Shielded marauder | 56 of 86 | 1 of 1 |
| Shielded stormvermin | 10 of 33 | 2 of 2 |
| Slave rat | 47 of 74 | 3 of 3 |
| Standard bearer | 0 of 30 | 0 of 2 |
| Standard bearer (crater) | 0 of 30 | 0 of 2 |
| Stormvermin | 6 of 32 | 2 of 2 |
| Stormvermin patrol | 8 of 32 | 2 of 2 |
| Ungor | 47 of 83 | 3 of 3 |
| Other Skaven (14 types) | 0 of 330 | 0 of 5 |
| Other Chaos (17 types) | 0 of 309 | 0 of 4 |
| Other Beastmen (5 types) | 0 of 236 | 0 of 9 |
<!-- tally end -->

**For developers:** the message version is 12 (`VERSION` in `Shared.lua`), so build 4 can't play with build 3.2 or earlier. `CLAUDE.md` lists every hook, message and log line, and the design brief's "Checking the build 4 playtest" says what to look for in the logs.
