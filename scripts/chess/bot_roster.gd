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
		"id": "pip", "name": "Pip", "avatar": "chick.png",
		"tagline": "Just learned how the pieces move.",
		"elo": 250, "tier": "Beginner",
		"sf_skill": 0, "movetime": 60,
		"depth": 1, "weakness": 0.85,
	},
	{
		"id": "biscuit", "name": "Biscuit", "avatar": "dog.png",
		"tagline": "Plays for the fun of it.",
		"elo": 500, "tier": "Beginner",
		"sf_skill": 2, "movetime": 100,
		"depth": 2, "weakness": 0.65,
	},
	{
		"id": "whiskers", "name": "Whiskers", "avatar": "cat.png",
		"tagline": "Curious, cautious, occasionally pounces.",
		"elo": 750, "tier": "Casual",
		"sf_skill": 4, "movetime": 150,
		"depth": 2, "weakness": 0.40,
	},
	{
		"id": "hops", "name": "Hops", "avatar": "frog.png",
		"tagline": "Leaps at every capture.",
		"elo": 1000, "tier": "Casual",
		"sf_skill": 7, "movetime": 200,
		"depth": 3, "weakness": 0.25,
	},
	{
		"id": "reynard", "name": "Reynard", "avatar": "fox.png",
		"tagline": "Sly. Sets little traps.",
		"elo": 1300, "tier": "Improver",
		"sf_skill": 11, "movetime": 300,
		"depth": 3, "weakness": 0.12,
	},
	{
		"id": "professor", "name": "Professor", "avatar": "owl.png",
		"tagline": "Sees a few moves ahead. Patient.",
		"elo": 1600, "tier": "Club",
		"sf_skill": 15, "movetime": 450,
		"depth": 4, "weakness": 0.04,
	},
	{
		"id": "bruno", "name": "Bruno", "avatar": "bear.png",
		"tagline": "Solid. Punishes loose play.",
		"elo": 1900, "tier": "Strong",
		"sf_skill": 17, "movetime": 600,
		"depth": 4, "weakness": 0.0,
	},
	{
		"id": "iceberg", "name": "Iceberg", "avatar": "penguin.png",
		"tagline": "Cool, precise, patient.",
		"elo": 2150, "tier": "Expert",
		"sf_skill": 18, "movetime": 800,
		"depth": 4, "weakness": 0.0,
	},
	{
		"id": "aria", "name": "Aria", "avatar": "lion.png",
		"tagline": "Bold, sharp attacks.",
		"elo": 2450, "tier": "Master",
		"sf_skill": 19, "movetime": 1100,
		"depth": 4, "weakness": 0.0,
	},
	{
		"id": "maximus", "name": "Maximus", "avatar": "robot.png",
		"tagline": "Calculates without mercy.",
		"elo": 2800, "tier": "Grandmaster",
		"sf_skill": 20, "movetime": 1500,
		"depth": 4, "weakness": 0.0,
	},
]


static func avatar_path(bot: Dictionary) -> String:
	return AVATAR_DIR + str(bot.get("avatar", "robot.png"))


static func get_by_id(id: String) -> Dictionary:
	for bot in ALL:
		if bot["id"] == id:
			return bot
	return ALL[0]


static func default() -> Dictionary:
	return ALL[1]  # Biscuit — a gentle starting opponent
