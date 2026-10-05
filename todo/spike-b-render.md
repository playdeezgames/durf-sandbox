# Spike B: render the delve in the browser

Goal: let a person play the delve engine, to learn how the avoidance game feels and to prove the web stack. Planned; starts after A3. Design: `DESIGN.md` ("Input and UI", "Architecture").

## Stack
- [ ] `src/web.odin` (`#+build js`) and `web/index.html`: copy the 2D canvas shim from `/home/yermom/git/tggd_jamference2/` (tileset knock-out, tints)
- [ ] `ODIN=... ./build.sh` builds to `build/web`; serve with `python3 -m http.server`
- [ ] Seed the RNG from the clock in `main`; cap every retry loop
- [ ] Keys: read `e.key` before `e.code`

## Map
- [ ] Pick tiles for walls, floors, stairs, player, loot, each monster (see `DESIGN.md` sprite candidates; record every tile used)
- [ ] Scrolling 20 by 13 tile viewport on the 48 by 32 floor
- [ ] Fog: seen tiles remembered, light radius from the torch
- [ ] Draw monsters only when seen; show hunting versus neutral

## HUD and log
- [ ] Top HUD: Wounds, Armor, HD, torch Turns left, gold carried
- [ ] Bag display: slots as squares, coloured for item versus Stress
- [ ] 4-line message log, every roll shown (`d20 12 +2 = 14`)
- [ ] Keep every text line within about 33 characters

## Play
- [ ] Movement, bump-attack, swap with neutrals, pick up, drop, wait
- [ ] Push toggle; stairs exit
- [ ] Round structure and initiative visible to the player
- [ ] Game-over screen with the run's result and seed
- [ ] Best run saved in `localStorage` (guarded)

## Verification
- [ ] Headless Chrome screenshots of the delve (`google-chrome --headless=new ...`)
- [ ] Play a full delve in the browser pane and note what feels wrong
- [ ] Record findings in `LEARNINGS.md`
