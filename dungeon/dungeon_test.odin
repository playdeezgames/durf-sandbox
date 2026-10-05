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
				testing.expect(t, l.item.gp > 0 && l.item.slots >= 1 && l.item.kind == .Lost, "loot is a lost item with value and weight")
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
pick_up_is_explicit_and_limited_by_free_slots :: proc(t: ^testing.T) {
	d: Delve
	corridor(&d, hardy(), 10)
	for d.pc.inv_count < R.MAX_ITEMS && R.slots_free(d.pc) > 1 { R.add_item(&d.pc, R.item_junk("x")) } // one slot free
	d.loot[0] = Loot{pos = {11, 5}, item = {name = "big", kind = .Lost, slots = 2, gp = 100}}
	d.loot[1] = Loot{pos = {12, 5}, item = {name = "small", kind = .Lost, slots = 1, gp = 50}}
	d.loot_count = 2
	round_move(&d, {12, 5}) // walks over both: nothing is taken by walking
	testing.expect_value(t, lost_count(&d), 0)
	testing.expect(t, !d.loot[1].taken, "walking onto an item does not take it")
	round_pickup(&d)
	testing.expect(t, d.loot[1].taken, "a 1 slot item fits into 1 free slot")
	testing.expect_value(t, lost_gp(&d), 50)
	testing.expect_value(t, R.slots_free(d.pc), 0)
	d.pos = {11, 5}
	round_pickup(&d)
	testing.expect(t, !d.loot[0].taken, "a 2 slot item does not fit")
}

