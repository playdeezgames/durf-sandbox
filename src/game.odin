package main

// The game: screens, keys, banking a delve, the shop and the message log. Pure (no browser
// imports) so it runs and tests natively; web.odin draws it and feeds it keys.

import "core:fmt"
import D "../dungeon"
import R "../rules"

TITLE :: "Lost & Found of SPLORR!!" // working title (decision 4): change it here

LOG_KEEP :: 24
LINE_MAX :: 48
MAX_DEPTH :: 3

Screen :: enum { Intro, Office, Shop, Delve, Result, Dead }

Key :: enum {
	None, Up, Down, Left, Right,
	Wait, Pickup, Confirm, Cancel, Push, Drop, Fire, Reroll, Shop, Travel, Attack,
	N0, N1, N2, N3, N4, N5, N6, N7, N8, N9,
}

Log_Line :: struct {
	text: [LINE_MAX]u8,
	n:    int,
}

// What a delve brought home, for the result screen.
Summary :: struct {
	depth:     int,
	items:     int,
	gold:      int,
	kill_xp:   int,
	hd_gained: int,
	turns:     int,
	kills:     int,
}

Game :: struct {
	screen:      Screen,
	rng:         R.Rng, // run-level randomness: characters and delve seeds
	run_seed:    u64,
	pc:          R.Creature, // the character between delves
	delve:       D.Delve,
	depth:       int,
	delves_done: int,
	log:         [LOG_KEEP]Log_Line,
	log_count:   int,
	push:        bool,
	drop_menu:   bool,
	summary:     Summary,
	// the run so far
	run_gold:    int, // gold of lost items returned over the run: the score
	run_deepest: int,
	// the best run, saved in the browser
	best_score:  int,
	best_depth:  int,
	new_best:    bool,
	killer:      string,
}

KEY_BEST_SCORE :: 0
KEY_BEST_DEPTH :: 1

game: Game

// ---------- log ----------

log_add :: proc(g: ^Game, text: string) {
	if g.log_count == LOG_KEEP { // scroll
		for i in 1 ..< LOG_KEEP { g.log[i - 1] = g.log[i] }
		g.log_count -= 1
	}
	line := &g.log[g.log_count]
	line.n = min(len(text), LINE_MAX)
	for i in 0 ..< line.n { line.text[i] = text[i] }
	g.log_count += 1
}

log_addf :: proc(g: ^Game, f: string, args: ..any) { log_add(g, fmt.tprintf(f, ..args)) }

log_line :: proc(g: ^Game, from_end: int) -> string {
	i := g.log_count - 1 - from_end
	if i < 0 { return "" }
	return string(g.log[i].text[:g.log[i].n])
}

// ---------- runs ----------

new_run :: proc(g: ^Game, seed: u64) {
	best_score, best_depth := g.best_score, g.best_depth
	g^ = {}
	g.best_score, g.best_depth = best_score, best_depth
	g.run_seed = seed
	R.rng_seed(&g.rng, seed)
	g.pc = R.new_character(&g.rng, "You")
	g.screen = .Office
	g.depth = 1
}

reroll_character :: proc(g: ^Game) { g.pc = R.new_character(&g.rng, "You") } // free until the first delve

start_delve :: proc(g: ^Game, depth: int) {
	g.depth = depth
	g.delve = {}
	seed := g.run_seed * 2654435761 + u64(g.delves_done) * 1000 + u64(depth) + 1
	D.init_delve(&g.delve, seed, depth, g.pc, 0, 0)
	D.notice(&g.delve)
	g.push = false
	g.drop_menu = false
	g.log_count = 0
	g.screen = .Delve
	g.run_deepest = max(g.run_deepest, depth)
	log_addf(g, "Depth %d. The torch is lit.", depth)
	drain_events(g)
}

