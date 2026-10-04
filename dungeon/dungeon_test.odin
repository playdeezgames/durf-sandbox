package dungeon

import "core:testing"
import R "../rules"

hardy :: proc() -> R.Creature {
	c := R.Creature{name = "hardy", is_pc = true, attrs = {.STR = 3, .DEX = 3, .WIL = 3}, hd = 12, weapon = .Sword, alive = true, ml = -1}
	return c
}

// A straight corridor y=5 from x=1 to x=40 with the stairs at x=1. For testing movement rules.
corridor :: proc(d: ^Delve, pc: R.Creature, pc_x: int) {
	init_delve(d, 1, 1, pc)
	d.tiles = {}
	d.mob_count = 0
	d.loot_count = 0
	d.group_count = 0
	d.groups = {}
	d.room_count = 1
	d.rooms[0] = Room{1, 5, 40, 1}
	for x in 1 ..= 40 { d.tiles[5][x] = .Floor }
	d.stairs = {1, 5}
	d.tiles[5][1] = .Stairs
	d.pos = {pc_x, 5}
}

add_mob :: proc(d: ^Delve, kind: R.Monster, x: int, state: Mob_State) {
	i := d.mob_count
	d.mobs[i] = Mob{c = R.new_npc(kind), kind = kind, pos = {x, 5}, group = d.group_count, state = state}
	d.groups[d.group_count] = {size = 1, reacted = true, reaction = .Indifferent}
	d.group_count += 1
	d.mob_count += 1
}

reachable_all :: proc(d: ^Delve, p: Pos, g: ^Grid) -> bool { return g[p.y][p.x] != INF }

@(test)
generation_is_connected_and_populated :: proc(t: ^testing.T) {
	d: Delve
	for depth in 1 ..= 3 {
		for seed in 1 ..= 300 {
			init_delve(&d, u64(seed), depth, hardy())
			testing.expectf(t, d.room_count >= 3, "seed %d depth %d made only %d rooms", seed, depth, d.room_count)
			g: Grid
			bfs(&d, d.stairs, &g)
			for i in 0 ..< d.room_count {
				testing.expect(t, reachable_all(&d, room_center(d.rooms[i]), &g), "every room is reachable")
			}
			testing.expect(t, d.loot_count >= 3, "at least three lost items")
			for i in 0 ..< d.loot_count {
				l := d.loot[i]
				testing.expect(t, walkable(&d, l.pos) && reachable_all(&d, l.pos, &g), "loot is reachable")
				testing.expect(t, l.gp > 0 && l.slots >= 1, "loot has value and weight")
			}
			for i in 0 ..< d.mob_count {
				m := d.mobs[i]
				testing.expect(t, walkable(&d, m.pos) && reachable_all(&d, m.pos, &g), "monsters stand on reachable floor")
				testing.expect(t, m.pos != d.stairs, "nothing waits on the stairs")
				for j in i + 1 ..< d.mob_count { testing.expect(t, d.mobs[j].pos != m.pos, "no two monsters share a tile") }
				in_start := m.pos.x >= d.rooms[0].x && m.pos.x < d.rooms[0].x + d.rooms[0].w && m.pos.y >= d.rooms[0].y && m.pos.y < d.rooms[0].y + d.rooms[0].h
				testing.expect(t, !in_start, "the start room is safe")
			}
		}
	}
}

@(test)
generation_is_deterministic :: proc(t: ^testing.T) {
	a, b: Delve
	init_delve(&a, 777, 2, hardy())
	init_delve(&b, 777, 2, hardy())
	testing.expect(t, a.tiles == b.tiles, "same seed, same map")
	testing.expect_value(t, a.mob_count, b.mob_count)
	testing.expect_value(t, a.loot_count, b.loot_count)
	for i in 0 ..< a.mob_count { testing.expect(t, a.mobs[i].pos == b.mobs[i].pos && a.mobs[i].kind == b.mobs[i].kind, "same monsters") }
}

