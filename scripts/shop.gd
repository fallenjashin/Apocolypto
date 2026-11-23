class_name Shop
extends RefCounted
## The military store: what the bank buys. Upgrades are crew-wide (one shared bank)
## and last the whole run. Floodlights are the exception: a daily purchase that
## buys extra time on the clock.
##
## Prices and strengths are a first guess. Tune them after playtests.

const ORDER := ["battery", "coils", "harness", "boots", "daylight"]

## costs[level] is the price of the NEXT level, so costs.size() is the max level.
const ITEMS := {
	"battery": {"title": "Prod Battery", "desc": "+2 prod charges", "costs": [120, 220, 350]},
	"coils": {"title": "Stun Coils", "desc": "Stuns last 30% longer", "costs": [150, 250, 400]},
	"harness": {"title": "Carry Harness", "desc": "Heavy loads slow you down much less", "costs": [180, 320]},
	"boots": {"title": "Sprint Boots", "desc": "Sprint 12% faster", "costs": [100, 200]},
	"daylight": {"title": "Floodlights", "desc": "+45 seconds on today's clock (twice a day, while the clock runs)", "costs": [120, 120]},
}
const DAYLIGHT_SECONDS := 45.0


static func max_level(id: String) -> int:
	return ITEMS[id].costs.size()


## Price of the next level when you already own `level`.
static func cost(id: String, level: int) -> int:
	return ITEMS[id].costs[level]


# --- Effects. Each takes the crew's upgrade levels: {"battery": 1, ...} ------

static func level_of(levels: Dictionary, id: String) -> int:
	return int(levels.get(id, 0))


static func max_charges(levels: Dictionary) -> int:
	return Player.MAX_CHARGES + 2 * level_of(levels, "battery")


static func stun_mult(levels: Dictionary) -> float:
	return 1.0 + 0.3 * level_of(levels, "coils")


## Divides the weight of what you carry: bigger means a lighter load.
static func carry_strength(levels: Dictionary) -> float:
	return 1.0 + 0.6 * level_of(levels, "harness")


static func sprint_mult(levels: Dictionary) -> float:
	return 1.0 + 0.12 * level_of(levels, "boots")
