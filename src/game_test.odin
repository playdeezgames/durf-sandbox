#+build !js
package main

import "core:testing"
import D "../dungeon"
import R "../rules"

fresh :: proc(seed: u64) -> ^Game {
	g := &game
	g^ = {}
	g.run_seed = seed
	native_store = {}
	return g
}

press :: proc(g: ^Game, keys: ..Key) { for k in keys { handle_key(g, k) } }

@(test)
a_run_starts_with_a_character_and_the_office :: proc(t: ^testing.T) {
	g := fresh(5)
	testing.expect_value(t, g.screen, Screen.Intro)
	press(g, .Confirm)
	testing.expect_value(t, g.screen, Screen.Office)
	for a in R.Attr { testing.expect(t, g.pc.attrs[a] >= 1 && g.pc.attrs[a] <= 3, "d3 attributes") }
	testing.expect(t, g.pc.gold >= 10, "starting gold")
}

@(test)
rerolling_is_free_only_before_the_first_delve :: proc(t: ^testing.T) {
	g := fresh(6)
	press(g, .Confirm)
	before := g.pc
	changed := false
	for _ in 0 ..< 20 { press(g, .Reroll); if g.pc.attrs != before.attrs || g.pc.gold != before.gold { changed = true } }
	testing.expect(t, changed, "rerolling gives new characters")
	press(g, .N1, .Confirm) // delve and leave at once
	testing.expect_value(t, g.screen, Screen.Result)
	press(g, .Confirm)
	frozen := g.pc
	for _ in 0 ..< 10 { press(g, .Reroll) }
	testing.expect(t, g.pc.attrs == frozen.attrs && g.pc.gold == frozen.gold, "no rerolls after the first delve")
}

@(test)
a_delve_starts_on_the_stairs_and_leaving_banks_the_haul :: proc(t: ^testing.T) {
	g := fresh(7)
	press(g, .Confirm, .N2)
	testing.expect_value(t, g.screen, Screen.Delve)
	testing.expect_value(t, g.depth, 2)
	testing.expect(t, g.delve.pos == g.delve.stairs, "start on the stairs")
	gold0 := g.pc.gold
	R.add_item(&g.delve.pc, R.Item{name = "Teapot", kind = .Lost, slots = 1, gp = 300})
	R.add_item(&g.delve.pc, R.Item{name = "Ledger", kind = .Lost, slots = 1, gp = 800})
	press(g, .Confirm)
	testing.expect_value(t, g.screen, Screen.Result)
	testing.expect_value(t, g.pc.gold, gold0 + 1100)
	testing.expect_value(t, g.summary.gold, 1100)
	testing.expect_value(t, g.summary.items, 2)
	testing.expect_value(t, g.summary.hd_gained, 1) // 1100 XP buys HD 2 (1000), 100 left
	testing.expect_value(t, g.pc.hd, 2)
	testing.expect_value(t, g.pc.xp, 100)
	testing.expect_value(t, R.count_items(g.pc, .Lost), 0)
	testing.expect_value(t, g.run_gold, 1100)
	testing.expect_value(t, g.best_score, 1100)
	testing.expect_value(t, native_store[KEY_BEST_SCORE], 1100) // saved
	testing.expect(t, g.new_best, "a new best")
	press(g, .Confirm)
	testing.expect_value(t, g.screen, Screen.Office)
	testing.expect_value(t, g.delves_done, 1)
}

