extends SceneTree

## Dev-only: render the end-of-game result dialog (a won bot game) at design scale for the listing.
##   godot --path . -s res://scripts/dev/shot_review.gd  (needs a display) -> /tmp/limpid_review.png

const Rules := preload("res://scripts/chess/chess_rules.gd")
const MATE_FEN := "r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4"  # after Qxf7#

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
		gm.is_premium = true                # no daily-limit popup over the dialog
		gm.player_is_white = true
		gm.pass_and_play = false
		gm.pending_review_check = false
		gm.current_bot = BotRoster.get_by_id("reynard")
		game = load("res://scenes/game.tscn").instantiate()
		vp.add_child(game)
		return false
	if frames == 40:
		game._gen += 1
		game._busy = false
		game.player_color = Rules.WHITE
		game.board.flipped = false
		game.rules.set_fen(MATE_FEN)
		game.board.set_rules(game.rules)
		game._update_check_highlight()      # light up the mated king
		game._best[0] = 6;    game._best[1] = 0
		game._decent[0] = 3;  game._decent[1] = 0
		game._blunder[0] = 1; game._blunder[1] = 0
		game._game_over = true
		game.feedback.text = ""
		game.eval_bar.set_eval(2000)        # White is winning (mate)
		game._show_result("You win!", "Checkmate. Well played.", "win")
		return false
	if frames == 58:
		vp.get_texture().get_image().save_png("/tmp/limpid_review.png")
		print("saved /tmp/limpid_review.png")
		quit()
	return false
