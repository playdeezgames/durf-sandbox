package main

// Spike A2: whole delves on the grid, played by a bot under different policies.
// Measures whether a starting character can survive a floor, and what it brings back.

import "core:fmt"
import D "../dungeon"
import R "../rules"

Bot :: struct {
	name:             string,
	fight_max_danger: int, // fight hunters only while their combined danger is at most this
	flee_wounds:      int, // head for the stairs once Wounds reach this
	attack_neutrals:  bool, // kill things that ignore you (for XP)
	avoid_neutrals:   bool, // path around ignoring monsters
	push_att:         int,
	push_def:         int,
	loot_goal:        int, // go home after carrying this many items
	drop_junk:        bool, // drop junk belongings to fit a lost item (decision F)
	traps:            Trap_Policy,
}

// Ignore: walks on (a trap it has never found goes off). Careful: searches when it sees a clue and disarms what it finds.
Trap_Policy :: enum { Ignore, Careful }

BOTS := [?]Bot{
	{"Brave (fights everything)", 999, 99, true, false, 0, 0, 99, true, .Ignore},
	{"Careful (flees big threats)", 7, 2, false, false, 0, 0, 99, true, .Ignore},
	{"Careful, never drops", 7, 2, false, false, 0, 0, 99, false, .Ignore},
	{"Careful + pushes", 7, 2, false, false, 1, 1, 99, true, .Ignore},
	{"Coward (flees any hunter)", 0, 1, false, false, 0, 0, 99, true, .Ignore},
	{"Careful + searches for traps", 7, 2, false, false, 0, 0, 99, true, .Careful},
}

Ending :: enum { Died, Home_done, Home_light, Home_hurt, Home_fled, Home_stuck, Timeout }

Delve_Result :: struct {
	ending: Ending,
	gold:   int, // banked (0 if died)
	xp:     int, // banked (0 if died)
	items:  int,
	rounds: int,
	turns:  int,
	killer: R.Monster,
	rooms_visited: int,
	loot_seen: int,
	slots_free_end: int,
	by_trap: bool,
	trap: R.Trap_Kind,
	traps_sprung, traps_disarmed, searches: int,
}

debug_timeouts := false
trace_on := false // print one line per bot decision (use: sim trace)
replaying := false

// A clue mark of a still-hidden trap in view and close by (what a player would see and search for).
clue_in_view :: proc(d: ^D.Delve) -> bool {
	for dy in -D.CLUE_SIGHT ..= D.CLUE_SIGHT {
		for dx in -D.CLUE_SIGHT ..= D.CLUE_SIGHT {
			p := d.pos + D.Pos{dx, dy}
			if !D.clue_visible(d, p) { continue }
			if _, ok := D.clue_at(d, p); !ok { continue }
			for i in 0 ..< d.trap_count { // only clues of traps not yet found
				t := d.traps[i]
				if t.armed && !t.revealed { for k in 0 ..< t.clue_count { if t.clues[k] == p { return true } } }
			}
		}
	}
	return false
}

junk_index :: proc(d: ^D.Delve) -> int {
	for i in 0 ..< d.pc.inv_count { if d.pc.inv[i].kind == .Junk { return i } }
	return -1
}

hunters_count :: proc(d: ^D.Delve) -> int { _, n := hunting_danger(d); return n }

danger :: proc(m: R.Monster) -> int {
	def := R.MONSTERS[m]
	return def.skill + 2 * def.hd + def.dmg
}

hunting_danger :: proc(d: ^D.Delve) -> (total, count: int) {
	for i in 0 ..< d.mob_count {
		m := d.mobs[i]
		if D.mob_alive(m) && m.state == .Hunting && D.can_see(d, m.pos) { total += danger(m.kind); count += 1 }
	}
	return
}

nearest_hunter :: proc(d: ^D.Delve) -> int {
	best, bi := 9999, -1
	for i in 0 ..< d.mob_count {
		m := d.mobs[i]
		if D.mob_alive(m) && m.state == .Hunting && D.can_see(d, m.pos) && D.manhattan(m.pos, d.pos) < best { best = D.manhattan(m.pos, d.pos); bi = i }
	}
	return bi
}

nearest_seen_neutral :: proc(d: ^D.Delve) -> int {
	best, bi := 9999, -1
	for i in 0 ..< d.mob_count {
		m := d.mobs[i]
		if D.mob_alive(m) && m.state == .Neutral && m.seen && D.manhattan(m.pos, d.pos) < best { best = D.manhattan(m.pos, d.pos); bi = i }
	}
	return bi
}

