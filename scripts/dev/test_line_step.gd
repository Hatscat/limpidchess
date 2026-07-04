extends SceneTree

## Dev-only headless check: the best-replies step buttons move exactly one move per tap, pause playback,
## snap to a boundary from mid-slide, and clamp at the ends.
##   godot --headless --path . -s res://scripts/dev/test_line_step.gd

const Rules := preload("res://scripts/chess/chess_rules.gd")
const MOVES := ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6"]

var game
var frames := 0
var ok := true


func _eq(label: String, got: float, want: float) -> void:
	if absf(got - want) > 0.0001:
		ok = false
		print("  FAIL %s: got %s, want %s" % [label, got, want])
	else:
		print("  ok   %s = %s" % [label, got])


func _initialize() -> void:
	var gm: Node = root.get_node("GameManager")
	gm.is_premium = true
	gm.player_is_white = false
	gm.pass_and_play = false
	gm.current_bot = BotRoster.get_by_id("reynard")
	game = load("res://scenes/game.tscn").instantiate()
	root.add_child(game)


func _process(_d: float) -> bool:
	frames += 1
	if frames == 40:
		game._gen += 1
		game._busy = false
		game._game_over = true
		game.player_color = Rules.BLACK
		game.rules.reset_startpos()
		game._undo_stack.clear(); game._review.clear(); game._history.clear()
		for uci in MOVES:
			var m: int = game.rules.move_from_uci(uci)
			var mv: int = game.rules.side_to_move
			var undo: Dictionary = game.rules.make_move(m)
			game._undo_stack.append({"move": m, "undo": undo, "captured": 0, "mover": mv})
			game._review.append({})
		var pre := Rules.new()
		pre.reset_startpos()
		for i in range(5):
			pre.make_move(pre.move_from_uci(MOVES[i]))
		game._review[5] = {
			"quality": "blunder", "label": "Blunder", "cp_loss": 880,
			"best": pre.move_from_uci("g7g6"),
			"best_pv": PackedStringArray(["g7g6", "g1f3", "d7d6", "e1g1", "f8e7", "b1c3"]),
			"eval_cp": 60,
		}
		game._review_ply = 5
		return false
	if frames == 48:
		game._on_line_best()   # 6-move best line -> _line_total == 6, auto-play at pos 0
		_eq("total moves", game._line_total, 6.0)

		# Step forward advances by exactly one move and pauses.
		game._on_line_step_forward()
		_eq("after 1 step fwd: pos", game._line_pos, 1.0)
		_eq("stepping pauses (rate)", game._line_rate, 0.0)
		game._on_line_step_forward()
		game._on_line_step_forward()
		_eq("after 3 steps fwd: pos", game._line_pos, 3.0)

		# Step back retreats by one.
		game._on_line_step_back()
		_eq("after 1 step back: pos", game._line_pos, 2.0)

		# From a mid-slide position, snap to the boundary in the step direction.
		game._line_pos = 2.5
		game._on_line_step_forward()
		_eq("mid-slide 2.5 fwd -> 3", game._line_pos, 3.0)
		game._line_pos = 2.5
		game._on_line_step_back()
		_eq("mid-slide 2.5 back -> 2", game._line_pos, 2.0)

		# Clamp at the far end.
		for _i in range(10):
			game._on_line_step_forward()
		_eq("clamp forward at total", game._line_pos, 6.0)
		# Clamp at the start.
		for _i in range(10):
			game._on_line_step_back()
		_eq("clamp back at 0", game._line_pos, 0.0)

		print("LINE STEP TEST: ", "PASS" if ok else "FAIL")
		quit(0 if ok else 1)
	return false
