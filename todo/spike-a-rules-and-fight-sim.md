# Spike A: rules engine and abstract fight simulator

Goal: find out whether DURF's numbers are survivable, and produce the first reusable code. Done Oct 4, 2026. Findings: `DESIGN.md`, "Spike A findings".

- [x] Read the DURF 2.2 rulebook and write the rules digest
- [x] `rules/data.odin`: every rule number in one data table
- [x] `rules/rules.odin`: seeded RNG, action roll, Buffs and Breaks, opposed rolls
- [x] Push and Stress against inventory slots
- [x] Damage: Armor, shield, Wounds, HD death roll (sum of HD dice)
- [x] Crit, worn weapon, morale, reaction, initiative
- [x] XP, HD advancement, rest, character creation (d3 attributes, d40 belongings)
- [x] Native tests, including property tests over thousands of seeded rolls (16)
- [x] Mutation check: change the DC and see tests fail
- [x] `sim/main.odin`: abstract fight simulator over monsters, kits and policies
- [x] Sensitivity run: one exchange per round versus two
- [x] Record findings in `DESIGN.md` and `LEARNINGS.md`
- [x] Save results to `sim/results-fights-v2.2.txt`
