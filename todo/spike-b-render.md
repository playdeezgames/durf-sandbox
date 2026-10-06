# Spike B: render the delve in the browser

Goal: let a person play the delve engine, to learn how the avoidance game feels and to prove the web stack. Started and mostly done Oct 5, 2026. Design: `DESIGN.md` ("Input and UI", "Architecture"); findings: "Spike B findings".

## Stack
- [x] `src/web.odin` (`#+build js`) and `web/index.html`: 2D canvas shim from `/home/yermom/git/tggd_jamference2/` (tileset knock-out, tints)
- [x] `ODIN=... ./build.sh` builds to `build/web`; serve with `python3 -m http.server -d build/web <port>`
- [x] Seed the RNG from the clock in `main`; every retry loop capped
- [x] Keys: logical `e.key` read first
- [x] `_test.odin` files in imported packages need `#+build !js` (else `core:os` panics the wasm build)
- [x] QA hooks: `?seed=7&depth=2` and `&hunter=<Monster index>&hdist=<tiles>` (spawn a hunter)

## Map
- [x] Tiles for walls, floors, stairs, player, lost items, dropped items, every monster (`tools/sprites.py` renders them labelled)
- [x] Scrolling 20 by 13 viewport on the 48 by 32 floor
- [x] Fog: seen tiles remembered (dimmed), light radius from the torch
- [x] Monsters drawn only when visible; hunters get a red tint, fled ones fade
- [ ] A proper dragon sprite (the placeholder is a humanoid) and a nicer stand-in for lost items than a gem
- [x] Floor muted; stairs and items given a glow so they stand out; remembered (fog) tiles at half brightness (`FOG_ALPHA`)

## HUD and log
- [x] Top HUD: HD, Wounds, Armor, Gold, depth, torch Turns, gold carried, round slots (MV and AC), PUSH, HUNTED
- [x] Bag display: slots as coloured squares per item kind, Stress in red
- [x] 5-line message log, every roll shown (`Dog > You: 22v13`, damage, HD roll against Wounds)
- [x] Test that every log line fits 33 characters (it found a `(push)` overflow)
- [x] The death screen shows the last log lines, so a death is always explained
- [ ] Show who won the initiative in the log (monsters act before your input when they win it)
- [ ] Long item names (belongings) are clipped in the drop menu

## Play
- [x] Movement, bump-attack, swap with neutrals, pick up (G), drop (X menu), wait (Space), fire (F), attack the nearest thing even if neutral (Z), push (P)
- [x] Stairs exit (Enter); travel to the stairs (T), which stops when anything happens
- [x] Round structure visible: a move and an action in either order; the HUD shows what is left
- [x] Office: character sheet, bag list, depth 1 to 3, shop (9 items), free reroll before the first delve
- [x] Game-over screen with the run's result and seed; any key starts a new run
- [x] Best run saved in `localStorage` (guarded in the page; works without it)
- [x] Best run **loads** from real `localStorage` after a reload (planted a value, reloaded, the intro showed it); saving is covered by a native test and uses the same shim call
- [ ] Hire a hireling (milestone 4)

## Found in the product owner's playtest (all fixed)
- [x] The 'no room' hint named the wrong drop key (D instead of X)
- [x] Items and stairs were hard to see on the bright floor
- [x] Fog of war too bright
- [x] No way to attack a neutral (friendly) monster: added Z
- [x] The browser kept a stale game.wasm: added `tools/serve.py` (no-cache)

## Verification
- [x] Native tests: rules 25, dungeon 32, game 11, all passing
- [x] Round refactor checked bit for bit: the delve simulator output is identical before and after
- [x] Headless Chrome screenshots (`google-chrome --headless=new ... --screenshot`)
- [x] Played delves in the browser pane: walking, fog, pick up, drop menu, office, shop, fights, deaths
- [x] A full human playtest by the product owner (the point of the spike). Verdict Oct 6: works as a little demo; the jam game needs menu-driven inventory and minimal keypresses (see `LEARNINGS.md`, `DESIGN.md`)
- [x] Record findings in `LEARNINGS.md`
