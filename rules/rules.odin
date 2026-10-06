package rules

// DURF rules engine. Pure: no browser imports, no globals, randomness through an explicit Rng
// (seedable, same sequence native and wasm). See DESIGN.md for the readings of ambiguous rules.

import "core:fmt"

// ---------- randomness ----------

Rng :: struct { s: u64 }

rng_seed :: proc(r: ^Rng, seed: u64) {
	r.s = seed if seed != 0 else 0x9E3779B97F4A7C15
	for _ in 0 ..< 4 { rng_u64(r) }
}

rng_u64 :: proc(r: ^Rng) -> u64 { // xorshift64*
	x := r.s
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	r.s = x
	return x * 0x2545F4914F6CDD1D
}

d :: proc(r: ^Rng, sides: int) -> int { return int(rng_u64(r) % u64(sides)) + 1 }
nd :: proc(r: ^Rng, n, sides: int) -> (sum: int) {
	for _ in 0 ..< n { sum += d(r, sides) }
	return
}

// ---------- rolls ----------

Roll :: struct {
	score:   int, // the attribute or Skill added
	nat:     int, // the d20
	buffs:   int, // net Buffs (positive) after cancelling Breaks, or net Breaks (negative)
	extra:   int, // the d6 added (Buff) or subtracted (Break); signed
	total:   int,
	success: bool, // total over DC (only meaningful for action rolls and saves)
}

// d20 + score, with Buffs and Breaks: each is an extra d6, they cancel in pairs, and only the
// highest d6 of the surviving kind counts.
roll_d20 :: proc(r: ^Rng, score: int, buffs := 0, breaks := 0) -> Roll {
	net := buffs - breaks
	out := Roll{score = score, nat = d(r, 20), buffs = net}
	if net != 0 {
		best := 0
		for _ in 0 ..< abs(net) { best = max(best, d(r, 6)) }
		out.extra = best if net > 0 else -best
	}
	out.total = out.nat + score + out.extra
	out.success = out.total > DC
	return out
}

describe_roll :: proc(x: Roll) -> string {
	if x.extra != 0 {
		return fmt.tprintf("d20 %d %+d %+d = %d", x.nat, x.score, x.extra, x.total)
	}
	return fmt.tprintf("d20 %d %+d = %d", x.nat, x.score, x.total)
}

// ---------- items ----------

Item_Kind :: enum { Junk, Weapon, Armor, Shield, Ammo, Supply, Lost }

Item :: struct {
	name:   string,
	kind:   Item_Kind,
	slots:  int,
	gp:     int, // what it is worth (a lost item is returned for this much XP and gold)
	weapon: Weapon_Kind, // for kind == .Weapon
	armor:  Armor_Kind, // for kind == .Armor
}

MAX_ITEMS :: 24

item_weapon :: proc(w: Weapon_Kind) -> Item { return {WEAPONS[w].name, .Weapon, WEAPONS[w].slots, WEAPONS[w].price, w, .None} }
item_armor :: proc(a: Armor_Kind) -> Item { return {ARMORS[a].name, .Armor, ARMORS[a].slots, ARMORS[a].price, .Unarmed, a} }
item_shield :: proc(name := "Shield") -> Item { return {name, .Shield, SHIELD_SLOTS, SHIELD_PRICE, .Unarmed, .None} }
item_ammo :: proc() -> Item { return {"Ammo", .Ammo, AMMO_SLOTS, AMMO_PRICE, .Unarmed, .None} }
item_supply :: proc() -> Item { return {"Supply", .Supply, 1, SUPPLY_COST, .Unarmed, .None} }
item_junk :: proc(name: string) -> Item { return {name, .Junk, 1, 0, .Unarmed, .None} }

// ---------- creatures ----------

Creature :: struct {
	name:        string,
	is_pc:       bool,
	attrs:       [Attr]int, // an NPC's Skill sits in all three
	hd:          int,
	wounds:      int,
	armor:       int, // current Armor points
	armor_max:   int, // derived from the best armor in the inventory (PCs)
	weapon:      Weapon_Kind, // PCs: derived from the inventory
	npc_dmg:     int, // NPCs
	ranged:      bool, // this creature's attack is ranged
	shield:      bool, // derived from the inventory (PCs)
	worn:        bool, // weapon worn: damage drops to WORN_DAMAGE until repaired
	stress:      int,
	inv:         [MAX_ITEMS]Item,
	inv_count:   int,
	shot_this_fight: bool, // the PC fired an ammo weapon since the last fight ended
	ammo_low:    bool, // a post-fight d6 of 1: one shot of Ammo left
	str_drained: int,
	ml:          int, // NPC morale, -1 none
	abilities:   bit_set[Ability],
	stun_used:   bool,
	paralyzed:   int, // > 0: helpless (cannot contest rolls)
	xp:          int,
	gold:        int,
	alive:       bool,
	fled:        bool,
}

