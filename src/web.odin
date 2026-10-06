#+build js
package main

// Browser side: key input, canvas drawing and the frame loop. Everything that touches the page
// lives here; the game itself is in game.odin.

import "base:runtime"
import "core:fmt"
import "core:sys/wasm/js"
import "core:time"
import D "../dungeon"
import R "../rules"

// Implemented in web/index.html (2D canvas); world coordinates, y up.
foreign import canvas "canvas"
@(default_calling_convention = "contextless")
foreign canvas {
	clear_canvas :: proc(r, g, b: f32) ---
	fill_rect :: proc(x, y, w, h: f32, r, g, b, a: f32, tiles: f32) ---
	// tile (col,row) of assets/tileset.png (12px tiles, 1px gap) at world x,y; tint 0 as drawn, 1 swaps red and blue, 2 brightens
	draw_sprite :: proc(col, row: i32, x, y: f32, alpha: f32, tiles: f32, tint: i32, size: f32) ---
	// the best run, kept in localStorage (guarded in the page; 0 when blocked or empty)
	store_get :: proc(key: i32) -> i32 ---
	store_set :: proc(key: i32, value: i32) ---
}

platform_store_get :: proc(key: int) -> int { return int(store_get(i32(key))) }
platform_store_set :: proc(key: int, value: int) { store_set(i32(key), i32(value)) }

ctx: runtime.Context

main :: proc() {
	ctx = context
	game.run_seed = u64(time.now()._nsec) | 1
	R.rng_seed(&game.rng, game.run_seed)
	load_best(&game)
	js.add_window_event_listener(.Key_Down, nil, on_key)
}

// QA: index.html?seed=7&depth=2 starts a fresh run with that seed and drops into that depth.
@(export)
debug_start :: proc "c" (seed, depth: i32) {
	context = ctx
	new_run(&game, u64(seed))
	start_delve(&game, clamp(int(depth), 1, MAX_DEPTH))
}

// QA: add a hunting monster (kind is the Monster enum index) this many tiles of walking away.
@(export)
debug_hunter :: proc "c" (kind, dist: i32) {
	context = ctx
	debug_add_hunter(&game, R.Monster(clamp(int(kind), 0, len(R.Monster) - 1)), int(dist))
}

// QA: add a hidden trap (kind is the Trap_Kind enum index) this many tiles of walking away.
@(export)
debug_trap :: proc "c" (kind, dist: i32) {
	context = ctx
	debug_add_trap(&game, R.Trap_Kind(clamp(int(kind), 0, len(R.Trap_Kind) - 1)), int(dist))
}

// Read the logical key first: remote desktops can send wrong e.code values.
map_key :: proc(k: string) -> Key {
	switch k {
	case "ArrowUp", "w", "W":    return .Up
	case "ArrowDown", "s", "S":  return .Down
	case "ArrowLeft", "a", "A":  return .Left
	case "ArrowRight", "d", "D": return .Right
	case " ", ".":               return .Wait
	case "Enter":                return .Confirm
	case "Escape":               return .Cancel
	case "g", "G", ",":          return .Pickup
	case "p", "P":               return .Push
	case "x", "X":               return .Drop
	case "f", "F":               return .Fire
	case "z", "Z":               return .Attack
	case "r", "R":               return .Reroll
	case "b", "B":               return .Shop
	case "t", "T":               return .Travel
	case "e", "E":               return .Search
	case "c", "C":               return .Disarm
	case "0": return .N0
	case "1": return .N1
	case "2": return .N2
	case "3": return .N3
	case "4": return .N4
	case "5": return .N5
	case "6": return .N6
	case "7": return .N7
	case "8": return .N8
	case "9": return .N9
	}
	return .None
}

on_key :: proc(e: js.Event) {
	if e.kind != .Key_Down || e.key.repeat { return }
	k := map_key(e.key.key)
	if k == .None { return }
	js.event_prevent_default()
	handle_key(&game, k)
}

// ---------- tiles (assets/tileset.png, Urizen 1-bit by vurmux, CC0) ----------

Tile :: [2]i32

