package rules

import "core:log"
import "core:testing"

seeded :: proc(seed: u64) -> Rng {
	r: Rng
	rng_seed(&r, seed)
	return r
}

// A creature that wins or loses every opposed roll against ordinary scores.
titan :: proc() -> Creature { return Creature{name = "titan", attrs = {.STR = 40, .DEX = 40, .WIL = 40}, hd = 1, weapon = .Sword, alive = true, is_pc = true} }
mouse :: proc() -> Creature { return Creature{name = "mouse", attrs = {}, hd = 1, npc_dmg = 2, alive = true} }

@(test)
rng_is_deterministic_and_in_range :: proc(t: ^testing.T) {
	a := seeded(42)
	b := seeded(42)
	counts: [21]int
	for _ in 0 ..< 20000 {
		x := d(&a, 20)
		testing.expect_value(t, x, d(&b, 20))
		testing.expect(t, x >= 1 && x <= 20, "d20 out of range")
		counts[x] += 1
	}
	for f in 1 ..= 20 { testing.expectf(t, counts[f] > 700 && counts[f] < 1300, "face %d came up %d of 20000", f, counts[f]) }
}

@(test)
action_roll_succeeds_only_over_the_dc :: proc(t: ^testing.T) {
	r := seeded(1)
	for _ in 0 ..< 5000 {
		x := roll_d20(&r, 2)
		testing.expect_value(t, x.total, x.nat + 2)
		testing.expect_value(t, x.success, x.total > 15)
	}
}

@(test)
action_roll_odds_match_the_book :: proc(t: ^testing.T) {
	// score 1 needs a natural 15+ (30 percent), score 3 needs 13+ (40 percent)
	r := seeded(2)
	wins1, wins3, n := 0, 0, 40000
	for _ in 0 ..< n {
		if roll_d20(&r, 1).success { wins1 += 1 }
		if roll_d20(&r, 3).success { wins3 += 1 }
	}
	testing.expectf(t, abs(f64(wins1) / f64(n) - 0.30) < 0.02, "score 1 success %d / %d", wins1, n)
	testing.expectf(t, abs(f64(wins3) / f64(n) - 0.40) < 0.02, "score 3 success %d / %d", wins3, n)
}

@(test)
buffs_and_breaks_cancel_and_take_the_highest :: proc(t: ^testing.T) {
	r := seeded(3)
	sum1, sum2, n := 0, 0, 20000
	for _ in 0 ..< n {
		even := roll_d20(&r, 0, 2, 2)
		testing.expect_value(t, even.extra, 0)
		testing.expect_value(t, even.buffs, 0)
		one := roll_d20(&r, 0, 1, 0)
		two := roll_d20(&r, 0, 2, 0)
		testing.expect(t, one.extra >= 1 && one.extra <= 6, "one Buff adds a d6")
		testing.expect(t, two.extra >= 1 && two.extra <= 6, "two Buffs add the highest d6")
		sum1 += one.extra
		sum2 += two.extra
		brk := roll_d20(&r, 0, 0, 1)
		testing.expect(t, brk.extra <= -1 && brk.extra >= -6, "a Break subtracts a d6")
		net := roll_d20(&r, 0, 3, 2) // 3 Buffs - 2 Breaks = 1 Buff
		testing.expect_value(t, net.buffs, 1)
	}
	testing.expectf(t, f64(sum1) / f64(n) > 3.3 && f64(sum1) / f64(n) < 3.7, "mean of d6 is %v", f64(sum1) / f64(n))
	testing.expectf(t, f64(sum2) / f64(n) > 4.3 && f64(sum2) / f64(n) < 4.7, "mean of best of 2d6 is %v", f64(sum2) / f64(n))
}

@(test)
armor_soaks_before_wounds :: proc(t: ^testing.T) {
	r := seeded(4)
	c := Creature{hd = 1, armor = 3, armor_max = 3, alive = true}
	res := apply_damage(&r, &c, 2)
	testing.expect_value(t, c.armor, 1)
	testing.expect_value(t, c.wounds, 0)
	testing.expect(t, !res.hd_rolled, "no Wounds, no HD roll")
	res = apply_damage(&r, &c, 4) // 1 soaked, 3 Wounds
	testing.expect_value(t, c.armor, 0)
	testing.expect_value(t, c.wounds, 3)
	testing.expect(t, res.hd_rolled, "Wounds trigger the HD roll")
}

