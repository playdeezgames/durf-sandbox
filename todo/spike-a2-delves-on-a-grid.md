# Spike A2: delve engine and delve bot

Goal: model retreat with real distance and see whether a careful player can survive a floor. Done Oct 4, 2026. Findings: `DESIGN.md`, "Spike A2 findings".

- [x] `dungeon/`: seeded floor generation (rooms, corridors, loops), depth rosters, loot
- [x] Line of sight (Bresenham), BFS distance fields
- [x] Reaction roll on first sight; Hostile and Unfriendly hunt, the rest are Neutral
- [x] Monsters act: a move plus an action, second move, ranged shots with reload, stun call
- [x] Equal-speed retreat (book-faithful, decision C), with tests
- [x] Turn clock (10 tiles of travel), torch, wandering monsters
- [x] Morale; fled monsters run away; swap places with Neutral monsters; bump-attack blockers
- [x] Loot against the slot limit; exit by the stairs
- [x] Native tests (15), including generation connectivity over 900 floors
- [x] `sim/delve.odin`: delve bot with four policies and a `debug` timeout dump
- [x] Fix engine bugs the bot found (blocking monsters, stuck clock, 1-room spawner)
- [x] Save results to `sim/results-delves-v2.2.txt`
- [x] Record findings in `DESIGN.md` and `LEARNINGS.md`
