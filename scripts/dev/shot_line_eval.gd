extends SceneTree

## Dev-only: show the eval bar during best-replies playback. Same Scholar's-mate blunder as the other
## review shots. Renders: (a) the PLAYED line at its end -> bar reads "M" (Black walked into mate);
## (b) the BEST line at its end -> bar stays at the position eval (best play holds it).
##   DISPLAY=:0 godot --path . -s res://scripts/dev/shot_line_eval.gd
## -> /tmp/limpid_line_eval_played.png  +  /tmp/limpid_line_eval_best.png

const Rules := preload("res://scripts/chess/chess_rules.gd")
const MOVES := ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6"]

var vp: SubViewport
var game
var frames := 0


func _initialize() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(1560, 2778)
	vp.size_2d_override = Vector2i(720, 1280)
	vp.size_2d_override_stretch = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)


func _freeze_line_at(pos: float) -> void:
	game._line_rate = 0.0  # stop auto-play so we can park at a chosen frame
	game._line_pos = pos
	game._render_line_frame()


func _process(_d: float) -> bool:
	frames += 1
	if frames == 1:
		var gm: Node = root.get_node("GameManager")
		gm.is_premium = true
		gm.player_is_white = false
		gm.pass_and_play = false
		gm.pending_review_check = false
		gm.current_bot = BotRoster.get_by_id("reynard")
		game = load("res://scenes/game.tscn").instantiate()
		vp.add_child(game)
		return false
	if frames == 40:
		game._gen += 1
		game._busy = false
		game._game_over = true
		game.player_color = Rules.BLACK
		game.board.flipped = true
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
			"played_pv": PackedStringArray(["g8f6", "h5f7"]),
			"eval_cp": 80,             # White a touch better with best defence (...g6)
			"played_eval_cp": 100000,  # ...Nf6 is mate for White
		}
		game._open_review(5)
		return false
	if frames == 48:
		game._on_line_played()      # play the player's own (losing) line
		_freeze_line_at(2.0)        # park at the end: after ...Nf6 Qxf7#
		return false
	if frames == 56:                # let the parked frame actually render before capturing
		vp.get_texture().get_image().save_png("/tmp/limpid_line_eval_played.png")
		print("PLAYED line end: eval bar white_cp=%d (expect mate, |v|>=50000)" % game.eval_bar._white_cp)
		game._exit_line()
		game._show_review_ply(5, false)
		game._on_line_best()        # play the best line
		_freeze_line_at(6.0)        # park at the end of the 6-ply best line
		return false
	if frames == 64:
		vp.get_texture().get_image().save_png("/tmp/limpid_line_eval_best.png")
		print("BEST line end: eval bar white_cp=%d (expect flat = 80)" % game.eval_bar._white_cp)
		quit()
	return false
