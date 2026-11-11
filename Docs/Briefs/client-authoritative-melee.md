# Client-authoritative enemy melee

## Status

Design agreed with Lance on 2026-11-10 in a `/grill` session.

| Roadmap step | State |
|---|---|
| 1. Family A, the core | Built on 2026-11-10 and playtested twice by testers the same day (see "Playtest results"). It works. A fix build (step 1.1: D22 to D25) was made on 2026-11-11 and compiles; it has not been run in game yet. |
| 2. Instant results on A | Not started. Starts after step 1.1 has been playtested. |
| 3 to 5. Families B, C, D | Not started. Until they land, those attacks are vanilla. |

Lance chose to playtest step 1 on its own before step 2 goes on top.

`CLAUDE.md` describes the code as it is built. The handout for the other developer and for playtesters is [playtest-handout.md](playtest-handout.md).

## Goal

In Lance's words:

> Move the enemy melee attack hit detection and damage application to the clients themselves (make it entirely client authoritative), and that information is then sent to the host (server) to keep them and other connected players in sync. This should make the game feel very responsive for players regardless of their latency, so they can block and dodge attacks on their perspective without having to worry about latency causing them to fail those actions.

## Why vanilla feels bad at high ping

The host judges each swing on its own copy of the fight. What it knows about a remote player (position, block, dodge) is half a ping old, and that player sees the swing half a ping late. So a remote player has to block or dodge a full ping before the swing lands on their screen. Lance's test logs show pings of 150–340 ms.

## Principles

1. **As client-authoritative as possible.** Lance: "that's fine for a PvE experience since it prioritises game feel over 'fairness' to try and make latency almost a non-factor for connected clients."
2. **Trust the client.** Lance: "We trust the client's perspective and hit outcomes, we do not need to verify/validate it." The host accepts the result, passes it to the other players, and sends back any effects that follow from the damage.
3. **Use what the client already knows.** Lance: "If a client has access to information themselves, then we should use that instead of rely on the host."

## How one swing plays out

"Ping" is the round trip. Each direction takes about half a ping.

1. **Host.** The enemy's AI starts an attack on a remote modded player. The host tells that player a swing has begun: a swing id, which enemy, which attack, and the crowd scaling. The vanilla animation message goes out as usual.
2. **Client, half a ping later.** The swing starts on the player's screen. From here the client turns the enemy itself, by the game's own rules, from the player's live position and dodge.
3. **Host.** Its own copy reaches the damage frame. It does not judge. It only notes what it would have judged, for the debug log and the combo guess.
4. **Client.** Its copy reaches the damage frame. The client judges reach, facing and block from live state, applies the results on screen at once (from step 2 of the roadmap), and sends its answer.
5. **Host, about one ping after its own damage frame.** It books the hit through the normal damage code, or shows the block to the other players. Everyone else sees the result now.

## What runs where

| Part | Runs on |
|---|---|
| Choosing attacks, moving enemies, staggers, deaths | Host, as in vanilla |
| Announcing a swing to its target | Host |
| Turning the enemy during a swing, on the target's screen | Target's client |
| Judging the swing: reach, facing, block, dodge | Target's client |
| Instant results: feedback, knockback, HP-bar estimate, block recoil | Target's client |
| Booking damage, relaying blocks, knockdown and death | Host |
| Ending a predicted recoil early | Host |
| Bots, the host's own hero, players without the mod | Host, vanilla rules |

## Attack families

Each family has its own hit code in the game, so each needs its own client-side copy.

