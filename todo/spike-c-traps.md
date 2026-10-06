# Spike C: traps

Goal: add traps to the delve, with a way to detect and disable them. Added Oct 5, 2026 at the product owner's request. Design decided Oct 6; **built Oct 6** (engine, simulator, game), awaiting the product owner's playtest.

## What the DURF 2.2 book gives us (it has no trap rules)
- A **Turn** (10 minutes) is the time "to search a dungeon room, pick a lock or do any other significant activity". So searching or disarming should cost a Turn, which burns torch and rolls the wanderer d6.
- **Saves and action rolls** are d20 + attribute over 15 (STR, DEX, WIL), with Buffs and Breaks, and Push for an extra Buff at the cost of Stress.
- **Direct Wounds** (damage that ignores Armor) exist: the Myconid's spores ("STR save or take 1 direct Wound"). The dragon's fire breath is "DEX save for half".
- The only trap in the book is a magic item, Rutglut's Magical Bear Trap (a thrown +1 bear trap: 4 damage and a pull). Not a dungeon trap.
- So traps, their damage, and detection are **our own design**, built from those parts. Credit and flag them as house content, as with the Blowpipe Imp and the Crossbow Cultist.

## Design decisions needed (ask the product owner one at a time)
- [x] What traps do (decided Oct 6): **all four** effects, one trap kind each: a **dart/pit** (1 direct Wound; no save, see Fairness), a **snare** (1d4 lost Turns), an **alarm** (the nearest monster group hunts you whatever its Reaction), and a **mess** (Stress that takes bag slots until rest). Numbers go in `rules/data.odin` as house content.
- [x] How you detect them (decided Oct 6): **search action plus visible clues**. A hidden trap leaves a clue on a nearby tile (bones, scorch marks, an odd floor tile); the search key (costs a Turn, so torch and wanderer die) rolls to reveal traps nearby. Still to settle: the roll, the search radius, and how clues are drawn.
- [x] How you disarm or avoid them (decided Oct 6): a revealed trap stays on the map; **walk around it, or spend the action to disarm with a DEX roll** (d20 + DEX over 15, Push allowed); a failed disarm triggers it. Disarmed traps stay safe. Placement must therefore keep a route around, or accept a roll.
- [x] Fairness (decided Oct 6): **no save; clues are the defence.** Stepping on an unrevealed trap always triggers it, so the dart/pit no longer has a DEX save (it is 1 direct Wound, automatic). Consequence to design for: a clue must sit near every trap, readable and consistent, and a trap's damage must be low enough that permadeath doesn't feel cheap (check in the simulator).
- [x] Fit with decision D (resolved by the above): traps are another thing to avoid; searching costs torch, a route around must exist, they are never mandatory.
- [x] Monsters (decided Oct 6): **hunting monsters trigger traps** they step on. Wound trap: 1 direct Wound to the monster; snare: it loses 1d4 Turns of action (like the gecko stun, here as rounds); alarm: wakes the nearest other group; mess: no effect on monsters. A known trap is a tool for leading a chaser over it. Wanderers and neutrals do not trigger.

## Engine (`dungeon/`), after the decisions
- [x] A `Trap` record on the floor: position, kind, hidden or revealed, armed or disarmed
- [x] Placement in generation: by depth, never in the start room, never blocking the only route home, always avoidable by some route or roll
- [x] Triggering when the PC steps on one: the save or roll, then the effect, as events for the log
- [x] Detection and disarming actions, costing the round's action and, if searching, a Turn
- [x] Events: trap found, triggered, disarmed, saved
- [x] Tests: connectivity with traps placed, determinism by seed, save odds, a Turn cost for searching, no trap in the start room

## Simulator (`sim/`)
- [x] Bot detects and avoids traps by policy; measure deaths and time cost against torch pressure
- [x] Rerun the delve report; check that survival and income stay in the range decided in A3 and L

## Game and rendering (`src/`)
- [x] A key to search or disarm, shown in the intro and the HUD hints (generate hints from the key map)
- [x] Draw hidden traps as nothing, revealed ones with a sprite and a glow, disarmed ones dimmed
- [x] Log lines for every roll, within 33 characters
- [x] Death screen names the trap

## Wrap-up
- [x] Tests pass (rules 25, dungeon 47, src 16); `DESIGN.md`, `LEARNINGS.md` and `CLAUDE.md` updated
- [x] First playtest (Oct 6): clue far too obvious (fixed), trap worked (got gooed)
- [ ] Second look: is the faint clue now too easy to miss, is searching worth a Turn, is a failed disarm fair
- [ ] A search roll was NOT added (decided by the builder, flagged): a search always reveals traps within 4 tiles. Ask whether it should roll (WIL or DEX over 15) instead
- [x] Clue made subtle after the playtest (Oct 6): faint stain, only within 3 tiles and in torchlight
- [ ] Trap sprites are stand-ins (a spatter for the clue, an iron grate for a found trap); one clue sprite for all four kinds
- [ ] Clues only warn within 2 tiles of a trap; consider giving each kind its own clue (the table in `rules/data.odin` already names them)
