class_name Quotes
extends RefCounted

## Chess aphorisms shown on the home screen and on game-over feedback.
## They carry the game's whole philosophy: errors are the heart of chess, and
## seeing the move is the skill we're training. Mostly Savielly Tartakower.

const ALL := [
	{"text": "The winner of the game is the player who makes the next-to-last mistake.", "author": "Savielly Tartakower"},
	{"text": "Chess is a fairy tale of 1001 blunders.", "author": "Savielly Tartakower"},
	{"text": "The blunders are all there on the board, waiting to be made.", "author": "Savielly Tartakower"},
	{"text": "It is always better to sacrifice your opponent's men.", "author": "Savielly Tartakower"},
	{"text": "No one ever won a game by resigning.", "author": "Savielly Tartakower"},
	{"text": "The mistakes are there, waiting to be made.", "author": "Savielly Tartakower"},
	{"text": "Chess is a struggle against one's own errors.", "author": "Johannes Zukertort"},
	{"text": "The move is there, but you must see it.", "author": "Savielly Tartakower"},
	{"text": "When you see a good move, look for a better one.", "author": "Emanuel Lasker"},
	{"text": "Help your pieces so they can help you.", "author": "Paul Morphy"},
]


## A random quote. Pass a different seed each call site if you want variety.
static func random() -> Dictionary:
	return ALL[randi() % ALL.size()]


## A quote chosen to fit a game outcome, for the end-of-game card.
## outcome: "win" | "loss" | "draw" | "resign".
static func for_outcome(outcome: String) -> Dictionary:
	match outcome:
		"win":
			return {"text": "The winner of the game is the player who makes the next-to-last mistake.", "author": "Savielly Tartakower"}
		"loss":
			return {"text": "Chess is a struggle against one's own errors.", "author": "Johannes Zukertort"}
		"resign":
			return {"text": "No one ever won a game by resigning.", "author": "Savielly Tartakower"}
		_:
			return {"text": "The move is there, but you must see it.", "author": "Savielly Tartakower"}
