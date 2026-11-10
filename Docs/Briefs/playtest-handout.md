# Ping Compensation: playtest handout

For the other developer on the mod and for anyone playtesting it. This describes **build step 1**, made on 2026-11-10. It is updated whenever a new build changes what you see or what to test.

The full design is in [client-authoritative-melee.md](client-authoritative-melee.md). You don't need it to test.

## What the mod does now

In the normal game the host decides whether an enemy's swing hits you, using a picture of you that is out of date by your ping. That is why a block or dodge that looked fine on your screen can still fail.

This mod moves that decision to your own game. When an enemy's swing lands **on your screen**, your game checks whether you were in reach, whether the enemy was facing you and whether your block was up, then tells the host the result. The host accepts it.

On your own screen the mod also turns the enemy that is swinging at you, using the game's normal turning rules but your real position. Dodging still makes it lose track of you, as in the normal game.

## What changed from the previous version

The old version was "lag compensation": the host held each hit, asked your game what it saw, and still made the final call. All of that is gone.

- Your game now decides, and the host never overrules it.
- If your game sends no answer, the swing does nothing. There is no fallback to the host's opinion.
- `/ping_probe` is removed. The debug tools are now under `/pingcomp` (see below).
- Host and clients must run the same build. A different build is treated as "no mod".

## What is covered in this build

Covered, meaning judged on your screen:

- Slave rats, clan rats (with or without shields), marauders (with or without shields), fanatics, gors, ungors.
- The ordinary single swings of plague monks and savages.

Not covered yet. These behave exactly like the normal game:

- Plague monk and savage frenzy combos.
- Stormvermin, mauler, chaos warrior, bestigor and standard bearer sweeps, overheads and shoves.
- Monsters, lords and disablers (packmaster, assassin, leech).
- Anything aimed at the host's own hero, a bot, or a player without the mod.

## What to expect

- **Blocks and dodges count the way you saw them.** If your block was up when the swing landed on your screen, it is a block. If the swing missed you on your screen, it is a miss.
- **A landed hit is felt a moment late.** When a swing does hit you, the health loss, the grunt and the knockback arrive about one ping after the swing connects. This is known and intended for this build. The next build removes the delay. Your block's spark, sound and stamina cost are already instant.
- **The enemy's recoil after your block is also a moment late**, for the same reason.
- **Other players see your results a moment late.** On their screens a swing may pass through you and your health drops a beat later, or a swing that looked like a hit does nothing.
- **Backing away from a swing is easier than in the normal game**, more so with a high ping. We want to know whether it feels too easy.

## Before you play

1. Use the build Lance gives you. Everyone in the lobby who wants the mod, the host included, needs the same one. The host must have it, or nothing changes for anyone.
2. Once everyone is in the keep or a mission, type `/pingcomp version` in chat. Every player should show the same text in square brackets. `Mod not found.` means that player has no mod, has it switched off, or is on an older build.
3. Type `/pingcomp debug on`. Do this on every computer, once per game start. It resets when the game restarts or the mods are reloaded.

## Commands

All of them are typed into the game's chat.

| Command | What it does |
|---|---|
| `/pingcomp version` | Lists the build each connected player is running. Only you see the list. |
| `/pingcomp debug on` or `off` | Writes one line per judged swing into your console log. On the host it also shows a chat line when the host would have judged a swing differently, or when a client never answered. |
| `/pingcomp stats` | Shows totals since the mission started: swings judged, hits, blocks, misses and so on. |
| `/pingcomp facing on` or `off` | Clients only. Off makes the enemy turn the way the host says, as in the normal game, so you can compare. It starts on. |
| `/pingcomp mark <note>` | Writes a marker into your console log, for example `/pingcomp mark that rat hit me through my block`. |

## What to test

Any difficulty works. Champion or higher is best, because enemies track and commit to swings more. A higher ping makes every effect easier to see.

**As a client (not the host)**

1. **Late block.** Let a single clan rat or marauder swing at you and raise your block as late as you dare. If the block was up when the swing landed on your screen, it should always count.
2. **Dodge.** Dodge sideways or backwards just before a swing lands. If it missed you on your screen, you should take no damage.
3. **Take a hit on purpose.** Stand still. You should lose the usual amount of health, a moment after the swing connects.
4. **Parry.** Block within half a second of raising your guard. You should hear the parry sound, and anything on your build that triggers on a parry should trigger.
5. **Block from the side and behind.** A swing from outside your weapon's block arc should still be blocked but cost more stamina, as in the normal game.
6. **Interrupt the swing.** Push or stagger an enemy during its wind-up. That swing should do nothing.
7. **Walk backwards out of swings.** Tell us how easy it is compared with the normal game.
8. **Facing.** Watch how the enemy turns towards you during a swing, and whether it twitches when the swing ends. Then try a few fights with `/pingcomp facing off` and tell us which looks and plays better.
9. **A long horde fight.** Play normally for a few minutes. Look for hits that feel wrong in either direction, enemies that stop attacking, or anything that seems stuck.

**As the host**

10. **Watch a client being attacked.** Their blocks should show the block reaction, the enemy should recoil, and their health should only drop for hits. Each result appears about one ping late.
11. **Your own fights** should feel exactly like the normal game.
12. **A bot or a player without the mod** in the lobby should play exactly like the normal game.

**Everyone**

13. At the end of the mission, before you leave, type `/pingcomp stats`.
14. Anything that crashes, freezes or throws a red error message in chat is important. Note what you were doing.

## When something looks wrong

Type `/pingcomp mark` and a few words straight away, for example `/pingcomp mark blocked but took damage`. It puts a line in your log at that moment, which makes the problem much faster to find.

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
What felt wrong, and roughly when (or the text of your /pingcomp mark notes):
What felt better than the normal game:
```

**4. A video clip, if you can.** For "it looked wrong" moments a short recording is the most useful thing there is. It is optional.

The log only helps if `/pingcomp debug on` was typed before the fight. Without it the log still shows errors and crashes, but not the individual swings.

A note on privacy: the console log contains your Steam name and ID, your PC's hardware, and your Windows user folder name. Send it to Lance directly, not to a public channel.

## Known limits of this build

- A landed hit's results and the enemy's recoil arrive about one ping late (see "What to expect").
- Only the enemies listed under "What is covered" are judged on your screen.
- If your game freezes or your connection stalls for more than 4 seconds, the host treats you as having no mod until you are back.
- A few enemy types (ungor archers in melee) normally can't hit you without a clear line of sight. That rule is not applied to swings judged on your screen.
- If the mod hits repeated internal errors, it switches itself off until the next mission and says so in chat. The game carries on as normal. Please send the log if you see that message.

## For the developer

- The code lives in `scripts/mods/Ping Compensation/`: `Shared.lua` (constants, helpers, the error guard), `Geometry.lua` (the reach and facing maths), `Host.lua`, `Client.lua`, `Version.lua`, and `Ping Compensation.lua` (the shared damage-frame hook, the commands and the lifecycle).
- `CLAUDE.md` lists every hook with its file and line in the decompiled source, the network messages, and the rules for this repo.
- The message version is `VERSION = 5` in `Shared.lua`. Bump it whenever `pc_hello`, `pc_swing_begin` or `pc_swing_answer` changes.
- Build with `./build.bat < /dev/null` in Git Bash, or `.\build.bat` in PowerShell.
- Debug lines in the log start with `[PingComp]`. A client line reads `client swing=… verdict=… reason=… distance=… reach=… angle=… cone=… frozen=… facing=…`. A host line reads `host swing=… answer=… host_would=… outcome=… answer_after=… ping=…`.
