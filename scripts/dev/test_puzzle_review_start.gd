extends SceneTree

## Dev-only headless check: the failed-puzzle review must open ON the player's wrong move (the last ply),
## not at the start of the line.  godot --headless --path . -s res://scripts/dev/test_puzzle_review_start.gd
## A 3-ply line so the new behaviour (open on the LAST ply, index 2) differs from the old one (index 1).

var game
var frames := 0


func _initialize() -> void:
	var gm: Node = root.get_node("GameManager")
	gm.puzzle_review = {
		"fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
		"moves": PackedStringArray(["e2e4", "e7e5", "g1f3"]),  # 3 legal plies; last stands in for the wrong move
		"player_white": true,
	}
	game = load("res://scenes/game.tscn").instantiate()
	root.add_child(game)


func _process(_d: float) -> bool:
	frames += 1
	if frames < 4:
		return false  # let _ready -> _enter_puzzle_review run
	var plies: int = game._undo_stack.size()
	var ply: int = game._review_ply
	var ok: bool = ply == plies - 1
	print("puzzle review: plies=%d review_ply=%d (expect last = %d) -> %s" % [
		plies, ply, plies - 1, "PASS" if ok else "FAIL"])
	quit(0 if ok else 1)
	return true