// A delve ended in a safe return: lost items are handed in for gold and XP, kills count too, a
// level is bought automatically, and the office lets you rest.
bank_delve :: proc(g: ^Game) {
	d := &g.delve
	pc := d.pc
	gp := D.lost_gp(d)
	items := D.lost_count(d)
	for i := pc.inv_count - 1; i >= 0; i -= 1 { if pc.inv[i].kind == .Lost { R.remove_item(&pc, i) } }
	pc.gold += gp
	gained := R.add_xp(&pc, gp + d.xp)
	R.rest(&pc)
	pc.ammo_low = false
	g.pc = pc
	g.run_gold += gp
	g.delves_done += 1
	g.summary = Summary{depth = d.depth, items = items, gold = gp, kill_xp = d.xp, hd_gained = gained, turns = d.turns, kills = d.kills}
	save_best_if_better(g)
	g.screen = .Result
}

save_best_if_better :: proc(g: ^Game) {
	if g.run_gold <= 0 { return } // a run that returned nothing is not a record
	if g.run_gold > g.best_score || (g.run_gold == g.best_score && g.run_deepest > g.best_depth) {
		g.best_score, g.best_depth = g.run_gold, g.run_deepest
		g.new_best = true
		platform_store_set(KEY_BEST_SCORE, g.best_score)
		platform_store_set(KEY_BEST_DEPTH, g.best_depth)
	}
}

load_best :: proc(g: ^Game) {
	g.best_score = platform_store_get(KEY_BEST_SCORE)
	g.best_depth = platform_store_get(KEY_BEST_DEPTH)
}

// ---------- the shop ----------

Shop_Item :: struct {
	item:  R.Item,
	price: int,
}

shop_items :: proc() -> [9]Shop_Item {
	return {
		{R.item_weapon(.Sword), R.WEAPONS[.Sword].price},
		{R.item_weapon(.Greatsword), R.WEAPONS[.Greatsword].price},
		{R.item_weapon(.Bow), R.WEAPONS[.Bow].price},
		{R.item_ammo(), R.AMMO_PRICE},
		{R.item_armor(.Light), R.ARMORS[.Light].price},
		{R.item_armor(.Medium), R.ARMORS[.Medium].price},
		{R.item_armor(.Heavy), R.ARMORS[.Heavy].price},
		{R.item_shield(), R.SHIELD_PRICE},
		{R.item_supply(), R.SUPPLY_COST},
	}
}

buy :: proc(g: ^Game, n: int) -> string {
	items := shop_items()
	if n < 0 || n >= len(items) { return "" }
	it := items[n]
	switch {
	case g.pc.gold < it.price:        return "Not enough gold."
	case !R.can_carry(g.pc, it.item): return "No room in your bag."
	}
	g.pc.gold -= it.price
	R.add_item(&g.pc, it.item)
	return fmt.tprintf("Bought %s.", it.item.name)
}

// ---------- events to text ----------

fmt_damage :: proc(g: ^Game, who: string, r: R.Damage_Result) {
	if r.dmg_in == 0 && r.wounds_new == 0 { return }
	if r.absorbed > 0 && r.wounds_new > 0 {
		log_addf(g, "%s: armor -%d, wounds +%d", who, r.absorbed, r.wounds_new)
	} else if r.absorbed > 0 {
		log_addf(g, "%s: armor -%d", who, r.absorbed)
	} else {
		log_addf(g, "%s: wounds +%d", who, r.wounds_new)
	}
	if r.hd_rolled {
		verdict := "dies" if r.died else "lives"
		log_addf(g, "HD roll %d v %d wounds: %s", r.hd_sum, r.wounds_total, verdict)
	}
}

describe_attack :: proc(g: ^Game, e: D.Event) {
	x := e.x
	a, b := e.name, "You"
	if e.by_pc { a, b = "You", e.name }
	push_note := ""
	if e.by_pc && x.att_pushes > 0 { push_note = "*" } // * marks a roll that was pushed (Stress spent for a Buff)
	log_addf(g, "%s > %s: %dv%d%s", a, b, x.att.total, x.def.total, push_note)
	if x.hit_def {
		crit := " CRIT" if x.att_crit else ""
		log_addf(g, "%s hit for %d%s", a, x.dmg_def, crit)
		fmt_damage(g, b, x.res_def)
	}
	if x.hit_att {
		log_addf(g, "%s hits back for %d", b, x.dmg_att)
		fmt_damage(g, a, x.res_att)
	}
	if x.dodged { log_addf(g, "%s dodges.", b) }
}

