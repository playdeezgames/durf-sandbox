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
MAX_LOOT :: 48 // lost items plus whatever the PC drops
MAX_GROUPS :: 24
MAX_TRAPS :: 12

SIGHT          :: 6 // tiles you can see by torchlight
SIGHT_DARK     :: 1
LIGHT_START    :: 12 // Turns of light: two torches (a torch burns 6 Turns)
TILES_PER_TURN :: 10 // out of combat, 10 tiles of travel is one 10 minute Turn
RANGED_RANGE   :: 8
ENCOUNTER_DIE  :: 6 // each Turn, a 1 brings a wandering group
CLUE_SIGHT     :: 3 // clues can only be made out this close (and in torchlight)
SEARCH_RADIUS  :: 4 // a search (one Turn) reveals every hidden trap this near

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
	snared:    int, // rounds still held by a snare
}

// Something on the floor: a lost item to fetch, or anything the PC dropped.
Loot :: struct {
	pos:     Pos,
	item:    R.Item,
	taken:   bool,
	seen:    bool,
	dropped: bool, // left by the PC (never auto-fetched by the bot, never counted as found)
}

// A trap: hidden until a search finds it. It springs once (or when disarmed) and is then spent.
Trap :: struct {
	pos:        Pos,
	kind:       R.Trap_Kind,
	revealed:   bool,
	armed:      bool,
	clues:      [2]Pos, // marks on nearby tiles that warn of it
	clue_count: int,
}

Room :: struct { x, y, w, h: int }

Result_Kind :: enum { Running, Exited, Died }

// What happened, for a log the player can read. The game layer turns these into text and drains them.
Event_Kind :: enum { Attack, Reaction, Mob_Fled, Mob_Died, Pickup, Drop, Light_Out, Stunned, Ammo_Low, Ammo_Gone, Trap_Found, Search_Nothing, Trap_Sprung, Trap_Disarmed, Disarm_Failed }

Event :: struct {
	kind:     Event_Kind,
	name:     string, // the monster, or the item
	n:        int, // Turns lost, gold, ...
	by_pc:    bool, // Attack: the PC attacked (else a monster attacked the PC)
	x:        R.Exchange, // Attack: every roll
	reaction: R.Reaction,
	trap:     R.Trap_Kind, // Trap_*: which trap (name is the monster that sprang it; empty for the PC)
	roll:     R.Roll, // Disarm_*: the roll
}
EVENT_CAP :: 64

// One round as a person plays it: a move and an action, in either order.
Round_State :: struct {
	active:       bool,
	had_hunters:  bool,
	fighting:     bool,
	pcs_first:    bool,
	move_left:    int,
	action_left:  int,
	pos_before:   Pos,
}

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
	traps:        [MAX_TRAPS]Trap,
	trap_count:   int,
	depth:        int,
	rng:          R.Rng,
	pc:           R.Creature,
	pos:          Pos,
	push_att:     int, // Stress the PC spends per attack roll
	push_def:     int, // ... per defence roll
	tiles_moved:  int,
	turns:        int,
	light:        int, // Turns of light left
	xp:           int,
	kills:        int,
	rounds:       int, // combat rounds
	result:       Result_Kind,
	rd:           Round_State,
	events:       [EVENT_CAP]Event,
	event_count:  int,
	explored:     [H][W]bool,
	visible:      [H][W]bool,
	killer:       R.Monster, // valid when result == .Died and trap_death is false
	trap_death:   bool, // the PC died to a trap
	traps_sprung: int, // on the PC (for the simulator's report)
	traps_disarmed: int,
	searches:     int,
	killer_trap:  R.Trap_Kind,
}

in_bounds :: proc(p: Pos) -> bool { return p.x >= 0 && p.y >= 0 && p.x < W && p.y < H }
emit :: proc(d: ^Delve, e: Event) {
	if d.event_count < EVENT_CAP { d.events[d.event_count] = e; d.event_count += 1 }
}

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
	for i in 0 ..< d.loot_count { if !d.loot[i].taken && d.loot[i].pos == p { return true } }
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
	place_traps(d)
}

