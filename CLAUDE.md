# CLAUDE.md

Guidance for Claude Code sessions in this repo, **including a future jam session that is told to reference this project**.

## What this repo is

A **practice project** for [DURF Jam 6](https://itch.io/jam/durf-jam-6) (Oct 14 to Nov 14, 2026, theme "Lost & Found"). It is a CRPG adaptation of the tabletop game DURF (Emiel Boven, CC-BY 4.0) played in the browser. It is not a jam entry and will not ship. Its purpose is to find out what works, so the real jam entry goes faster. Working title: "Lost & Found of SPLORR!!".

- **Rules target for the practice: DURF core rules.** For the jam we may reconsider (for example DURF Expanded). The 2.2 PDF is in `durf-reference/`; the current release is v2.4 (decision 8 in `DESIGN.md`: built on 2.2 with every number in `rules/data.odin`; **2.4 no longer matters for this prototype**, the jam may reconsider).
- **Work tracking:** one TODO file per spike in `todo/`, with `- [ ]` checkboxes (see `todo/README.md`). Tick boxes as work is done and verified, add boxes as you discover work, and keep `todo/README.md`'s state column current.
- Status and plan: **`DESIGN.md`** (source of truth: rules digest, design, architecture, milestones, open questions). Running log of lessons: **`LEARNINGS.md`**.
- Phase: design decisions are made (see the decision log in `DESIGN.md`); spikes A, A2, A3, B (a playable browser build, playtested Oct 6: "works for a little demo") and C (traps, built Oct 6, awaiting playtest) are done; the product owner's notes for the real jam game (menu-driven inventory, minimal keypresses) are in `DESIGN.md` and `LEARNINGS.md`. The user still wants design and plan first for new areas; spikes are fine.
- **Key findings to remember:** dropping junk dissolves the bag limit and the torch becomes the binding limit; ranged monsters make depth matter; the book's Ammo rule barely limits a kiting bow. And, from A1: under the book's rules combat is lethal and never pays; avoidance (running at equal speed, Reaction, light, the bag) is the game.

## If you are the jam project's session

1. Read `LEARNINGS.md` first (short, newest last), then `DESIGN.md` sections "Rule readings", "Architecture" and "Balance simulator".
2. Reusable code (once spikes exist) is documented under "Reusable parts" below. Copy it into the jam repo rather than depending on this path.
3. Do **not** copy: anything in `durf-reference/` (user-supplied, git-ignored), or third-party DURF Collection content (own licenses).
4. Re-check the jam page's rules before building; they could change. At last check: **no AI art**, DURF-related, theme "Lost & Found". The product owner decided on Oct 5 that **CC0 art (the Urizen tileset) counts as a "provided resource"** because it is public domain.
5. Add what you learn to this repo's `LEARNINGS.md` only if the user asks; otherwise keep the jam repo self-contained.

## Reusable parts (update as spikes land)

| Part | Where | Status |
| --- | --- | --- |
| Odin wasm build script | `build.sh` | copied from `/home/yermom/git/tggd_jamference2/`, unmodified |
| 2D canvas shim with tileset knock-out, tint modes | `web/index.html` (not yet copied) | planned, from the same repo |
| Tileset contact-sheet tool | `tools/sheet.py` | works; usage in `LEARNINGS.md` |
| Urizen tileset | `assets/tileset.png` | copy of the vault's sheet (CC0, credit vurmux) |
| DURF v2.2 rules engine: seeded RNG, Buffs/Breaks, opposed combat, inventory of items with slots, equipment derived from the bag, Stress, Ammo, damage, HD death, morale, reaction, XP, character creation | `rules/` (package `rules`; numbers in `rules/data.odin`) | **built**, 25 passing native tests (mutation-checked) |
| Dungeon/delve engine: seeded floor generation, line of sight, Reaction on sight, chase and flee (a move plus an action per round), Turn clock and torch, wandering encounters, explicit pick up and drop against the slot limit, Ammo check after fights, gecko paralysis as lost Turns, bump-swap with neutrals | `dungeon/` (package `dungeon`, imports `../rules`) | **built**, 47 passing native tests (including traps) |
| Playable browser build: game layer (screens, keys, banking, shop, log text), canvas shim, drawing, QA URL hooks | `src/game.odin` (pure, 11 native tests), `src/web.odin` (`#+build js`), `web/index.html`, `build.sh` | **built** (Spike B), awaiting a human playtest |
| Labelled contact sheet of the sprites in use | `tools/sprites.py` | works |
| Simulator bots: abstract fights (`fights`) and whole delves on the grid with four policies (`delves`) | `sim/`, results in `sim/results-fights-v2.2.txt` and `sim/results-delves-v2.2.txt` | **built**; no spells, no hirelings, bot knows the room layout; `sim trace` and `sim delves debug` (replays timeouts with a trace) help find stuck bots |

## Commands

```bash
/home/yermom/ODIN/odin test rules -define:ODIN_TEST_THREADS=1 -out:/tmp/rules_test   # rules tests (always pass -out so no binary lands in the repo)
/home/yermom/ODIN/odin test dungeon -define:ODIN_TEST_THREADS=1 -out:/tmp/dungeon_test # delve engine tests
/home/yermom/ODIN/odin build sim -o:speed -out:/tmp/sim && /tmp/sim fights 4000          # abstract fights (an unoptimised build is about 10x slower)
/tmp/sim delves 400                                                                      # whole delves, 400 per cell (about 1 minute); add `debug` to dump timeouts
```

Browser build and QA (the game is `package main` in `src/`, importing `../rules` and `../dungeon`):

```bash
/home/yermom/ODIN/odin test src -define:ODIN_TEST_THREADS=1 -out:/tmp/src_test      # game layer tests
ODIN=/home/yermom/ODIN/odin ./build.sh                                                # builds build/web (wasm, shim, tileset)
python3 tools/serve.py 8000                                                            # serve it with no-cache headers (plain http.server caches a stale game.wasm)
google-chrome --headless=new --no-sandbox --disable-gpu --hide-scrollbars --window-size=800,800 \
  --virtual-time-budget=4000 --screenshot=out.png "http://localhost:8000/?seed=7&depth=1"   # a screenshot
python3 tools/sprites.py out.png                                                      # sprite contact sheet
```

QA URL hooks: `?seed=N&depth=D` starts a seeded delve, `&hunter=<Monster index>&hdist=<tiles>` adds a hunting monster, `&trap=<0 Darts,1 Snare,2 Alarm,3 Mess>&tdist=<tiles>` adds a hidden trap with clues on the way. In the browser pane, `window.dispatchEvent(new KeyboardEvent("keydown", {key: "ArrowRight"}))` drives the game (it listens on `window`); screenshots can lag one step.

## Conventions (same as the earlier SPLORR!! entries)

- Stack: Odin (`/home/yermom/ODIN/odin`) compiled to `js_wasm32`, own `odin.js` runtime, 2D canvas through a JS shim, never WebGL. Build: `ODIN=/home/yermom/ODIN/odin ./build.sh`; serve `build/web` with `python3 -m http.server -d build/web <port>` (not 8765).
- Pure logic with no browser imports; browser code behind `#+build js`; **every `_test.odin` file needs `#+build !js` as its first line** (test files in imported packages are compiled into the wasm build otherwise, and `core:os` panics on wasm); run `odin test <pkg> -define:ODIN_TEST_THREADS=1 -out:/tmp/x`.
- Read `/home/yermom/git/bok-of-splorr/splorr/Gotchas.md` before writing Odin or wasm code (seed the RNG, cap retry loops, `e.key` before `e.code`, no `core:os` in shared code).
- Art: Urizen 1-bit tileset only (human-made, CC0, which the product owner decided counts as a "provided resource"). **Never generate art with AI**: the jam forbids it.
- Style: deadpan, minimal, retro; "of SPLORR!!" absurdism lives in item and monster names.

## Rules for sessions in this repo

- **Never commit `durf-reference/`** (git-ignored). Never `git push` or ship anything unless the user explicitly says so (the user said so for the first commit on Oct 4; ask again for later pushes).
- Commit author is `TheGrumpyGameDev`. Commit only when asked.
- Propose designs with a recommendation and let the user decide; turn each decision into an acceptance criterion the user can check by playing.
- Verify what you can (build, native tests, headless Chrome screenshots) before handing over a build, and say what was and was not verified.
- Credit DURF (Emiel Boven, CC-BY 4.0) and vurmux wherever the game or its page appears.
