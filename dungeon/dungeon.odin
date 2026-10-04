package dungeon

// A delve: one dungeon floor on a grid, with monsters that react, chase and flee under the
// DURF rules (see ../rules). Pure and seeded: no browser imports, same results native and wasm.
// Movement is 4-directional. Each creature's round is a move plus an action; an action can be a
// second move (the 2.2 text: "move around and take an action ... making a second move").

import R "../rules"

W :: 48
H :: 32
MAX_ROOMS :: 8
MAX_MOBS :: 24
MAX_LOOT :: 16
MAX_GROUPS :: 24

SIGHT          :: 6 // tiles you can see by torchlight
SIGHT_DARK     :: 1
LIGHT_START    :: 12 // Turns of light: two torches (a torch burns 6 Turns)
TILES_PER_TURN :: 10 // out of combat, 10 tiles of travel is one 10 minute Turn
RANGED_RANGE   :: 8
ENCOUNTER_DIE  :: 6 // each Turn, a 1 brings a wandering group

Pos :: [2]int
Tile :: enum u8 { Wall, Floor, Stairs }
Grid :: [H][W]int
Blocked :: [H][W]bool
INF :: 9999

Mob_State :: enum { Idle, Hunting, Neutral, Fled }

Mob :: struct {
	c:         R.Creature,
	kind:      R.Monster,
	pos:       Pos,
	group:     int,
	state:     Mob_State,
	reloading: bool,
	seen:      bool, // the PC has seen it at least once
}

Loot :: struct {
	pos:   Pos,
	gp:    int,
	slots: int,
	taken: bool,
	seen:  bool,
}

Room :: struct { x, y, w, h: int }

Result_Kind :: enum { Running, Exited, Died }

Group_Info :: struct {
	size:      int,
	dead:      int,
	reacted:   bool,
	reaction:  R.Reaction,
}

Delve :: struct {
	tiles:        [H][W]Tile,
	rooms:        [MAX_ROOMS]Room,
	room_count:   int,
	visited:      [MAX_ROOMS]bool,
	stairs:       Pos,
	mobs:         [MAX_MOBS]Mob,
	mob_count:    int,
	groups:       [MAX_GROUPS]Group_Info,
	group_count:  int,
	loot:         [MAX_LOOT]Loot,
	loot_count:   int,
	depth:        int,
	rng:          R.Rng,
	pc:           R.Creature,
	pos:          Pos,
	push_att:     int, // Stress the PC spends per attack roll
	push_def:     int, // ... per defence roll
	tiles_moved:  int,
	turns:        int,
	light:        int, // Turns of light left
	carried_gp:   int,
	items:        int,
	xp:           int,
	kills:        int,
	rounds:       int, // combat rounds
	result:       Result_Kind,
	killer:       R.Monster, // valid when result == .Died
}

in_bounds :: proc(p: Pos) -> bool { return p.x >= 0 && p.y >= 0 && p.x < W && p.y < H }
walkable :: proc(d: ^Delve, p: Pos) -> bool { return in_bounds(p) && d.tiles[p.y][p.x] != .Wall }
manhattan :: proc(a, b: Pos) -> int { return abs(a.x - b.x) + abs(a.y - b.y) }

// ---------- generation ----------

ri :: proc(d: ^Delve, lo, hi: int) -> int { return lo + R.d(&d.rng, hi - lo + 1) - 1 }

room_center :: proc(r: Room) -> Pos { return {r.x + r.w / 2, r.y + r.h / 2} }

carve_room :: proc(d: ^Delve, r: Room) {
	for y in r.y ..< r.y + r.h { for x in r.x ..< r.x + r.w { d.tiles[y][x] = .Floor } }
}

carve_line :: proc(d: ^Delve, a, b: Pos, horizontal_first: bool) {
	p := a
	step :: proc(v, to: int) -> int { return 1 if to > v else (-1 if to < v else 0) }
	if horizontal_first {
		for p.x != b.x { d.tiles[p.y][p.x] = .Floor; p.x += step(p.x, b.x) }
		for p.y != b.y { d.tiles[p.y][p.x] = .Floor; p.y += step(p.y, b.y) }
	} else {
		for p.y != b.y { d.tiles[p.y][p.x] = .Floor; p.y += step(p.y, b.y) }
		for p.x != b.x { d.tiles[p.y][p.x] = .Floor; p.x += step(p.x, b.x) }
	}
	d.tiles[b.y][b.x] = .Floor
}

