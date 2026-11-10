# Ping Compensation

The Ping Compensation mod for Vermintide 2. This folder is its own git repo, cloned into Vermintide Mod Builder's (VMB) `mods` folder as `Ping Compensation`: the folder name must match `Ping Compensation.mod`, or VMB can't build it. If your VMB folder has its own `CLAUDE.md`, two levels up, its rules apply here too: if they aren't in your context, read that file before doing anything else.

## Design (keep this current)
The full design, its numbered decisions, the roadmap and the deferred work are in [Docs/Briefs/client-authoritative-melee.md](Docs/Briefs/client-authoritative-melee.md). Read it before changing anything. The tester handout is [Docs/Briefs/playtest-handout.md](Docs/Briefs/playtest-handout.md); update it whenever a build changes what testers see or should test. Testers get it as a PDF, so rebuild `Docs/Briefs/playtest-handout.pdf` with `handout_pdf.bat` after every change to it.

- Goal: client-authoritative enemy melee. A swing aimed at a remote player is judged on that player's own screen, on the frame their copy of the enemy fires the damage animation event, from their live position, block and dodge. The host books whatever the client reports and never second-guesses it. It is PvE, so game feel beats fairness.
- Built so far: roadmap step 1, family A only. That is every attack run by `BTAttackAction` whose damage frame goes through the generic `anim_cb_damage`: slave rats, clan rats, marauders, fanatics, gors, ungors, and the non-frenzy swings of monks and savages. Frenzy combos, elite sweeps, overheads and shoves are vanilla again until their steps land. Monsters and lords (`breed.boss`) are always vanilla for now.
- Runs on: both.
  - Host (`Host.lua`): announces each swing to its target when the attack starts, skips its own hit test at its damage frame, and books the client's answer. A hit is booked with `AiUtils.damage_target`, so the unmodified damage code still runs. A block is shown to the other players and makes the enemy recoil.
  - Client (`Client.lua`): turns its copy of the enemy every frame by the game's own rules, judges at its damage frame, plays its own block at once, and answers.
  - Only remote human players whose client has said hello in the last 4 seconds are judged this way. Bots, the host's own hero and players without the mod stay vanilla. Host and client must have the same `VERSION` (in `Shared.lua`).
- Hit results are still confirmed by the host in step 1: a landed hit's HP drop, feedback and knockback, and the enemy's recoil after a block, arrive about one ping late. Step 2 (instant results) removes that.
- Silence is never a hit. The host books nothing until an answer arrives, and every answer counts for the 5 seconds the host remembers a swing. If a client's hello has expired by the host's damage frame, the host judges that one swing itself.
- Not copied from vanilla: the host's line-of-sight flag, which only a few breeds have (ungor archers, bestigors). A client-judged swing ignores it.
- Safety net: the two `mod:hook` handlers run everything except the original call through `pc.guard`, which catches errors. After 5 errors in one place the mod sets `pc.broken`: clients stop saying hello, the host stops announcing, and the game carries on with vanilla rules until the next mission.
- Settings: none, only the on/off toggle (`is_togglable`). Chat commands, all under `/pingcomp`:
  - `version` lists the build each connected player is running.
  - `debug on|off` writes one line per judged swing to the console log, prefixed `[PingComp]`. On the host, disagreements and unanswered swings also echo to chat.
  - `stats` prints totals since the mission started.
  - `facing on|off` switches the client-driven facing, to compare. Off means the hit test uses the host's facing as the client sees it.
  - `mark <note>` writes a marker line to the console log.
- Network messages (bump `VERSION` when any of these change):
  - `pc_hello` — client to host every second: `version`.
  - `pc_swing_begin` — host to the targeted client when an attack starts: `version, id, attacker_go_id, family, set_name, action_name, attack_anim, box_up, box_down, box_flat`. `family` is `"A"`. `set_name` and `action_name` find the attack in the client's own `BreedActions`. The three box numbers are only used by attacks flagged `use_box_range`, which no attack in the current game data is.
  - `pc_swing_answer` — client to host at its damage frame: `version, id, frame, result, multiplier, improved, direction, through_block, distance, angle`. `result` is `hit`, `blocked`, `miss`, `cut` (the swing never reached its damage frame on the client's screen) or `unjudged` (the client couldn't find the enemy or the attack). `multiplier, improved, direction` are the block values from `can_block`. `distance` and `angle` are only for the host's debug log.
- Version-report messages (these don't carry `VERSION`, so changing them doesn't need a bump). `/pingcomp version` runs for whoever types it, on host or client, and only they see the list. Anyone who doesn't answer within 3 seconds is listed as `Mod not found.`, which includes players with the mod disabled or on a build older than this command.
  - `pc_version_request` — from the player who typed the command to every other modded player: `request_id`.
  - `pc_version_reply` — back to that player: `request_id, version`.
- Build stamp: game Lua can't run git, so `build.bat` writes the commit and branch to `scripts/mods/Ping Compensation/BuildInfo.lua` (gitignored) before compiling and deletes it afterwards. `-dirty` after the commit means the build had uncommitted changes. A build made without `build.bat` reports `unknown`.

## Hooks
One line per hook, so they can be checked after game patches:
`Class.method` — file:line in the decompiled source — hook type — why.

