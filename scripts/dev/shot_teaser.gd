extends SceneTree

## Dev-only: render the teaser frame-by-frame into a 540x960 SubViewport (deterministic, no
## Movie Maker viewport quirks). Saves PNGs to /tmp/teaser_frames/; ffmpeg stitches them.
##   godot --path . -s res://scripts/dev/shot_teaser.gd   (needs a display)
##
## Scholar's mate: best = Qxf7# (mate), OK = Nc3, blunder = Qxe5 (hangs the queen).

const Rules := preload("res://scripts/chess/chess_rules.gd")
const BoardScript := preload("res://scripts/ui/chess_board.gd")

const FEN := "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4"
const BEST := 39 | (53 << 6)     # Qh5xf7#
const DECENT := 1 | (18 << 6)    # Nb1-c3
const BLUNDER := 39 | (36 << 6)  # Qh5xe5
const OUT_DIR := "/tmp/teaser_frames"
const TOTAL := 240               # 8.0s @ 30fps

var vp: SubViewport
var board
var rules
var caption: Label
var feedback: Label
var warmup := 6
var frame := 0
var revealed := false
var move_made := false


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	vp = SubViewport.new()
	vp.size = Vector2i(540, 960)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var host := Control.new()
	host.size = Vector2(540, 960)
	vp.add_child(host)
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.1, 0.12)
	bg.size = Vector2(540, 960)
	host.add_child(bg)
	caption = _label(26, Color(1, 1, 1, 0.92))
	caption.position = Vector2(10, 72); caption.size = Vector2(520, 84)
	host.add_child(caption)
	board = BoardScript.new()
	board.position = Vector2(20, 176); board.size = Vector2(500, 500)
	host.add_child(board)
	feedback = _label(40, Color(0.36, 0.78, 0.52))
	feedback.position = Vector2(20, 700); feedback.size = Vector2(500, 80)
	host.add_child(feedback)
	rules = Rules.new()
	rules.set_fen(FEN)
	board.set_rules(rules)
	board.set_check_square(-1)
	_neutral()


func _label(sz: int, col: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", col)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_OFF  # keep every caption on one line (no awkward wrap)
	return l


func _neutral() -> void:
	board.set_options([
		{"move": BLUNDER, "quality": "blunder"},
		{"move": DECENT, "quality": "decent"},
		{"move": BEST, "quality": "best"},
	], false)


func _setup_frame(f: int) -> void:
	if f < 45:
		caption.text = "Every turn, three moves"
	elif f < 105:
		caption.text = "Find the best one"
	elif f < 171:
		caption.text = "Best · OK · blunder"
		if not revealed:
			board.reveal()
			revealed = true
	elif f < 195:
		caption.text = "The best move"
		board.clear_options()
		board.show_move_frame(BEST, clampf(float(f - 171) / 23.0, 0.0, 1.0))
	else:
		if not move_made:
			board.end_animation()
			rules.make_move(BEST)
			board.set_rules(rules)
			board.set_last_move(BEST, Rules.WHITE)
			board.clear_options()
			move_made = true
		caption.text = "Learn to see them"
		feedback.text = "★ Checkmate!"


func _process(_d: float) -> bool:
	if warmup > 0:
		warmup -= 1
		return false
	if frame > 0:
		vp.get_texture().get_image().save_png("%s/frame_%04d.png" % [OUT_DIR, frame - 1])
	if frame >= TOTAL:
		print("saved ", TOTAL, " frames to ", OUT_DIR)
		quit()
		return false
	_setup_frame(frame)
	frame += 1
	return false