rooms_overlap :: proc(a, b: Room) -> bool {
	return a.x - 1 < b.x + b.w && b.x - 1 < a.x + a.w && a.y - 1 < b.y + b.h && b.y - 1 < a.y + a.h
}

tile_occupied :: proc(d: ^Delve, p: Pos) -> bool {
	if p == d.pos { return true }
	for i in 0 ..< d.mob_count { if d.mobs[i].c.alive && d.mobs[i].pos == p { return true } }
	for i in 0 ..< d.loot_count { if d.loot[i].pos == p { return true } }
	return p == d.stairs
}

random_free_tile :: proc(d: ^Delve, r: Room) -> (p: Pos, ok: bool) {
	for _ in 0 ..< 60 { // capped: an unbounded retry loop freezes a browser tab
		p = {ri(d, r.x, r.x + r.w - 1), ri(d, r.y, r.y + r.h - 1)}
		if !tile_occupied(d, p) { return p, true }
	}
	return {}, false
}

// Builds a floor from a seed. The PC starts on the stairs in room 0.
init_delve :: proc(d: ^Delve, seed: u64, depth: int, pc: R.Creature, push_att := 0, push_def := 0) {
	d^ = {}
	R.rng_seed(&d.rng, seed)
	d.depth = depth
	d.pc = pc
	d.push_att = push_att
	d.push_def = push_def
	d.light = LIGHT_START
	for tries := 0; d.room_count < MAX_ROOMS && tries < 300; tries += 1 {
		r := Room{w = ri(d, 4, 8), h = ri(d, 4, 6)}
		r.x = ri(d, 1, W - r.w - 2)
		r.y = ri(d, 1, H - r.h - 2)
		clash := false
		for i in 0 ..< d.room_count { if rooms_overlap(r, d.rooms[i]) { clash = true } }
		if clash { continue }
		d.rooms[d.room_count] = r
		d.room_count += 1
		carve_room(d, r)
	}
	// sort rooms left to right so the chain of corridors stays short
	for i in 1 ..< d.room_count {
		for j := i; j > 0 && d.rooms[j].x < d.rooms[j - 1].x; j -= 1 {
			d.rooms[j], d.rooms[j - 1] = d.rooms[j - 1], d.rooms[j]
		}
	}
	for i in 1 ..< d.room_count {
		carve_line(d, room_center(d.rooms[i - 1]), room_center(d.rooms[i]), R.d(&d.rng, 2) == 1)
	}
	for i in 2 ..< d.room_count { // extra corridors make loops, so one monster cannot cut the floor in two
		if R.d(&d.rng, 2) == 1 { carve_line(d, room_center(d.rooms[i - 2]), room_center(d.rooms[i]), R.d(&d.rng, 2) == 1) }
	}
	d.stairs = room_center(d.rooms[0])
	d.tiles[d.stairs.y][d.stairs.x] = .Stairs
	d.pos = d.stairs
	d.visited[0] = true
	for i in 1 ..< d.room_count {
		if R.d(&d.rng, 10) <= 6 { place_group(d, i, pick_monster(d, depth)) }
		if R.d(&d.rng, 10) <= 7 { place_loot(d, i) }
	}
	for d.room_count > 1 && d.loot_count < 3 { // always something worth fetching
		if !place_loot(d, ri(d, 1, d.room_count - 1)) { break }
	}
}

// Depth rosters, weighted. The easy depth 1 roster is decision A in DESIGN.md.
pick_monster :: proc(d: ^Delve, depth: int) -> R.Monster {
	roster: []R.Monster
	switch depth {
	case 1:  roster = {.Goose, .Goose, .Dog, .Dog, .Echo_Gecko, .Echo_Gecko}
	case 2:  roster = {.Dog, .Echo_Gecko, .Myconid, .Myconid, .Eelfolk, .Spellclaw, .Shadow}
	case:    roster = {.Myconid, .Eelfolk, .Spellclaw, .Spellclaw, .Shadow, .Shadow, .Flesh_Orb}
	}
	return roster[R.d(&d.rng, len(roster)) - 1]
}