Line numbers are from the [decompiled source](https://github.com/Aussiemon/Vermintide-2-Source-Code) at `93dea911` (game version 6.13.0).

- `BTAttackAction.enter` — `scripts/entity_system/systems/behaviour/nodes/bt_attack_action.lua:24` — `hook_safe` — Host, once per attack: announces the swing to the targeted client. In `Host.lua`.
- `AnimationSystem.animation_callback` — `scripts/entity_system/systems/animation/animation_system.lua:54` — `hook` — The core of the mod, in `Ping Compensation.lua`. It fires for every animation callback on every machine and only acts on `anim_cb_damage`. Client: judges the swing and answers. Host: lets vanilla run with its hit test switched off for that swing.
- `DamageUtils.check_distance` — `scripts/helpers/damage_utils.lua:2626` — `hook` — Host: returns false while a client-judged swing is at its damage frame, so vanilla stops before the block and the damage but after its own bookkeeping. In `Host.lua`.
- `LocomotionSystem.update` — `scripts/entity_system/systems/locomotion/locomotion_system.lua:185` — `hook_safe` — Client, every frame, only while a swing is open: runs the facing rules and sets the enemy's rotation after the engine has eased it towards the host's. In `Client.lua`.
- `AnimationSystem.rpc_anim_event` — `scripts/entity_system/systems/animation/animation_system.lua:358` — `hook_safe` — Client, per animation message: notices that the host changed an enemy's animation, which ends or interrupts an open swing. In `Client.lua`.
- `AnimationSystem.rpc_anim_event_variable_float` — `scripts/entity_system/systems/animation/animation_system.lua:292` — `hook_safe` — Same as `rpc_anim_event`; staggers arrive this way.

Not hooked, but a game patch here can break the mod:
- `AnimationCallbackTemplates.server.anim_cb_damage` — `scripts/entity_system/systems/animation/animation_callback_templates.lua:132` — relied on — Switching off the hit test only works because it calls `check_distance` after its bookkeeping and before the block and the damage.
- `DamageUtils.check_distance` and `DamageUtils.check_infront` — `scripts/helpers/damage_utils.lua:2626` and `:2666` — copied — `Geometry.lua` repeats their maths, because they read the host's blackboard and can't run on a client.
- `DamageUtils.check_block` — `scripts/helpers/damage_utils.lua:2697` — copied — `would_block` and `play_block` in `Client.lua` repeat its player half, and `book_block` in `Host.lua` repeats what it does on the host after a block.
- `BTAttackAction._handle_movement` and the dodge-window lookups in `BTAttackAction.enter` — `scripts/entity_system/systems/behaviour/nodes/bt_attack_action.lua:390` and `:102` — copied — `update_facing` and the `pc_swing_begin` handler in `Client.lua`.
- `GenericStatusExtension.can_block` and `blocked_attack` — `scripts/unit_extensions/generic/generic_status_extension.lua:537` and `:607` — called — On the client to decide and play the block, on the host to show it.
- `AiUtils.damage_target` — `scripts/unit_extensions/human/ai_player_unit/ai_utils.lua:258` — called — The host books a hit with it.
- `BTAttackAction.attack_success` and `attack_blocked` — `scripts/entity_system/systems/behaviour/nodes/bt_attack_action.lua:339` and `:357` — called — By the host when the answer arrives, if the enemy is still in that attack.
- `StatusSystem.rpc_player_blocked_attack` — `scripts/entity_system/systems/status/status_system.lua:466` — relied on — The host sends it to every client except the blocker.
- `LocomotionTemplates.AiHuskLocomotionExtension.update` — `scripts/entity_system/systems/locomotion/locomotion_templates_ai_husk.lua:35` — relied on — The engine call in it is what the facing override overrides.
- `ModManager.network_send` — `scripts/managers/mod/mod_manager.lua:593` — relied on — Clients reach each other through the host's relay here and in `rpc_mod_user_data`, which `/pingcomp version` needs.

## Commands
Run this from this folder.
- Build: `./build.bat < /dev/null` in Git Bash, or `.\build.bat` in PowerShell. Use this rather than calling `vmb build` directly, because it also writes the commit and branch that `/pingcomp version` reports. The output is saved to `build_log.txt`.
- Handout PDF: `./handout_pdf.bat < /dev/null` in Git Bash, or `.\handout_pdf.bat` in PowerShell. It turns `Docs/Briefs/playtest-handout.md` into `Docs/Briefs/playtest-handout.pdf` (gitignored) with `Docs/handout_to_html.py` and headless Edge or Chrome. It needs Python 3 and installs nothing. The converter only understands the Markdown the handout uses, so check the PDF after adding anything new to the handout, such as nested lists or images.

## Playtest logs
- Lance's own logs are in the game's `console_logs` folder (newest file = last session). Search them for `[PingComp]`.
- Logs sent in by other testers go in `TestLogs/` in this folder, which is gitignored because console logs contain Steam names and IDs. Read them from there. One subfolder per session keeps host and client logs together.
- A client line starts `[PingComp] client swing=` and a host line `[PingComp] host swing=`. The same swing has the same number in both logs, so a host log and a client log from one session can be matched line by line. `[PingComp] MARK` lines are testers' notes, and `[PingComp] ERROR` lines are caught errors.

## Rules for this repo
- Edit only files inside this folder.
- Don't commit or push. When a change works, suggest a one-line commit message.
- Never run `vmb upload`, `vmb publish` or `vmb create`. Workshop uploads are done by hand.
