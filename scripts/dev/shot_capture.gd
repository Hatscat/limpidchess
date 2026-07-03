extends SceneTree

## Dev-only: render the capture "smash" mid-burst, to check the taken piece shatters over its square like
## a lighter checkmate flourish.  DISPLAY=:0 godot --path . -s res://scripts/dev/shot_capture.gd
## -> /tmp/limpid_capture_early.png (t=0.18) + /tmp/limpid_capture_mid.png (t=0.4)
## Scenario: after 4.Bxc6, the white bishop sits on c6 and the taken black knight bursts over it.

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


func _burst_at(t: float) -> void:
	game.board._cap_sq = 42        # c6 = rank5*8 + file2
	game.board._cap_piece = 10     # black knight (2 | 8)
	game.board._cap_t = t
	game.board._cap_active = true
	game.board.queue_redraw()


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
		# Position after 1.e4 e5 2.Nf3 Nc6 3.Bb5 a6 4.Bxc6: white bishop on c6, the knight just taken.
		game.rules.set_fen("r1bqkbnr/1ppp1ppp/p1B5/4p3/4P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 0 4")
		game.board.set_rules(game.rules)
		game.board.flipped = false
		_burst_at(0.18)
		return false
	if frames == 24:
		vp.get_texture().get_image().save_png("/tmp/limpid_capture_early.png")
		print("saved /tmp/limpid_capture_early.png")
		_burst_at(0.4)
		return false
	if frames == 28:
		vp.get_texture().get_image().save_png("/tmp/limpid_capture_mid.png")
		print("saved /tmp/limpid_capture_mid.png")
		quit()
	return false