group_size :: proc(d: ^Delve, m: R.Monster) -> int {
	switch m {
	case .Goose, .Echo_Gecko: return ri(d, 1, 3)
	case .Dog, .Myconid:      return ri(d, 1, 2)
	case .Eelfolk, .Spellclaw, .Shadow, .Flesh_Orb, .Dragon: return 1
	}
	return 1
}

place_group :: proc(d: ^Delve, room_idx: int, kind: R.Monster) -> bool {
	if d.group_count >= MAX_GROUPS { return false }
	g := d.group_count
	n := group_size(d, kind)
	placed := 0
	for _ in 0 ..< n {
		if d.mob_count >= MAX_MOBS { break }
		p, ok := random_free_tile(d, d.rooms[room_idx])
		if !ok { break }
		d.mobs[d.mob_count] = Mob{c = R.new_npc(kind), kind = kind, pos = p, group = g}
		d.mob_count += 1
		placed += 1
	}
	if placed == 0 { return false }
	d.groups[g].size = placed
	d.group_count += 1
	return true
}

place_loot :: proc(d: ^Delve, room_idx: int) -> bool {
	if d.loot_count >= MAX_LOOT { return false }
	p, ok := random_free_tile(d, d.rooms[room_idx])
	if !ok { return false }
	lo, hi := 40, 150
	switch d.depth {
	case 2: lo, hi = 80, 250
	case 3: lo, hi = 150, 400
	}
	d.loot[d.loot_count] = Loot{pos = p, gp = ri(d, lo, hi), slots = 2 if R.d(&d.rng, 5) == 1 else 1}
	d.loot_count += 1
	return true
}

// ---------- geometry ----------