| | Family | Game node | Who |
|---|---|---|---|
| A | Single-target swings: reach plus a frontal cone | `BTAttackAction` | Slave rats, clan rats, marauders, fanatics, gors, ungors; the non-frenzy swings of monks and savages |
| B | Frenzy combos | `BTComboAttackAction` | Plague monks, savages, shielded stormvermin |
| C | Elite sweeps and overheads: a box in front of the enemy that can hit several players | `BTStormVerminAttackAction` | Stormvermin, maulers, chaos warriors, bestigors, standard bearers, bulwarks |
| D | Elite shoves, unblockable | `BTStormVerminPushAction` | Stormvermin, maulers, chaos warriors, bestigors, standard bearers |
| E | Monsters and lords: weapon sweeps tested over many frames, slams, charges, grabs | `BTMeleeOverlapAttackAction`, `BTMeleeSlamAction`, `BTChampionAttackAction`, `BTChargeAttackAction` | Rat ogre, stormfiend, chaos spawn, troll, minotaur, lords; also the bestigor charge and the bulwark's running attacks |
| F | Disablers | `BTPackMasterAttackAction`, `BTCrazyJumpAction` and others | Packmaster, assassin, leech |

## Roadmap

1. **Family A, the core.** The judge and bookkeeper split, client-driven facing, blocks judged on the client, `/pingcomp debug` and `stats`, the `facing` switch. Hit results are still confirmed by the host in this step, so they arrive a ping late. This step proves the foundation; it is not the feel we are aiming for.
2. **Instant results on A.** Hit feedback, knockback, HP-bar estimate, block recoil (animation and movement), and the host ending a predicted recoil early. The `predict` and `recoil` switches.
3. **Family B**, with the `combowait` switch.
4. **Family C.**
5. **Family D.**

Later, each in its own session: leading the enemy's position (T1), predicting knockdown and death (T2), family E (T3), family F (T4).

## Decisions

- **D1. The pivot.** Client-authoritative enemy melee replaces host-side lag compensation for remote modded players. Everything is redone; the existing hooks are only a starting point. `/ping_probe`, its samples and the `flow_callback_animation_callback` hook are removed.
- **D2. Trust.** The host books whatever the client reports without checking the outcome, then propagates it. It only checks that a message is well-formed and names a swing it announced to that player, because it needs the swing's record to know what to book.
- **D3. Use the client's own information.** The host sends only what the client cannot know: that a swing targets it, which attack the enemy chose, and the crowd scaling. Everything else comes from the client's own copy of the game data and its own live state: reach, cone, box size, damage, stamina cost, dodge windows, unblockable flags, recoil animations.
- **D4. Judging.** The targeted client judges each swing on the frame its own copy of the enemy fires the damage animation event, from its live position, block and dodge.
- **D5. The client's screen decides.** If the swing landed on that client's screen, it counts, whatever happened on the host, even if the enemy was interrupted or has died there. If it did not land on that screen (cut short, out of reach, blocked), it never counts.
- **D6. Silence is never a hit.** The host books nothing until an answer arrives. Every answer counts, however late, for the 5 s the host remembers a swing. There is no host fallback. A swing cut short on the client's screen is reported as such, so the stats can tell it from true silence. Hellos go out every 1 s and expire after 4 s, after which the host judges that player as vanilla.
- **D7. HP stays on the host.** The host books damage through the unmodified damage code and works out the booked number. Gromril, overcharge, shared pools, knockdown and death work as before and reach everyone.
- **D8. Scope.** The first version covers families A, B, C and D. C drops the old "no push, catapult or blocked damage" limit. Monsters and lords (E) stay fully vanilla until their own phase, so one fight never mixes rules. Disablers (F) come later, with their own grill.
- **D9. Build order.** As in the roadmap: A with host-confirmed results, then instant results on A, then B, C and D.
- **D10. Facing.** On the target's screen the mod turns the enemy every frame by the game's own rules, fed from live data, and the hit test uses that facing. The enemy's position stays the host's. The host and everyone else see the host's facing. When the swing ends or is interrupted, the enemy eases back to the host's facing.
- **D11. Instant results.** At the frame of impact the client applies hit feedback, knockback and launch, and an HP-bar estimate. The bar corrects only when the host's number differs. Going down and dying stay host-driven for now (T2).
- **D12. Blocks.** Judged on the client with the game's own block code, on live state: block raised, block arc from the real aim, parry window, stamina cost. Spark, sound, stamina and parry are instant. The host's stale view of the block is ignored. The host shows the block to the other players.
- **D13. Block recoil.** The client plays the enemy's recoil animation and its push-back movement at once and sends its animation choice with the answer. The host plays the same animation for everyone else. The client ignores the host's echo unless something else has changed that enemy's animation meanwhile. Later host events (stagger, death, a new swing) overwrite the client's copy. If "blocked" arrives after the enemy has started a new swing on the host, the host cancels that swing and makes the enemy recoil, unless it is dead or staggered.
- **D14. The host ends a predicted recoil one ping early.** It counts the recoil time from when its own copy of the swing landed, not from when the answer arrived. The enemy's next move then reaches the blocker just as their copy's recoil ends, and the enemy resumes on the host when it would have in vanilla.
- **D15. Combos.** The host waits up to 0.5 s for the answer before choosing the follow-up, then goes with its own guess. Damage and blocks always follow the answer. A switch compares this against not waiting.
- **D16. Trailing position.** Accepted for the first build (see T1).
- **D17. Debug tools.** Everything lives under `/pingcomp`; there is no settings menu.
  - `/pingcomp debug on|off`: one log line per judged swing on each machine. Lines go to the console log; only disagreements and unanswered swings echo to chat.
    - Client: enemy, attack, verdict and why (out of reach by how much, outside the cone by how many degrees, blocked in the arc or the outer arc, parry, hit), and whether a dodge had frozen the enemy's facing.
    - Host: what its own judgment would have been, the answer, how long the answer took.
  - `/pingcomp stats`: totals since the mission started. Swings judged, hits, blocks, misses, swings cut short, swings the host would have judged differently, unanswered swings per enemy type, average answer time.
  - Comparison switches. On your own client: `facing on|off`, `predict on|off`, `recoil off|anim|full`. On the host: `combowait on|off`.
  - `/pingcomp version` stays as it is.
