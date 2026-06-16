class_name BotRoster
extends RefCounted

## The cast of AI opponents. Each entry both describes the bot to the player
## (name, avatar, tagline, friendly rating) and configures [ChessBot] (search
## `depth` and `weakness`). The roster skews EASY on purpose — this is a game
## for beginners, so even the top bot only looks a few moves ahead.
##
## Stockfish params (primary engine):
##   sf_skill — Stockfish "Skill Level" 0 (very weak, blunders often) … 20 (full).
##   movetime — milliseconds the bot is allowed to think per move.
## Fallback params (built-in GDScript engine, used only if Stockfish is absent):
##   depth    — search depth in plies.
##   weakness — 0.0 (always best) … 1.0 (often drifts to weaker moves).

const AVATAR_DIR := "res://assets/avatars/"

const ALL := [
	{
		"id": "coco", "name": "Coco", "avatar": "monkey.png",
		"tagline": "Gives lots of gifts.",
		"difficulty": 1, "tier": "First moves",
		"sf_skill": 0, "movetime": 40, "random_chance": 0.85,
		"depth": 1, "weakness": 0.95,
	},
	{
		"id": "pebble", "name": "Pebble", "avatar": "pig.png",
		"tagline": "Still learning the ropes.",
		"difficulty": 1, "tier": "Newcomer",
		"sf_skill": 0, "movetime": 80, "random_chance": 0.5,
		"depth": 1, "weakness": 0.9,
	},
	{
		"id": "pip", "name": "Pip", "avatar": "chick.png",
		"tagline": "Just learned how the pieces move.",
		"difficulty": 2, "tier": "Beginner",
		"sf_skill": 0, "movetime": 60,
		"depth": 1, "weakness": 0.85,
	},
	{
		"id": "biscuit", "name": "Biscuit", "avatar": "dog.png",
		"tagline": "Plays for the fun of it.",
		"difficulty": 2, "tier": "Beginner",
		"sf_skill": 2, "movetime": 100,
		"depth": 2, "weakness": 0.65,
	},
	{
		"id": "leon", "name": "Léon", "avatar": "sheep.png",
		"tagline": "Gentle. Tends to daydream.",
		"difficulty": 2, "tier": "Beginner",
		"sf_skill": 3, "movetime": 130,
		"depth": 2, "weakness": 0.52,
	},
	{
		"id": "whiskers", "name": "Whiskers", "avatar": "cat.png",
		"tagline": "Curious, cautious, occasionally pounces.",
		"difficulty": 3, "tier": "Casual",
		"sf_skill": 4, "movetime": 150,
		"depth": 2, "weakness": 0.40,
	},
	{
		"id": "hops", "name": "Hops", "avatar": "frog.png",
		"tagline": "Leaps at every capture.",
		"difficulty": 3, "tier": "Casual",
		"sf_skill": 7, "movetime": 200,
		"depth": 3, "weakness": 0.25,
	},
	{
		"id": "reynard", "name": "Reynard", "avatar": "fox.png",
		"tagline": "Sly. Sets little traps.",
		"difficulty": 4, "tier": "Improver",
		"sf_skill": 11, "movetime": 300,
		"depth": 3, "weakness": 0.12, "premium": true
	},
	{
		"id": "rusty", "name": "Rusty", "avatar": "orangutan.png",
		"tagline": "Smarter than he looks.",
		"difficulty": 4, "tier": "Improver",
		"sf_skill": 13, "movetime": 375,
		"depth": 3, "weakness": 0.08, "premium": true,
	},
	{
		"id": "professor", "name": "Professor", "avatar": "owl.png",
		"tagline": "Sees a few moves ahead. Patient.",
		"difficulty": 4, "tier": "Club",
		"sf_skill": 15, "movetime": 450,
		"depth": 4, "weakness": 0.04, "premium": true,
	},
	{
		"id": "bruno", "name": "Bruno", "avatar": "bear.png",
		"tagline": "Solid. Punishes loose play.",
		"difficulty": 5, "tier": "Strong",
		"sf_skill": 17, "movetime": 600,
		"depth": 4, "weakness": 0.0, "premium": true,
	},
	{
		"id": "iceberg", "name": "Iceberg", "avatar": "penguin.png",
		"tagline": "Cool, precise, patient.",
		"difficulty": 5, "tier": "Expert",
		"sf_skill": 18, "movetime": 800,
		"depth": 4, "weakness": 0.0, "premium": true,
	},
	{
		"id": "aria", "name": "Aria", "avatar": "tiger.png",
		"tagline": "Bold, sharp attacks.",
		"difficulty": 6, "tier": "Master",
		"sf_skill": 19, "movetime": 1100,
		"depth": 4, "weakness": 0.0, "premium": true,
	},
	{
		"id": "maximus", "name": "Maximus", "avatar": "robot.png",
		"tagline": "Calculates without mercy.",
		"difficulty": 6, "tier": "Grandmaster",
		"sf_skill": 20, "movetime": 1500,
		"depth": 4, "weakness": 0.0, "premium": true,
	},
]


static func avatar_path(bot: Dictionary) -> String:
	return AVATAR_DIR + str(bot.get("avatar", "robot.png"))


## The strongest bots are a premium perk.
static func is_premium_bot(bot: Dictionary) -> bool:
	return bool(bot.get("premium", false))


static func get_by_id(id: String) -> Dictionary:
	for bot in ALL:
		if bot["id"] == id:
			return bot
	return ALL[0]


static func default() -> Dictionary:
	return get_by_id("pip")  # a gentle starting opponent (id-based, order-independent)