items_slots :: proc(c: Creature) -> (n: int) {
	for i in 0 ..< c.inv_count { n += c.inv[i].slots }
	return
}
slots_total :: proc(c: Creature) -> int { return BASE_SLOTS + c.attrs[.STR] }
slots_used :: proc(c: Creature) -> int { return items_slots(c) + c.stress }
slots_free :: proc(c: Creature) -> int { return max(0, slots_total(c) - slots_used(c)) }

count_items :: proc(c: Creature, kind: Item_Kind) -> (n: int) {
	for i in 0 ..< c.inv_count { if c.inv[i].kind == kind { n += 1 } }
	return
}

can_fire :: proc(c: Creature) -> bool {
	w := WEAPONS[c.weapon]
	return w.ranged && (!w.uses_ammo || count_items(c, .Ammo) > 0)
}

can_carry :: proc(c: Creature, it: Item) -> bool { return c.inv_count < MAX_ITEMS && slots_free(c) >= it.slots }

// Equipment follows the inventory: the best usable weapon is wielded (ties go to a usable ranged
// weapon), the best armor is worn, any shield is carried. Dropping gear removes its effect.
refresh_gear :: proc(c: ^Creature) {
	if !c.is_pc { return }
	best := Weapon_Kind.Unarmed
	have_weapon := false
	best_armor := Armor_Kind.None
	c.shield = false
	for i in 0 ..< c.inv_count {
		it := c.inv[i]
		switch it.kind {
		case .Weapon:
			usable := !WEAPONS[it.weapon].ranged || !WEAPONS[it.weapon].uses_ammo || count_items(c^, .Ammo) > 0
			if !usable { continue }
			if !have_weapon || WEAPONS[it.weapon].dmg > WEAPONS[best].dmg || (WEAPONS[it.weapon].dmg == WEAPONS[best].dmg && WEAPONS[it.weapon].ranged) {
				best = it.weapon
				have_weapon = true
			}
		case .Armor:
			if ARMORS[it.armor].armor > ARMORS[best_armor].armor { best_armor = it.armor }
		case .Shield:
			c.shield = true
		case .Junk, .Ammo, .Supply, .Lost:
		}
	}
	if c.weapon != best { c.worn = false }
	c.weapon = best
	new_max := ARMORS[best_armor].armor
	if new_max > c.armor_max { c.armor = new_max } else { c.armor = min(c.armor, new_max) }
	c.armor_max = new_max
}

// Adds an item (the caller checks `can_carry` when a limit applies; starting kit may overflow).
add_item :: proc(c: ^Creature, it: Item) -> bool {
	if c.inv_count >= MAX_ITEMS { return false }
	c.inv[c.inv_count] = it
	c.inv_count += 1
	refresh_gear(c)
	return true
}

remove_item :: proc(c: ^Creature, idx: int) -> Item {
	it := c.inv[idx]
	for i in idx ..< c.inv_count - 1 { c.inv[i] = c.inv[i + 1] }
	c.inv_count -= 1
	c.inv[c.inv_count] = {}
	refresh_gear(c)
	return it
}

weapon_dmg :: proc(c: Creature) -> int {
	if c.worn { return WORN_DAMAGE }
	if c.is_pc { return WEAPONS[c.weapon].dmg }
	return c.npc_dmg
}

new_npc :: proc(m: Monster) -> Creature {
	def := MONSTERS[m]
	return Creature{
		name = def.name, attrs = {.STR = def.skill, .DEX = def.skill, .WIL = def.skill},
		hd = def.hd, armor = def.armor, armor_max = def.armor, npc_dmg = def.dmg, ranged = def.ranged,
		ml = def.ml, abilities = def.abilities, alive = true,
	}
}

// Character creation: d3 attributes, 1 HD, two Supplies, a dagger, three d40 belongings, 2d6 x 5 gold.
new_character :: proc(r: ^Rng, name := "Adventurer") -> Creature {
	c := Creature{name = name, is_pc = true, hd = HD_START, alive = true, ml = -1}
	for a in Attr { c.attrs[a] = (d(r, 6) + 1) / 2 } // d6 halved and rounded up
	c.gold = nd(r, 2, 6) * 5
	for _ in 0 ..< STARTING_SUPPLY { add_item(&c, item_supply()) }
	add_item(&c, item_weapon(.Dagger))
	picked: [3]int
	n := 0
	for tries := 0; n < 3 && tries < 200; tries += 1 { // reroll identical results (capped)
		roll := (d(r, 4) - 1) * 10 + (d(r, 10) - 1) // 0..39 for entries 10..49
		dup := false
		for i in 0 ..< n { if picked[i] == roll { dup = true } }
		if dup { continue }
		picked[n] = roll
		n += 1
	}
	for i in 0 ..< n { grant_belonging(&c, picked[i]) }
	return c
}