- **D18. Compatibility.** Bots, the host's own hero and players without the mod keep vanilla behaviour. The hello handshake stays. Host and client must share `VERSION`, which goes to 5. The mod keeps its name and Workshop ID; only the description text changes.
- **D19. Records.** Decisions, TODOs and open questions live in this brief. `CLAUDE.md`'s Design and Hooks sections are rewritten only when the new code lands.
- **D20. Team handout.** When implementation begins, a separate brief is written for the other developer and for playtesters. It summarises what changed, the debug tools and options, and what to test, and it is updated with every step. It also tells testers on other computers which files, logs and details to send back to Lance, and where to find them.
- **D21. Step 1 is playtested on its own.** Lance: "If you think it's better to test step one separately from step two rather than implementing both into a build straight away then do that." It is, because prediction would hide judging mistakes.
- **D22. A stagger that reaches your screen first cuts the swing.** If the host's change of the enemy's animation (almost always a stagger) reaches the client before the swing's damage moment, the swing is cut at once. This replaces the step 1 behaviour of keeping it judgeable for 2 more seconds, which the playtests showed was wrong: the damage moment can still fire during the blend into the stagger, and 5 of 20 such swings were booked as hits on enemies already staggering on the player's screen. On the host a staggered enemy's damage moment does nothing. A swing that lands on your screen before you hear about the stagger still counts (D5).
- **D23. Your own push cancels the swing aimed at you, at once.** The push is detected on your machine; the client cuts the swing straight away instead of waiting a ping for the host's stagger. Lance: "This sounds good, you may implement this as well." Only your own pushes, only against swings aimed at you, and not when the enemy takes the push on its shield. The enemy still visibly staggers a ping later (T6).
- **D24. The player's attacks will be client-authoritative too.** Lance: "We want the game to be client authoritative and that includes the player's attacks as well, not just their defensive actions. We just started with the defensive actions since they have the most impact, but the end game is to make everything the client does feel as responsive as possible." Lance was happy to do it now or later; it is later (T6), because predicting an attack's kill or stagger means copying the host's damage and stagger maths onto the client, which needs its own test, and it pairs with showing the enemy's reaction at once in step 2.
- **D25. Clients get the weapon's dodge count by default.** Lance: "I think it would be fine to have this enabled by default so there's more parity between what a connected client experiences and a host." In vanilla the host's copy of a remote player never counts dodges, so every dodge a client makes is effective; the client judge now applies the count, as the game always has for the host's own hero. `/pingcomp dodgecount off` restores the vanilla client behaviour for comparison.

