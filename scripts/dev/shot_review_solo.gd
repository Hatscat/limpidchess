extends SceneTree

## Dev-only: render a review ply where the player PLAYED THE BEST MOVE. Then only one best-replies button
## shows, so it carries the magnifier + "Best replies" text (not just the ✓).
##   DISPLAY=:0 godot --path . -s res://scripts/dev/shot_review_solo.gd -> /tmp/limpid_review_solo.png

const Rules := preload("res://scripts/chess/chess_rules.gd")
const MOVES := ["e2e4", "e7e5", "g1f3", "b8c6"]  # ends on Black's ...Nc6, which we mark as the best move

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
			game._history.append(game.rules.position_key())
		# Ply 3 (...Nc6): the player's move IS the best, so no played button -> the best button stands alone.
		var pre := Rules.new()
		pre.reset_startpos()
		for i in range(3):
			pre.make_move(pre.move_from_uci(MOVES[i]))
		game._review[3] = {
			"quality": "best", "label": "Best", "cp_loss": 0,
			"best": pre.move_from_uci("b8c6"),
			"best_pv": PackedStringArray(["b8c6", "f1b5", "g8f6", "e1g1"]),
			"deepened": true, "eval_cp": 20,
		}
		game._open_review(3)
		return false
	if frames == 48:
		vp.get_texture().get_image().save_png("/tmp/limpid_review_solo.png")
		print("saved /tmp/limpid_review_solo.png")
		print("SOLO ply3 (Nc6==best): played-visible=%s (expect false)  best-label-visible=%s (expect true)  best-mark-visible=%s (expect false)" % [
			game.review_line_played.visible, game._best_label.visible, game._best_mark.visible])
		quit()
	return false