@(test)
zero_hd_dies_on_any_wound :: proc(t: ^testing.T) {
	r := seeded(5)
	c := Creature{hd = 0, alive = true}
	apply_damage(&r, &c, 1)
	testing.expect(t, !c.alive, "0 HD dies on any Wound")
}

@(test)
shield_takes_one_off_but_never_below_one :: proc(t: ^testing.T) {
	r := seeded(6)
	c := Creature{hd = 12, shield = true, alive = true}
	testing.expect_value(t, apply_damage(&r, &c, 4).dmg_in, 3)
	testing.expect_value(t, apply_damage(&r, &c, 1).dmg_in, 1)
	testing.expect_value(t, apply_damage(&r, &c, 4, direct = true).dmg_in, 4)
}

@(test)
hd_death_uses_the_sum_of_hit_dice :: proc(t: ^testing.T) {
	r := seeded(7)
	// 1 HD with 6 Wounds always dies (a d6 is never above 6)
	for _ in 0 ..< 200 {
		c := Creature{hd = 1, alive = true}
		apply_damage(&r, &c, 6)
		testing.expect(t, !c.alive, "1 HD with 6 Wounds must die")
	}
	// 1 HD with 1 Wound dies on a 1 only: about 1 in 6
	dead, n := 0, 30000
	for _ in 0 ..< n {
		c := Creature{hd = 1, alive = true}
		apply_damage(&r, &c, 1)
		if !c.alive { dead += 1 }
	}
	testing.expectf(t, abs(f64(dead) / f64(n) - 1.0 / 6.0) < 0.01, "died %d of %d", dead, n)
	// 8 HD (a dragon) with 8 Wounds: the sum of 8d6 is at least 8, so only a perfect 8 kills it
	alive := 0
	for _ in 0 ..< 2000 {
		c := Creature{hd = 8, alive = true}
		apply_damage(&r, &c, 8)
		if c.alive { alive += 1 }
	}
	testing.expect(t, alive > 1990, "8 HD should almost never die to 8 Wounds")
}

@(test)
attack_exchanges_obey_the_rules :: proc(t: ^testing.T) {
	r := seeded(8)
	crit_while_losing := 0
	for i in 0 ..< 6000 {
		a := new_character(&r)
		b := new_npc(Monster(i % len(Monster)))
		kind := Attack_Kind.Melee if i % 3 != 0 else Attack_Kind.Ranged
		x := resolve_attack(&r, &a, &b, kind)
		testing.expect_value(t, x.att_wins, x.att.total >= x.def.total) // ties to the attacker
		if kind == .Ranged {
			testing.expect(t, !x.hit_att, "a ranged target never hits back")
			testing.expect_value(t, x.dodged, !x.hit_def)
		} else {
			testing.expect(t, !x.dodged, "melee has no dodge")
			if x.att_wins { testing.expect(t, x.hit_def, "the winner hits") } else { testing.expect(t, x.hit_att, "the loser is hit") }
		}
		if x.att_crit && x.hit_def {
			testing.expect_value(t, x.dmg_def, 2 * WEAPONS[a.weapon].dmg) // a crit is a natural 20, so the weapon was not just worn
			if !x.att_wins { crit_while_losing += 1 }
		}
		if x.att.nat == 1 { testing.expect(t, a.worn, "a PC's natural 1 wears its weapon") }
	}
	testing.expect(t, crit_while_losing > 0, "a natural 20 should hit even when the opposed roll is lost")
}

@(test)
stress_and_pushing_fill_slots :: proc(t: ^testing.T) {
	c := Creature{is_pc = true, attrs = {.STR = 1, .DEX = 0, .WIL = 0}, alive = true}
	for _ in 0 ..< 10 { add_item(&c, item_junk("junk")) }
	testing.expect_value(t, slots_total(c), 11)
	testing.expect_value(t, slots_free(c), 1)
	testing.expect_value(t, push(&c, 3), 1) // only one slot free
	testing.expect_value(t, c.stress, 1)
	testing.expect_value(t, slots_free(c), 0)
	testing.expect_value(t, push(&c, 1), 0)
	npc := new_npc(.Dog)
	testing.expect_value(t, push(&npc, 2), 0) // NPCs cannot push
	rest(&c)
	testing.expect_value(t, c.stress, 0)
}