## Assumptions

Confirmed with the decision list.

- For box attacks (C), every modded player near the box judges for themselves. Only the enemy's actual target drives its facing.
- The client works out "unblockable" itself, and step 1 does. The attack's own flag is in the game data. For the grudge-mark "crushing blow" buff the client checks its own copy of the enemy. That buff looks like it is replicated to clients; this is checked in the first grudge-mark test, and only if it turns out to be missing does the host send that one flag.
- Step 1 feels laggy on hit results by design: a landed hit's HP drop, grunt, flinch and knockback arrive about one ping after the swing connects on screen. Blocks and dodges already work on the client's screen in step 1. Step 2 removes the delay.
- If the host turns the mod off mid-mission, swings in flight go back to the host's own judgment.
- A hit from an enemy whose body is already gone from the host is still booked, credited to that enemy type.
- The host still works out what it would have judged for every swing, for the debug comparison and the combo guess. It never applies that to a modded client.

## TODO (deferred)

- **T1. Lead the enemy's position on the client's screen.** Lance calls this "the 'real' solution" to enemies trailing the player's real position. Shift the enemy toward the player by its speed times the ping while it chases them, moving the real model. It is the first thing to try once family A is playable, behind a switch.
- **T2. Predict going down and dying on the client.** Lance: fine as host-driven "for the time being"; revisit in a later session.
- **T3. Family E:** monsters and lords.
- **T4. Family F:** disablers. Feasible with the same split, since the packmaster's hook and the assassin's pounce are both judged on the host against where it thinks the player is. It needs its own grill because the grab sequences are multi-step.
- **T5.** Draw the reach and cone on the ground for debugging, only if the text log is not enough.
- **T6. Make the player's own attacks and pushes land on their screen (D24).** Planned for step 2, alongside the block recoil: an attack that kills or staggers an enemy mid-swing at you cancels the swing at once, and the enemy visibly staggers or dies on your screen without waiting a ping. Facts so far: the game only predicts kills on the client for projectiles (`GenericHealthExtension.apply_client_predicted_damage`, used only by `player_projectile_unit_extension.lua`), so melee needs its own prediction of damage and stagger. Family A enemies mid-swing can't resist a stagger, because their stagger immunity only applies while they are already heavily staggered (`stagger_modifier_function` in their breed files). Testers on 2026-11-10 noticed that "pushes and attacks are still delayed" once blocks and dodges became instant.
- **Not planned:** guessing the enemy's next action on the client. The host's AI picks it from random rolls, cooldowns and slot positions the client does not have, and a wrong guess looks worse than a short idle.

## Open questions

None block implementation. These can only be settled in play:

- Does the combo wait cause a visible hitch at high ping? (D15)
- Does the predicted recoil movement slide when it hands back to the host's position? (D13, D14)
- Does trailing make retreating too easy? At 150–340 ms a player covers 0.45–1.0 m backpedalling or 0.6–1.4 m running in the one extra ping they now get. (D16, T1)
- Does the facing override twitch as it eases back? (D10)
- Does the grudge-mark "crushing blow" buff reach clients? (Assumptions)
- Does the weapon's dodge count feel fair for clients, now that they have it (D25)? The step 1.1 log shows each swing's dodge state, and `/pingcomp dodgecount off` gives the vanilla client behaviour to compare.
- Does a push now stop the swings it should, and is a swing that still visibly connects after your push (until the stagger arrives) confusing? (D23, T6)

Answered by the 2026-11-10 playtests:

