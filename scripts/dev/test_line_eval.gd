extends SceneTree

## Dev-only headless check: the eval bar tracks the best-replies line in real time.
##   godot --headless --path . -s res://scripts/dev/test_line_eval.gd
## Scenario: Black blundered ...Nf6?? into Scholar's mate. The played line's eval must DROP for Black
## (rise for White) after the mistake; the best line's eval stays flat; signs correct for a Black mover.

const Rules := preload("res://scripts/chess/chess_rules.gd")
const MOVES := ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6"]

var game
var frames := 0
var ok := true


func _eq(label: String, got: int, want: int) -> void:
	if got != want:
		ok = false
		print("  FAIL %s: got %d, want %d" % [label, got, want])
	else:
		print("  ok   %s = %d" % [label, got])


func _initialize() -> void:
	var gm: Node = root.get_node("GameManager")
	gm.is_premium = true
	gm.player_is_white = false
	gm.pass_and_play = false
	gm.pending_review_check = false
	gm.current_bot = BotRoster.get_by_id("reynard")
	game = load("res://scenes/game.tscn").instantiate()
	root.add_child(game)


func _setup_ply() -> void:
	game._gen += 1
	game._busy = false
	game._game_over = true
	game.player_color = Rules.BLACK
	game.rules.reset_startpos()
	game._undo_stack.clear()
	game._review.clear()
	game._history.clear()
	for uci in MOVES:
		var m: int = game.rules.move_from_uci(uci)
		var mover: int = game.rules.side_to_move
		var undo: Dictionary = game.rules.make_move(m)
		game._undo_stack.append({"move": m, "undo": undo, "captured": int(undo.get("captured_piece", 0)), "mover": mover})
		game._review.append({})
	var pre := Rules.new()
	pre.reset_startpos()
	for i in range(5):
		pre.make_move(pre.move_from_uci(MOVES[i]))
	game._review[5] = {
		"quality": "blunder", "label": "Blunder", "cp_loss": 880,
		"best": pre.move_from_uci("g7g6"),
		"best_pv": PackedStringArray(["g7g6", "g1f3", "d7d6", "e1g1", "f8e7", "b1c3"]),
		"played_pv": PackedStringArray(["g8f6", "h5f7"]),  # ...Nf6 Qxf7#
		"eval_cp": -20,          # White-relative before the move: roughly level
		"played_eval_cp": 100000,  # after ...Nf6 it is mate for White
	}
	game._review_ply = 5


func _process(_d: float) -> bool:
	frames += 1
	if frames < 4:
		return false

	_setup_ply()

	# --- Played line (analysed post-eval present): eval drops from base to the played eval. ---
	game._play_line(false)
	var last: int = game._line_evals.size() - 1
	_eq("played base (state 0)", game._line_evals[0], -20)
	_eq("played post (last state)", game._line_evals[last], 100000)
	_eq("interp @0.0", game._line_eval_at(0.0), -20)
	_eq("interp @1.0", game._line_eval_at(1.0), 100000)
	_eq("mate segment snaps at 0.5 (not fake cp)", game._line_eval_at(0.5), 100000)
	_eq("mate segment shows base below 0.5", game._line_eval_at(0.4), -20)
	_eq("eval bar pushed at start", game.eval_bar._white_cp, -20)
	game._exit_line()

	# --- Best line: flat at the base eval (best play holds the evaluation). ---
	game._play_line(true)
	var bmin: int = game._line_evals[0]
	var bmax: int = game._line_evals[0]
	for v in game._line_evals:
		bmin = mini(bmin, v)
		bmax = maxi(bmax, v)
	_eq("best line flat (min)", bmin, -20)
	_eq("best line flat (max)", bmax, -20)
	game._exit_line()

	# --- Fallback (no analysed post-eval): derive from cp_loss with the Black-mover sign. ---
	# Black blundered 880cp: White-relative eval rises by 880 -> -20 + 880 = 860.
	game._review[5].erase("played_eval_cp")
	game._play_line(false)
	last = game._line_evals.size() - 1
	_eq("fallback post (Black mover, +cp_loss)", game._line_evals[last], 860)
	# Non-mate segment interpolates linearly (a smooth sweep, no snap): halfway between -20 and 860.
	_eq("non-mate linear interp @0.5", game._line_eval_at(0.5), int(round(lerpf(-20.0, 860.0, 0.5))))
	game._exit_line()

	print("LINE EVAL TEST: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
	return true