SPR_PLAYER :: Tile{105, 0}
SPR_WALL   :: Tile{0, 2} // grey cobblestone
SPR_FLOOR  :: Tile{8, 5} // dark parquet
SPR_STAIRS :: Tile{46, 3} // a ladder
SPR_LOST   :: Tile{1, 22} // a gem stands in for a lost item
SPR_DROPPED :: Tile{1, 23} // a pouch stands in for dropped things
SPR_CLUE   :: Tile{3, 25} // red spatters near a trap
SPR_TRAP   :: Tile{54, 0} // an iron grate: a found trap

MOB_SPRITES := [R.Monster]Tile{
	.Goose            = {5, 16},
	.Dog              = {4, 14},
	.Echo_Gecko       = {13, 14},
	.Myconid          = {2, 10},
	.Eelfolk          = {15, 14},
	.Spellclaw        = {106, 6},
	.Shadow           = {108, 13},
	.Flesh_Orb        = {57, 12},
	.Dragon           = {106, 7},
	.Blowpipe_Imp     = {112, 6},
	.Crossbow_Cultist = {112, 8},
}

WORLD :: 20
MAP_COLS :: 20
MAP_ROWS :: 13
FOG_ALPHA :: 0.175 // how bright remembered (not currently visible) tiles are
MAP_Y0 :: 5 // world y of the map's bottom edge; the log sits below it, the HUD above

draw_tile :: proc(t: Tile, x, y: f32, alpha: f32 = 1, tint: i32 = 0, size: f32 = 1) {
	draw_sprite(t.x, t.y, x, y, alpha, WORLD, tint, size)
}

draw_rect :: proc(x, y, w, h: f32, c: [4]f32) { fill_rect(x, y, w, h, c.r, c.g, c.b, c.a, WORLD) }

// ---------- text (the tileset's bitmap font) ----------

FontRun :: struct {
	row, col: i32,
	chars:    string,
}
PLAIN_FONT := [?]FontRun{
	{44, 78, "ABCDEFGHIJKLMNOPQRST12345"},
	{45, 78, "UVWXYZabcdefghijklmn67890"},
	{46, 78, "opqrstuvwxyz()[]{}<>+-?!^"},
	{47, 78, ":#_@%~$\"'&*=`|/\\.,;"},
}
TEXT_SIZE :: 0.6 // 24px per 12px glyph, an exact 2x so pixels stay crisp
MAX_CHARS :: 33 // what fits a 20 tile line

draw_glyph :: proc(c: u8, x, y, size, alpha: f32) {
	for run in PLAIN_FONT {
		for j in 0 ..< len(run.chars) {
			if run.chars[j] == c { draw_sprite(run.col + i32(j), run.row, x, y, alpha, WORLD, 0, size); return }
		}
	}
}

draw_text :: proc(s: string, x, y: f32, alpha: f32 = 1) {
	for i in 0 ..< min(len(s), MAX_CHARS) { draw_glyph(s[i], x + f32(i) * TEXT_SIZE, y, TEXT_SIZE, alpha) }
}

draw_text_centered :: proc(s: string, y: f32) {
	n := min(len(s), MAX_CHARS)
	draw_text(s, (WORLD - f32(n) * TEXT_SIZE) / 2, y)
}

LINE :: 0.8 // text line pitch

// A dark panel with lines of text, the first line at world y `top` going down.
draw_panel :: proc(lines: []string, top: f32, centered := true) {
	h := f32(len(lines)) * LINE + 0.5
	draw_rect(0.6, top - h + 0.3, WORLD - 1.2, h, {0.03, 0.04, 0.12, 0.95})
	for line, i in lines {
		y := top - f32(i + 1) * LINE + 0.3
		if centered { draw_text_centered(line, y) } else { draw_text(line, 1.0, y) }
	}
}

// ---------- the delve ----------

KIND_COLOR := [R.Item_Kind][4]f32{
	.Junk   = {0.55, 0.40, 0.25, 1},
	.Weapon = {0.78, 0.78, 0.85, 1},
	.Armor  = {0.40, 0.60, 1.00, 1},
	.Shield = {0.30, 0.50, 0.90, 1},
	.Ammo   = {1.00, 0.60, 0.20, 1},
	.Supply = {0.40, 0.80, 0.40, 1},
	.Lost   = {1.00, 0.85, 0.20, 1},
}