bfs :: proc(d: ^Delve, from: Pos, out: ^Grid, blocked: ^Blocked = nil) {
	for y in 0 ..< H { for x in 0 ..< W { out[y][x] = INF } }
	q: [W * H]Pos
	head, tail := 0, 1
	q[0] = from
	out[from.y][from.x] = 0
	dirs := [4]Pos{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	for head < tail {
		p := q[head]
		head += 1
		for dd in dirs {
			n := p + dd
			if !walkable(d, n) || out[n.y][n.x] != INF { continue }
			if blocked != nil && blocked[n.y][n.x] { continue }
			out[n.y][n.x] = out[p.y][p.x] + 1
			q[tail] = n
			tail += 1
		}
	}
}

// Bresenham: every tile strictly between a and b must be open.
los :: proc(d: ^Delve, a, b: Pos) -> bool {
	dx, dy := abs(b.x - a.x), abs(b.y - a.y)
	sx := 1 if a.x < b.x else -1
	sy := 1 if a.y < b.y else -1
	err := dx - dy
	p := a
	for p != b {
		e2 := 2 * err
		if e2 > -dy { err -= dy; p.x += sx }
		if e2 < dx { err += dx; p.y += sy }
		if p != b && !walkable(d, p) { return false }
	}
	return true
}

sight_radius :: proc(d: ^Delve) -> int { return SIGHT if d.light > 0 else SIGHT_DARK }

can_see :: proc(d: ^Delve, p: Pos) -> bool {
	return manhattan(d.pos, p) <= sight_radius(d) && los(d, d.pos, p)
}

mob_alive :: proc(m: Mob) -> bool { return m.c.alive && m.state != .Fled }

// Neutral monsters (the group rolled Indifferent or better) swap places with the PC; everything else blocks.
blocks_pc :: proc(m: Mob) -> bool { return m.c.alive && m.state != .Neutral }

hunters :: proc(d: ^Delve) -> (n: int) {
	for i in 0 ..< d.mob_count { if mob_alive(d.mobs[i]) && d.mobs[i].state == .Hunting { n += 1 } }
	return
}

fleeing :: proc(d: ^Delve) -> bool {
	for i in 0 ..< d.mob_count { if d.mobs[i].c.alive && d.mobs[i].state == .Fled { return true } }
	return false
}

// Hunters close enough to count as a fight (the clock stops for these; farther ones still approach).
COMBAT_RANGE :: 8

hunters_near :: proc(d: ^Delve) -> (n: int) {
	for i in 0 ..< d.mob_count {
		m := d.mobs[i]
		if mob_alive(m) && m.state == .Hunting && manhattan(m.pos, d.pos) <= COMBAT_RANGE { n += 1 }
	}
	return
}

// ---------- the clock ----------

new_turn :: proc(d: ^Delve) {
	d.turns += 1
	if d.light > 0 { d.light -= 1 }
	if R.d(&d.rng, ENCOUNTER_DIE) == 1 { spawn_wanderers(d) }
}

// A wandering group appears in a room the PC cannot see and heads for the PC.
spawn_wanderers :: proc(d: ^Delve) {
	if d.group_count >= MAX_GROUPS || d.room_count < 2 { return }
	for _ in 0 ..< 20 {
		ri_ := ri(d, 1, d.room_count - 1)
		c := room_center(d.rooms[ri_])
		if manhattan(c, d.pos) < 10 || los(d, d.pos, c) { continue }
		first := d.mob_count
		if place_group(d, ri_, pick_monster(d, d.depth)) {
			react_group(d, d.mobs[first].group)
		}
		return
	}
}

// ---------- reaction, morale ----------

// Rolls the group's Reaction once. Hostile or Unfriendly groups hunt the PC; the rest ignore it.
react_group :: proc(d: ^Delve, g: int) {
	gi := &d.groups[g]
	if !gi.reacted {
		gi.reacted = true
		gi.reaction = R.reaction_roll(&d.rng)
	}
	hunt := gi.reaction == .Hostile || gi.reaction == .Unfriendly
	for i in 0 ..< d.mob_count {
		m := &d.mobs[i]
		if m.group == g && m.c.alive && m.state == .Idle { m.state = .Hunting if hunt else .Neutral }
	}
}

provoke_group :: proc(d: ^Delve, g: int) {
	d.groups[g].reacted = true
	for i in 0 ..< d.mob_count {
		m := &d.mobs[i]
		if m.group == g && m.c.alive && m.state != .Fled { m.state = .Hunting }
	}
}

// Seeing a new group triggers its Reaction roll; seen things are remembered.
notice :: proc(d: ^Delve) {
	for i in 0 ..< d.mob_count {
		m := &d.mobs[i]
		if !m.c.alive || !can_see(d, m.pos) { continue }
		m.seen = true
		if m.state == .Idle { react_group(d, m.group) }
	}
	for i in 0 ..< d.loot_count { if can_see(d, d.loot[i].pos) { d.loot[i].seen = true } }
	for i in 0 ..< d.room_count {
		r := d.rooms[i]
		if d.pos.x >= r.x && d.pos.x < r.x + r.w && d.pos.y >= r.y && d.pos.y < r.y + r.h { d.visited[i] = true }
	}
}

// After a death: the first, and the half-way one, trigger a Morale check for the survivors.
note_death :: proc(d: ^Delve, i: int) {
	m := &d.mobs[i]
	d.kills += 1
	d.xp += R.xp_for_defeating(m.c.hd)
	gi := &d.groups[m.group]
	gi.dead += 1
	if gi.dead == 1 || gi.dead * 2 >= gi.size {
		for j in 0 ..< d.mob_count {
			o := &d.mobs[j]
			if o.group == m.group && mob_alive(o^) && R.morale_flees(&d.rng, o.c.ml) { o.state = .Fled }
		}
	}
}

pc_died :: proc(d: ^Delve, by: R.Monster) {
	d.result = .Died
	d.killer = by
}

// ---------- monsters act ----------

occupied_by_mob :: proc(d: ^Delve, p: Pos, except: int) -> bool {
	for i in 0 ..< d.mob_count { if i != except && d.mobs[i].c.alive && d.mobs[i].pos == p { return true } }
	return false
}

mob_step :: proc(d: ^Delve, i: int, df: ^Grid) {
	m := &d.mobs[i]
	best := df[m.pos.y][m.pos.x]
	to := m.pos
	dirs := [4]Pos{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	for dd in dirs {
		n := m.pos + dd
		if !walkable(d, n) || n == d.pos || occupied_by_mob(d, n, i) { continue }
		if df[n.y][n.x] < best { best = df[n.y][n.x]; to = n }
	}
	m.pos = to
}

can_shoot :: proc(d: ^Delve, m: Mob) -> bool {
	return m.c.ranged && manhattan(m.pos, d.pos) <= RANGED_RANGE && los(d, m.pos, d.pos)
}

mob_attack :: proc(d: ^Delve, i: int) {
	m := &d.mobs[i]
	kind := R.Attack_Kind.Ranged if m.c.ranged else R.Attack_Kind.Melee
	R.resolve_attack(&d.rng, &m.c, &d.pc, kind, 0, d.push_def)
	if !m.c.alive { note_death(d, i) }
	if !d.pc.alive { pc_died(d, m.kind) }
}

// A monster that failed Morale runs away from the PC, two tiles a round.
mob_flee :: proc(d: ^Delve, i: int, df: ^Grid) {
	m := &d.mobs[i]
	dirs := [4]Pos{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	for _ in 0 ..< 2 {
		best := df[m.pos.y][m.pos.x]
		to := m.pos
		for dd in dirs {
			n := m.pos + dd
			if !walkable(d, n) || n == d.pos || occupied_by_mob(d, n, i) || df[n.y][n.x] == INF { continue }
			if df[n.y][n.x] > best { best = df[n.y][n.x]; to = n }
		}
		m.pos = to
	}
}

monsters_act :: proc(d: ^Delve) {
	df: Grid
	bfs(d, d.pos, &df)
	for i in 0 ..< d.mob_count {
		m := &d.mobs[i]
		if m.c.alive && m.state == .Fled { mob_flee(d, i, &df); continue }
		if !mob_alive(m^) || m.state != .Hunting || d.result != .Running { continue }
		adjacent := manhattan(m.pos, d.pos) == 1
		if !adjacent && !can_shoot(d, m^) { mob_step(d, i, &df) } // the move
		adjacent = manhattan(m.pos, d.pos) == 1
		switch { // the action
		case .Stun_Call in m.c.abilities && !m.c.stun_used && adjacent:
			R.stun_call(&d.rng, &m.c, &d.pc)
		case m.c.ranged && m.reloading:
			m.reloading = false
		case adjacent || can_shoot(d, m^):
			mob_attack(d, i)
			if m.c.ranged { m.reloading = true }
		case:
			mob_step(d, i, &df) // a second move
		}
	}
}

// ---------- the PC's round ----------

pick_up :: proc(d: ^Delve) {
	for i in 0 ..< d.loot_count {
		l := &d.loot[i]
		if !l.taken && l.pos == d.pos && R.slots_free(d.pc) >= l.slots {
			l.taken = true
			d.pc.item_slots += l.slots
			d.carried_gp += l.gp
			d.items += 1
		}
	}
}

// The first living monster on the shortest path (ignoring monsters) from the PC to dest, or -1.
first_blocker :: proc(d: ^Delve, dest: Pos) -> int {
	g: Grid
	bfs(d, dest, &g)
	cur := d.pos
	dirs := [4]Pos{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	for _ in 0 ..< W * H {
		if cur == dest { return -1 }
		best := g[cur.y][cur.x]
		to := cur
		for dd in dirs {
			n := cur + dd
			if walkable(d, n) && g[n.y][n.x] < best { best = g[n.y][n.x]; to = n }
		}
		if to == cur { return -1 }
		for i in 0 ..< d.mob_count { if blocks_pc(d.mobs[i]) && d.mobs[i].pos == to { return i } }
		cur = to
	}
	return -1
}

// Moves the PC one tile along the shortest path to dest, around living mobs and any avoid set.
pc_step_toward :: proc(d: ^Delve, dest: Pos, avoid: ^Blocked) -> bool {
	if d.pos == dest { return false }
	blocked: Blocked
	for i in 0 ..< d.mob_count { if blocks_pc(d.mobs[i]) { blocked[d.mobs[i].pos.y][d.mobs[i].pos.x] = true } }
	if avoid != nil { for y in 0 ..< H { for x in 0 ..< W { if avoid[y][x] { blocked[y][x] = true } } } }
	blocked[dest.y][dest.x] = false
	g: Grid
	bfs(d, dest, &g, &blocked)
	best := g[d.pos.y][d.pos.x]
	to := d.pos
	dirs := [4]Pos{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	for dd in dirs {
		n := d.pos + dd
		if walkable(d, n) && !blocked[n.y][n.x] && g[n.y][n.x] < best { best = g[n.y][n.x]; to = n }
	}
	if to == d.pos { return false }
	for i in 0 ..< d.mob_count { // swap with a neutral monster
		if d.mobs[i].c.alive && d.mobs[i].state == .Neutral && d.mobs[i].pos == to { d.mobs[i].pos = d.pos }
	}
	d.pos = to
	pick_up(d)
	return true
}

// One round. `act` is the PC's part; hunting monsters act before or after it by the initiative d6.
// Monsters that start hunting this round only act from the next one.
round :: proc(d: ^Delve, act: proc(d: ^Delve, ctx: rawptr), ctx: rawptr) {
	if d.result != .Running { return }
	had_hunters := hunters(d) > 0 || fleeing(d) // monsters act this round, wherever they are
	fighting := hunters_near(d) > 0 // the clock only stops for a fight at hand
	pos_before := d.pos
	if had_hunters {
		if fighting { d.rounds += 1 }
		pcs_first := R.pcs_first(&d.rng)
		if !pcs_first { monsters_act(d) }
		if d.result == .Running { pc_part(d, act, ctx) }
		if pcs_first && d.result == .Running { monsters_act(d) }
	} else {
		pc_part(d, act, ctx)
	}
	if d.result != .Running { return }
	if d.pc.paralyzed > 0 { d.pc.paralyzed -= 1 }
	if fighting {
		if hunters_near(d) == 0 { new_turn(d) } // cleaning up after a fight takes a Turn
	} else {
		moved := manhattan(pos_before, d.pos)
		d.tiles_moved += moved
		for d.tiles_moved >= (d.turns + 1) * TILES_PER_TURN && d.result == .Running { new_turn(d) }
	}
	notice(d)
}

pc_part :: proc(d: ^Delve, act: proc(d: ^Delve, ctx: rawptr), ctx: rawptr) {
	if d.pc.paralyzed > 0 { return }
	act(d, ctx)
}

Move_Order :: struct { dest: Pos, avoid: ^Blocked }
Fight_Order :: struct { mob: int }

// The PC's move and action both spent on moving: up to two tiles.
round_move :: proc(d: ^Delve, dest: Pos, avoid: ^Blocked = nil) {
	order := Move_Order{dest, avoid}
	round(d, proc(d: ^Delve, ctx: rawptr) {
		o := cast(^Move_Order)ctx
		if pc_step_toward(d, o.dest, o.avoid) { pc_step_toward(d, o.dest, o.avoid) }
	}, &order)
}

// Close on a mob (a move) and strike it if adjacent (the action). Ranged weapons shoot in sight.
round_fight :: proc(d: ^Delve, mob: int) {
	order := Fight_Order{mob}
	round(d, proc(d: ^Delve, ctx: rawptr) {
		i := (cast(^Fight_Order)ctx).mob
		m := &d.mobs[i]
		if !m.c.alive { return }
		ranged := R.WEAPONS[d.pc.weapon].ranged
		if !(ranged && manhattan(d.pos, m.pos) <= RANGED_RANGE && los(d, d.pos, m.pos)) && manhattan(d.pos, m.pos) > 1 {
			pc_step_toward(d, m.pos, nil)
		}
		adjacent := manhattan(d.pos, m.pos) == 1
		shot := ranged && manhattan(d.pos, m.pos) <= RANGED_RANGE && los(d, d.pos, m.pos)
		if !adjacent && !shot { return }
		if m.state != .Hunting { provoke_group(d, m.group) }
		kind := R.Attack_Kind.Ranged if shot else R.Attack_Kind.Melee
		R.resolve_attack(&d.rng, &d.pc, &m.c, kind, d.push_att)
		if !m.c.alive { note_death(d, i) }
		if !d.pc.alive { pc_died(d, m.kind) }
	}, &order)
}

// Leave by the stairs, banking what is carried. Only valid on the stairs tile.
exit_delve :: proc(d: ^Delve) -> bool {
	if d.pos != d.stairs || d.result != .Running { return false }
	d.result = .Exited
	return true
}
