extends SceneTree

## Dev-only: render the PRE-COMMIT hold state of a player capture (Bxc6), the moment the fix targets:
## the bishop is parked on c6 (slide landed) and the taken knight is hidden + shattering, instead of
## lingering under the bishop for the ~1s reveal hold.
##   DISPLAY=:0 godot --path . -s res://scripts/dev/shot_capture.gd
## -> /tmp/limpid_capture_early.png (burst t=0.18) + /tmp/limpid_capture_mid.png (t=0.42)

const Rules := preload("res://scripts/chess/chess_rules.gd")

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


## Park the capturing bishop's slider on c6 (as it is at slide-end, before commit).
func _park_bishop_on_c6() -> void:
	game.board._anim_from = 4 * 8 + 1   # b5
	game.board._anim_to = 5 * 8 + 2     # c6
	game.board._anim_piece = Rules.BISHOP  # white bishop
	game.board._anim_progress = 1.0
	game.board._anim_active = true


func _process(_d: float) -> bool:
	frames += 1
	if frames == 1:
		var gm: Node = root.get_node("GameManager")
		gm.is_premium = true
		gm.player_is_white = true
		gm.pass_and_play = false
		gm.current_bot = BotRoster.get_by_id("reynard")
		game = load("res://scenes/game.tscn").instantiate()
		vp.add_child(game)
		return false
	if frames == 20:
		game._gen += 1
		game._busy = false
		game._game_over = true
		# Pre-move position: white bishop on b5, black knight still on c6 (about to be taken by Bxc6).
		game.rules.set_fen("r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 4")
		game.board.set_rules(game.rules)
		game.board.flipped = false
		game._start_capture_burst(game.rules.move_from_uci("b5c6"))  # hides c6, starts the shatter
		_park_bishop_on_c6()
		game.board._cap_t = 0.18
		game.board.queue_redraw()
		return false
	if frames == 24:
		vp.get_texture().get_image().save_png("/tmp/limpid_capture_early.png")
		print("saved /tmp/limpid_capture_early.png  (hide_sq=%d, expect c6=42)" % game.board._cap_hide_sq)
		_park_bishop_on_c6()
		game.board._cap_t = 0.42
		game.board.queue_redraw()
		return false
	if frames == 28:
		vp.get_texture().get_image().save_png("/tmp/limpid_capture_mid.png")
		print("saved /tmp/limpid_capture_mid.png")
		quit()
	return false
