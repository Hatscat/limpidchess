extends SceneTree

## Dev-only: render the post-game review on a BLUNDER ply, so both line buttons + both arrows show.
##   godot --path . -s res://scripts/dev/shot_review_line.gd   (needs a display) -> /tmp/limpid_review_line.png
## Scenario: player (Black) blundered ...Nf6?? into Scholar's mate (best was ...g6). The "Your line"
## button replays Nf6 Qxf7#; the "Best line" button replays the defence.

const Rules := preload("res://scripts/chess/chess_rules.gd")
const MOVES := ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6"]  # ends on Black's blunder ...Nf6

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
		# Rebuild the finished game from MOVES.
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
		# The blunder ply (index 5, ...Nf6): pre-position, best defence + the two lines.
		var pre := Rules.new()
		pre.reset_startpos()
		for i in range(5):
			pre.make_move(pre.move_from_uci(MOVES[i]))
		game._review[5] = {
			"quality": "blunder", "label": "Blunder", "cp_loss": 900,
			"best": pre.move_from_uci("g7g6"),
			"best_pv": PackedStringArray(["g7g6", "g1f3", "d7d6", "e1g1", "f8e7", "b1c3"]),
			"played_pv": PackedStringArray(["g8f6", "h5f7"]),  # ...Nf6 Qxf7#
			"deepened": true,
			"eval_cp": -900,
		}
		game._open_review(5)
		return false
	if frames == 48:
		vp.get_texture().get_image().save_png("/tmp/limpid_review_line.png")
		print("saved /tmp/limpid_review_line.png")
		return false
	if frames == 55:
		game._on_line_played()  # launch the player's own line (Nf6 Qxf7#)
		return false
	if frames == 64:
		print("PLAYED line: active=%s total=%d moves=%d (expect 2: Nf6 Qxf7#)" % [
			game._line_active, game._line_total, game._line_moves_arr.size()])
		vp.get_texture().get_image().save_png("/tmp/limpid_review_playing.png")
		game._exit_line()
		game._show_review_ply(5, false)
		print("PLAYER ply5 (Nf6, Black=player): Your-line-visible=%s (expect true)" % game.review_line_played.visible)
		game._on_line_best()
		print("BEST line: active=%s total=%d moves=%d (expect 6)" % [
			game._line_active, game._line_total, game._line_moves_arr.size()])
		game._exit_line()
		# A BOT ply (Qh5, ply 4, White; player is Black), a WRONG move: its played button must now show too
		# (the player can explore the bot's mistake), and playing it is labelled "This move", not "Your move".
		var pre4 := Rules.new()
		pre4.reset_startpos()
		for i in range(4):
			pre4.make_move(pre4.move_from_uci(MOVES[i]))
		game._review[4] = {
			"quality": "decent", "label": "Inaccuracy", "cp_loss": 50,
			"best": pre4.move_from_uci("d2d4"),
			"best_pv": PackedStringArray(["d2d4", "d7d6", "c1e3"]),
			"played_pv": PackedStringArray(["d1h5", "g8f6"]),
			"deepened": true, "eval_cp": 50,
		}
		game._show_review_ply(4, false)  # arrows view of the bot's wrong move (render it next frame)
		print("BOT ply4 (Qh5, White!=player, wrong): Played-visible=%s (expect true)  Best-disabled=%s (expect false)" % [
			game.review_line_played.visible, game.review_line_best.disabled])
		return false
	if frames == 72:
		vp.get_texture().get_image().save_png("/tmp/limpid_review_bot.png")
		print("saved /tmp/limpid_review_bot.png")
		game._on_line_played()  # explore the BOT's own wrong move
		print("BOT played line: active=%s is_player_move=%s (expect active=true, is_player_move=false)" % [
			game._line_active, game._line_is_player_move])
		game._exit_line()
		quit()
	return false