describe_event :: proc(g: ^Game, e: D.Event) {
	switch e.kind {
	case .Attack:    describe_attack(g, e)
	case .Reaction:  log_addf(g, "%s: %v", e.name, e.reaction)
	case .Mob_Fled:  log_addf(g, "%s flees!", e.name)
	case .Mob_Died:
		if e.n > 0 { log_addf(g, "%s dies. +%d XP", e.name, e.n) } else { log_addf(g, "%s dies.", e.name) }
	case .Pickup:    log_addf(g, "Took %s (%d gp)", e.name, e.n)
	case .Drop:      log_addf(g, "Dropped %s", e.name)
	case .Light_Out: log_add(g, "The torch goes out!")
	case .Stunned:   log_addf(g, "%s stuns you: %d Turns lost", e.name, e.n)
	case .Ammo_Low:  log_add(g, "Your Ammo is running low.")
	case .Ammo_Gone: log_add(g, "Out of Ammo!")
	}
}

drain_events :: proc(g: ^Game) {
	for i in 0 ..< g.delve.event_count { describe_event(g, g.delve.events[i]) }
	g.delve.event_count = 0
}

// ---------- keys ----------

key_dir :: proc(k: Key) -> (D.Pos, bool) {
	#partial switch k {
	case .Up:    return {0, 1}, true
	case .Down:  return {0, -1}, true
	case .Left:  return {-1, 0}, true
	case .Right: return {1, 0}, true
	}
	return {}, false
}

key_num :: proc(k: Key) -> int { // N1..N9 give 1..9, N0 gives 0, anything else -1
	#partial switch k {
	case .N0: return 0
	case .N1: return 1
	case .N2: return 2
	case .N3: return 3
	case .N4: return 4
	case .N5: return 5
	case .N6: return 6
	case .N7: return 7
	case .N8: return 8
	case .N9: return 9
	}
	return -1
}

handle_key :: proc(g: ^Game, k: Key) {
	if k == .None { return }
	switch g.screen {
	case .Intro:
		if k == .Confirm || k == .Wait { new_run(g, g.run_seed) }
	case .Office:
		office_key(g, k)
	case .Shop:
		if k == .Cancel || k == .Confirm || k == .Shop { g.screen = .Office; return }
		if n := key_num(k); n >= 1 { log_add(g, buy(g, n - 1)) }
	case .Delve:
		delve_key(g, k)
	case .Result:
		if k == .Confirm || k == .Wait { g.screen = .Office }
	case .Dead:
		if k == .Confirm || k == .Wait {
			g.run_seed = R.rng_u64(&g.rng) // a new character next run
			g.screen = .Intro
		}
	}
}

office_key :: proc(g: ^Game, k: Key) {
	if n := key_num(k); n >= 1 && n <= MAX_DEPTH {
		start_delve(g, n)
		return
	}
	#partial switch k {
	case .Reroll: if g.delves_done == 0 { reroll_character(g) }
	case .Shop:   g.screen = .Shop; g.log_count = 0
	}
}

// Afterwards: the events become log lines, and the delve may have ended.
after_action :: proc(g: ^Game) {
	drain_events(g)
	d := &g.delve
	switch d.result {
	case .Running:
	case .Died:
		g.killer = R.MONSTERS[d.killer].name
		save_best_if_better(g)
		g.screen = .Dead
	case .Exited:
		bank_delve(g)
	}
}

