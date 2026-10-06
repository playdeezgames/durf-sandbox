# Spike C: traps

Goal: add traps to the delve, with a way to detect and disable them. Planned; added Oct 5, 2026 at the product owner's request ("we will have to figure out how to detect/disable them later"). Not started, and the design questions below need decisions first.

## What the DURF 2.2 book gives us (it has no trap rules)
- A **Turn** (10 minutes) is the time "to search a dungeon room, pick a lock or do any other significant activity". So searching or disarming should cost a Turn, which burns torch and rolls the wanderer d6.
- **Saves and action rolls** are d20 + attribute over 15 (STR, DEX, WIL), with Buffs and Breaks, and Push for an extra Buff at the cost of Stress.
- **Direct Wounds** (damage that ignores Armor) exist: the Myconid's spores ("STR save or take 1 direct Wound"). The dragon's fire breath is "DEX save for half".
- The only trap in the book is a magic item, Rutglut's Magical Bear Trap (a thrown +1 bear trap: 4 damage and a pull). Not a dungeon trap.
- So traps, their damage, and detection are **our own design**, built from those parts. Credit and flag them as house content, as with the Blowpipe Imp and the Crossbow Cultist.

## Design decisions needed (ask the product owner one at a time)
- [ ] What traps do: damage (Armor or direct Wounds?), Stress, lost Turns, an alarm that wakes a room, a pit that drops you a level, a snare that holds you. Keep a short list to start (two or three).
- [ ] How you detect them: automatically on a roll when you step near, by an explicit search action that costs a Turn, by a tool (a 10' pole is a listed Supply item, "bag of caltrops", chalk), or by a monster or hireling.
- [ ] How you disarm or avoid them: a DEX or WIL action roll (with Push), spending a Supply, walking around, jumping, leaving them armed.
- [ ] Whether a hidden trap is always fair: a warning clue (bones, scorch marks, a different floor tile), a save to avoid, or purely luck. Permadeath means a trap that kills without a roll feels unfair; the book's "risky" tone argues for a save.
- [ ] How traps fit decision D (combat is a failure state; avoidance is the game): traps are another thing to avoid, so they should reward care (searching costs torch) and never be mandatory.
- [ ] Whether monsters trigger traps or avoid them (a trap as a way to hurt a chaser would be a new tool for the player).

## Engine (`dungeon/`), after the decisions
- [ ] A `Trap` record on the floor: position, kind, hidden or revealed, armed or disarmed
- [ ] Placement in generation: by depth, never in the start room, never blocking the only route home, always avoidable by some route or roll
- [ ] Triggering when the PC steps on one: the save or roll, then the effect, as events for the log
- [ ] Detection and disarming actions, costing the round's action and, if searching, a Turn
- [ ] Events: trap found, triggered, disarmed, saved
- [ ] Tests: connectivity with traps placed, determinism by seed, save odds, a Turn cost for searching, no trap in the start room

## Simulator (`sim/`)
- [ ] Bot detects and avoids traps by policy; measure deaths and time cost against torch pressure
- [ ] Rerun the delve report; check that survival and income stay in the range decided in A3 and L

## Game and rendering (`src/`)
- [ ] A key to search or disarm, shown in the intro and the HUD hints (generate hints from the key map)
- [ ] Draw hidden traps as nothing, revealed ones with a sprite and a glow, disarmed ones dimmed
- [ ] Log lines for every roll, within 33 characters
- [ ] Death screen names the trap

## Wrap-up
- [ ] Tests pass; update `DESIGN.md` (decision log and findings), `LEARNINGS.md`, `CLAUDE.md`