draw_bag :: proc(pc: R.Creature, x0, y: f32) {
	total := R.slots_total(pc)
	n := 0
	sq :: proc(x, y: f32, c: [4]f32) { draw_rect(x, y, 0.4, 0.4, c) }
	for i in 0 ..< pc.inv_count {
		for _ in 0 ..< pc.inv[i].slots {
			if n < total { sq(x0 + f32(n) * 0.5, y, KIND_COLOR[pc.inv[i].kind]); n += 1 }
		}
	}
	for _ in 0 ..< pc.stress {
		if n < total { sq(x0 + f32(n) * 0.5, y, {1, 0.2, 0.2, 1}); n += 1 }
	}
	for n < total {
		sq(x0 + f32(n) * 0.5, y, {0.2, 0.2, 0.26, 1})
		n += 1
	}
}

draw_hud :: proc(g: ^Game) {
	d := &g.delve
	pc := d.pc
	draw_rect(0, 18, WORLD, 2, {0.12, 0.13, 0.18, 1})
	draw_rect(0, 18, WORLD, 0.06, {0.45, 0.47, 0.55, 1})
	line := fmt.tprintf("HD%d Wnd%d Arm%d/%d Gold%d D%d", pc.hd, pc.wounds, pc.armor, pc.armor_max, pc.gold, d.depth)
	draw_text(line, 0.3, 19.2)
	draw_bag(pc, 0.4, 18.5)
	draw_text(fmt.tprintf("Torch%d", d.light), 8.1, 18.4, 1.0 if d.light > 2 else 0.6)
	if d.rd.active && d.rd.had_hunters {
		draw_text("MV" if d.rd.move_left > 0 else "--", 12.9, 18.4)
		draw_text("AC" if d.rd.action_left > 0 else "--", 14.3, 18.4)
	} else {
		for i in 0 ..< d.mob_count { // only hunters you can see: unseen ones are not known to you
			m := d.mobs[i]
			if D.mob_alive(m) && m.state == .Hunting && d.visible[m.pos.y][m.pos.x] { draw_text("HUNTED!", 12.9, 18.4); break }
		}
	}
	if g.push { draw_text("PUSH", 15.8, 18.4) }
	if D.lost_count(d) > 0 { draw_text(fmt.tprintf("$%d", D.lost_gp(d)), 17.6, 18.4) }
}