// ---------- traps (house content, see DESIGN.md "Traps") ----------

trap_index :: proc(d: ^Delve, p: Pos, armed_only := true) -> int {
	for i in 0 ..< d.trap_count { if d.traps[i].pos == p && (d.traps[i].armed || !armed_only) { return i } }
	return -1
}

in_start_room :: proc(d: ^Delve, p: Pos) -> bool {
	r := d.rooms[0]
	return p.x >= r.x - 1 && p.x <= r.x + r.w && p.y >= r.y - 1 && p.y <= r.y + r.h
}

// Hidden traps outside the start room, each with a clue or two on nearby floor. Depth 1 has two, one more per depth.
place_traps :: proc(d: ^Delve) {
	want := min(1 + d.depth, MAX_TRAPS)
	for _ in 0 ..< want {
		placed := false
		for _ in 0 ..< 80 { // capped: an unbounded retry loop freezes a browser tab
			p := Pos{ri(d, 1, W - 2), ri(d, 1, H - 2)}
			if d.tiles[p.y][p.x] != .Floor || in_start_room(d, p) || tile_occupied(d, p) || trap_index(d, p, false) >= 0 { continue }
			t := Trap{pos = p, kind = R.Trap_Kind(R.d(&d.rng, len(R.Trap_Kind)) - 1), armed = true}
			for _ in 0 ..< 30 { // up to two clue tiles within two tiles, on floor that is not another trap
				if t.clue_count >= 2 { break }
				c := p + Pos{ri(d, -2, 2), ri(d, -2, 2)}
				dist := manhattan(c, p)
				if dist < 1 || dist > 2 || !in_bounds(c) || d.tiles[c.y][c.x] != .Floor || trap_index(d, c, false) >= 0 { continue }
				if t.clue_count == 1 && t.clues[0] == c { continue }
				t.clues[t.clue_count] = c
				t.clue_count += 1
			}
			if t.clue_count == 0 { continue }
			d.traps[d.trap_count] = t
			d.trap_count += 1
			placed = true
			break
		}
		if !placed { break }
	}
}

// Whether a clue mark is on this tile (for drawing), and for which trap.
clue_at :: proc(d: ^Delve, p: Pos) -> (kind: R.Trap_Kind, ok: bool) {
	for i in 0 ..< d.trap_count {
		t := d.traps[i]
		if !t.armed { continue }
		for k in 0 ..< t.clue_count { if t.clues[k] == p { return t.kind, true } }
	}
	return
}

// Whether the PC can make out a clue on this tile: lit, and close.
clue_visible :: proc(d: ^Delve, p: Pos) -> bool {
	return in_bounds(p) && d.visible[p.y][p.x] && manhattan(d.pos, p) <= CLUE_SIGHT
}

// A revealed, armed trap on this tile: the PC will not walk into it (disarm it or go around).
known_trap_at :: proc(d: ^Delve, p: Pos) -> bool {
	i := trap_index(d, p)
	return i >= 0 && d.traps[i].revealed
}

// The nearest group that is not hunting wakes up and hunts (an alarm rings, whatever its Reaction).
wake_nearest :: proc(d: ^Delve, from: Pos, except_group: int) {
	best, best_dist := -1, INF
	for i in 0 ..< d.mob_count {
		m := d.mobs[i]
		if !m.c.alive || m.state == .Fled || m.state == .Hunting || m.group == except_group { continue }
		if dist := manhattan(m.pos, from); dist < best_dist { best, best_dist = i, dist }
	}
	if best >= 0 { provoke_group(d, d.mobs[best].group) }
}

