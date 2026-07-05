extends SceneTree

## Dev-only: render the Face to Face (two-player) game at design scale for the listing/site: the board
## with the three neutral options, the "Face to Face" opponent chip and both players' captured strips.
##   godot --path . -s res://scripts/dev/shot_facetoface.gd   (needs a display) -> /tmp/limpid_facetoface.png

const Rules := preload("res://scripts/chess/chess_rules.gd")

# A calm Ruy-Lopez-ish middlegame (both sides castled). Options are cosmetic arrows for the shot.
const FEN := "r1bq1rk1/2p1bppp/p1np1n2/1p2p3/3PP3/1BP2N2/PP3PPP/RNBQR1K1 w - - 0 9"
const BEST := 27 | (35 << 6)     # d4-d5, a strong central push
const DECENT := 1 | (11 << 6)    # Nb1-d2, quietly developing
const BLUNDER := 21 | (38 << 6)  # Nf3-g5, a loose lunge

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
		gm.is_premium = true          # Face to Face is a premium feature
		gm.player_is_white = true
		gm.pass_and_play = true
		gm.pending_review_check = false
		gm.current_bot = {}
		game = load("res://scenes/game.tscn").instantiate()
		vp.add_child(game)
		return false
	if frames == 40:
		_inject()
		return false
	if frames == 60:
		vp.get_texture().get_image().save_png("/tmp/limpid_facetoface.png")
		print("saved /tmp/limpid_facetoface.png")
		quit()
	return false


func _inject() -> void:
	game._gen += 1
	game._busy = false
	game._game_over = false
	game.player_color = Rules.WHITE
	game.board.flipped = false
	game.rules.set_fen(FEN)
	game.board.set_rules(game.rules)
	game.board.clear_last_moves()
	game._caps_white = PackedInt32Array()
	game._caps_black = PackedInt32Array()
	game._update_captured()
	game.board.set_check_square(-1)
	game.board.set_options([
		{"move": BLUNDER, "quality": "blunder"},
		{"move": DECENT, "quality": "decent"},
		{"move": BEST, "quality": "best"},
	], true)
	game.feedback.text = ""