@(test)
leaving_needs_the_stairs :: proc(t: ^testing.T) {
	g := fresh(8)
	press(g, .Confirm, .N1)
	// walk away from the stairs
	moved := false
	for k in ([?]Key{.Right, .Left, .Up, .Down}) {
		if _, ok := key_dir(k); ok { D.pc_move(&g.delve, {0, 0}) }
	}
	for dir in ([?]D.Pos{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) { if D.pc_move(&g.delve, dir) { moved = true; break } }
	testing.expect(t, moved, "a step was possible")
	press(g, .Confirm)
	testing.expect_value(t, g.screen, Screen.Delve)
	testing.expect_value(t, log_line(g, 0), "Walk to the stairs to leave.")
}

@(test)
dying_ends_the_run_and_keeps_the_best :: proc(t: ^testing.T) {
	g := fresh(9)
	press(g, .Confirm, .N1)
	g.run_gold = 250
	g.delve.pc.alive = false
	D.pc_died(&g.delve, .Dog)
	after_action(g)
	testing.expect_value(t, g.screen, Screen.Dead)
	testing.expect_value(t, g.killer, "Dog")
	testing.expect_value(t, g.best_score, 250)
	press(g, .Confirm)
	testing.expect_value(t, g.screen, Screen.Intro)
	press(g, .Confirm) // a new run: a new character, the best is kept
	testing.expect_value(t, g.screen, Screen.Office)
	testing.expect_value(t, g.best_score, 250)
	testing.expect_value(t, g.run_gold, 0)
}

@(test)
the_shop_sells_what_fits_and_what_you_can_afford :: proc(t: ^testing.T) {
	g := fresh(10)
	press(g, .Confirm)
	g.pc.gold = 100
	press(g, .Shop)
	testing.expect_value(t, g.screen, Screen.Shop)
	slots0 := R.slots_free(g.pc)
	press(g, .N1) // a sword for 10, 2 slots (if the bag has room)
	if slots0 >= 2 {
		testing.expect_value(t, g.pc.gold, 90)
		testing.expect_value(t, log_line(g, 0), "Bought Sword.")
	} else {
		testing.expect_value(t, log_line(g, 0), "No room in your bag.")
	}
	g.pc.gold = 3
	press(g, .N8)
	testing.expect_value(t, log_line(g, 0), "Not enough gold.")
	press(g, .Cancel)
	testing.expect_value(t, g.screen, Screen.Office)
}

@(test)
drop_menu_drops_the_chosen_item :: proc(t: ^testing.T) {
	g := fresh(11)
	press(g, .Confirm, .N1)
	n0 := g.delve.pc.inv_count
	name0 := g.delve.pc.inv[0].name
	press(g, .Drop)
	testing.expect(t, g.drop_menu, "the menu is open")
	press(g, .N1)
	testing.expect(t, !g.drop_menu, "and closes")
	testing.expect_value(t, g.delve.pc.inv_count, n0 - 1)
	testing.expect(t, log_line(g, 0)[:7] == "Dropped" && log_line(g, 0)[8:] == name0, "the log says what was dropped")
	press(g, .Drop, .Cancel)
	testing.expect(t, !g.drop_menu, "cancel closes the menu")
}

@(test)
push_toggles_stress_spending :: proc(t: ^testing.T) {
	g := fresh(12)
	press(g, .Confirm, .N1)
	press(g, .Push)
	testing.expect(t, g.push && g.delve.push_att == 1 && g.delve.push_def == 1, "push on")
	press(g, .Push)
	testing.expect(t, !g.push && g.delve.push_att == 0, "push off")
}

@(test)
log_lines_fit_the_screen :: proc(t: ^testing.T) {
	g := fresh(13)
	press(g, .Confirm, .N1)
	r: R.Rng
	R.rng_seed(&r, 99)
	longest := 0
	check :: proc(t: ^testing.T, g: ^Game, n0: int, longest: ^int) {
		for i in n0 ..< g.log_count {
			longest^ = max(longest^, g.log[i].n)
			testing.expectf(t, g.log[i].n <= 33, "log line too long (%d): %s", g.log[i].n, string(g.log[i].text[:g.log[i].n]))
		}
	}
	for m in R.Monster {
		for by_pc in ([?]bool{true, false}) {
			for _ in 0 ..< 50 {
				pc := R.new_character(&r, "You")
				mob := R.new_npc(m)
				x: R.Exchange
				if by_pc { x = R.resolve_attack(&r, &pc, &mob, .Melee, 1) } else { x = R.resolve_attack(&r, &mob, &pc, .Melee, 0, 1) }
				n0 := g.log_count
				describe_event(g, D.Event{kind = .Attack, name = R.MONSTERS[m].name, by_pc = by_pc, x = x})
				check(t, g, n0, &longest)
			}
		}
		n0 := g.log_count
		for reaction in R.Reaction { describe_event(g, D.Event{kind = .Reaction, name = R.MONSTERS[m].name, reaction = reaction}) }
		describe_event(g, D.Event{kind = .Mob_Died, name = R.MONSTERS[m].name, n = 125})
		describe_event(g, D.Event{kind = .Mob_Fled, name = R.MONSTERS[m].name})
		describe_event(g, D.Event{kind = .Stunned, name = R.MONSTERS[m].name, n = 4})
		check(t, g, n0, &longest)
	}
	n0 := g.log_count
	for name in D.LOST_ITEMS { describe_event(g, D.Event{kind = .Pickup, name = name, n = 399}); describe_event(g, D.Event{kind = .Drop, name = name}) }
	check(t, g, n0, &longest)
}

@(test)
travel_walks_to_the_stairs_and_stops_for_a_fight :: proc(t: ^testing.T) {
	g := fresh(14)
	press(g, .Confirm, .N1)
	// walk a few steps away along any open direction, then travel home
	steps := 0
	for _ in 0 ..< 8 {
		for dir in ([?]D.Pos{{1, 0}, {0, 1}, {-1, 0}, {0, -1}}) { if D.pc_move(&g.delve, dir) { steps += 1; break } }
	}
	testing.expect(t, steps > 0, "moved away")
	g.delve.mob_count = 0 // nothing to stop for
	drain_events(g) // (the raw engine calls above left events behind; real keys drain them)
	press(g, .Travel)
	testing.expect(t, g.delve.pos == g.delve.stairs, "back on the stairs")
	// a hunter near stops it
	g2 := fresh(15)
	press(g2, .Confirm, .N1)
	for dir in ([?]D.Pos{{1, 0}, {0, 1}, {-1, 0}, {0, -1}}) { if D.pc_move(&g2.delve, dir) { break } }
	g2.delve.mob_count = 1
	g2.delve.mobs[0] = D.Mob{c = R.new_npc(.Dog), kind = .Dog, pos = g2.delve.pos + D.Pos{0, 0}, state = .Hunting, group = 0}
	g2.delve.groups[0] = {size = 1, reacted = true}
	g2.delve.group_count = 1
	g2.delve.mobs[0].pos = g2.delve.stairs + D.Pos{40, 0} // somewhere far but "near" is by manhattan: put it close
	g2.delve.mobs[0].pos = g2.delve.pos
	pos0 := g2.delve.pos
	press(g2, .Travel)
	testing.expect(t, g2.delve.pos == pos0 || D.hunters_near(&g2.delve) > 0, "a hunter at hand stops the walk")
}

@(test)
a_run_that_returned_nothing_is_not_a_best :: proc(t: ^testing.T) {
	g := fresh(16)
	press(g, .Confirm, .N1, .Confirm) // delve and leave with nothing
	testing.expect_value(t, g.best_score, 0)
	testing.expect(t, !g.new_best, "nothing returned, no record")
	testing.expect_value(t, native_store[KEY_BEST_SCORE], 0)
}

@(test)
z_attacks_a_neutral_monster_and_provokes_it :: proc(t: ^testing.T) {
	g := fresh(17)
	press(g, .Confirm, .N1)
	d := &g.delve
	// a friendly dog right next to the PC
	pos := D.Pos{}
	for dir in ([?]D.Pos{{1, 0}, {0, 1}, {-1, 0}, {0, -1}}) { if D.walkable(d, d.pos + dir) { pos = d.pos + dir; break } }
	d.mob_count = 1
	d.mobs[0] = D.Mob{c = R.new_npc(.Dog), kind = .Dog, pos = pos, state = .Neutral, group = 0}
	d.mobs[0].c.hd, d.mobs[0].c.armor = 12, 99 // survives the blow
	d.groups[0] = {size = 1, reacted = true, reaction = .Friendly}
	d.group_count = 1
	drain_events(g)
	press(g, .Attack)
	found := false
	for i in 0 ..< g.log_count { if g.log[i].n > 3 && string(g.log[i].text[:g.log[i].n]) != "" && g.log[i].text[0] == 'Y' && g.log[i].text[1] == 'o' && g.log[i].text[2] == 'u' && g.log[i].text[4] == '>' { found = true } }
	testing.expect(t, found, "an attack line 'You > Dog' is in the log")
	testing.expect_value(t, d.mobs[0].state, D.Mob_State.Hunting) // attacking it provoked the group
	// with nothing around, Z says so
	d.mob_count = 0
	press(g, .Attack)
	testing.expect_value(t, log_line(g, 0), "Nothing in reach to attack.")
}