// The PC sets off trap i (stepped on it, or failed to disarm it).
spring_on_pc :: proc(d: ^Delve, i: int) {
	t := &d.traps[i]
	t.armed = false
	t.revealed = true
	d.traps_sprung += 1
	switch t.kind {
	case .Darts:
		res := R.apply_damage(&d.rng, &d.pc, R.TRAP_DART_WOUNDS, direct = true)
		emit(d, Event{kind = .Trap_Sprung, trap = t.kind, n = res.wounds_new})
		if !d.pc.alive { d.result = .Died; d.trap_death = true; d.killer_trap = t.kind }
	case .Snare:
		turns := R.d(&d.rng, R.TRAP_SNARE_DIE)
		emit(d, Event{kind = .Trap_Sprung, trap = t.kind, n = turns})
		helpless_turns(d, turns, hunters_strike = true)
	case .Alarm:
		emit(d, Event{kind = .Trap_Sprung, trap = t.kind})
		wake_nearest(d, d.pos, -1)
	case .Mess:
		emit(d, Event{kind = .Trap_Sprung, trap = t.kind, n = R.push(&d.pc, R.TRAP_MESS_STRESS)})
	}
}

// A hunting monster steps on trap i. Only seen springs are logged (an alarm is always heard).
spring_on_mob :: proc(d: ^Delve, i, mob: int) {
	t := &d.traps[i]
	t.armed = false
	seen := can_see(d, t.pos)
	t.revealed = t.revealed || seen
	m := &d.mobs[mob]
	switch t.kind {
	case .Darts:
		res := R.apply_damage(&d.rng, &m.c, R.TRAP_DART_WOUNDS, direct = true)
		if seen { emit(d, Event{kind = .Trap_Sprung, trap = t.kind, name = m.c.name, n = res.wounds_new}) }
		if !m.c.alive { note_death(d, mob) }
	case .Snare:
		m.snared = R.d(&d.rng, R.TRAP_SNARE_DIE)
		if seen { emit(d, Event{kind = .Trap_Sprung, trap = t.kind, name = m.c.name, n = m.snared}) }
	case .Alarm:
		emit(d, Event{kind = .Trap_Sprung, trap = t.kind, name = m.c.name})
		wake_nearest(d, t.pos, m.group)
	case .Mess:
		if seen { emit(d, Event{kind = .Trap_Sprung, trap = t.kind, name = m.c.name}) }
	}
}

// Search (one Turn, an action): reveals every hidden armed trap within SEARCH_RADIUS. No roll: the cost is the
// Turn, and the clues say where to look.
search_here :: proc(d: ^Delve) {
	found := 0
	d.searches += 1
	for i in 0 ..< d.trap_count {
		t := &d.traps[i]
		if t.armed && !t.revealed && manhattan(t.pos, d.pos) <= SEARCH_RADIUS {
			t.revealed = true
			found += 1
			emit(d, Event{kind = .Trap_Found, trap = t.kind})
		}
	}
	if found == 0 { emit(d, Event{kind = .Search_Nothing}) }
	lose_turn(d)
}

// The revealed armed trap next to the PC, if any.
adjacent_known_trap :: proc(d: ^Delve) -> int {
	for i in 0 ..< d.trap_count {
		t := d.traps[i]
		if t.armed && t.revealed && manhattan(t.pos, d.pos) == 1 { return i }
	}
	return -1
}

// Disarm (an action): a DEX roll over the DC, Push allowed. A failure sets it off on the PC.
disarm_here :: proc(d: ^Delve) -> bool {
	i := adjacent_known_trap(d)
	if i < 0 { return false }
	pushes := R.push(&d.pc, d.push_att)
	x := R.roll_d20(&d.rng, R.eff_attr(d.pc, .DEX), pushes)
	if x.success {
		d.traps[i].armed = false
		d.traps_disarmed += 1
		emit(d, Event{kind = .Trap_Disarmed, trap = d.traps[i].kind, roll = x})
	} else {
		emit(d, Event{kind = .Disarm_Failed, trap = d.traps[i].kind, roll = x})
		spring_on_pc(d, i)
	}
	return true
}

// After the PC enters a tile: an armed trap there goes off.
pc_enter :: proc(d: ^Delve) {
	if i := trap_index(d, d.pos); i >= 0 { spring_on_pc(d, i) }
}