// Walk toward the stairs one step at a time, stopping the moment anything happens: a fight begins,
// something is noticed (any event), or the way is blocked. Each step is a normal move.
travel_to_stairs :: proc(g: ^Game) {
	d := &g.delve
	for _ in 0 ..< 300 {
		if d.pos == d.stairs { log_add(g, "You are at the stairs."); return }
		if D.hunters_near(d) > 0 || d.result != .Running || d.event_count > 0 { return }
		grid: D.Grid
		blocked: D.Blocked
		for i in 0 ..< d.mob_count { if D.blocks_pc(d.mobs[i]) { blocked[d.mobs[i].pos.y][d.mobs[i].pos.x] = true } }
		blocked[d.stairs.y][d.stairs.x] = false
		D.bfs(d, d.stairs, &grid, &blocked)
		best := grid[d.pos.y][d.pos.x]
		step := D.Pos{}
		for dir in ([?]D.Pos{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			n := d.pos + dir
			if D.walkable(d, n) && grid[n.y][n.x] < best { best = grid[n.y][n.x]; step = dir }
		}
		if step == {} { log_add(g, "The way is blocked."); return }
		if !D.pc_move(d, step) { return }
	}
}

// The monster the PC would attack first: a visible hunter, nearest first; failing that (only when
// `any` is set) the nearest visible monster of any kind, so a Neutral one can be attacked on purpose.
nearest_target :: proc(g: ^Game, any := false) -> int {
	d := &g.delve
	best, bi := 9999, -1
	for pass in 0 ..< 2 {
		for i in 0 ..< d.mob_count {
			m := d.mobs[i]
			if !m.c.alive || m.state == .Fled { continue }
			if pass == 0 && m.state != .Hunting { continue }
			if ok, _ := D.attackable(d, i); ok && D.manhattan(m.pos, d.pos) < best { best = D.manhattan(m.pos, d.pos); bi = i }
		}
		if bi >= 0 || !any { break }
	}
	return bi
}

delve_key :: proc(g: ^Game, k: Key) {
	d := &g.delve
	if g.drop_menu {
		if k == .Cancel || k == .Drop { g.drop_menu = false; return }
		if n := key_num(k); n >= 0 {
			idx := (n + 9) % 10 // 1..9 are items 0..8, 0 is item 9
			if idx < d.pc.inv_count { D.pc_do_drop(d, idx); g.drop_menu = false; after_action(g) }
		}
		return
	}
	if dir, ok := key_dir(k); ok {
		D.pc_move(d, dir)
		after_action(g)
		return
	}
	#partial switch k {
	case .Wait:
		D.pc_wait(d)
	case .Pickup:
		if !D.pc_do_pickup(d) {
			here := false
			for i in 0 ..< d.loot_count { if !d.loot[i].taken && d.loot[i].pos == d.pos { here = true } }
			log_add(g, "No room: drop something (X)." if here else "Nothing here to pick up.")
		}
	case .Confirm:
		if d.pos == d.stairs { D.exit_delve(d) } else { log_add(g, "Walk to the stairs to leave.") }
	case .Push:
		g.push = !g.push
		d.push_att = 1 if g.push else 0
		d.push_def = d.push_att
		log_add(g, "Push ON: Stress for a Buff." if g.push else "Push off.")
	case .Drop:
		if d.pc.inv_count > 0 { g.drop_menu = true }
	case .Travel:
		travel_to_stairs(g)
	case .Fire:
		if !R.can_fire(d.pc) {
			log_add(g, "You have nothing to shoot with.")
		} else if i := nearest_target(g, true); i >= 0 {
			D.pc_attack(d, i)
		} else {
			log_add(g, "Nothing to shoot at.")
		}
	case .Attack: // melee or a shot at the nearest thing, even one that ignores you
		if i := nearest_target(g, true); i >= 0 {
			D.pc_attack(d, i)
		} else {
			log_add(g, "Nothing in reach to attack.")
		}
	}
	after_action(g)
}

// QA: a hunting monster of this kind, `dist` tiles of walking from the PC, for looking at fights.
debug_add_hunter :: proc(g: ^Game, kind: R.Monster, dist: int) -> bool {
	d := &g.delve
	if g.screen != .Delve || d.mob_count >= D.MAX_MOBS || d.group_count >= D.MAX_GROUPS { return false }
	grid: D.Grid
	D.bfs(d, d.pos, &grid)
	for y in 0 ..< D.H {
		for x in 0 ..< D.W {
			p := D.Pos{x, y}
			if grid[y][x] != dist || D.tile_occupied(d, p) { continue }
			gi := d.group_count
			d.mobs[d.mob_count] = D.Mob{c = R.new_npc(kind), kind = kind, pos = p, group = gi, state = .Hunting}
			d.groups[gi] = {size = 1, reacted = true, reaction = .Hostile}
			d.mob_count += 1
			d.group_count += 1
			return true
		}
	}
	return false
}
