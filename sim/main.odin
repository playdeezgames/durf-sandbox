package main

// Spike A: a text-mode combat simulator. Fights the book's monsters thousands of times with
// different gear and push policies, to see whether DURF's numbers are survivable.
//   odin run sim -- fights [runs]   abstract fights (default 4000 per cell)
//   odin run sim -- delves [runs]   whole delves on the grid (default 1000 per cell)

import "core:fmt"
import "core:os"
import "core:strconv"
import R "../rules"

Policy :: struct {
	name:      string,
	push_att:  int, // Stress to spend per attack roll (only into free slots)
	push_def:  int, // Stress to spend per defence roll
	flee_at:   int, // flee once Wounds reach this
}

Kit :: struct {
	name:   string,
	weapon: R.Weapon_Kind,
	armor:  R.Armor_Kind,
	shield: bool,
}

Group :: struct {
	name:    string,
	members: []R.Monster,
}

// Reading of the combat rules: false = every acting side makes its own opposed roll (two exchanges
// per round); true = the side that wins initiative is the only one that attacks that round.
ONE_EXCHANGE_PER_ROUND := false

Outcome :: enum { Won, Fled, Died, Timeout } // Fled includes being stunned (the group leaves; Turns are lost)

Result :: struct {
	out:    Outcome,
	rounds: int,
	wounds: int,
	stress: int,
	xp:     int,
}

Fight :: struct {
	r:       ^R.Rng,
	pc:      ^R.Creature,
	mons:    [6]R.Creature,
	counted: [6]bool, // death already scored
	n:       int,
	pol:     Policy,
	res:     Result,
	deaths:  int,
	stunned: bool,
}

// A random starting character (attributes and gold) in a fixed kit: two Supplies, a dagger and three
// junk belongings, plus the kit's weapon (with Ammo if it needs it), armor and shield.
make_pc :: proc(r: ^R.Rng, kit: Kit) -> R.Creature {
	c := R.new_character(r)
	c.inv = {}
	c.inv_count = 0
	c.armor, c.armor_max, c.shield, c.worn = 0, 0, false, false
	for _ in 0 ..< R.STARTING_SUPPLY { R.add_item(&c, R.item_supply()) }
	R.add_item(&c, R.item_weapon(.Dagger))
	for _ in 0 ..< 3 { R.add_item(&c, R.item_junk("Junk")) }
	if kit.weapon != .Dagger {
		R.add_item(&c, R.item_weapon(kit.weapon))
		if R.WEAPONS[kit.weapon].uses_ammo { R.add_item(&c, R.item_ammo()) }
	}
	if kit.armor != .None { R.add_item(&c, R.item_armor(kit.armor)) }
	if kit.shield { R.add_item(&c, R.item_shield()) }
	return c
}

living :: proc(f: ^Fight) -> int {
	n := 0
	for i in 0 ..< f.n { if f.mons[i].alive && !f.mons[i].fled { n += 1 } }
	return n
}

// Scores new deaths and runs the morale check when the first falls and when half are down.
note_deaths :: proc(f: ^Fight) {
	new_dead := 0
	for i in 0 ..< f.n {
		if !f.mons[i].alive && !f.counted[i] {
			f.counted[i] = true
			f.deaths += 1
			new_dead += 1
			f.res.xp += R.xp_for_defeating(f.mons[i].hd)
		}
	}
	if new_dead > 0 && (f.deaths == 1 || f.deaths * 2 >= f.n) {
		for i in 0 ..< f.n {
			if f.mons[i].alive && !f.mons[i].fled && R.morale_flees(f.r, f.mons[i].ml) { f.mons[i].fled = true }
		}
	}
}

first_target :: proc(f: ^Fight) -> ^R.Creature {
	for i in 0 ..< f.n { if f.mons[i].alive && !f.mons[i].fled { return &f.mons[i] } }
	return nil
}

pc_act :: proc(f: ^Fight) -> (fled: bool) {
	if f.pc.paralyzed > 0 { return }
	if f.pc.wounds >= f.pol.flee_at { f.res.out = .Fled; return true }
	t := first_target(f)
	if t == nil { return }
	kind := R.Attack_Kind.Ranged if R.can_fire(f.pc^) else R.Attack_Kind.Melee
	R.resolve_attack(f.r, f.pc, t, kind, f.pol.push_att)
	note_deaths(f)
	return
}

monsters_act :: proc(f: ^Fight) {
	for i in 0 ..< f.n {
		m := &f.mons[i]
		if !m.alive || m.fled || !f.pc.alive { continue }
		actions := 2 if .Extra_Action in m.abilities else 1
		for _ in 0 ..< actions {
			if !f.pc.alive || !m.alive { break }
			if .Stun_Call in m.abilities && !m.stun_used {
				if R.stun_call(f.r, m, f.pc) > 0 { f.stunned = true; return } // paralysed for Turns: the group leaves
				continue
			}
			kind := R.Attack_Kind.Ranged if m.ranged else R.Attack_Kind.Melee
			R.resolve_attack(f.r, m, f.pc, kind, 0, f.pol.push_def)
			note_deaths(f)
		}
	}
}

fight :: proc(r: ^R.Rng, pc: ^R.Creature, group: []R.Monster, pol: Policy) -> Result {
	f := Fight{r = r, pc = pc, n = len(group), pol = pol}
	for m, i in group { f.mons[i] = R.new_npc(m) }
	f.res.out = .Timeout
	loop: for round in 1 ..= 60 {
		f.res.rounds = round
		pcs_first := R.pcs_first(r)
		for phase in 0 ..< 2 {
			if ONE_EXCHANGE_PER_ROUND && phase == 1 { break }
			if (phase == 0) == pcs_first {
				if pc_act(&f) { break loop }
			} else {
				monsters_act(&f)
			}
			if !pc.alive { f.res.out = .Died; break loop }
			if f.stunned { f.res.out = .Fled; break loop }
			if living(&f) == 0 { f.res.out = .Won; break loop }
		}
		if pc.paralyzed > 0 { pc.paralyzed -= 1 }
	}
	f.res.wounds = pc.wounds
	f.res.stress = pc.stress
	return f.res
}

