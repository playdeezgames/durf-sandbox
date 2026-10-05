# Learnings (practice for DURF Jam 6)

A running log of what to reuse or avoid in the real jam. Newest at the bottom.

## Setup (Oct 4, 2026)

- Jam page (fetched with WebFetch): Oct 14 to Nov 14, theme "Lost & Found", **No AI art**, DURF-related content required, 2021 rules or Expanded both fine. The jam page lists nothing about judging.
- DURF is CC-BY 4.0: credit Emiel Boven. `pdftotext -layout` extracts the rulebook cleanly (12 pages). The sheet PDFs are just forms.
- Reusable stack and scaffolding: copy `build.sh`, `.gitignore`, `web/index.html` from `/home/yermom/git/tggd_jamference2/`. The vault at `/home/yermom/git/bok-of-splorr/splorr/` has the Odin wasm recipe and the Urizen tile coordinates; `Gotchas.md` is required reading.
- `tools/sheet.py c0 c1 r0 r1 out.png` makes a labelled contact sheet of a tileset region. The `(col,row)` label sits **above** its tile. Finding sprites by eye costs a lot of time, so for the jam record every tile used in a table as you go, and decide the cast from the monster roster *before* hunting tiles.
- The people section of Urizen (columns 104+) is a grid of 26 poses by about 28 colour rows (colour = species-ish: orange goblin-ish, red horned, teal, dark green, beige skeleton, blue and so on), which suits a cast of many humanoids.
- DURF's itch page (https://emielboven.itch.io/durf) is at **v2.4**; the PDF we first had is v2.2. Always check the source page's version before reading the rules into a design. The page also offers an online rules reference, a character generator, an editable Google Doc, a companion adventure ("The Lair of the Gobbler") and a "DURF Collection" of third-party content.
- The DURF Collection (https://itch.io/c/1888615/durf-collection, 29 entries) is the user's second source. Third-party entries are inspiration only: each has its own license, so check before reusing monsters, items or spells. It includes two digital solo games (The Rise of Nudroth, The Liminal Sanctum) and mentions "DURF Expanded" as a separate ruleset.
- `durf-reference/` is user-supplied and git-ignored: never commit it.
- Scope decision: the practice uses the **core rules**; the jam may reconsider (for example DURF Expanded). The jam project is expected to reference this repo, so `CLAUDE.md` carries a handoff section and a "reusable parts" table.
- Process: the user wants **design and planning first**, prototype spikes are allowed. Write `DESIGN.md` with open questions before coding.
- Decision 1 (death): permadeath, full restart. Consequences (short runs, instant character creation, bot-proven fairness, hirelings as buffer, seeds on the game-over screen) are written up in `DESIGN.md`. Decisions are being made one at a time, in the order of the open questions list.
- Decision 2 (delve shape): one floor per delve, depth chosen at the stairs (1 to 3 in practice). Short trips and a clear return beat; easy to balance with a bot.
- Decision 3 (hirelings): milestone 4, one at a time; solo loop first. Balance the solo game at depth 1 first.
- Decision 4 (title): undecided on purpose; use the placeholder and keep it in one constant/string so renaming is one edit.
- Decision 5 (ending): the last claim is the player's own name tag. Claims are a data table (name, owner, depth, value) so the story is content, not code.
- Decision 6 (first spike): Spike A, a rules engine with native tests plus a text-mode combat simulator, before any rendering.
- Decision 8 (rules version): build on 2.2, with all rule numbers in one data table so a later 2.4 diff is cheap. Lesson: when the source text may be out of date, isolate the numbers behind data from day one.
- Decision 9 / prior-art pass (Oct 4): *The Rise of Nudroth* (2022) and *The Liminal Sanctum* (2025) are **print-and-play, not digital**; a fetch summary of the collection had called them digital. Always open the page before repeating a summary's claim. Their pages give no mechanics, only pitches. Takeaways for us:
  - A **browser CRPG is rare** in a jam of mostly printed TTRPG content, which helps stand out; the cost is that "tangentially related to DURF" should be obvious (show the d20 rolls, Buffs, Stress and slots on screen).
  - Nudroth runs on a **clock** ("before Midnight"). Our torch (6 turns) and wandering-encounter d6 are a DURF-native clock; a hard deadline per delve is optional, not required.
  - Liminal Sanctum offers **powers with a price** (souls) and "very quick leveling". Under permadeath, a short run wants fast levelling; DURF's 1000 x HD XP would need big treasure values (see rule readings). A priced power-up is a cheap content idea (it could cost a slot or HD).
  - The Liminal Sanctum's page states "No generative AI was used". The jam community cares about this, so the jam page must disclose Claude's role clearly (code only) and the art must be human-made.

## Spike A: rules engine and simulator (Oct 4)

- **What was built:** `rules/` (package `rules`, 16 native tests) and `sim/` (a combat bot). About 500 lines of Odin, working first time after one compile fix. Full findings are in `DESIGN.md` ("Spike A findings").
- **Biggest learning:** DURF's combat is brutal for a solo 1 HD character (a goose kills the starting PC 18 percent of the time; the best starting kit still dies 40 percent to a Myconid). So a solo CRPG must make *avoiding* fights the main verb (Reaction, Morale, retreat, stealth, "outsmarting" XP). Measure this early in the jam; it changes the whole design, and a simulator answers it in an hour.
- **Test the rules with property tests over thousands of seeded rolls**, not single examples (success odds 30 and 40 percent, Buff mean 3.5 and best-of-two 4.47, ties to the attacker, ranged targets never hit back, a natural 20 hits even when losing). A **mutation check** (change DC to 14, watch tests fail) proved the tests have teeth. Do this once per new rules engine.
- **Isolate every rule number in one data file** (`rules/data.odin`) because the source text was out of date (v2.2 vs 2.4); the diff becomes a data edit.
- **Own RNG, injected explicitly** (xorshift64*): deterministic across native and wasm, sidesteps the default-RNG-in-wasm gotcha, and makes any death reproducible from a seed.
- **A rules ambiguity can be measured instead of argued.** "Does a melee pair resolve once or twice per round?" changed almost nothing in the sim, so we stopped worrying. Make ambiguous readings a parameter and run the sim both ways.
- **Odin notes:** enumerated array literals must name every enum case (or use `{}`); constant enum-indexed tables used at runtime should be declared with `:=`; `odin test <dir> -out:<path>` keeps stray test binaries out of the repo; native `odin run sim -out:...` works for a quick text tool beside the wasm game.
- **Fetch summaries lie:** two entries called "digital" in a collection summary were print-and-play. Open the page.
- Decision A (lethality): keep the book's numbers; depth 1 is an easy roster and avoidance tools carry the game. Tune the roster and tools, not the dice.
- Decision B (loot economy): slow burn with the book's 1000 x HD XP; loot is modest (40 to 150 GP at depth 1). Gear bought with returned gold is the real progression (sim: armor and shield matter more than a level early).
- Decision C (retreat): book-faithful, a second move at the same speed, no free attack. The book is silent on distances and speeds, which a CRPG must supply (tiles per move). The sim must model distance before its flee numbers mean anything (spike A2). Lesson: when asked 'does the rulebook cover X?', grep the PDF first and quote it.

## Spike A2: delves on a grid (Oct 4)

- **What was built:** `dungeon/` (floor generation, sight, Reaction, chase, flee, clock, loot; 15 native tests) and a delve bot in `sim/`. Findings in `DESIGN.md` ("Spike A2 findings").
- **Biggest learning:** with the book's retreat (a second move, equal speed) avoidance works almost perfectly (91 to 99 percent of depth 1 delves survived by a bot that runs from every hunter), fighting never pays under DURF's XP rule, and the bag (slots) is the real income limit. For the jam: decide early whether combat is a mode or a failure state, and design threats that running does not solve.
- **A bot finds design bugs fast.** Four of its stuck cases were engine bugs worth knowing: hunters and fled monsters blocking one-tile corridors forever (fix: fleeing monsters run; the PC swaps with ignoring monsters; bump-attack blockers), a Turn clock that stopped whenever any monster anywhere was hunting (fix: only near hunters stop it), a 1-room floor dividing by zero in the spawner (found by a test), and a linear chain of rooms that made one monster cut the map (fix: loops). Run a bot as soon as there is a map.
- **Debug workflow that worked:** add a `debug` flag to the sim that dumps the state of timeouts (position, stairs, light, hunters, every live monster). Two minutes from "4 percent timeouts" to the cause.
- **Odin and tooling:** enum zero values are silent defaults (a test helper's "idle" goose was Hostile because `Reaction`'s first value is Hostile; put a neutral value first or set it explicitly). `odin build -o:speed` makes the sim about 10 times faster than the default debug build (12 s versus over 2 minutes). Never `pkill -f` a pattern that appears in your own command line (it killed the shell again; the vault already records this). Long sim runs go to a file and a background task; do not block the tool call.
- **Numbers must be read, not trusted.** The first delve report said careful bots survive 88 to 99 percent; after the bot was fixed to explore the whole floor it was 66 to 94 percent. Always ask "why is the income this low/high?" (here: 0.9 of 4.9 items returned led straight to the slots finding).
- Decision D: combat is a failure state, not a mode. The avoidance game (light, routes, bag, timing) carries the fun; the UI must show what is hunting you and how much light remains.
- Decision E: depth threats are ranged monsters and darkness (no faster monsters, which would be an invented rule). Knobs: ranged share of the roster, torch length, wanderer die.
- Decision F: players can drop and pick up items; the junk belongings are the bag's pressure valve. The sim's income numbers (1.9 of 4.9 items returned) assumed no dropping and must be rerun with a drop policy.
- Decision G: the book's Ammo rule (a d6 after a fight, 1 = one shot left) is implemented to tame ranged weapons. Decisions A to G are now all made; the next spike (A3) reruns the sim with drop, ammo, and more ranged monsters.

## Oct 5: rule readings decided (walk-through)

- Reading each ambiguous rule one by one with the exact book text and its effect on the numbers made the decisions quick and let the user choose a faithful reading in four of six cases (sum of HD dice, attacker-only crits, 0 XP for 0 HD, PC-only worn weapons). Do this for the jam: list ambiguities with the quote, the options and a number, rather than asking for approval of a bundle.
- A literal reading can be too harsh to play (Echo Gecko paralysis for 1d4 *Turns*, i.e. 10 to 40 minutes). The user's answer was a house rule that keeps the literal duration and removes the death sentence: the stunners leave, the cost is time. When a literal rule collides with permadeath, look for the version that costs time or resources instead of the run.
- Darkness: sight-only for now (no Break on rolls); decide after playtesting.
- Saved best run: yes, in localStorage, guarded so the game works without it (the Artifact/itch embed guidance: storage can be empty or throw).
- Spells in the practice build: Bolt and Healing Hand only, with a short Blunders table.
- Order of work: A3 (apply decided rules, ammo, drop, rosters, rerun sims), then Spike B (render).

## Oct 5: process decisions

- **One TODO file per spike** in `todo/` with `- [ ]` checkboxes keeps the work visible and the design doc free of task lists. Start each spike by writing its file, tick boxes as work is verified.
- The jam's "No AI art" rule: the product owner decided that CC0 art (public domain) counts as a "provided resource". DURF 2.4 no longer matters for this prototype.

## Spike A3: applying the decisions (Oct 5)

- **What was done:** an item inventory (equipment derived from it), explicit drop and pick up, Ammo, attacker-only crits, PC-only weapon wear, the gecko stun as lost Turns, two house ranged monsters, depth rosters; rules 25 tests, dungeon 23. Findings: `DESIGN.md`, "Spike A3 findings".
- **A rerun after a rules change is a different experiment.** A3's numbers differ from A2 for known reasons (gecko rule, dropping, ranged monsters). Keep a comparison table of old versus new and explain each difference, so a result is never just "different".
- **One fix can invalidate an earlier conclusion.** "Armor halves your income" (A2) disappeared once dropping existed. State conclusions with their assumptions ("assuming the bot never drops") so they can be retired cleanly.
- **Bots find infinite loops in your actions.** Two came from the same cause: an action whose result depends on array order (`pick_up` returned junk the bot had just dropped) and an uncapped inner loop. Give every action an unambiguous target, cap every bot loop, and have the sim replay any timed-out delve with a trace (`sim delves debug`).
- **Add a trace mode at the start.** `sim trace` plus a replay-with-trace for timeouts (saving the RNG state before each delve) made the stuck bot visible in minutes.
- **Odin:** `pkill -x name` (exact process name) is safe where `pkill -f` is not; `until [ -f flag ]; do sleep 2; done` in a command with `run_in_background` (or a `timeout`) is the way to wait for a long background job; unbounded loops that call an action which can fail will hang a batch run.
- Decision L: accept the faster levelling (HD 2 after about 4 shallow or 2 to 3 deep delves); amends decision B. Loot values and torch length are the tuning knobs.
- Decision M: leave the book's Ammo rule as written (combat is a failure state, so a strong bow only softens the failure state). All design decisions through M are made; Spike B (render) is next.
