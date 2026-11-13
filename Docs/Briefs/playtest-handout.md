# Ping Compensation: playtest handout

For the mod's developers and playtesters. This describes **build 3.1**, made on 2026-11-13. It is updated with every build that changes what you see or what to test.

## What the mod does

In the normal game the host decides whether an enemy's swing hits you, and what your hits do to enemies, from a picture of you that is a ping out of date. This mod makes those decisions on your own screen: a block or dodge counts the way you saw it, and your staggers, kills and the recoil after your block show the instant they happen. The host accepts your game's results.

**Trash** in this handout means every enemy that isn't an elite, special or boss: slave rats, clan rats and marauders (with or without shields), fanatics, gors and ungors.

## What's new in build 3.1

- **Fixed: a client's game could crash** when the host's voice line for an enemy arrived after that enemy had died on the client's screen.
- **Fixed: big blasts.** A shout reaching around 90 enemies showed nothing early, because its list of enemies was too long for one message, and its staggers reached the host one message per enemy, so some came late and played twice. Both now travel in a few messages.
- **New: bombs and other exploding projectiles**, such as fireballs, show their staggers and kills at once.
- **Changed: staggers you cause on Chaos enemies** (marauders with or without shields, fanatics, savages) end early on the host instead of being played faster, because their animations can't be sped up. On your screen the enemy's next move follows straight on; other players see the end of the stagger cut short. Skaven staggers are still played faster.
- **Built-in stagger timings for savages and plague monks**, so their staggers are shortened from your first fight.
- **More detail in the logs**, on why recoils end and on staggers against plague monks and savages.

## Before you play

1. Everyone who wants the mod uses the same build, the host included. Without it on the host, nothing changes for anyone.
2. Every player runs the same mods that change enemies or weapons. With Deathwish, every player needs "Cata 3 & Deathwish" enabled, and only the host switches it on.
3. In the keep, type `/pingcomp version`. Every player should show the same text in square brackets and "Enemy data matches yours".
4. Leave the debug log on. It is on by default in playtest builds.

## What to test

Play Champion or higher, at least one mission mostly against Chaos (Righteous Stand is one), and if you can, one with beastmen, which no playtest has had yet. Whenever something looks wrong, type `/pingcomp mark` and a few words at once, for example `/pingcomp mark marauder recoil ended early`. It puts a line in your log at that moment.

1. **Block recoils on trash** (clients). Block single swings from marauders, fanatics and clan rats for a few minutes with each recoil setting in turn: `/pingcomp recoil anim` (the default), then `full`, then `off`, then back to `anim`. Mark any recoil that ends early, with the enemy coming straight back at you. Only after trying all three, say which felt best.
2. **After your staggers** (clients). Push and hit marauders, fanatics and savages, and watch the moment each stagger ends. The enemy should carry straight on. Mark any pause, with the enemy's name.
3. **Bombs and area skills** (clients). Throw a bomb at your feet and another into a horde, shoot exploding projectiles if your career has them, and use area career skills, such as the Mercenary's shout into a big horde. Staggers and kills should show the instant the blast goes off. Mark any enemy that reacts late, twice or not at all.
4. **Plague monks and savages** (clients). Block, dodge, push and hit them during their frenzies and outside them. Mark any pause between a monk's blows, and any hit that should have staggered one of them but didn't.
5. **Watching others** (host, and clients near another player). Watch the staggers and recoils other players cause, Chaos enemies above all. Mark any enemy that jumps, slides, freezes or reacts twice.

## What to send back

Every player sends these, clients as well as the host. The host's log shows what the host did; only a client's log shows what that client saw.

1. **Your console log.** Press `Win + R`, paste `%APPDATA%\Fatshark\Vermintide 2\console_logs` and press Enter. The game writes one file per launch: sort by "Date modified" and send every file from the session. On Linux or Steam Deck the folder is `steamapps/compatdata/552500/pfx/drive_c/users/steamuser/AppData/Roaming/Fatshark/Vermintide 2/console_logs`.
2. **If the game crashed**, say what you were doing, and send the newest file in `%APPDATA%\Fatshark\Vermintide 2\crash_dumps`.
3. **The form below.** The log already records your ping, build, role, switches and every judged swing, so the form only asks what the log can't show.
4. **A video clip**, if you can, for anything that looked wrong.

