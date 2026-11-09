# Ping Compensation

The Ping Compensation mod for Vermintide 2. This folder is its own git repo, cloned into Vermintide Mod Builder's (VMB) `mods` folder as `Ping Compensation`: the folder name must match `Ping Compensation.mod`, or VMB can't build it. If your VMB folder has its own `CLAUDE.md`, two levels up, its rules apply here too: if they aren't in your context, read that file before doing anything else.

## Design (keep this current)
- Goal: Experimental lag compensation for enemy melee against remote players. When an attack reaches its damage moment, the host holds the hit, waits for what the targeted client saw at that moment, then applies or drops the hit based on the client's view. The wait is `ping * 1.5 + 0.05` seconds, clamped to 0.1–0.75. If the client doesn't answer in time, the host's original decision stands. Covers `BTAttackAction`, `BTComboAttackAction` (including frenzy swings) and `BTStormVerminAttackAction` area attacks with no push, catapult or blocked damage.
- Runs on: both. The host decides and applies damage; the client only reports what it saw. Host and client must have the same `VERSION` (in `Main.lua`). Only remote human players whose client has said hello in the last 8 seconds are compensated. Bots, the host's own player and unmodded clients get vanilla behaviour.
- Settings: none, only the on/off toggle (`is_togglable`). Chat commands: `/ping_probe start|stop|report` records up to 50 attack samples for debugging, and `/pingcomp version` lists the build each connected player is running.
- Network messages (bump `VERSION` when any of these change):
  - `pc_melee_hello` — client to host every 2 seconds: `version`.
  - `pc_melee_begin` — host to the targeted client when an attack starts: `version, id, attacker_id, target_id, window_start, window_duration, kind`, plus `range, height, width, offset_up, offset_forward` for area attacks.
  - `pc_melee_observation` — client to host at the damage callback: `version, id, attacker_id, target_id, dx, dy, dz, fx, fy, dodging, locked, area_hit, callback_index`.
- Version-report messages (these don't carry `VERSION`, so changing them doesn't need a bump). `/pingcomp version` runs for whoever types it, on host or client, and only they see the list. Anyone who doesn't answer within 3 seconds is listed as `Mod not found.`, which includes players with the mod disabled or on a build older than this command.
  - `pc_version_request` — from the player who typed the command to every other modded player: `request_id`.
  - `pc_version_reply` — back to that player: `request_id, version`.
- Build stamp: game Lua can't run git, so `build.bat` writes the commit and branch to `scripts/mods/Ping Compensation/BuildInfo.lua` (gitignored) before compiling and deletes it afterwards. `-dirty` after the commit means the build had uncommitted changes. A build made without `build.bat` reports `unknown`.

## Hooks
One line per hook, so they can be checked after game patches:
`Class.method` — file:line in the decompiled source — hook type — why.

Line numbers are from the [decompiled source](https://github.com/Aussiemon/Vermintide-2-Source-Code) at `93dea911` (game version 6.13.0).

- `BTAttackAction.enter` — `scripts/entity_system/systems/behaviour/nodes/bt_attack_action.lua:24` — `hook_safe` — Host: tells the targeted client that a normal melee attack has started.
- `BTComboAttackAction._start_attack` — `scripts/entity_system/systems/behaviour/nodes/bt_combo_attack_action.lua:150` — `hook_safe` — Host: same announcement for each swing, because one combo node can run several.
- `BTStormVerminAttackAction.enter` — `scripts/entity_system/systems/behaviour/nodes/storm_vermin/bt_storm_vermin_attack_action.lua:21` — `hook_safe` — Host: announces eligible area attacks and their hitbox to every remote modded player.
- `DamageUtils.check_distance` — `scripts/helpers/damage_utils.lua:2626` — `hook` — Returns true during a captured callback so vanilla code reaches the damage call. `Geometry.lua` repeats this math, so change both together.
- `DamageUtils.check_infront` — `scripts/helpers/damage_utils.lua:2666` — `hook` — Same as `check_distance`, for the facing check, and also repeated in `Geometry.lua`.
- `DamageUtils.check_block` — `scripts/helpers/damage_utils.lua:2697` — `hook` — Records the host's block result for each area-attack target. The result isn't changed.
- `AiUtils.damage_target` — `scripts/unit_extensions/human/ai_player_unit/ai_utils.lua:258` — `hook` — Captures the damage instead of applying it, so it can be applied or dropped once the client has answered.
- `BTAttackAction.attack_success` — `scripts/entity_system/systems/behaviour/nodes/bt_attack_action.lua:339` — `hook` — Delayed along with the damage, so hit reactions only play if the hit lands.
- `BTComboAttackAction.attack_success` — `scripts/entity_system/systems/behaviour/nodes/bt_combo_attack_action.lua:397` — `hook` — Delayed along with the damage. It also sets `successful_hit`, which picks the next swing.
- `BTComboAttackAction.anim_cb_frenzy_damage` — `scripts/entity_system/systems/behaviour/nodes/bt_combo_attack_action.lua:524` — `hook` — Captures the frenzy swing so it can be re-run when the hit resolves.
- `BTComboAttackAction.run` — `scripts/entity_system/systems/behaviour/nodes/bt_combo_attack_action.lua:279` — `hook` — Keeps the combo running while a swing's hit is pending, so it can't move on first.
- `AnimationSystem.animation_callback` — `scripts/entity_system/systems/animation/animation_system.lua:54` — `hook` — The core of the mod. Client: sends its observation. Host: runs the vanilla callback under capture and queues the result.
- `flow_callback_animation_callback` — `scripts/flow/flow_callbacks.lua:27` — `hook_safe` — Diagnostics only: records samples for `/ping_probe`.

Not hooked, but a game patch here can break the mod:
- `AnimationCallbackTemplates.server.anim_cb_damage` — `scripts/entity_system/systems/animation/animation_callback_templates.lua:132` — relied on — The capture depends on its order: distance, facing, block, `damage_target`, `attack_success`.
- `BTStormVerminAttackAction.anim_cb_damage` — `scripts/entity_system/systems/behaviour/nodes/storm_vermin/bt_storm_vermin_attack_action.lua:374` — copied — `client_area_attack_hit` in `Main.lua` repeats its hitbox query on the client.
- `ModManager.network_send` — `scripts/managers/mod/mod_manager.lua:593` — relied on — Clients reach each other through the host's relay here and in `rpc_mod_user_data`, which `/pingcomp version` needs.

## Commands
Run this from this folder.
- Build: `./build.bat < /dev/null` in Git Bash, or `.\build.bat` in PowerShell. Use this rather than calling `vmb build` directly, because it also writes the commit and branch that `/pingcomp version` reports. The output is saved to `build_log.txt`.

## Rules for this repo
- Edit only files inside this folder.
- Don't commit or push. When a change works, suggest a one-line commit message.
- Never run `vmb upload`, `vmb publish` or `vmb create`. Workshop uploads are done by hand.