@(test)
walls_block_sight :: proc(t: ^testing.T) {
	d: Delve
	corridor(&d, hardy(), 10)
	testing.expect(t, los(&d, {10, 5}, {16, 5}), "a clear corridor is visible")
	d.tiles[5][13] = .Wall
	testing.expect(t, !los(&d, {10, 5}, {16, 5}), "a wall blocks sight")
	testing.expect(t, los(&d, {10, 5}, {12, 5}), "tiles before the wall are visible")
}

@(test)
fleeing_at_equal_speed_is_never_caught_from_three_tiles :: proc(t: ^testing.T) {
	// Book-faithful retreat (decision C): a second move at the same speed. The chaser moves and then
	// moves again, so from 3 tiles away it never gets an attack in.
	for seed in 1 ..= 200 {
		d: Delve
		corridor(&d, hardy(), 20)
		R.rng_seed(&d.rng, u64(seed))
		add_mob(&d, .Dog, 23, .Hunting)
		for _ in 0 ..< 12 {
			round_move(&d, d.stairs)
			if d.pos == d.stairs { break }
		}
		testing.expect_value(t, d.pc.wounds, 0)
		testing.expect_value(t, d.pc.armor, 0)
		testing.expect(t, d.pos == d.stairs, "the PC reaches the stairs")
		testing.expect(t, exit_delve(&d), "and can leave")
		testing.expect_value(t, d.result, Result_Kind.Exited)
	}
}

@(test)
disengaging_from_an_adjacent_monster_costs_at_most_one_exchange :: proc(t: ^testing.T) {
	// An adjacent chaser keeps pace. It attacks the first time it wins initiative while still
	// adjacent; the gap then settles at 3 tiles and it never attacks again (equal speed).
	flights_hit, n := 0, 400
	for seed in 1 ..= n {
		d: Delve
		corridor(&d, hardy(), 20)
		R.rng_seed(&d.rng, u64(seed))
		add_mob(&d, .Dog, 21, .Hunting)
		hit_rounds := 0
		for _ in 0 ..< 9 {
			before := d.pc.wounds
			round_move(&d, d.stairs)
			if d.pc.wounds > before { hit_rounds += 1 }
		}
		testing.expect(t, hit_rounds <= 1, "at most one bite during the whole flight")
		if hit_rounds == 1 { flights_hit += 1 }
	}
	testing.expectf(t, flights_hit > 0 && flights_hit < n, "the dog landed a bite in %d of %d flights", flights_hit, n)
}

@(test)
only_hunters_chase :: proc(t: ^testing.T) {
	d: Delve
	corridor(&d, hardy(), 20)
	add_mob(&d, .Dog, 24, .Neutral)
	add_mob(&d, .Dog, 26, .Idle)
	for _ in 0 ..< 6 { round_move(&d, {5, 5}) } // walks away from both
	testing.expect_value(t, d.mobs[0].pos.x, 24)
	testing.expect_value(t, d.mobs[1].pos.x, 26)
}

@(test)
reaction_roll_decides_who_hunts :: proc(t: ^testing.T) {
	hunting, n := 0, 3000
	for seed in 1 ..= n {
		d: Delve
		corridor(&d, hardy(), 10)
		R.rng_seed(&d.rng, u64(seed))
		add_mob(&d, .Goose, 13, .Idle)
		d.groups[0].reacted = false
		notice(&d)
		testing.expect(t, d.mobs[0].state != .Idle, "seen monsters have reacted")
		if d.mobs[0].state == .Hunting { hunting += 1 }
	}
	// Hostile or Unfriendly is 2d6 of 2 to 5: 10 of 36
	testing.expectf(t, abs(f64(hunting) / f64(n) - 10.0 / 36.0) < 0.03, "%d of %d hunted", hunting, n)
}

@(test)
unseen_monsters_stay_idle :: proc(t: ^testing.T) {
	d: Delve
	corridor(&d, hardy(), 10)
	add_mob(&d, .Goose, 30, .Idle) // 20 tiles away, beyond sight
	d.groups[0].reacted = false
	notice(&d)
	testing.expect_value(t, d.mobs[0].state, Mob_State.Idle)
}