@(test)
morale_and_reaction :: proc(t: ^testing.T) {
	r := seeded(9)
	flee2, n := 0, 5000
	for _ in 0 ..< n {
		testing.expect(t, !morale_flees(&r, -1), "ML none never flees")
		testing.expect(t, !morale_flees(&r, 12), "2d6 cannot beat 12")
		if morale_flees(&r, 2) { flee2 += 1 }
	}
	testing.expectf(t, f64(flee2) / f64(n) > 0.95, "ML 2 should almost always flee (%d)", flee2)
	for total in 2 ..= 12 {
		want: Reaction
		switch total {
		case 2, 3: want = .Hostile
		case 4, 5: want = .Unfriendly
		case 6, 7, 8: want = .Indifferent
		case 9, 10: want = .Friendly
		case: want = .Helpful
		}
		testing.expect_value(t, reaction_for_total(total), want)
	}
}

@(test)
initiative_ties_go_to_the_pcs :: proc(t: ^testing.T) {
	r := seeded(10)
	first, n := 0, 30000
	for _ in 0 ..< n { if pcs_first(&r) { first += 1 } }
	// P(pc >= npc) with d6 vs d6 = 21/36
	testing.expectf(t, abs(f64(first) / f64(n) - 21.0 / 36.0) < 0.01, "pcs first %d of %d", first, n)
}

@(test)
xp_buys_hit_dice_automatically :: proc(t: ^testing.T) {
	c := Creature{hd = 1, alive = true}
	testing.expect_value(t, add_xp(&c, 999), 0)
	testing.expect_value(t, add_xp(&c, 1), 1)
	testing.expect_value(t, c.hd, 2)
	testing.expect_value(t, c.xp, 0)
	c = Creature{hd = 1, alive = true}
	testing.expect_value(t, add_xp(&c, 3000), 2) // 1000 for HD 2, 2000 for HD 3
	testing.expect_value(t, c.hd, 3)
	c = Creature{hd = HD_MAX, alive = true}
	testing.expect_value(t, add_xp(&c, 999999), 0)
	testing.expect_value(t, xp_for_defeating(4), 100)
	testing.expect_value(t, xp_for_defeating(0), 0) // the literal 25 x HD rule: nothing for a 0 HD monster
}

@(test)
characters_follow_the_creation_rules :: proc(t: ^testing.T) {
	r := seeded(11)
	overloaded := 0
	for _ in 0 ..< 3000 {
		c := new_character(&r)
		for a in Attr { testing.expect(t, c.attrs[a] >= 1 && c.attrs[a] <= 3, "attributes are d3") }
		testing.expect_value(t, c.hd, 1)
		testing.expect_value(t, count_items(c, .Supply), 2)
		testing.expect(t, count_items(c, .Weapon) >= 1, "a dagger at least")
		testing.expect(t, c.gold >= 10 && c.gold <= 60 && c.gold % 5 == 0, "gold is 2d6 x 5")
		testing.expect(t, items_slots(c) >= 6, "two Supply, a dagger and three belongings")
		if slots_used(c) > slots_total(c) { overloaded += 1 }
	}
	log.infof("starting characters carrying more than their slots: %d of 3000", overloaded)
}

@(test)
shadow_drains_strength_and_rest_restores_it :: proc(t: ^testing.T) {
	r := seeded(12)
	pc := titan()
	pc.attrs = {.STR = 1, .DEX = 1, .WIL = 1}
	shadow := new_npc(.Shadow)
	for _ in 0 ..< 40 { // the shadow wins some exchanges and drains
		resolve_attack(&r, &shadow, &pc, .Melee)
		if !pc.alive { break }
	}
	testing.expect(t, pc.str_drained > 0 || !pc.alive, "a shadow's hits drain STR")
	pc.alive = true
	rest(&pc)
	testing.expect_value(t, pc.str_drained, 0)
}

@(test)
data_tables_are_sane :: proc(t: ^testing.T) {
	testing.expect_value(t, len(BELONGINGS), 40)
	for b in BELONGINGS { testing.expect(t, len(b) > 0, "belonging has a name") }
	for m in Monster {
		def := MONSTERS[m]
		testing.expect(t, def.hd >= 0 && def.skill >= 0 && def.dmg >= 1, def.name)
		testing.expect(t, def.skill <= 14, "converted monsters cap Skill at 14")
	}
	for w in Weapon_Kind { testing.expect(t, WEAPONS[w].dmg >= 2, WEAPONS[w].name) }
}