// Fight a target; if something stands in the way, fight that first (bump-attack).
engage :: proc(d: ^D.Delve, i: int) {
	g: D.Grid
	blocked: D.Blocked
	for j in 0 ..< d.mob_count { if D.blocks_pc(d.mobs[j]) && j != i { blocked[d.mobs[j].pos.y][d.mobs[j].pos.x] = true } }
	D.bfs(d, d.mobs[i].pos, &g, &blocked)
	ranged := R.can_fire(d.pc) && D.los(d, d.pos, d.mobs[i].pos)
	if g[d.pos.y][d.pos.x] == D.INF && !ranged {
		if j := D.first_blocker(d, d.mobs[i].pos); j >= 0 && j != i { D.round_fight(d, j); return }
	}
	D.round_fight(d, i)
}

go_home :: proc(d: ^D.Delve, why: Ending) -> (ending: Ending, done: bool) {
	if d.pos == d.stairs {
		D.exit_delve(d)
		return why, true
	}
	// a monster standing in the way: fight it if it is adjacent
	g: D.Grid
	blocked: D.Blocked
	for i in 0 ..< d.mob_count { if D.blocks_pc(d.mobs[i]) { blocked[d.mobs[i].pos.y][d.mobs[i].pos.x] = true } }
	blocked[d.stairs.y][d.stairs.x] = false
	D.bfs(d, d.stairs, &g, &blocked)
	if g[d.pos.y][d.pos.x] == D.INF {
		if i := D.first_blocker(d, d.stairs); i >= 0 { D.round_fight(d, i); return why, false }
	}
	D.round_move(d, d.stairs)
	return why, false
}

