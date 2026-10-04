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
}

BOTS := [?]Bot{
	{"Brave (fights everything)", 999, 99, true, false, 0, 0, 99},
	{"Careful (flees big threats)", 7, 2, false, false, 0, 0, 99},
	{"Careful + pushes", 7, 2, false, false, 1, 1, 99},
	{"Coward (flees any hunter)", 0, 1, false, false, 0, 0, 99},
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
}

debug_timeouts := false

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
	ranged := R.WEAPONS[d.pc.weapon].ranged && D.los(d, d.pos, d.mobs[i].pos)
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
	d: D.Delve
	D.init_delve(&d, seed, depth, make_pc(r, kit), bot.push_att, bot.push_def)
	D.notice(&d)
	skip: [D.MAX_ROOMS]bool
	going_home: Ending
	heading_home := false
	stuck := 0
	last_pos := d.pos
	loop: for iter in 0 ..< 700 {
		if d.result != .Running { break }
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
		case d.items >= bot.loot_goal:     why = .Home_done
		case stuck >= 4:                   why = .Home_stuck
		}
		if why != nil && why != .Died {
			heading_home = true
			going_home = why
			continue
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
		goal: D.Pos
		have_goal := false
		g: D.Grid
		blocked: D.Blocked
		for i in 0 ..< d.mob_count { if D.blocks_pc(d.mobs[i]) { blocked[d.mobs[i].pos.y][d.mobs[i].pos.x] = true } }
		if have_avoid { for y in 0 ..< D.H { for x in 0 ..< D.W { if avoid[y][x] { blocked[y][x] = true } } } }
		D.bfs(&d, d.pos, &g, &blocked)
		best := D.INF
		for i in 0 ..< d.loot_count {
			l := d.loot[i]
			if l.taken || !l.seen || R.slots_free(d.pc) < l.slots { continue }
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
	if d.result == .Running && debug_timeouts {
		fmt.printf("TIMEOUT seed %d depth %d: pos %v stairs %v light %d turns %d items %d hunters %d wounds %d heading_home %v stuck %d visited %v\n", seed, depth, d.pos, d.stairs, d.light, d.turns, d.items, hunters_count(&d), d.pc.wounds, heading_home, stuck, d.visited)
		for i in 0 ..< d.mob_count { m := d.mobs[i]; if m.c.alive { fmt.printf("   %s at %v state %v seen %v\n", m.c.name, m.pos, m.state, m.seen) } }
	}
	for i in 0 ..< d.room_count { if d.visited[i] { res.rooms_visited += 1 } }
	for i in 0 ..< d.loot_count { if d.loot[i].seen { res.loot_seen += 1 } }
	res.slots_free_end = R.slots_free(d.pc)
	res.rounds = d.rounds
	res.turns = d.turns
	res.items = d.items
	switch d.result {
	case .Died:
		res.ending = .Died
		res.killer = d.killer
	case .Exited:
		res.ending = going_home
		res.gold = d.carried_gp
		res.xp = d.xp + d.carried_gp // 1 GP of treasure returned is 1 XP, plus 25 per HD defeated
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
	// where does the loot go? Careful bot, Sword+Light, depth 1
	{
		d: D.Delve
		tot_loot, tot_items, tot_rooms, tot_visited, tot_gold_avail, tot_seen, tot_free := 0, 0, 0, 0, 0, 0, 0
		for n in 0 ..< runs {
			seed := u64(1 * 1_000_003 + n + 1)
			res := play_delve(r, seed, 1, KITS[2], BOTS[1])
			D.init_delve(&d, seed, 1, make_pc(r, KITS[2]))
			tot_loot += d.loot_count
			for i in 0 ..< d.loot_count { tot_gold_avail += d.loot[i].gp }
			tot_rooms += d.room_count
			tot_items += res.items
			tot_visited += res.rooms_visited
			tot_seen += res.loot_seen
			tot_free += res.slots_free_end
		}
		fmt.printf("Depth 1 floors: %.1f rooms, %.1f lost items worth %.0f GP in total; the careful bot returned %.1f items (visited %.1f rooms, saw %.1f items, %.1f slots free at the end)\n", f64(tot_rooms) / f64(runs), f64(tot_loot) / f64(runs), f64(tot_gold_avail) / f64(runs), f64(tot_items) / f64(runs), f64(tot_visited) / f64(runs), f64(tot_seen) / f64(runs), f64(tot_free) / f64(runs))
	}
	for depth in 1 ..= 3 {
		bot := BOTS[1]
		kit := KITS[2]
		killers: [R.Monster]int
		endings: [Ending]int
		for n in 0 ..< runs {
			res := play_delve(r, u64(depth * 1_000_003 + n + 1), depth, kit, bot)
			endings[res.ending] += 1
			if res.ending == .Died { killers[res.killer] += 1 }
		}
		fmt.printf("Depth %d, %s, %s: endings", depth, bot.name, kit.name)
		for e in Ending { if endings[e] > 0 { fmt.printf(" %v=%d", e, endings[e]) } }
		fmt.printf("; killers")
		for m in R.Monster { if killers[m] > 0 { fmt.printf(" %s=%d", R.MONSTERS[m].name, killers[m]) } }
		fmt.println()
	}
}