// Depth rosters, weighted. The easy depth 1 roster is decision A in DESIGN.md.
pick_monster :: proc(d: ^Delve, depth: int) -> R.Monster {
	roster: []R.Monster
	switch depth {
	case 1:  roster = {.Goose, .Goose, .Dog, .Dog, .Echo_Gecko, .Echo_Gecko}
	case 2:  roster = {.Dog, .Echo_Gecko, .Myconid, .Myconid, .Eelfolk, .Eelfolk, .Spellclaw, .Shadow, .Blowpipe_Imp, .Blowpipe_Imp, .Crossbow_Cultist}
	case:    roster = {.Myconid, .Eelfolk, .Eelfolk, .Spellclaw, .Spellclaw, .Shadow, .Shadow, .Flesh_Orb, .Crossbow_Cultist, .Crossbow_Cultist, .Blowpipe_Imp}
	}
	return roster[R.d(&d.rng, len(roster)) - 1]
}

group_size :: proc(d: ^Delve, m: R.Monster) -> int {
	switch m {
	case .Goose, .Echo_Gecko: return ri(d, 1, 3)
	case .Dog, .Myconid, .Blowpipe_Imp, .Crossbow_Cultist: return ri(d, 1, 2)
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

LOST_ITEMS := [?]string{
	"Umbrella", "Left shoe", "Set of dentures", "Ledger", "Teapot", "Fiddle", "Wedding ring", "Spectacles",
	"Pocket watch", "Hat", "Music box", "Parrot cage", "Wooden leg", "Letter", "Garden gnome", "Locket",
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
	it := R.Item{name = LOST_ITEMS[R.d(&d.rng, len(LOST_ITEMS)) - 1], kind = .Lost, slots = 2 if R.d(&d.rng, 5) == 1 else 1, gp = ri(d, lo, hi)}
	d.loot[d.loot_count] = Loot{pos = p, item = it}
	d.loot_count += 1
	return true
}

// What the PC is carrying that is worth something: lost items only.
lost_count :: proc(d: ^Delve) -> int { return R.count_items(d.pc, .Lost) }
lost_gp :: proc(d: ^Delve) -> (gp: int) {
	for i in 0 ..< d.pc.inv_count { if d.pc.inv[i].kind == .Lost { gp += d.pc.inv[i].gp } }
	return
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

// The last hunter nearby is gone: cleaning up takes a Turn, and Ammo that was shot is checked.
end_fight :: proc(d: ^Delve) {
	lose_turn(d)
	was_low := d.pc.ammo_low
	if R.ammo_check(&d.rng, &d.pc) && !was_low { emit(d, Event{kind = .Ammo_Low}) }
}


new_turn :: proc(d: ^Delve) {
	d.turns += 1
	if d.light > 0 {
		d.light -= 1
		if d.light == 0 { emit(d, Event{kind = .Light_Out}) }
	}
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
		for i in 0 ..< d.mob_count {
			if d.mobs[i].group == g { emit(d, Event{kind = .Reaction, name = d.mobs[i].c.name, reaction = gi.reaction}); break }
		}
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

// What the PC can see now (the torch's radius, with line of sight); seen tiles are remembered.
update_fov :: proc(d: ^Delve) {
	d.visible = {}
	r := sight_radius(d)
	for dy in -r ..= r {
		for dx in -r ..= r {
			if abs(dx) + abs(dy) > r { continue }
			p := d.pos + Pos{dx, dy}
			if !in_bounds(p) || !los(d, d.pos, p) { continue }
			d.visible[p.y][p.x] = true
			d.explored[p.y][p.x] = true
		}
	}
}

// Seeing a new group triggers its Reaction roll; seen things are remembered.
notice :: proc(d: ^Delve) {
	update_fov(d)
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
	emit(d, Event{kind = .Mob_Died, name = m.c.name, n = R.xp_for_defeating(m.c.hd)})
	gi := &d.groups[m.group]
	gi.dead += 1
	if gi.dead == 1 || gi.dead * 2 >= gi.size {
		for j in 0 ..< d.mob_count {
			o := &d.mobs[j]
			if o.group == m.group && mob_alive(o^) && R.morale_flees(&d.rng, o.c.ml) {
				o.state = .Fled
				emit(d, Event{kind = .Mob_Fled, name = o.c.name})
			}
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
	moved := to != m.pos
	m.pos = to
	if i2 := trap_index(d, m.pos); moved && i2 >= 0 { spring_on_mob(d, i2, i) }
}

can_shoot :: proc(d: ^Delve, m: Mob) -> bool {
	return m.c.ranged && manhattan(m.pos, d.pos) <= RANGED_RANGE && los(d, m.pos, d.pos)
}

mob_attack :: proc(d: ^Delve, i: int) {
	m := &d.mobs[i]
	kind := R.Attack_Kind.Ranged if m.c.ranged else R.Attack_Kind.Melee
	x := R.resolve_attack(&d.rng, &m.c, &d.pc, kind, 0, d.push_def)
	emit(d, Event{kind = .Attack, name = m.c.name, by_pc = false, x = x})
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
		if m.c.alive && m.snared > 0 { m.snared -= 1; continue } // held by a snare
		if m.c.alive && m.state == .Fled { mob_flee(d, i, &df); continue }
		if !mob_alive(m^) || m.state != .Hunting || d.result != .Running { continue }
		adjacent := manhattan(m.pos, d.pos) == 1
		if !adjacent && !can_shoot(d, m^) { mob_step(d, i, &df) } // the move
		if m.snared > 0 || !m.c.alive { continue } // sprang a snare (or a dart trap) on the way
		adjacent = manhattan(m.pos, d.pos) == 1
		switch { // the action
		case .Stun_Call in m.c.abilities && !m.c.stun_used && adjacent:
			if turns := R.stun_call(&d.rng, &m.c, &d.pc); turns > 0 { paralyse(d, i, turns) }
		case .Reload in m.c.abilities && m.reloading:
			m.reloading = false
		case adjacent || can_shoot(d, m^):
			mob_attack(d, i)
			if .Reload in m.c.abilities { m.reloading = true }
		case:
			mob_step(d, i, &df) // a second move
		}
	}
}

// ---------- the PC's round ----------

// Time lost outright (a fight's clean-up, paralysis): a Turn passes, and travel time catches up.
lose_turn :: proc(d: ^Delve) {
	new_turn(d)
	d.tiles_moved = max(d.tiles_moved, d.turns * TILES_PER_TURN)
}

// The Echo Gecko's stun (house reading 8): the PC loses `turns` Turns helpless. The stunning group
// loses interest and becomes Neutral. Each Turn burns torch and rolls the wanderer d6; a wandering
// group that turns up and hunts gets one free attack per remaining Turn on the helpless PC.
paralyse :: proc(d: ^Delve, by: int, turns: int) {
	g := d.mobs[by].group
	emit(d, Event{kind = .Stunned, name = d.mobs[by].c.name, n = turns})
	for i in 0 ..< d.mob_count {
		if d.mobs[i].group == g && d.mobs[i].c.alive && d.mobs[i].state != .Fled { d.mobs[i].state = .Neutral }
	}
	helpless_turns(d, turns)
}

helpless_turns :: proc(d: ^Delve, turns: int, hunters_strike := false) {
	for t in 1 ..= turns {
		d.pc.paralyzed = turns - t + 1
		if hunters_strike { // hunters nearby get one free attack per Turn held
			for i in 0 ..< d.mob_count {
				m := d.mobs[i]
				if d.pc.alive && mob_alive(m) && m.state == .Hunting && manhattan(m.pos, d.pos) <= COMBAT_RANGE { mob_attack(d, i) }
			}
			if !d.pc.alive { break }
		}
		first_new := d.mob_count
		lose_turn(d)
		if d.mob_count > first_new && d.mobs[first_new].state == .Hunting {
			for _ in 0 ..< d.pc.paralyzed { if d.pc.alive { mob_attack(d, first_new) } }
		}
		if !d.pc.alive { break }
	}
	d.pc.paralyzed = 0
}

// ---------- floor items ----------

// Takes what the PC is standing on, if it fits (explicit: the PC's action). Lost items come first,
// then anything the PC dropped, so the order never depends on where records sit in the array.
pick_up :: proc(d: ^Delve) -> bool {
	for pass in 0 ..< 2 {
		for i in 0 ..< d.loot_count {
			l := &d.loot[i]
			if l.taken || l.pos != d.pos || l.dropped != (pass == 1) || !R.can_carry(d.pc, l.item) { continue }
			R.add_item(&d.pc, l.item)
			l.taken = true
			emit(d, Event{kind = .Pickup, name = l.item.name, n = l.item.gp})
			return true
		}
	}
	return false
}

// Puts inventory item `idx` on the floor at the PC's feet; it can be picked up again.
drop_item :: proc(d: ^Delve, idx: int) -> bool {
	if idx < 0 || idx >= d.pc.inv_count { return false }
	slot := -1
	for i in 0 ..< d.loot_count { if d.loot[i].taken { slot = i; break } } // reuse the record of something already picked up
	if slot < 0 {
		if d.loot_count >= MAX_LOOT { return false }
		slot = d.loot_count
		d.loot_count += 1
	}
	it := R.remove_item(&d.pc, idx)
	d.loot[slot] = Loot{pos = d.pos, item = it, dropped = true, seen = true}
	emit(d, Event{kind = .Drop, name = it.name})
	return true
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
	for i in 0 ..< d.trap_count { if d.traps[i].armed && d.traps[i].revealed { blocked[d.traps[i].pos.y][d.traps[i].pos.x] = true } }
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
	pc_enter(d)
	return true
}

// Starts a round: who is hunting, the initiative d6, and monsters that won it act first.
begin_round :: proc(d: ^Delve) {
	d.rd = Round_State{active = true, move_left = 1, action_left = 1}
	d.rd.had_hunters = hunters(d) > 0 || fleeing(d) // monsters act this round, wherever they are
	d.rd.fighting = hunters_near(d) > 0 // the clock only stops for a fight at hand
	d.rd.pos_before = d.pos
	if d.rd.had_hunters {
		if d.rd.fighting { d.rounds += 1 }
		d.rd.pcs_first = R.pcs_first(&d.rng)
		if !d.rd.pcs_first { monsters_act(d) }
	}
}

// Ends a round: monsters that lost the initiative act, then time passes and the PC looks around.
end_round :: proc(d: ^Delve) {
	rd := d.rd
	d.rd.active = false
	if rd.had_hunters && rd.pcs_first && d.result == .Running { monsters_act(d) }
	if d.result != .Running { return }
	if d.pc.paralyzed > 0 { d.pc.paralyzed -= 1 }
	if rd.fighting {
		if hunters_near(d) == 0 { end_fight(d) }
	} else {
		moved := manhattan(rd.pos_before, d.pos)
		d.tiles_moved += moved
		for d.tiles_moved >= (d.turns + 1) * TILES_PER_TURN && d.result == .Running { new_turn(d) }
	}
	notice(d)
}

// One whole round with the PC's part given as a callback (used by the simulator's bots).
round :: proc(d: ^Delve, act: proc(d: ^Delve, ctx: rawptr), ctx: rawptr) {
	if d.result != .Running { return }
	begin_round(d)
	if d.result == .Running { pc_part(d, act, ctx) }
	end_round(d)
}

pc_part :: proc(d: ^Delve, act: proc(d: ^Delve, ctx: rawptr), ctx: rawptr) {
	if d.pc.paralyzed > 0 { return }
	act(d, ctx)
}

// The PC attacks monster i (adjacent, or shot from range). Provokes the group if it was not hunting.
pc_attack_mob :: proc(d: ^Delve, i: int, shot: bool) {
	m := &d.mobs[i]
	if m.state != .Hunting { provoke_group(d, m.group) }
	kind := R.Attack_Kind.Ranged if shot else R.Attack_Kind.Melee
	ammo_before := R.count_items(d.pc, .Ammo)
	x := R.resolve_attack(&d.rng, &d.pc, &m.c, kind, d.push_att)
	emit(d, Event{kind = .Attack, name = m.c.name, by_pc = true, x = x})
	if R.count_items(d.pc, .Ammo) < ammo_before { emit(d, Event{kind = .Ammo_Gone}) }
	if !m.c.alive { note_death(d, i) }
	if !d.pc.alive { pc_died(d, m.kind) }
}

Move_Order :: struct { dest: Pos, avoid: ^Blocked }
Fight_Order :: struct { mob: int }

// The PC's move and action both spent on moving: up to two tiles.
round_move :: proc(d: ^Delve, dest: Pos, avoid: ^Blocked = nil) {
	order := Move_Order{dest, avoid}
	round(d, proc(d: ^Delve, ctx: rawptr) {
		o := cast(^Move_Order)ctx
		if pc_step_toward(d, o.dest, o.avoid) && d.result == .Running && d.pc.paralyzed == 0 { pc_step_toward(d, o.dest, o.avoid) }
	}, &order)
}

// Close on a mob (a move) and strike it if adjacent (the action). Ranged weapons shoot in sight.
round_fight :: proc(d: ^Delve, mob: int) {
	order := Fight_Order{mob}
	round(d, proc(d: ^Delve, ctx: rawptr) {
		i := (cast(^Fight_Order)ctx).mob
		m := &d.mobs[i]
		if !m.c.alive { return }
		ranged := R.can_fire(d.pc)
		if !(ranged && manhattan(d.pos, m.pos) <= RANGED_RANGE && los(d, d.pos, m.pos)) && manhattan(d.pos, m.pos) > 1 {
			pc_step_toward(d, m.pos, nil)
		}
		adjacent := manhattan(d.pos, m.pos) == 1
		shot := ranged && manhattan(d.pos, m.pos) <= RANGED_RANGE && los(d, d.pos, m.pos)
		if !adjacent && !shot { return }
		pc_attack_mob(d, i, shot)
	}, &order)
}

Item_Order :: struct { idx: int }

// The PC's action: pick up what is underfoot (a round passes; hunting monsters act).
round_pickup :: proc(d: ^Delve) {
	round(d, proc(d: ^Delve, ctx: rawptr) { pick_up(d) }, nil)
}

// The PC's action: drop inventory item `idx`.
round_drop :: proc(d: ^Delve, idx: int) {
	order := Item_Order{idx}
	round(d, proc(d: ^Delve, ctx: rawptr) { drop_item(d, (cast(^Item_Order)ctx).idx) }, &order)
}

// The PC's action: search for traps (costs a Turn).
round_search :: proc(d: ^Delve) {
	round(d, proc(d: ^Delve, ctx: rawptr) { search_here(d) }, nil)
}

// The PC's action: disarm the revealed trap next to it, if there is one.
round_disarm :: proc(d: ^Delve) {
	round(d, proc(d: ^Delve, ctx: rawptr) { disarm_here(d) }, nil)
}

// Leave by the stairs, banking what is carried. Only valid on the stairs tile.
exit_delve :: proc(d: ^Delve) -> bool {
	if d.pos != d.stairs || d.result != .Running { return false }
	d.result = .Exited
	return true
}

// ---------- a person's round: separate inputs, a move and an action ----------
//
// Out of a fight every input is its own round (one tile of travel, or one action). In a fight the
// first input starts the round (the initiative d6 is rolled and monsters that won it act first), the
// PC gets a move and an action in either order (an action can be a second move), and the round ends
// when both are used or the PC waits. Monsters that lost the initiative act when it ends.

start_round :: proc(d: ^Delve) {
	if !d.rd.active { begin_round(d) }
}

// After the PC uses a slot: out of a fight, or with nothing left, the round ends.
spend :: proc(d: ^Delve, slot_is_move: bool) {
	if slot_is_move && d.rd.move_left > 0 { d.rd.move_left -= 1 } else { d.rd.action_left -= 1 }
	if d.result != .Running || !d.rd.had_hunters || d.rd.move_left + d.rd.action_left <= 0 { end_round(d) }
}

mob_at :: proc(d: ^Delve, p: Pos) -> int {
	for i in 0 ..< d.mob_count { if d.mobs[i].c.alive && d.mobs[i].pos == p { return i } }
	return -1
}

// Whether the PC could attack monster i right now, and whether it would be a shot: a usable ranged
// weapon in sight shoots (even point blank, as the bot does); otherwise melee needs it adjacent.
attackable :: proc(d: ^Delve, i: int) -> (ok: bool, shot: bool) {
	m := d.mobs[i]
	if !m.c.alive { return }
	if R.can_fire(d.pc) && manhattan(d.pos, m.pos) <= RANGED_RANGE && can_see(d, m.pos) { return true, true }
	if manhattan(d.pos, m.pos) == 1 { return true, false }
	return
}

// A step in a direction. Walking into a monster attacks it (bump), into a neutral one swaps places.
// Returns false (and spends nothing) if the move is not possible.
pc_move :: proc(d: ^Delve, dir: Pos) -> bool {
	if d.result != .Running { return false }
	to := d.pos + dir
	if !walkable(d, to) || known_trap_at(d, to) { return false }
	if d.rd.active && d.rd.move_left + d.rd.action_left <= 0 { return false }
	if i := mob_at(d, to); i >= 0 && blocks_pc(d.mobs[i]) { return pc_attack(d, i) }
	start_round(d)
	if d.result != .Running { end_round(d); return true } // the monsters that won initiative killed the PC
	for i in 0 ..< d.mob_count { // swap with a neutral monster
		if d.mobs[i].c.alive && d.mobs[i].state == .Neutral && d.mobs[i].pos == to { d.mobs[i].pos = d.pos }
	}
	d.pos = to
	pc_enter(d)
	spend(d, true)
	return true
}

// Attack monster i: needs the round's action. Melee when adjacent; a ranged weapon with Ammo shoots in sight.
pc_attack :: proc(d: ^Delve, i: int) -> bool {
	if d.result != .Running || i < 0 || i >= d.mob_count { return false }
	if d.rd.active && d.rd.action_left <= 0 { return false }
	ok, shot := attackable(d, i)
	if !ok { return false }
	start_round(d)
	if d.result != .Running { end_round(d); return true }
	if d.mobs[i].c.alive { pc_attack_mob(d, i, shot) }
	spend(d, false)
	return true
}

pc_do_pickup :: proc(d: ^Delve) -> bool {
	if d.result != .Running || (d.rd.active && d.rd.action_left <= 0) { return false }
	has := false
	for i in 0 ..< d.loot_count { if !d.loot[i].taken && d.loot[i].pos == d.pos && R.can_carry(d.pc, d.loot[i].item) { has = true } }
	if !has { return false }
	start_round(d)
	if d.result != .Running { end_round(d); return true }
	pick_up(d)
	spend(d, false)
	return true
}

pc_do_drop :: proc(d: ^Delve, idx: int) -> bool {
	if d.result != .Running || idx < 0 || idx >= d.pc.inv_count || (d.rd.active && d.rd.action_left <= 0) { return false }
	start_round(d)
	if d.result != .Running { end_round(d); return true }
	drop_item(d, idx)
	spend(d, false)
	return true
}

// Search for hidden traps near the PC: the round's action, and a Turn passes.
pc_search :: proc(d: ^Delve) -> bool {
	if d.result != .Running || (d.rd.active && d.rd.action_left <= 0) { return false }
	start_round(d)
	if d.result != .Running { end_round(d); return true }
	search_here(d)
	spend(d, false)
	return true
}

// Disarm the revealed trap next to the PC: the round's action. False (nothing spent) if there is none.
pc_disarm :: proc(d: ^Delve) -> bool {
	if d.result != .Running || (d.rd.active && d.rd.action_left <= 0) || adjacent_known_trap(d) < 0 { return false }
	start_round(d)
	if d.result != .Running { end_round(d); return true }
	disarm_here(d)
	spend(d, false)
	return true
}

// Wait: spends whatever is left of the round. Out of a fight it still takes a moment (a tile's worth
// of the Turn clock), so waiting for torchlight or a wanderer is not free.
pc_wait :: proc(d: ^Delve) {
	if d.result != .Running { return }
	start_round(d)
	free_time := !d.rd.had_hunters
	d.rd.move_left, d.rd.action_left = 0, 0
	end_round(d)
	if free_time && d.result == .Running {
		d.tiles_moved += 1
		for d.tiles_moved >= (d.turns + 1) * TILES_PER_TURN && d.result == .Running { new_turn(d) }
	}
}