The console log contains your Steam name and ID, your PC's hardware and your Windows user name. Send it to the developers directly, not to a public channel.

## The form

Fill in your section only. Give each problem its own lines, with the enemy and roughly when, rather than one answer for all enemies.

```
EVERYONE
Name in game:
Career and melee weapon:
Each problem (copy these four lines for every one):
  What happened:
  Which enemy:
  Roughly when (the time, or what you were doing):
  Marked with /pingcomp mark? (yes/no)

CLIENTS ONLY (skip if you hosted)
Recoil setting that felt best, after trying anim, full and off, and why:
Recoils that ended early (which enemy, roughly when):
Enemies that paused after your stagger (which enemy, roughly when):
Blasts that showed late, twice or not at all (which bomb or skill, which enemy):
Pauses between a plague monk's blows (roughly when):

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
| `/pingcomp debug on` or `off` | The per-event lines in your log. On by default in playtest builds; your choice is remembered. |
| `/pingcomp recoil anim`, `full` or `off` | Clients. The recoil after your block: `anim` (default) plays it at once, `full` its movement too, `off` waits for the host. |
| `/pingcomp attacks on` or `off` | Clients. Off leaves your staggers and kills to the host, a moment late. |
| `/pingcomp predict on` or `off` | Clients. Off waits for the host before showing a hit on you. |
| `/pingcomp dodgecount on` or `off` | Clients. On (default) applies your weapon's dodge count, as the game does for the host. |
| `/pingcomp facing on` or `off` | Clients. Leave it on; off makes you far harder to hit than in the normal game. |
| `/pingcomp stagger speed`, `end` or `off` | Host. How a client's stagger is shortened: `speed` (default) plays Skaven staggers faster and ends Chaos ones early, `end` ends all early, `off` leaves them full length. |
| `/pingcomp combowait on` or `off` | Host. On (default), a plague monk's frenzy waits up to half a second for the client's answer before its next blow. |
| `/pingcomp echo on` or `off` | Host. Also shows in chat when the host would have judged a swing differently. Off by default. |

## What is covered

- **Judged on your screen:** swings from trash, the single swings and frenzies of plague monks and savages, and the shielded stormvermin's frenzy.
- **Shown on your screen at once:** staggers and kills from your hits and blasts on trash, plague monks, savages and shielded stormvermin; the enemy's recoil after your block; the results of a hit on you.
- **Still as in the normal game**, so a moment late when you aren't the host: everything else, including other elites, specials, monsters, lords, disablers, elite sweeps and shoves, damage over time, and explosions you didn't set off.

## Known limits

- A fanatic's recoil can last a little longer than normal. How long it lasts depends on the swing you blocked, so the host waits for the animation instead of ending it early.
- Gors, ungors and shielded stormvermin have no built-in stagger timings yet, so a pause of about a ping can follow your staggers on them until the host has measured them.
- An enemy at the very edge of a blast that only the host's blast reached gets the host's stagger, a moment late.
- Your game's damage reckoning doesn't include every damage bonus the host knows about. A kill that falls short shows a moment late; one that overshoots is finished off by the host and credited to you.
- If your game freezes or your connection stalls for more than 4 seconds, the host treats you as having no mod until you are back.
- Difficulty mods other than Deathwish that change enemies, such as Dutch Spice, aren't supported: your staggers and kills then come from the host. Weapon balance mods must match on every player's game; that isn't checked.
- Ungor archers and bestigors normally can't hit you without a clear line of sight. Swings judged on your screen don't apply that rule.
- After repeated internal errors the mod switches itself off until the next mission and says so in chat. Send the log if you see that message.

**For developers:** the message version is 9 (`VERSION` in `Shared.lua`), so build 3.1 can't play with build 3 or earlier. `CLAUDE.md` lists every hook, message and log line, and the design brief's "Checking the build 3.1 playtest" says what to look for in the logs.