draw_map :: proc(g: ^Game) {
	d := &g.delve
	cam_x := clamp(d.pos.x - MAP_COLS / 2, 0, D.W - MAP_COLS)
	cam_y := clamp(d.pos.y - MAP_ROWS / 2, 0, D.H - MAP_ROWS)
	for sx in 0 ..< MAP_COLS {
		for sy in 0 ..< MAP_ROWS {
			wx, wy := cam_x + sx, cam_y + sy
			if wx >= D.W || wy >= D.H || !d.explored[wy][wx] { continue }
			alpha: f32 = 1 if d.visible[wy][wx] else FOG_ALPHA
			x, y := f32(sx), f32(MAP_Y0 + sy)
			switch d.tiles[wy][wx] {
			case .Wall:   draw_tile(SPR_WALL, x, y, alpha)
			case .Floor:  draw_tile(SPR_FLOOR, x, y, alpha) // muted, so things on it stand out
			case .Stairs:
				draw_tile(SPR_FLOOR, x, y, alpha)
				draw_rect(x, y, 1, 1, {0.2, 0.9, 1.0, 0.18 * alpha}) // a cool glow marks the way out
				draw_tile(SPR_STAIRS, x, y, alpha, 2)
			}
		}
	}
	for i in 0 ..< d.trap_count { // clues are drawn once seen; a found trap stands out, a spent one fades
		t := d.traps[i]
		if t.armed {
			for k in 0 ..< t.clue_count {
				c := t.clues[k]
				sx, sy := c.x - cam_x, c.y - cam_y
				if sx < 0 || sx >= MAP_COLS || sy < 0 || sy >= MAP_ROWS || !D.clue_visible(d, c) { continue }
				draw_tile(SPR_CLUE, f32(sx), f32(MAP_Y0 + sy), 0.3) // a faint stain: you have to be looking
			}
		}
		sx, sy := t.pos.x - cam_x, t.pos.y - cam_y
		if !t.revealed || sx < 0 || sx >= MAP_COLS || sy < 0 || sy >= MAP_ROWS { continue }
		x, y := f32(sx), f32(MAP_Y0 + sy)
		if t.armed {
			draw_rect(x, y, 1, 1, {1.0, 0.25, 0.25, 0.25})
			draw_tile(SPR_TRAP, x, y, 1 if d.visible[t.pos.y][t.pos.x] else FOG_ALPHA * 1.5, 2)
		} else {
			draw_tile(SPR_TRAP, x, y, 0.3 if d.visible[t.pos.y][t.pos.x] else FOG_ALPHA, 2)
		}
	}
	for i in 0 ..< d.loot_count {
		l := d.loot[i]
		if l.taken || !(l.seen || d.visible[l.pos.y][l.pos.x]) { continue }
		sx, sy := l.pos.x - cam_x, l.pos.y - cam_y
		if sx < 0 || sx >= MAP_COLS || sy < 0 || sy >= MAP_ROWS { continue }
		alpha: f32 = 1 if d.visible[l.pos.y][l.pos.x] else FOG_ALPHA * 1.25
		x, y := f32(sx), f32(MAP_Y0 + sy)
		draw_rect(x, y, 1, 1, {1.0, 0.85, 0.2, 0.22 * alpha}) // a warm glow so items show on any floor
		draw_tile(SPR_DROPPED if l.dropped else SPR_LOST, x, y, alpha, 2)
	}
	for i in 0 ..< d.mob_count {
		m := d.mobs[i]
		if !m.c.alive || !d.visible[m.pos.y][m.pos.x] { continue }
		sx, sy := m.pos.x - cam_x, m.pos.y - cam_y
		if sx < 0 || sx >= MAP_COLS || sy < 0 || sy >= MAP_ROWS { continue }
		x, y := f32(sx), f32(MAP_Y0 + sy)
		if m.state == .Hunting { draw_rect(x, y, 1, 1, {1, 0.2, 0.2, 0.35}) }
		draw_tile(MOB_SPRITES[m.kind], x, y, 0.55 if m.state == .Fled else 1, 2)
	}
	px, py := f32(d.pos.x - cam_x), f32(MAP_Y0 + d.pos.y - cam_y)
	draw_tile(SPR_PLAYER, px, py)
}

draw_log :: proc(g: ^Game) {
	draw_rect(0, 0, WORLD, 5, {0.06, 0.06, 0.09, 1})
	draw_rect(0, 4.94, WORLD, 0.06, {0.45, 0.47, 0.55, 1})
	for k in 0 ..< 5 { // newest at the bottom
		draw_text(log_line(g, 4 - k), 0.3, 4.15 - f32(k) * LINE, 1.0 if k == 4 else 0.7)
	}
}

draw_drop_menu :: proc(g: ^Game) {
	pc := g.delve.pc
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, "DROP WHICH? (Esc: cancel)")
	for i in 0 ..< min(pc.inv_count, 10) {
		key := (i + 1) % 10
		append(&lines, fmt.tprintf("%d %s (%d)", key, pc.inv[i].name, pc.inv[i].slots))
	}
	draw_panel(lines[:], 16.2, centered = false)
}

draw_delve :: proc(g: ^Game) {
	draw_map(g)
	draw_hud(g)
	draw_log(g)
	if g.drop_menu { draw_drop_menu(g) }
}

// ---------- the other screens ----------

draw_intro :: proc(g: ^Game) {
	lines := [?]string{
		TITLE,
		"",
		"Dungeons swallow things.",
		"You return them for gold and XP.",
		"Fighting rarely pays. Run.",
		"",
		"Arrows/WASD  move, bump to hit",
		"Space   wait       G  pick up",
		"X  drop   F  fire   P  push",
		"Z  attack the nearest thing",
		"T  walk to the stairs",
		"E  search for traps (a Turn)",
		"C  disarm a trap you found",
		"Enter   take the stairs out",
		"",
		fmt.tprintf("Best: %d gp, depth %d", g.best_score, g.best_depth),
		"",
		"Press Enter to start",
	}
	draw_panel(lines[:], 17.5)
	draw_text_centered("DURF by Emiel Boven, CC-BY 4.0", 1.6)
	draw_text_centered("Art: Urizen by vurmux, CC0", 0.9)
}