@(test)
loot_is_limited_by_free_slots :: proc(t: ^testing.T) {
	d: Delve
	pc := hardy()
	corridor(&d, pc, 10)
	d.pc.item_slots = R.slots_total(d.pc) - 1 // one slot free
	d.loot[0] = Loot{pos = {11, 5}, gp = 100, slots = 2}
	d.loot[1] = Loot{pos = {12, 5}, gp = 50, slots = 1}
	d.loot_count = 2
	round_move(&d, {12, 5})
	testing.expect(t, !d.loot[0].taken, "a 2 slot item does not fit into 1 free slot")
	testing.expect(t, d.loot[1].taken, "a 1 slot item does")
	testing.expect_value(t, d.carried_gp, 50)
	testing.expect_value(t, R.slots_free(d.pc), 0)
}

@(test)
travel_costs_turns_and_the_torch_runs_out :: proc(t: ^testing.T) {
	d: Delve
	corridor(&d, hardy(), 40)
	// 39 tiles out of combat: three Turns of 10 tiles
	for d.pos != d.stairs { round_move(&d, d.stairs) }
	testing.expect_value(t, d.turns, 3)
	testing.expect_value(t, d.light, LIGHT_START - 3)
	testing.expect_value(t, sight_radius(&d), SIGHT)
	d.light = 0
	testing.expect_value(t, sight_radius(&d), SIGHT_DARK)
}

@(test)
only_the_stairs_exit :: proc(t: ^testing.T) {
	d: Delve
	corridor(&d, hardy(), 10)
	testing.expect(t, !exit_delve(&d), "cannot leave from the middle of a corridor")
	d.pos = d.stairs
	testing.expect(t, exit_delve(&d), "can leave from the stairs")
}

@(test)
wandering_groups_appear_about_one_turn_in_six :: proc(t: ^testing.T) {
	spawned, n := 0, 3000
	for seed in 1 ..= n {
		d: Delve
		init_delve(&d, u64(seed), 1, hardy())
		before := d.group_count
		R.rng_seed(&d.rng, u64(seed) * 7919)
		new_turn(&d)
		if d.group_count > before { spawned += 1 }
	}
	// 1 in 6, and some spawns find no room out of sight
	testing.expectf(t, f64(spawned) / f64(n) > 0.10 && f64(spawned) / f64(n) < 0.20, "%d of %d turns spawned a group", spawned, n)
}

@(test)
fled_monsters_run_away_instead_of_blocking :: proc(t: ^testing.T) {
	d: Delve
	corridor(&d, hardy(), 10)
	add_mob(&d, .Goose, 13, .Fled)
	round_move(&d, {10, 5}) // the PC stays; the goose runs
	testing.expect(t, d.mobs[0].pos.x > 13, "a fled monster moves away from the PC")
	for _ in 0 ..< 30 { round_move(&d, {10, 5}) }
	testing.expect(t, d.mobs[0].pos.x == 40, "and keeps going to the far end")
}

@(test)
a_monster_in_the_way_can_be_found_and_fought :: proc(t: ^testing.T) {
	d: Delve
	corridor(&d, hardy(), 20)
	add_mob(&d, .Goose, 15, .Hunting)
	testing.expect_value(t, first_blocker(&d, d.stairs), 0)
	testing.expect_value(t, first_blocker(&d, {30, 5}), -1) // the other way is clear
	d.mobs[0].c.paralyzed = 99 // (a hunting monster would walk to us; this one is held in place)
	d.mobs[0].state = .Fled
	d.mobs[0].pos = {15, 5}
	d.mobs[0].c.alive = true
	testing.expect_value(t, first_blocker(&d, d.stairs), 0) // a fled monster still blocks until it runs
}

@(test)
the_pc_swaps_places_with_a_neutral_monster :: proc(t: ^testing.T) {
	d: Delve
	corridor(&d, hardy(), 20)
	add_mob(&d, .Goose, 15, .Neutral)
	for _ in 0 ..< 10 { round_move(&d, d.stairs) }
	testing.expect_value(t, d.pos, d.stairs)
	testing.expect(t, d.mobs[0].c.alive && d.mobs[0].state == .Neutral, "the goose is unharmed and still neutral")
	testing.expect_value(t, first_blocker(&d, {30, 5}), -1)
}