play_delve :: proc(r: ^R.Rng, seed: u64, depth: int, kit: Kit, bot: Bot) -> (res: Delve_Result) {
	saved := r^
	d: D.Delve
	D.init_delve(&d, seed, depth, make_pc(r, kit), bot.push_att, bot.push_def)
	D.notice(&d)
	skip: [D.MAX_ROOMS]bool
	going_home: Ending
	heading_home := false
	stuck := 0
	last_pos := d.pos
	last_search := D.Pos{-99, -99}
	loop: for iter in 0 ..< 700 {
		if d.result != .Running { break }
		if trace_on && (iter < 60 || iter > 640) {
			tot, n := hunting_danger(&d)
			fmt.printf("iter %d pos %v turn %d light %d wounds %d hunters %d danger %d heading_home %v items %d slots_free %d\n", iter, d.pos, d.turns, d.light, d.pc.wounds, n, tot, heading_home, D.lost_count(&d), R.slots_free(d.pc))
			for i in 0 ..< d.mob_count { m := d.mobs[i]; if m.c.alive && (m.state == .Hunting || m.state == .Fled) { fmt.printf("    %s %v %v seen=%v\n", m.c.name, m.pos, m.state, D.can_see(&d, m.pos)) } }
		}
		if d.pos == last_pos { stuck += 1 } else { stuck = 0; last_pos = d.pos }

		// 1. something hunting us
		if tot, n := hunting_danger(&d); n > 0 {
			if tot > bot.fight_max_danger || d.pc.wounds >= bot.flee_wounds {
				heading_home = true
				going_home = .Home_fled
			} else {
				engage(&d, nearest_hunter(&d))
				continue
			}
		}
		if heading_home {
			why, done := go_home(&d, going_home)
			if done { break loop }
			_ = why
			continue
		}

		// 2. nothing hunting: decide whether to go home
		why: Ending
		switch {
		case d.light <= 1:                 why = .Home_light
		case d.pc.wounds >= bot.flee_wounds: why = .Home_hurt
		case D.lost_count(&d) >= bot.loot_goal: why = .Home_done
		case stuck >= 4:                   why = .Home_stuck
		}
		if why != nil && why != .Died {
			heading_home = true
			going_home = why
			continue
		}

		// 2b. traps: disarm one found next to us; search when a clue is in view
		if bot.traps == .Careful {
			if D.adjacent_known_trap(&d) >= 0 { D.round_disarm(&d); stuck = 0; continue }
			if D.manhattan(d.pos, last_search) >= 3 && clue_in_view(&d) {
				last_search = d.pos
				D.round_search(&d)
				stuck = 0
				continue
			}
		}

		// 3. attack things that ignore us, if the policy says so
		if bot.attack_neutrals {
			if i := nearest_seen_neutral(&d); i >= 0 { engage(&d, i); continue }
		}

		// 4. pick a goal: seen loot that fits, else the nearest unvisited room
		avoid: D.Blocked
		have_avoid := false
		if bot.avoid_neutrals {
			for i in 0 ..< d.mob_count {
				m := d.mobs[i]
				if !D.mob_alive(m) || m.state != .Neutral || !m.seen { continue }
				for dy in -2 ..= 2 { for dx in -2 ..= 2 {
					p := m.pos + D.Pos{dx, dy}
					if D.in_bounds(p) && abs(dx) + abs(dy) <= 2 { avoid[p.y][p.x] = true; have_avoid = true }
				} }
			}
			avoid[d.pos.y][d.pos.x] = false
		}
		// 3b. standing on a lost item: take it, dropping junk first if that makes it fit
		for i in 0 ..< d.loot_count {
			l := d.loot[i]
			if l.taken || l.dropped || l.pos != d.pos { continue }
			if !R.can_carry(d.pc, l.item) && bot.drop_junk {
				for _ in 0 ..< 8 { // capped: an unbounded loop here would hang the whole run
					if R.slots_free(d.pc) >= l.item.slots { break }
					j := junk_index(&d)
					if j < 0 { break }
					D.round_drop(&d, j)
					stuck = 0 // an action, not being stuck
				}
			}
			if R.can_carry(d.pc, l.item) { D.round_pickup(&d); stuck = 0; continue loop }
		}
		goal: D.Pos
		have_goal := false
		g: D.Grid
		blocked: D.Blocked
		for i in 0 ..< d.mob_count { if D.blocks_pc(d.mobs[i]) { blocked[d.mobs[i].pos.y][d.mobs[i].pos.x] = true } }
		if have_avoid { for y in 0 ..< D.H { for x in 0 ..< D.W { if avoid[y][x] { blocked[y][x] = true } } } }
		D.bfs(&d, d.pos, &g, &blocked)
		best := D.INF
		junk_slots := 0
		if bot.drop_junk { for i in 0 ..< d.pc.inv_count { if d.pc.inv[i].kind == .Junk { junk_slots += d.pc.inv[i].slots } } }
		for i in 0 ..< d.loot_count {
			l := d.loot[i]
			if l.taken || l.dropped || !l.seen || R.slots_free(d.pc) + junk_slots < l.item.slots { continue }
			if dist := g[l.pos.y][l.pos.x]; dist < best { best = dist; goal = l.pos; have_goal = true }
		}
		if !have_goal {
			for i in 0 ..< d.room_count {
				if d.visited[i] || skip[i] { continue }
				c := D.room_center(d.rooms[i])
				dist := g[c.y][c.x]
				if dist == D.INF { skip[i] = true; continue }
				if dist < best { best = dist; goal = c; have_goal = true }
			}
		}
		if !have_goal {
			heading_home = true
			going_home = .Home_done
			continue
		}
		D.round_move(&d, goal, &avoid if have_avoid else nil)
	}
	if d.result == .Running && debug_timeouts && !replaying && !trace_on {
		fmt.printf("--- replaying a timeout: %s, seed %d, depth %d, %s\n", bot.name, seed, depth, kit.name)
		replaying = true
		trace_on = true
		rr := saved
		play_delve(&rr, seed, depth, kit, bot)
		trace_on = false
		replaying = false
	}
	if d.result == .Running && debug_timeouts && !replaying {
		fmt.printf("TIMEOUT seed %d depth %d: pos %v stairs %v light %d turns %d items %d hunters %d wounds %d heading_home %v stuck %d visited %v\n", seed, depth, d.pos, d.stairs, d.light, d.turns, D.lost_count(&d), hunters_count(&d), d.pc.wounds, heading_home, stuck, d.visited)
		for i in 0 ..< d.mob_count { m := d.mobs[i]; if m.c.alive { fmt.printf("   %s at %v state %v seen %v\n", m.c.name, m.pos, m.state, m.seen) } }
	}
	for i in 0 ..< d.room_count { if d.visited[i] { res.rooms_visited += 1 } }
	for i in 0 ..< d.loot_count { if d.loot[i].seen && !d.loot[i].dropped { res.loot_seen += 1 } }
	res.slots_free_end = R.slots_free(d.pc)
	res.traps_sprung, res.traps_disarmed, res.searches = d.traps_sprung, d.traps_disarmed, d.searches
	res.rounds = d.rounds
	res.turns = d.turns
	res.items = D.lost_count(&d)
	switch d.result {
	case .Died:
		res.ending = .Died
		res.killer = d.killer
		res.by_trap = d.trap_death
		res.trap = d.killer_trap
	case .Exited:
		res.ending = going_home
		res.gold = D.lost_gp(&d)
		res.xp = d.xp + D.lost_gp(&d) // 1 GP of treasure returned is 1 XP, plus 25 per HD defeated
	case .Running:
		res.ending = .Timeout
	}
	return
}

