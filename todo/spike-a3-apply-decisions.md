# Spike A3: apply the decisions, rerun the simulators

**Done Oct 5, 2026.** Findings: `DESIGN.md`, "Spike A3 findings". Tests: rules 25, dungeon 23, all passing.

Goal: put the decisions of Oct 4 and 5 into the engines and see how the numbers change. Started Oct 5, 2026. Decisions: `DESIGN.md` (decision log, "Rule readings", reading 8).

## Rules (`rules/`)
- [x] `XP_PER_ZERO_HD` is 0 (reading 2)
- [x] Crits come only from the attacker's roll (reading 6); remove the defender crit
- [x] Only a PC's own attack roll of 1 wears its weapon (reading 7)
- [x] Items: an inventory of named items with slot sizes (junk, weapon, armor, shield, Ammo, Supply, lost item); slots used derive from it
- [x] Equipment derives from the inventory (best weapon, best armor, any shield), so dropping gear removes its effect
- [x] Ammo (decision G): bows, crossbows and pistols need an Ammo item to shoot; after a fight in which the PC shot, a d6 of 1 leaves one shot, then the Ammo is removed; the blowpipe needs none
- [x] Echo Gecko paralysis (reading 8): `stun_call` returns the Turns lost (1d4) instead of rounds
- [x] More ranged NPCs (our own conversions: Blowpipe Imp, Crossbow Cultist), flagged as house content in `data.odin`
- [x] Only the pistol-wielding Eelfolk reload (an ability, not every ranged monster)
- [x] Tests for all of the above (property tests where it makes sense), and keep the mutation habit

## Delve engine (`dungeon/`)
- [x] Floor items instead of Loot only: drop and pick up are explicit round actions (`round_drop`, `round_pickup`), no auto pick-up
- [x] Gecko paralysis in a delve: the PC loses 1d4 Turns (torch burns, wanderer d6 each Turn), the stunning group becomes Neutral, a wanderer that arrives gets free hits on the helpless PC
- [x] Post-fight Ammo check when a fight ends
- [x] Ranged player shots require Ammo
- [x] Depth 2 and 3 rosters get more ranged monsters
- [x] Tests for drop, pick up, ammo, paralysis, rosters

## Simulators (`sim/`)
- [x] Kits carry Ammo with ranged weapons
- [x] Delve bot drop policy: drop junk to fit a seen lost item
- [x] Abstract fight sim: a stun ends the fight (survived, Turns lost)
- [x] Rerun both simulators and save `sim/results-*-v2.2.txt`
- [x] Compare against the Oct 4 results and record the findings in `DESIGN.md` and `LEARNINGS.md`

## Found while doing it (all fixed, with tests)
- [x] A `pick_up` that took a just-dropped junk item instead of the lost item sent the bot into an endless drop and pick-up loop (now lost items come first)
- [x] Bot loops must be capped (the drop loop hung the whole run when a drop failed)
- [x] Floor item records are reused after pickup, so drops cannot exhaust the array

## Wrap-up
- [x] All tests pass (rules and dungeon)
- [x] Update `CLAUDE.md` reusable parts and this checklist; tick `todo/README.md`