@(test)
dropping_frees_slots_and_can_be_undone :: proc(t: ^testing.T) {
	d: Delve
	pc := hardy()
	R.add_item(&pc, R.item_weapon(.Dagger))
	R.add_item(&pc, R.item_armor(.Light))
	R.add_item(&pc, R.item_junk("teeth"))
	corridor(&d, pc, 10)
	free0 := R.slots_free(d.pc)
	testing.expect_value(t, d.pc.armor_max, 3)
	round_drop(&d, 2) // the junk
	testing.expect_value(t, R.slots_free(d.pc), free0 + 1)
	testing.expect(t, d.loot[d.loot_count - 1].dropped && d.loot[d.loot_count - 1].item.name == "teeth", "it lies on the floor")
	round_drop(&d, 1) // the armor
	testing.expect_value(t, d.pc.armor_max, 0) // dropping gear removes its effect
	d.pos = d.pos // (standing on the dropped items)
	round_pickup(&d) // picks up one item underfoot
	testing.expect(t, R.slots_free(d.pc) < free0 + 1 + 1, "something was picked up again")
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

@(test)
ranged_player_shots_need_ammo :: proc(t: ^testing.T) {
	d: Delve
	pc := hardy()
	R.add_item(&pc, R.item_weapon(.Dagger))
	R.add_item(&pc, R.item_weapon(.Bow))
	corridor(&d, pc, 10)
	testing.expect_value(t, d.pc.weapon, R.Weapon_Kind.Dagger) // no Ammo: the bow is not wielded
	R.add_item(&d.pc, R.item_ammo())
	testing.expect_value(t, d.pc.weapon, R.Weapon_Kind.Bow)
	testing.expect(t, R.can_fire(d.pc), "with Ammo the bow fires")
}

@(test)
the_ammo_check_runs_when_a_fight_ends :: proc(t: ^testing.T) {
	lows, n := 0, 3000
	for seed in 1 ..= n {
		d: Delve
		pc := hardy()
		R.add_item(&pc, R.item_weapon(.Bow))
		R.add_item(&pc, R.item_ammo())
		corridor(&d, pc, 10)
		R.rng_seed(&d.rng, u64(seed))
		d.pc.shot_this_fight = true // fired during the fight
		turns0 := d.turns
		end_fight(&d)
		testing.expect_value(t, d.turns, turns0 + 1) // clean-up takes a Turn
		testing.expect(t, !d.pc.shot_this_fight, "the check resets the flag")
		if d.pc.ammo_low { lows += 1 }
	}
	testing.expectf(t, abs(f64(lows) / f64(n) - 1.0 / 6.0) < 0.03, "Ammo ran low in %d of %d fights", lows, n)
}

@(test)
no_shots_no_ammo_check :: proc(t: ^testing.T) {
	d: Delve
	pc := hardy()
	R.add_item(&pc, R.item_weapon(.Bow))
	R.add_item(&pc, R.item_ammo())
	corridor(&d, pc, 10)
	for _ in 0 ..< 200 { end_fight(&d) }
	testing.expect(t, !d.pc.ammo_low, "Ammo never runs low if the PC did not shoot")
}

@(test)
only_the_eelfolk_reload :: proc(t: ^testing.T) {
	for kind in ([?]R.Monster{.Eelfolk, .Crossbow_Cultist, .Blowpipe_Imp}) {
		d: Delve
		corridor(&d, hardy(), 10)
		add_mob(&d, kind, 15, .Hunting)
		d.mobs[0].c.stun_used = true
		for _ in 0 ..< 4 {
			monsters_act(&d)
			if kind != .Eelfolk { testing.expect(t, !d.mobs[0].reloading, "only the pistol reloads") }
		}
	}
}

@(test)
depth_two_and_three_rosters_have_ranged_monsters :: proc(t: ^testing.T) {
	d: Delve
	for depth in 2 ..= 3 {
		ranged, total := 0, 0
		for seed in 1 ..= 200 {
			init_delve(&d, u64(seed), depth, hardy())
			for i in 0 ..< d.mob_count { total += 1; if d.mobs[i].c.ranged { ranged += 1 } }
		}
		testing.expectf(t, f64(ranged) / f64(total) > 0.25, "depth %d: %d of %d monsters are ranged", depth, ranged, total)
	}
	// depth 1 stays the easy roster: no ranged monsters
	for seed in 1 ..= 100 {
		init_delve(&d, u64(seed), 1, hardy())
		for i in 0 ..< d.mob_count { testing.expect(t, !d.mobs[i].c.ranged, "depth 1 has no ranged monsters") }
	}
}

@(test)
gecko_stun_costs_turns_and_the_geckos_wander_off :: proc(t: ^testing.T) {
	stunned := 0
	for seed in 1 ..= 400 {
		d: Delve
		pc := hardy()
		pc.attrs = {.STR = 0, .DEX = 0, .WIL = 0} // fails the save 75 percent of the time
		corridor(&d, pc, 20)
		R.rng_seed(&d.rng, u64(seed))
		add_mob(&d, .Echo_Gecko, 21, .Hunting)
		add_mob(&d, .Echo_Gecko, 22, .Hunting)
		d.mobs[1].group = d.mobs[0].group // one group
		light0, turns0 := d.light, d.turns
		monsters_act(&d)
		if d.turns > turns0 {
			lost := d.turns - turns0
			if d.mob_count == 2 { // no wanderer joined
				stunned += 1
				testing.expect(t, lost >= 1 && lost <= 4, "1d4 Turns lost")
				testing.expect_value(t, d.light, light0 - lost)
				testing.expect_value(t, d.mobs[0].state, Mob_State.Neutral)
				testing.expect_value(t, d.mobs[1].state, Mob_State.Neutral)
				testing.expect_value(t, d.pc.paralyzed, 0) // helpless only during the Turns
			}
		}
	}
	testing.expect(t, stunned > 50, "stuns happened")
}

@(test)
pick_up_prefers_lost_items_over_dropped_ones :: proc(t: ^testing.T) {
	d: Delve
	corridor(&d, hardy(), 10)
	// a dropped junk record sits at a LOWER index than the lost item, both underfoot
	d.loot[0] = Loot{pos = {10, 5}, item = R.item_junk("teeth"), dropped = true, seen = true}
	d.loot[1] = Loot{pos = {10, 5}, item = {name = "Umbrella", kind = .Lost, slots = 1, gp = 90}}
	d.loot_count = 2
	testing.expect(t, pick_up(&d), "something is picked up")
	testing.expect(t, d.loot[1].taken && !d.loot[0].taken, "the lost item comes first")
	testing.expect_value(t, lost_count(&d), 1)
}