- *Does the client ever see a swing as "cut short" when it wasn't?* No. 150 of 319 swings were cut short (45 because the enemy died, 105 because it was staggered), and the host's own copy never reached its damage moment in any of them.

One design question came up while building step 1 and is not decided:

- **The host's line-of-sight flag.** A few breeds have one (ungor archers and bestigors among them), and vanilla skips their damage when it is false. A client-judged swing ignores it for now. Decide by step 4, when the bestigor's attacks arrive: copy the check on the client, or leave it out.

## Blueprint and asset work

None. The mod is Lua only.

## Messages

The exact fields are listed in `CLAUDE.md`. Any change to them bumps `VERSION`, which step 1 set to 5.

- `pc_hello`, client to host every second.
- `pc_swing_begin`, host to the target. Step 2 adds the crowd scaling for the HP estimate. Step 4 sends it to every modded player near a box attack.
- `pc_swing_answer`, client to host at its damage frame. Step 2 adds the recoil animation chosen when blocked.
- The version-report messages for `/pingcomp version` are unchanged.

## Step 1 notes

Things settled while building step 1 that the grill did not cover. None of them changes a decision.

- **Two extra results.** Besides hit, blocked and miss, a client can answer `cut` (the swing never reached its damage frame on its screen) and `unjudged` (it could not find the enemy or the attack in its own data). Neither books anything. Both show up in the host's stats, so a client that can't judge is visible instead of silently immune.
- **When "cut short" is sent.** At once if the enemy dies, starts a new swing, has its animation changed by the host (D22), or is pushed by the player (D23). In step 1 an animation change kept the swing judgeable for 2 more seconds; the playtests showed that was wrong, and step 1.1 removed it. A damage event that still fires within 2 seconds of a cut is logged and counted, not judged.
- **A client that goes quiet mid-swing.** If the target's hello has expired by the time the host's copy reaches the damage frame, the host judges that one swing itself and ignores a late answer for it. This is the only case where the host judges a swing it announced.
- **A hit whose attacker is gone.** The host uses the real attacker while it still has the network id it started the swing with, which covers an enemy that has just died. After that it books the damage with the victim standing in as the attacker unit and the enemy's type as the damage source, which is what the game does for damage whose attacker has gone.
- **Finding the attack on the client.** An enemy's attack table does not always live under its own breed name (a stormvermin commander uses the plain stormvermin's set), so the host sends the name of the set as well as the name of the attack.
- **Safety net.** Both `mod:hook` handlers run through a guard that catches errors. After 5 errors in one place the mod switches itself off until the next mission: clients stop saying hello, the host stops announcing, and vanilla rules apply.
- **`/pingcomp mark <note>`** was added so a tester can drop a line into their log at the moment something looked wrong.
- **Box-range attacks.** The game code supports attacks with a box-shaped reach test (`use_box_range`), but no attack in the current data uses it. The maths is copied anyway.

## Playtest results

### Step 1, 2026-11-10

Two sessions run by testers without Lance, on The Screaming Bell at Cataclysm 3 with Onslaught-style difficulty mods. The same host both times: one client in session 1, two in session 2. Logs are in `TestLogs/2026-11-10-testers/` and `TestLogs/2026-11-10-testers-2/` (gitignored).

- **Plumbing.** 319 swings were announced and every one was answered, in 0.21–0.24 s on average, matching pings of 213–247 ms. No errors from the mod, no rejected or ignored answers, and the host never had to judge a swing itself.
- **Judging.** On the 138 swings both sides judged with the client's facing on, the host's own judgement (vanilla) would have hit the players 48 times; they took 25. Of vanilla's 48: 11 were blocked late on the player's screen, 11 were dodged on it, and 7 missed because the player was further away or off to the side on their own screen. The players took 6 hits vanilla wouldn't have: 3 after dropping their block on their screen while the host still saw it up, 3 where they were closer than the host thought. Every disagreement had an explanation of that kind.
- **Data.** The reach values the clients used match the unmodded game data (slave rat 3.0, clan rat 3.1, marauder 3.5, fanatic 3.25), so the different difficulty mods on each machine didn't change them.
- **Cut short.** See the answered open question. Most of the 105 staggers were the testers' own pushes and hits.
- **Judged after a stagger.** 20 swings were judged after the client had already received the stagger; 5 were booked as hits. Fixed by D22.
- **`/pingcomp facing off`.** With it off for 30 s, all 7 swings missed, 5 of which the host would have landed. Off is far more forgiving than vanilla, not "the normal game".
- **Commands.** Two testers got the usage message three times. Step 1.1 accepts any capitalisation, names an unknown word and logs every command.