@(test)
only_the_attackers_natural_20_crits :: proc(t: ^testing.T) {
	r := seeded(13)
	def_20_seen := 0
	for _ in 0 ..< 20000 {
		a := mouse() // attacker: a monster with 2 damage
		a.attrs = {.STR = 0, .DEX = 0, .WIL = 0}
		b := titan() // defender: wins nearly every opposed roll
		b.weapon = .Sword
		x := resolve_attack(&r, &a, &b, .Melee)
		if x.def.nat == CRIT_ROLL && x.att.nat != CRIT_ROLL {
			def_20_seen += 1
			testing.expect_value(t, x.dmg_att, WEAPONS[.Sword].dmg) // a defender's 20 is not doubled
		}
		b = titan()
		b.alive = true
	}
	testing.expect(t, def_20_seen > 100, "the test saw defender 20s")
}

@(test)
only_a_pcs_own_attack_roll_wears_its_weapon :: proc(t: ^testing.T) {
	r := seeded(14)
	saw_def_one := 0
	for _ in 0 ..< 10000 {
		a := mouse()
		b := titan()
		b.hd = 12
		x := resolve_attack(&r, &a, &b, .Melee)
		if x.def.nat == WORN_ROLL { saw_def_one += 1; testing.expect(t, !b.worn, "a defending PC's natural 1 does not wear its weapon") }
	}
	testing.expect(t, saw_def_one > 100, "the test saw defender 1s")
	// the PC's own attack: natural 1 wears the weapon
	worn_after_one := 0
	for _ in 0 ..< 10000 {
		a := titan()
		a.hd = 12
		b := mouse()
		b.hd = 12
		x := resolve_attack(&r, &a, &b, .Melee)
		if x.att.nat == WORN_ROLL { testing.expect(t, a.worn, "the PC's own natural 1 wears the weapon"); worn_after_one += 1 }
	}
	testing.expect(t, worn_after_one > 100, "the test saw attacker 1s")
}

@(test)
equipment_follows_the_inventory :: proc(t: ^testing.T) {
	c := Creature{is_pc = true, attrs = {.STR = 3, .DEX = 1, .WIL = 1}, hd = 1, alive = true}
	add_item(&c, item_weapon(.Dagger))
	testing.expect_value(t, c.weapon, Weapon_Kind.Dagger)
	add_item(&c, item_weapon(.Sword))
	testing.expect_value(t, c.weapon, Weapon_Kind.Sword)
	add_item(&c, item_armor(.Light))
	add_item(&c, item_shield())
	testing.expect_value(t, c.armor_max, 3)
	testing.expect_value(t, c.armor, 3)
	testing.expect(t, c.shield, "a shield in the bag is carried")
	add_item(&c, item_armor(.Medium))
	testing.expect_value(t, c.armor_max, 5)
	testing.expect_value(t, c.armor, 5)
	// dropping removes the effect
	for i in 0 ..< c.inv_count { if c.inv[i].kind == .Weapon && c.inv[i].weapon == .Sword { remove_item(&c, i); break } }
	testing.expect_value(t, c.weapon, Weapon_Kind.Dagger)
	for i in 0 ..< c.inv_count { if c.inv[i].kind == .Armor && c.inv[i].armor == .Medium { remove_item(&c, i); break } }
	testing.expect_value(t, c.armor_max, 3)
	for i in 0 ..< c.inv_count { if c.inv[i].kind == .Shield { remove_item(&c, i); break } }
	testing.expect(t, !c.shield, "the shield is gone")
	// no weapons at all: fists
	for c.inv_count > 0 { remove_item(&c, 0) }
	testing.expect_value(t, c.weapon, Weapon_Kind.Unarmed)
	testing.expect_value(t, c.armor_max, 0)
}

@(test)
carrying_is_limited_by_slots :: proc(t: ^testing.T) {
	c := Creature{is_pc = true, attrs = {.STR = 1, .DEX = 1, .WIL = 1}, hd = 1, alive = true} // 11 slots
	for _ in 0 ..< 10 { add_item(&c, item_junk("x")) }
	testing.expect_value(t, slots_free(c), 1)
	testing.expect(t, can_carry(c, item_junk("one")), "a 1 slot item fits")
	testing.expect(t, !can_carry(c, item_weapon(.Sword)), "a 2 slot weapon does not")
	c.stress = 1
	testing.expect(t, !can_carry(c, item_junk("one")), "Stress takes the last slot")
}

