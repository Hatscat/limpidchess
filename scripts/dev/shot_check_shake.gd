extends SceneTree

## Dev-only: render the checked-king tremble at its two extremes so the shake is visible in a still.
## A live game loops it continuously.  DISPLAY=:0 godot --path . -s res://scripts/dev/shot_check_shake.gd
## -> /tmp/limpid_check_right.png (max sway one way) + /tmp/limpid_check_left.png (the other)
## Position: 1.d4 e5 2.a3?? Bb4+ — the White king on e1 is in check from the black bishop on b4.

const Rules := preload("res://scripts/chess/chess_rules.gd")
const FEN := "rnbqk1nr/pppp1ppp/8/4p3/1b1P4/8/PPP1PPPP/RNBQKBNR w KQkq - 1 3"
const E1 := 4

# sin(_check_shake * TAU * HZ) hits +1 / -1 at these phases (HZ = 4.0): quarter and three-quarter period.
const PHASE_RIGHT := 0.0625   # 1 / (4 * HZ)
const PHASE_LEFT := 0.1875    # 3 / (4 * HZ)

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


func _freeze(phase: float) -> void:
	game.board.check_square = E1
	game.board.set_process(false)   # stop the auto-advance so the still holds our chosen phase
	game.board._check_shake = phase
	game.board.queue_redraw()


func _process(_d: float) -> bool:
	frames += 1
	if frames == 1:
		var gm: Node = root.get_node("GameManager")
		gm.is_premium = false
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
		game._game_over = false
		game.player_color = Rules.WHITE
		game.board.flipped = false
		game.rules.set_fen(FEN)
		game.board.set_rules(game.rules)
		game.board.clear_options()
		game.board.clear_last_moves()
		game.feedback.text = ""
		game.status_label.text = "Check!"
		_freeze(PHASE_RIGHT)
		return false
	if frames == 48:
		vp.get_texture().get_image().save_png("/tmp/limpid_check_right.png")
		print("saved /tmp/limpid_check_right.png")
		_freeze(PHASE_LEFT)
		return false
	if frames == 56:
		vp.get_texture().get_image().save_png("/tmp/limpid_check_left.png")
		print("saved /tmp/limpid_check_left.png")
		quit()
	return false
