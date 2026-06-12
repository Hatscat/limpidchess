class_name BotRoster
extends RefCounted

## The cast of AI opponents. Each entry both describes the bot to the player
## (name, avatar, tagline, friendly rating) and configures [ChessBot] (search
## `depth` and `weakness`). The roster skews EASY on purpose — this is a game
## for beginners, so even the top bot only looks a few moves ahead.
##
## ChessBot params:
##   depth    — search depth in plies (how far ahead it calculates)
##   weakness — 0.0 (always plays its best) … 1.0 (often drifts to weaker moves);
##              this is what makes the easy bots feel human and beatable.

const AVATAR_DIR := "res://assets/avatars/"

const ALL := [
	{
		"id": "pip", "name": "Pip", "avatar": "chick.png",
		"tagline": "Just learned how the pieces move.",
		"elo": 250, "tier": "Beginner",
		"depth": 1, "weakness": 0.85,
	},
	{
		"id": "biscuit", "name": "Biscuit", "avatar": "dog.png",
		"tagline": "Plays for the fun of it.",
		"elo": 500, "tier": "Beginner",
		"depth": 2, "weakness": 0.65,
	},
	{
		"id": "whiskers", "name": "Whiskers", "avatar": "cat.png",
		"tagline": "Curious, cautious, occasionally pounces.",
		"elo": 750, "tier": "Casual",
		"depth": 2, "weakness": 0.40,
	},
	{
		"id": "hops", "name": "Hops", "avatar": "frog.png",
		"tagline": "Leaps at every capture.",
		"elo": 1000, "tier": "Casual",
		"depth": 3, "weakness": 0.25,
	},
	{
		"id": "reynard", "name": "Reynard", "avatar": "fox.png",
		"tagline": "Sly. Sets little traps.",
		"elo": 1300, "tier": "Improver",
		"depth": 3, "weakness": 0.12,
	},
	{
		"id": "professor", "name": "Professor", "avatar": "owl.png",
		"tagline": "Sees a few moves ahead. Patient.",
		"elo": 1600, "tier": "Club",
		"depth": 4, "weakness": 0.04,
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