// The items a d40 belonging gives (index into BELONGINGS, entry number minus 10). Gear that is not
// modelled is a one-slot Junk item. Bows, crossbows and pistols come with Ammo, as listed.
belonging_items :: proc(idx: int) -> (items: [2]Item, n: int) {
	put :: proc(items: ^[2]Item, n: ^int, it: Item) { items[n^] = it; n^ += 1 }
	switch idx {
	case 0:          put(&items, &n, item_armor(.Light))
	case 9:          put(&items, &n, item_armor(.Medium))
	case 29:         put(&items, &n, item_armor(.Heavy))
	case 2:          put(&items, &n, item_weapon(.Bow)); put(&items, &n, item_ammo())
	case 5:          put(&items, &n, item_weapon(.Blowpipe))
	case 8, 34:      put(&items, &n, item_weapon(.Greatsword)) // warhammer, halberd
	case 12, 20, 35: put(&items, &n, item_weapon(.Sword)) // sword, silver axe, flail
	case 16:         put(&items, &n, item_weapon(.Pistol)); put(&items, &n, item_ammo())
	case 28:         put(&items, &n, item_weapon(.Crossbow)); put(&items, &n, item_ammo())
	case 26:         put(&items, &n, item_shield(BELONGINGS[26]))
	case:            put(&items, &n, item_junk(BELONGINGS[idx]))
	}
	return
}

grant_belonging :: proc(c: ^Creature, idx: int) {
	items, n := belonging_items(idx)
	for i in 0 ..< n { add_item(c, items[i]) }
}

// Attribute after Strength drain (a shadow's touch).
eff_attr :: proc(c: Creature, a: Attr) -> int {
	if a == .STR { return max(0, c.attrs[.STR] - c.str_drained) }
	return c.attrs[a]
}

// ---------- combat ----------

Attack_Kind :: enum { Melee, Ranged }

Damage_Result :: struct {
	dmg_in:      int, // after shield
	absorbed:    int, // by Armor
	wounds_new:  int,
	wounds_total: int, // all the Wounds the creature has after this hit
	hd_rolled:   bool,
	hd_sum:      int,
	died:        bool,
}

// Armor first, then Wounds; each time Wounds are received, roll the HD d6s (summed): at or below the
// total Wounds the creature dies. 0 HD dies on any Wound. A shield takes 1 off (never below 1).
apply_damage :: proc(r: ^Rng, c: ^Creature, dmg: int, direct := false) -> (out: Damage_Result) {
	n := dmg
	if c.shield && !direct && n > 0 { n = max(n - SHIELD_REDUCTION, 1) }
	out.dmg_in = n
	if !direct {
		out.absorbed = min(c.armor, n)
		c.armor -= out.absorbed
		n -= out.absorbed
	}
	if n > 0 {
		c.wounds += n
		out.wounds_new = n
		out.wounds_total = c.wounds
		out.hd_rolled = true
		if c.hd == 0 {
			out.died = true
		} else {
			out.hd_sum = nd(r, c.hd, 6)
			out.died = out.hd_sum <= c.wounds
		}
		if out.died { c.alive = false }
	}
	return
}

Exchange :: struct {
	kind:        Attack_Kind,
	att, def:    Roll,
	att_pushes:  int,
	def_pushes:  int,
	att_wins:    bool, // ties go to the attacker
	dodged:      bool, // ranged: defender won and nothing hit
	att_crit:    bool,
	hit_def:     bool,
	hit_att:     bool,
	dmg_def:     int,
	dmg_att:     int,
	res_def:     Damage_Result,
	res_att:     Damage_Result,
	spores:      bool, // the attacker was caught by spores
}

// Spends up to `want` Stress on pushing (PCs only, only into free slots); returns the Stress taken.
push :: proc(c: ^Creature, want: int) -> int {
	if !c.is_pc || want <= 0 { return 0 }
	n := min(want, slots_free(c^))
	c.stress += n
	return n
}