draw_office :: proc(g: ^Game) {
	pc := g.pc
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, "THE LOST PROPERTY OFFICE")
	append(&lines, fmt.tprintf("STR %d  DEX %d  WIL %d  HD %d", pc.attrs[.STR], pc.attrs[.DEX], pc.attrs[.WIL], pc.hd))
	append(&lines, fmt.tprintf("Gold %d   XP %d/%d", pc.gold, pc.xp, R.XP_PER_HD_COST * pc.hd))
	append(&lines, fmt.tprintf("Bag %d/%d  Armor %d  %s", R.slots_used(pc), R.slots_total(pc), pc.armor_max, R.WEAPONS[pc.weapon].name))
	append(&lines, "")
	for i in 0 ..< pc.inv_count { append(&lines, fmt.tprintf(" %s (%d)", pc.inv[i].name, pc.inv[i].slots)) }
	append(&lines, "")
	append(&lines, fmt.tprintf("Delves %d  Returned %d gp", g.delves_done, g.run_gold))
	append(&lines, "1 2 3  go down to that depth")
	append(&lines, "B  shop   R  new character" if g.delves_done == 0 else "B  shop")
	draw_panel(lines[:], 19.5, centered = false)
}

draw_shop :: proc(g: ^Game) {
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, "THE OFFICE SHOP")
	append(&lines, fmt.tprintf("Gold %d   Bag %d/%d", g.pc.gold, R.slots_used(g.pc), R.slots_total(g.pc)))
	append(&lines, "")
	items := shop_items()
	for it, i in items { append(&lines, fmt.tprintf("%d %s %dgp (%d)", i + 1, it.item.name, it.price, it.item.slots)) }
	append(&lines, "")
	append(&lines, log_line(g, 0))
	append(&lines, "Esc  back")
	draw_panel(lines[:], 18.5, centered = false)
}

draw_result :: proc(g: ^Game) {
	s := g.summary
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, "BACK UP THE STAIRS")
	append(&lines, "")
	append(&lines, fmt.tprintf("Depth %d, %d Turns", s.depth, s.turns))
	append(&lines, fmt.tprintf("Lost items returned: %d", s.items))
	append(&lines, fmt.tprintf("Gold and XP: %d", s.gold))
	if s.kill_xp > 0 { append(&lines, fmt.tprintf("XP from kills: %d", s.kill_xp)) }
	if s.hd_gained > 0 { append(&lines, fmt.tprintf("You reach HD %d!", g.pc.hd)) }
	append(&lines, "")
	append(&lines, fmt.tprintf("Run total: %d gp", g.run_gold))
	if g.new_best { append(&lines, "A new best run!") }
	append(&lines, "")
	append(&lines, "Press Enter")
	draw_panel(lines[:], 16.5)
}

draw_dead :: proc(g: ^Game) {
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, "YOU DIED")
	append(&lines, "")
	append(&lines, fmt.tprintf("Killed by: %s", g.killer))
	append(&lines, fmt.tprintf("Depth reached: %d", g.run_deepest))
	append(&lines, fmt.tprintf("Returned this run: %d gp", g.run_gold))
	append(&lines, fmt.tprintf("Best: %d gp, depth %d", g.best_score, g.best_depth))
	if g.new_best { append(&lines, "A new best run!") }
	append(&lines, fmt.tprintf("Seed %d", g.run_seed % 1000000))
	append(&lines, "")
	append(&lines, "How it ended:")
	for k in 0 ..< 5 { // the last lines of the log: the player must see why they died
		if line := log_line(g, 4 - k); line != "" { append(&lines, line) }
	}
	append(&lines, "")
	append(&lines, "Press Enter")
	draw_panel(lines[:], 19.0)
}

// Only draws; every state change happens in handle_key.
@(export)
step :: proc(dt: f64, c: runtime.Context) -> bool {
	context = ctx
	free_all(context.temp_allocator)
	clear_canvas(0.02, 0.02, 0.04)
	switch game.screen {
	case .Intro:  draw_intro(&game)
	case .Office: draw_office(&game)
	case .Shop:   draw_shop(&game)
	case .Delve:  draw_delve(&game)
	case .Result: draw_result(&game)
	case .Dead:   draw_dead(&game)
	}
	return true
}
