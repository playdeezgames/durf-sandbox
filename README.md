# durf-sandbox

A practice project for [DURF Jam 6](https://itch.io/jam/durf-jam-6) (Oct 14 to Nov 14, 2026, theme "Lost & Found"). It adapts the tabletop RPG [DURF](https://emielboven.itch.io/durf) by Emiel Boven (CC-BY 4.0) into a browser CRPG, to find out what works before the real jam entry. Nothing here ships.

Working title: "Lost & Found of SPLORR!!". You work at a Lost Property Office and go down dungeons to recover lost items. Under DURF's own XP rule (1 XP per gold piece of treasure brought back safely), the way to get ahead is to return what is lost and survive the walk home.

## Status

Design phase, with two prototype spikes done (no graphics yet):

- `rules/`: a pure Odin DURF v2.2 rules engine (dice, Buffs and Breaks, opposed combat, Stress and slots, damage and HD death, morale, reaction, XP, character creation). 16 native tests.
- `dungeon/`: a seeded delve engine (floors, sight, Reaction on sight, chase and flee, the Turn clock and torch, wandering monsters, loot against the slot limit). 15 native tests.
- `sim/`: bots that play thousands of fights and whole delves. Results are in `sim/results-*.txt`.

Read `DESIGN.md` for the design, the decisions made so far and the findings, and `LEARNINGS.md` for lessons for the jam. `CLAUDE.md` is the guide for Claude Code sessions, including a future jam session that references this project.

## Commands

Needs the Odin compiler (the nightly at `/home/yermom/ODIN/odin` was used).

```bash
odin test rules -define:ODIN_TEST_THREADS=1 -out:/tmp/rules_test
odin test dungeon -define:ODIN_TEST_THREADS=1 -out:/tmp/dungeon_test
odin build sim -o:speed -out:/tmp/sim && /tmp/sim fights 4000   # abstract fights
/tmp/sim delves 400                                              # whole delves (about a minute)
```

## Credits

- DURF by Emiel Boven, CC-BY 4.0: https://emielboven.itch.io/durf
- Art (`assets/tileset.png`): the Urizen 1-bit tileset by vurmux, CC0: https://vurmux.itch.io/urizen-onebit-tileset
- Code written with Claude Code (Claude Sonnet 5.5), directed by the product owner.

The DURF rulebook PDFs used as reference are kept locally and are not part of this repository.