// One opposed attack. Melee: opposed STR, the winner deals its weapon damage to the loser.
// Ranged: opposed DEX, a defender win means the shot is dodged and nothing comes back.
// A natural 20 on the attacker's roll crits (double damage) even when the opposed roll is lost; a
// defender's 20 is just a roll and ranged targets never crit. A PC's natural 1 on its own attack
// roll wears its weapon. Firing an Ammo weapon with one shot left uses the Ammo up.
resolve_attack :: proc(r: ^Rng, att, def: ^Creature, kind: Attack_Kind, att_pushes := 0, def_pushes := 0) -> (x: Exchange) {
	x.kind = kind
	attr := Attr.STR if kind == .Melee else Attr.DEX
	x.att_pushes = push(att, att_pushes)
	x.def_pushes = push(def, def_pushes)
	// A paralyzed creature cannot contest the roll.
	x.att = roll_d20(r, eff_attr(att^, attr), x.att_pushes)
	x.def = roll_d20(r, eff_attr(def^, attr), x.def_pushes)
	if def.paralyzed > 0 { x.def = Roll{score = 0, nat = 1, total = 0} }
	x.att_wins = x.att.total >= x.def.total
	x.att_crit = x.att.nat == CRIT_ROLL
	if att.is_pc && x.att.nat == WORN_ROLL { att.worn = true }
	if kind == .Ranged && att.is_pc && WEAPONS[att.weapon].uses_ammo { // a shot is fired, hit or miss
		att.shot_this_fight = true
		if att.ammo_low {
			for i in 0 ..< att.inv_count {
				if att.inv[i].kind == .Ammo { remove_item(att, i); break }
			}
			att.ammo_low = false
		}
	}

	x.hit_def = x.att_wins || x.att_crit
	x.hit_att = kind == .Melee && !x.att_wins
	x.dodged = kind == .Ranged && !x.hit_def
	if x.hit_def {
		x.dmg_def = weapon_dmg(att^) * (2 if x.att_crit else 1)
		x.res_def = apply_damage(r, def, x.dmg_def)
		if kind == .Melee && .Spores in def.abilities && x.res_def.dmg_in > 0 {
			save := roll_d20(r, eff_attr(att^, .STR))
			if !save.success {
				x.spores = true
				apply_damage(r, att, 1, direct = true)
			}
		}
		if .Drain_STR in att.abilities && x.res_def.dmg_in > 0 && def.alive {
			def.str_drained += 1
			if def.attrs[.STR] - def.str_drained < 0 { def.alive = false }
		}
	}
	if x.hit_att && att.alive {
		x.dmg_att = weapon_dmg(def^)
		x.res_att = apply_damage(r, att, x.dmg_att)
		if .Drain_STR in def.abilities && x.res_att.dmg_in > 0 && att.alive {
			att.str_drained += 1
			if att.attrs[.STR] - att.str_drained < 0 { att.alive = false }
		}
	}
	return
}

// Echo gecko's call: once per fight, the target makes a STR save or is paralyzed for 1d4 Turns.
// Returns the Turns lost (0 when the save succeeds). What the paralysis means is up to the caller
// (a delve loses the Turns and the stunners wander off; see DESIGN.md, reading 8).
stun_call :: proc(r: ^Rng, user, target: ^Creature) -> int {
	if user.stun_used || .Stun_Call not_in user.abilities { return 0 }
	user.stun_used = true
	if !roll_d20(r, eff_attr(target^, .STR)).success { return d(r, 4) }
	return 0
}

// After a fight in which the PC shot an Ammo weapon: a d6 of 1 leaves one shot of Ammo.
// Returns true if the Ammo is now low.
ammo_check :: proc(r: ^Rng, c: ^Creature) -> bool {
	if !c.shot_this_fight { return false }
	c.shot_this_fight = false
	if count_items(c^, .Ammo) > 0 && d(r, 6) == AMMO_LOW_ROLL { c.ammo_low = true }
	return c.ammo_low
}

// Morale: roll 2d6, higher than ML means the NPC flees (or parleys). ML -1 never flees.
morale_flees :: proc(r: ^Rng, ml: int) -> bool {
	if ml < 0 { return false }
	return nd(r, 2, 6) > ml
}

// Initiative: a d6 per side each round; ties go to the PCs.
pcs_first :: proc(r: ^Rng) -> bool { return d(r, 6) >= d(r, 6) }

reaction_roll :: proc(r: ^Rng) -> Reaction { return reaction_for_total(nd(r, 2, 6)) }

// ---------- experience ----------

xp_for_defeating :: proc(hd: int) -> int { return XP_PER_NPC_HD * hd if hd > 0 else XP_PER_ZERO_HD }

// Adds XP and automatically buys HD (1000 x current HD each). Returns the HD gained.
// A PC that would gain a 13th HD retires; the caller can check hd == HD_MAX.
add_xp :: proc(c: ^Creature, amount: int) -> (gained: int) {
	c.xp += amount
	for c.hd < HD_MAX && c.xp >= XP_PER_HD_COST * c.hd {
		c.xp -= XP_PER_HD_COST * c.hd
		c.hd += 1
		gained += 1
	}
	return
}

// Rest in a safe place: all Wounds and Stress cleared, Armor repaired, weapon restored, STR back.
rest :: proc(c: ^Creature) {
	c.wounds = 0
	c.stress = 0
	c.armor = c.armor_max
	c.worn = false
	c.str_drained = 0
	c.paralyzed = 0
}
