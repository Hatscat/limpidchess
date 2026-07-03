extends SceneTree

## Dev-only: render the capture smash in the PUZZLE scene (pre-commit: bishop parked on c6, taken knight
## hidden + shattering).  DISPLAY=:0 godot --path . -s res://scripts/dev/shot_capture_puzzle.gd
## -> /tmp/limpid_capture_puzzle.png

const Rules := preload("res://scripts/chess/chess_rules.gd")

var vp: SubViewport
var puz
var frames := 0


func _initialize() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(1560, 2778)
	vp.size_2d_override = Vector2i(720, 1280)
	vp.size_2d_override_stretch = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)


func _park_bishop_on_c6() -> void:
	puz.board._anim_from = 4 * 8 + 1   # b5
	puz.board._anim_to = 5 * 8 + 2     # c6
	puz.board._anim_piece = Rules.BISHOP
	puz.board._anim_progress = 1.0
	puz.board._anim_active = true


func _process(_d: float) -> bool:
	frames += 1
	if frames == 1:
		puz = load("res://scenes/puzzle_rush.tscn").instantiate()
		vp.add_child(puz)
		return false
	if frames == 20:
		puz._gen += 1
		puz._over = true
		puz._busy = true
		puz.rules.set_fen("r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 4")
		puz.board.set_rules(puz.rules)
		puz.board.flipped = false
		puz.board.burst_capture_for(puz.rules.move_from_uci("b5c6"))
		_park_bishop_on_c6()
		puz.board._cap_t = 0.32
		puz.board.queue_redraw()
		return false
	if frames == 26:
		vp.get_texture().get_image().save_png("/tmp/limpid_capture_puzzle.png")
		print("saved /tmp/limpid_capture_puzzle.png (hide_sq=%d expect 42)" % puz.board._cap_hide_sq)
		quit()
	return false