Tester feedback (session 2):

- "Everything defensive related is way more responsive, block and dodges, whilst pushes and attack are still delayed." (GK, Bretonnian longsword, 220 ms)
- "You can for sure dodge and block attacks you normally couldnt on trash enemies." (Mercenary, mace and shield, 230 ms)
- "When you push attack it seemed the trash enemies would still hit your guard even after a push. You would still get guard broken when pushing attacking." Two causes: the D22 bug, and a push in the last ping before a swing lands can't stop it in time. That deadline is the same as vanilla's, but it stands out next to instant blocks. D23 addresses it.
- "Possibly back dodges on trash enemies not working." The client judge applied the weapon's dodge count, which vanilla never applies to clients (D25). 6 of that tester's 14 hits landed within 0.25 m of the enemy's maximum reach, the margin an effective dodge buys. The step 1 log couldn't show whether they were dodging; step 1.1 logs it.

## Game facts the design rests on

Line numbers are from the decompiled source at `93dea911` (game version 6.13.0), paths under `scripts/`.

**Judging on the host today**
- `AnimationCallbackTemplates.server.anim_cb_damage` — `entity_system/systems/animation/animation_callback_templates.lua:132` — family A's damage frame: line of sight, reach, cone, block, then damage.
- `DamageUtils.check_distance`, `check_infront`, `check_block` — `helpers/damage_utils.lua:2626`, `:2666`, `:2697`. The first two read host-only AI state, so the client needs its own copy of that maths (`Geometry.lua` already has one). `check_block` runs on a client without sending anything.
- `BTComboAttackAction.anim_cb_frenzy_damage` — `entity_system/systems/behaviour/nodes/bt_combo_attack_action.lua:524` — family B.
- `BTStormVerminAttackAction.anim_cb_damage` — `entity_system/systems/behaviour/nodes/storm_vermin/bt_storm_vermin_attack_action.lua:374` — family C's box test.
- `BTStormVerminPushAction.anim_cb_stormvermin_push` — `entity_system/systems/behaviour/nodes/storm_vermin/bt_storm_vermin_push_action.lua:99` — family D.

**The client can judge**
- Damage animation events fire on clients for enemy copies: `AnimationSystem.animation_callback` — `entity_system/systems/animation/animation_system.lua:54`. Lance's client log of 2026-11-09 shows them for stormvermin and maulers.
- Every attack table carries its own name (`settings/breeds.lua:139`), so the host can name an attack and the client can look it up in its own `BreedActions`. Animation names alone do not identify an attack: `attack_pounce` is shared by several.
- Block and dodge state already belong to the client in vanilla: `GenericStatusExtension.set_is_dodging` (`unit_extensions/generic/generic_status_extension.lua:2556`), `can_block` (`:537`), `blocked_attack` (`:607`), and the parry window set in `unit_extensions/weapons/actions/action_block.lua:45`.
- The slot extension exists only on the host (`network/unit_extension_templates.lua:57` and `:104`), so crowd scaling has to be sent.