@(test)
ranged_weapons_need_ammo_and_the_blowpipe_does_not :: proc(t: ^testing.T) {
	c := Creature{is_pc = true, attrs = {.STR = 3, .DEX = 3, .WIL = 1}, hd = 1, alive = true}
	add_item(&c, item_weapon(.Dagger))
	add_item(&c, item_weapon(.Pistol))
	testing.expect_value(t, c.weapon, Weapon_Kind.Dagger) // no Ammo, so the pistol is not usable
	testing.expect(t, !can_fire(c), "a dagger is not a ranged weapon")
	add_item(&c, item_ammo())
	testing.expect_value(t, c.weapon, Weapon_Kind.Pistol)
	testing.expect(t, can_fire(c), "pistol with Ammo fires")
	c2 := Creature{is_pc = true, attrs = {.STR = 1, .DEX = 1, .WIL = 1}, hd = 1, alive = true}
	add_item(&c2, item_weapon(.Blowpipe))
	testing.expect_value(t, c2.weapon, Weapon_Kind.Blowpipe)
	testing.expect(t, can_fire(c2), "the blowpipe needs no Ammo")
}

@(test)
ammo_runs_low_on_a_one_and_is_used_up_by_the_next_shot :: proc(t: ^testing.T) {
	r := seeded(15)
	lows, n := 0, 6000
	for _ in 0 ..< n {
		c := Creature{is_pc = true, attrs = {.STR = 2, .DEX = 2, .WIL = 1}, hd = 1, alive = true}
		add_item(&c, item_weapon(.Bow))
		add_item(&c, item_ammo())
		target := mouse()
		target.hd = 12
		testing.expect(t, !ammo_check(&r, &c), "no shot, no check")
		resolve_attack(&r, &c, &target, .Ranged)
		testing.expect(t, c.shot_this_fight, "firing is recorded")
		if ammo_check(&r, &c) {
			lows += 1
			testing.expect_value(t, count_items(c, .Ammo), 1) // still there until the next shot
			resolve_attack(&r, &c, &target, .Ranged)
			testing.expect_value(t, count_items(c, .Ammo), 0) // the last shot used it up
			testing.expect(t, !can_fire(c), "out of Ammo")
			testing.expect_value(t, c.weapon, Weapon_Kind.Unarmed) // a bow with no Ammo is not wielded
		}
	}
	testing.expectf(t, abs(f64(lows) / f64(n) - 1.0 / 6.0) < 0.02, "Ammo ran low in %d of %d fights", lows, n)
}

@(test)
stun_call_returns_turns_and_only_once :: proc(t: ^testing.T) {
	r := seeded(16)
	stunned, n := 0, 6000
	for _ in 0 ..< n {
		g := new_npc(.Echo_Gecko)
		pc := titan()
		pc.attrs = {.STR = 2, .DEX = 2, .WIL = 2} // needs a 14+ to save: 35 percent
		turns := stun_call(&r, &g, &pc)
		testing.expect(t, turns >= 0 && turns <= 4, "0 or 1d4 Turns")
		testing.expect_value(t, pc.paralyzed, 0) // the caller decides what the Turns mean
		testing.expect_value(t, stun_call(&r, &g, &pc), 0) // once per fight
		if turns > 0 { stunned += 1 }
	}
	testing.expectf(t, abs(f64(stunned) / f64(n) - 0.65) < 0.03, "stunned %d of %d", stunned, n)
}

@(test)
belongings_give_the_listed_items :: proc(t: ^testing.T) {
	for i in 0 ..< 40 {
		items, n := belonging_items(i)
		testing.expect(t, n >= 1 && n <= 2, "one or two items")
		testing.expect(t, items[0].slots >= 1, "an item takes a slot")
	}
	bow, nb := belonging_items(2)
	testing.expect_value(t, nb, 2)
	testing.expect_value(t, bow[1].kind, Item_Kind.Ammo) // "Bow + Ammo"
	_, np := belonging_items(16)
	testing.expect_value(t, np, 2) // "Pistol + Ammo"
}

@(test)
house_monsters_are_flagged_and_only_the_eelfolk_reload :: proc(t: ^testing.T) {
	for m in Monster {
		def := MONSTERS[m]
		is_house := m == .Blowpipe_Imp || m == .Crossbow_Cultist
		testing.expect_value(t, def.house, is_house)
		testing.expect_value(t, .Reload in def.abilities, m == .Eelfolk)
	}
}