KITS := [?]Kit{
	{"Dagger", .Dagger, .None, false},
	{"Sword", .Sword, .None, false},
	{"Sword+Light", .Sword, .Light, false},
	{"Sword+Med+Shield", .Sword, .Medium, true},
	{"Bow+Light", .Bow, .Light, false},
}

POLICIES := [?]Policy{
	{"fight on, never push", 0, 0, 99},
	{"push 1 on attack, fight on", 1, 0, 99},
	{"push 1 on attack and defence, flee at 2 Wounds", 1, 1, 2},
	{"never push, flee at 1 Wound", 0, 0, 1},
}

GROUPS := [?]Group{
	{"Goose", {.Goose}},
	{"Dog", {.Dog}},
	{"Echo Gecko", {.Echo_Gecko}},
	{"3 Echo Geckos", {.Echo_Gecko, .Echo_Gecko, .Echo_Gecko}},
	{"Myconid", {.Myconid}},
	{"Eelfolk", {.Eelfolk}},
	{"Spellclaw", {.Spellclaw}},
	{"Shadow", {.Shadow}},
	{"Flesh Orb", {.Flesh_Orb}},
	{"Dragon", {.Dragon}},
}

main :: proc() {
	runs := 4000
	mode := "delves"
	for a in os.args[1:] {
		if a == "debug" { debug_timeouts = true } else if a == "fights" || a == "delves" || a == "trace" { mode = a } else if v, ok := strconv.parse_int(a); ok { runs = v }
	}
	if mode == "trace" { // sim trace: the stuck seed, Careful bot, Sword+Light, depth 1
		trace_on = true
		r: R.Rng
		R.rng_seed(&r, 1)
		res := play_delve(&r, 1000101, 1, KITS[2], BOTS[1])
		fmt.println(res)
		return
	}
	if mode == "delves" {
		r: R.Rng
		R.rng_seed(&r, 20261004)
		delve_report(&r, runs if runs != 4000 else 1000)
		return
	}
	fmt.printf("DURF rules %s. %d fights per cell, fresh random character each, abstract melee (no map).\n", R.RULES_VERSION, runs)
	fmt.println("Cell = Won% / Fled% / Died%  (Fled = left the fight alive, or was stunned and left helpless for Turns; Timeout counted as Fled)")
	fmt.println("Abstract fights ignore Ammo and distance.\n")
	r: R.Rng
	R.rng_seed(&r, 20261004)
	hd_table(&r, runs)
	ONE_EXCHANGE_PER_ROUND = true
	fmt.println("== Sensitivity: ONE exchange per round (only the initiative winner attacks), never push, fight on ==")
	reading_table(&r, runs)
	ONE_EXCHANGE_PER_ROUND = false
	for pol in POLICIES {
		fmt.printf("== Policy: %s ==\n", pol.name)
		fmt.printf("%-14s", "")
		for kit in KITS { fmt.printf("%-20s", kit.name) }
		fmt.println()
		for g in GROUPS {
			fmt.printf("%-14s", g.name)
			for kit in KITS {
				won, fled, died := 0, 0, 0
				for _ in 0 ..< runs {
					pc := make_pc(&r, kit)
					res := fight(&r, &pc, g.members, pol)
					switch res.out {
					case .Won:  won += 1
					case .Died: died += 1
					case .Fled, .Timeout: fled += 1
					}
				}
				p := 100.0 / f64(runs)
				cell := fmt.tprintf("%2.0f / %2.0f / %2.0f", f64(won) * p, f64(fled) * p, f64(died) * p)
				fmt.printf("%-20s", cell)
			}
			fmt.println()
		}
		fmt.println()
	}
}

// How much do extra Hit Dice help? Sword + Medium armor + shield, never push, fight on.
hd_table :: proc(r: ^R.Rng, runs: int) {
	fmt.println("== Died% by Hit Dice (Sword+Med+Shield, never push, fight on) ==")
	fmt.printf("%-14s", "")
	for hd in 1 ..= 5 { fmt.printf("%-10s", fmt.tprintf("%d HD", hd)) }
	fmt.println()
	for g in GROUPS {
		fmt.printf("%-14s", g.name)
		for hd in 1 ..= 5 {
			died := 0
			for _ in 0 ..< runs {
				pc := make_pc(r, KITS[3])
				pc.hd = hd
				if fight(r, &pc, g.members, POLICIES[0]).out == .Died { died += 1 }
			}
			fmt.printf("%-10s", fmt.tprintf("%2.0f", 100.0 * f64(died) / f64(runs)))
		}
		fmt.println()
	}
	fmt.println()
}

reading_table :: proc(r: ^R.Rng, runs: int) {
	fmt.printf("%-14s", "")
	for kit in KITS { fmt.printf("%-20s", kit.name) }
	fmt.println()
	for g in GROUPS {
		fmt.printf("%-14s", g.name)
		for kit in KITS {
			won, died := 0, 0
			for _ in 0 ..< runs {
				pc := make_pc(r, kit)
				res := fight(r, &pc, g.members, POLICIES[0])
				if res.out == .Won { won += 1 }
				if res.out == .Died { died += 1 }
			}
			p := 100.0 / f64(runs)
			fmt.printf("%-20s", fmt.tprintf("%2.0f / -- / %2.0f", f64(won) * p, f64(died) * p))
		}
		fmt.println()
	}
	fmt.println()
}