delve_report :: proc(r: ^R.Rng, runs: int) {
	fmt.printf("DURF rules %s. Whole delves on the grid, %d per cell, a fresh random starting character each.\n", R.RULES_VERSION, runs)
	fmt.println("Cell = survived% / gold banked per delve / XP per delve (XP = gold returned + kills; a death banks nothing)")
	fmt.println("Retreat is the book's: a second move at the same speed, no free attack.\n")
	for depth in 1 ..= 3 {
		fmt.printf("######## Depth %d ########\n", depth)
		fmt.printf("%-30s", "")
		for kit in KITS { fmt.printf("%-22s", kit.name) }
		fmt.println()
		for bot in BOTS {
			fmt.printf("%-30s", bot.name)
			for kit in KITS {
				survived, gold, xp := 0, 0, 0
				for n in 0 ..< runs {
					res := play_delve(r, u64(depth * 1_000_003 + n + 1), depth, kit, bot)
					if res.ending != .Died { survived += 1 }
					gold += res.gold
					xp += res.xp
				}
				cell := fmt.tprintf("%2.0f%% / %3.0f / %3.0f", 100.0 * f64(survived) / f64(runs), f64(gold) / f64(runs), f64(xp) / f64(runs))
				fmt.printf("%-22s", cell)
			}
			fmt.println()
		}
		fmt.println()
	}
	// who kills us, and how do delves end, for the careful bot on depth 1 with the Sword+Light kit
	// where does the loot go? Careful bot, Sword+Light, depth 1, with and without dropping junk
	for bi in 1 ..= 2 {
		d: D.Delve
		tot_loot, tot_items, tot_rooms, tot_visited, tot_gold_avail, tot_seen, tot_free := 0, 0, 0, 0, 0, 0, 0
		for n in 0 ..< runs {
			seed := u64(1 * 1_000_003 + n + 1)
			res := play_delve(r, seed, 1, KITS[2], BOTS[bi])
			D.init_delve(&d, seed, 1, make_pc(r, KITS[2]))
			tot_loot += d.loot_count
			for i in 0 ..< d.loot_count { tot_gold_avail += d.loot[i].item.gp }
			tot_rooms += d.room_count
			tot_items += res.items
			tot_visited += res.rooms_visited
			tot_seen += res.loot_seen
			tot_free += res.slots_free_end
		}
		fmt.printf("Depth 1 floors, %s: %.1f rooms, %.1f lost items worth %.0f GP; returned %.1f items (visited %.1f rooms, saw %.1f items, %.1f slots free at the end)\n", BOTS[bi].name, f64(tot_rooms) / f64(runs), f64(tot_loot) / f64(runs), f64(tot_gold_avail) / f64(runs), f64(tot_items) / f64(runs), f64(tot_visited) / f64(runs), f64(tot_seen) / f64(runs), f64(tot_free) / f64(runs))
	}
	for depth in 1 ..= 3 {
		bot := BOTS[1]
		kit := KITS[2]
		killers: [R.Monster]int
		endings: [Ending]int
		trap_deaths := 0
		for n in 0 ..< runs {
			res := play_delve(r, u64(depth * 1_000_003 + n + 1), depth, kit, bot)
			endings[res.ending] += 1
			if res.ending == .Died && !res.by_trap { killers[res.killer] += 1 }
			if res.ending == .Died && res.by_trap { trap_deaths += 1 }
		}
		fmt.printf("Depth %d, %s, %s: endings", depth, bot.name, kit.name)
		for e in Ending { if endings[e] > 0 { fmt.printf(" %v=%d", e, endings[e]) } }
		fmt.printf("; killers")
		for m in R.Monster { if killers[m] > 0 { fmt.printf(" %s=%d", R.MONSTERS[m].name, killers[m]) } }
		if trap_deaths > 0 { fmt.printf(" traps=%d", trap_deaths) }
		fmt.println()
	}
	trap_report(r, runs)
}

// Traps: for each bot, the cost of ignoring them against searching for them (Sword+Light kit).
trap_report :: proc(r: ^R.Rng, runs: int) {
	fmt.println("\nTraps (Sword+Light kit): sprung on the PC, disarmed, searches, deaths by trap, survival, Turns used, gold")
	for depth in 1 ..= 3 {
		for bi in 1 ..= 5 {
			if bi != 1 && bi != 5 { continue }
			bot := BOTS[bi]
			sprung, disarmed, searches, trap_deaths, survived, turns, gold := 0, 0, 0, 0, 0, 0, 0
			for n in 0 ..< runs {
				res := play_delve(r, u64(depth * 1_000_003 + n + 1), depth, KITS[2], bot)
				sprung += res.traps_sprung; disarmed += res.traps_disarmed; searches += res.searches
				if res.ending == .Died && res.by_trap { trap_deaths += 1 }
				if res.ending != .Died { survived += 1 }
				turns += res.turns; gold += res.gold
			}
			f := f64(runs)
			fmt.printf("Depth %d, %-30s sprung %.2f, disarmed %.2f, searches %.2f, trap deaths %.1f%%, survived %.0f%%, Turns %.1f, gold %.0f\n", depth, bot.name, f64(sprung) / f, f64(disarmed) / f, f64(searches) / f, 100 * f64(trap_deaths) / f, 100 * f64(survived) / f, f64(turns) / f, f64(gold) / f)
		}
	}
}
