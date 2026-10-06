package rules

// Every DURF number lives here, so a rules edition change (2.2 -> 2.4) is a data edit.
// Source: DURF v2.2 (2021) by Emiel Boven, CC-BY 4.0. https://emielboven.itch.io/durf

RULES_VERSION :: "2.2"

DC             :: 15 // an action roll succeeds on a total over this
ATTR_MAX       :: 8
BASE_SLOTS     :: 10 // inventory slots = this + STR
CRIT_ROLL      :: 20 // natural roll that doubles damage
WORN_ROLL      :: 1 // natural roll that wears a PC's weapon
HD_START       :: 1
HD_MAX         :: 12
XP_PER_HD_COST :: 1000 // next HD costs this times the current HD
XP_PER_NPC_HD  :: 25
XP_PER_ZERO_HD :: 0 // the literal 25 x HD rule pays nothing for a 0 HD NPC (decided Oct 5)
SUPPLY_COST    :: 5
STARTING_SUPPLY :: 2
WORN_DAMAGE    :: 1
SHIELD_REDUCTION :: 1

Attr :: enum { STR, DEX, WIL }

Weapon_Kind :: enum { Unarmed, Blowpipe, Dagger, Sword, Greatsword, Bow, Crossbow, Pistol }

Weapon :: struct {
	name:      string,
	dmg:       int,
	slots:     int, // total slots to carry
	hands:     int,
	price:     int,
	ranged:    bool,
	uses_ammo: bool, // needs an Ammo item (the blowpipe, sling and dart do not)
}

WEAPONS := [Weapon_Kind]Weapon{
	.Unarmed    = {"Fists", 2, 0, 1, 0, false, false},
	.Blowpipe   = {"Blowpipe", 2, 1, 1, 2, true, false},
	.Dagger     = {"Dagger", 3, 1, 1, 4, false, false},
	.Sword      = {"Sword", 4, 2, 1, 10, false, false},
	.Greatsword = {"Greatsword", 5, 3, 2, 15, false, false},
	.Bow        = {"Bow", 3, 2, 2, 35, true, true},
	.Crossbow   = {"Crossbow", 4, 3, 2, 30, true, true},
	.Pistol     = {"Pistol", 5, 2, 1, 100, true, true},
}

Armor_Kind :: enum { None, Light, Medium, Heavy }

Armor :: struct {
	name:  string,
	armor: int,
	slots: int,
	price: int,
}

ARMORS := [Armor_Kind]Armor{
	.None   = {"No armor", 0, 0, 0},
	.Light  = {"Light armor", 3, 1, 20},
	.Medium = {"Medium armor", 5, 2, 50},
	.Heavy  = {"Heavy armor", 7, 3, 200},
}
SHIELD_PRICE :: 10
SHIELD_SLOTS :: 1
AMMO_PRICE :: 5
AMMO_SLOTS :: 1
AMMO_LOW_ROLL :: 1 // a d6 after a fight in which the PC shot: on this, one shot is left

Ability :: enum {
	Spores,       // when hit in melee, the attacker makes a STR save or takes 1 direct Wound
	Drain_STR,    // a hit also lowers STR by 1 until a day's rest; STR below 0 kills
	Stun_Call,    // once per fight, target makes a STR save or is paralyzed for 1d4 rounds
	Extra_Action, // acts twice each round
	Reload,       // a pistol: every other action is spent reloading
	Slippery,     // (not modelled yet)
	Undead,       // (not modelled yet)
}

Monster_Def :: struct {
	name:      string,
	skill:     int,
	hd:        int,
	armor:     int,
	ml:        int, // morale; -1 means it never flees
	dmg:       int,
	ranged:    bool,
	abilities: bit_set[Ability],
	house:     bool, // our own conversion, not a monster from the DURF book
}

Monster :: enum { Goose, Dog, Echo_Gecko, Myconid, Eelfolk, Spellclaw, Shadow, Flesh_Orb, Dragon, Blowpipe_Imp, Crossbow_Cultist }

MONSTERS := [Monster]Monster_Def{
	.Goose      = {"Miniature goose", 1, 0, 0, 6, 1, false, {}, false},
	.Dog        = {"Dog", 2, 1, 0, 6, 3, false, {}, false},
	.Echo_Gecko = {"Echo Gecko", 2, 0, 0, 6, 2, false, {.Stun_Call}, false},
	.Myconid    = {"Myconid", 3, 1, 3, 7, 3, false, {.Spores}, false},
	.Eelfolk    = {"Eelfolk", 4, 1, 3, 7, 5, true, {.Slippery, .Reload}, false},
	.Spellclaw  = {"Spellclaw", 4, 2, 5, 7, 3, false, {}, false},
	.Shadow     = {"Shadow", 3, 2, 0, -1, 3, false, {.Drain_STR, .Undead}, false},
	.Flesh_Orb  = {"Flesh Orb of Zuld", 6, 5, 3, 9, 4, false, {}, false},
	.Dragon     = {"Dragon", 12, 8, 10, 10, 12, false, {.Extra_Action}, false},
	// House conversions (the book's "Converting OSR monsters" recipe), to give depth 2 and 3 more ranged threats.
	.Blowpipe_Imp     = {"Blowpipe Imp", 2, 0, 0, 6, 2, true, {}, true}, // a blowpipe: 2 dmg, no reload
	.Crossbow_Cultist = {"Crossbow Cultist", 3, 1, 3, 7, 4, true, {}, true}, // a crossbow: 4 dmg, no reload
}

Reaction :: enum { Hostile, Unfriendly, Indifferent, Friendly, Helpful }

// 2d6 reaction bands: 2-3, 4-5, 6-8, 9-10, 11-12.
reaction_for_total :: proc(total: int) -> Reaction {
	switch {
	case total <= 3:  return .Hostile
	case total <= 5:  return .Unfriendly
	case total <= 8:  return .Indifferent
	case total <= 10: return .Friendly
	}
	return .Helpful
}

// The d40 belongings table, entries 10 to 49 (a d4 for the tens, a d10 for the ones).
BELONGINGS := [40]string{
	"Light armor", "Pipe and smokeleaf", "Bow + Ammo", "Scroll of a spell",
	"You know a spell", "Blowpipe", "Hat of the Eye", "Dream flute",
	"Warhammer", "Medium armor", "Wooden staff", "Dried chicken feet",
	"Sword", "Dog", "Make-up set", "Bag of human teeth",
	"Pistol + Ammo", "Vial of poison", "Glass eye", "Miniature goose",
	"Silver axe", "Bottle of bees", "Dramatic cape", "Lyre",
	"Pot of fluorescent paint", "Bomb", "Spiked shield", "Spyglass",
	"Crossbow + Ammo", "Heavy armor", "Tonic of Health", "Outer Planes guide",
	"Piece of a treasure map", "Cult leader's diary", "Halberd", "Flail",
	"Serpent Scale Cloak", "Self-growing soap", "Bottle of perfume", "Rings that share sight",
}