**Turning rules to copy**
- Family A: `BTAttackAction._handle_movement` — `entity_system/systems/behaviour/nodes/bt_attack_action.lua:390`. The enemy faces where the target was at the start, starts tracking after the dodge-window delay, and an effective dodge within 4 m freezes its facing for the window duration. On Champion and up: 0.25 s delay and 0.5 s freeze for a normal swing, 0.75 s and 0.75 s for a running one (`settings/breeds/breed_tweaks.lua:1041` and `:1075`). While frozen, the cone narrows from 30° to about 18° either side and the reach bonus shrinks from 1 m to 0.75 m (0.5 m for clan rats).
- Family B: `BTComboAttackAction._update_rotation_target` — `bt_combo_attack_action.lua:411`. Continuous tracking; on a dodge it aims at the last position for 0.3 s and the turn speed drops from 20 to 2.
- Family C: `BTStormVerminAttackAction.attack` — `bt_storm_vermin_attack_action.lua:349`. It tracks for the attack's `rotation_time` and stops for good on a dodge.
- Family D: `BTStormVerminPushAction.attack` — `bt_storm_vermin_push_action.lua:88`. It tracks the whole time.
- On clients, enemy facing comes from the host's `yaw_rot` field, eased each frame by engine code called from `LocomotionTemplates.AiHuskLocomotionExtension.update` — `entity_system/systems/locomotion/locomotion_templates_ai_husk.lua:35`. Overriding it means setting the rotation after that update every frame.

**Damage and HP**
- The host creates each remote player's health object (`unit_extensions/default_player_unit/player_unit_health_extension.lua:72`) and only the host writes HP (`:780`). Clients learn of a hit from `rpc_add_damage` (`:837`, handled in `entity_system/systems/damage/health_system.lua:368`), which is also where hit feedback plays.
- `AiUtils.damage_target` — `unit_extensions/human/ai_player_unit/ai_utils.lua:258`. `DamageUtils.apply_buffs_to_damage` — `helpers/damage_utils.lua:2134`, called only on the host (`:1790`). It is where Gromril is consumed, damage becomes overcharge and shared pools split damage.

**Block recoil**
- `BTBlockedAction.enter` — `entity_system/systems/behaviour/nodes/bt_blocked_action.lua:13`. One animation, set by the attack or picked at random from the breed's list, with animation-driven push-back. Duration from `breed_tweaks.lua:621`: 1.0–1.2 s on Champion, 0.75–1.0 s on Legend, 0.5–0.75 s on Cataclysm.
- On clients the push-back is a teleport at the start plus the host's velocity applied each frame (`LocomotionSystem.rpc_set_animation_driven_movement` — `entity_system/systems/locomotion/locomotion_system.lua:287`, and `locomotion_templates_ai_husk.lua:209`).
- Attacks flagged `no_block_stagger` have no recoil.

**Networking**
- `ModManager.network_send` — `managers/mod/mod_manager.lua:593`. Mod messages are engine RPCs relayed through the host.
- `StatusSystem.rpc_player_blocked_attack` — `entity_system/systems/status/status_system.lua:466`. The host relays a block to the other clients.

**Disablers, for T4**
- `BTPackMasterAttackAction.attack_success` — `entity_system/systems/behaviour/nodes/bt_pack_master_attack_action.lua:110`. One check at one frame: dodge angle, distance, line of sight.
- `BTCrazyJumpAction.check_colliding_players` — `entity_system/systems/behaviour/nodes/bt_crazy_jump_action.lua:415`. A 1 m sphere test on every frame of the leap.

## Other research

- **Can the client own its HP?** No. The host creates the health object, ownership never moves (the migration callbacks are stubs), and every other damage and heal source writes the host's copy. Prediction (D11) gives the feel without it.
- **The Darktide "Latency Compensation" mod** (Nexus Mods, Darktide mod 702, by Quantum). Client-only, because Darktide's servers cannot be modded. It does not move enemies or shift animations. It draws where a disabler will be by the time the player's input reaches the server: velocity times full ping along a nav path it computes itself, guessing the target. We are better placed because our host runs the mod. Its position-lead idea is T1.
- **Shifting or slowing animations.** No supported way was found in the game's Lua to start an animation partway through. The only speed control found is the `stagger_scale` variable used for stagger animations (`bt_stagger_action.lua:76`); whether recoil animations respond to it is untested. D14 avoids needing it.
