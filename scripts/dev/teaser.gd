extends Control

## Marketing teaser generator. Record it through Godot's Movie Maker:
##   godot --path . --write-movie /tmp/teaser.avi --fixed-fps 30 res://scripts/dev/teaser.tscn
## then encode with ffmpeg (see the build notes). Dev-only; not shipped gameplay.
##
## Layout is computed from the ACTUAL viewport size (get_viewport_rect), not a hard
## 720 assumption — Movie Maker's viewport can differ, which otherwise shifts the
## board off the left edge. Captions autowrap so they can never be clipped.

const Rules := preload("res://scripts/chess/chess_rules.gd")
const BoardScript := preload("res://scripts/ui/chess_board.gd")
# A quiet middle-game where the three candidates fan OUT (no crossing, none on the
# a/h edge): d4-d5 (best, centre), Nf3-g5 (decent, right), Nc3-b5 (blunder, left).
const FEN := "r1bq1rk1/ppp2ppp/2np1n2/4p3/2PP4/2N2N2/PP3PPP/R1BQ1RK1 w - - 0 9"
const BEST := 27 | (35 << 6)     # d4-d5
const DECENT := 21 | (38 << 6)   # Nf3-g5
const BLUNDER := 18 | (33 << 6)  # Nc3-b5

var board
var rules
var caption: Label
var feedback: Label


func _ready() -> void:
	TranslationServer.set_locale("en")
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.1, 0.12)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	caption = _label(36, Color(1, 1, 1, 0.92))
	add_child(caption)
	board = BoardScript.new()
	add_child(board)
	rules = Rules.new()
	rules.set_fen(FEN)
	board.set_rules(rules)
	feedback = _label(46, Color(0.36, 0.78, 0.52))
	add_child(feedback)

	_layout()
	get_viewport().size_changed.connect(_layout)
	_run()


## Centre the board square within the real viewport, with margins, and park the
## caption above / feedback below it.
func _layout() -> void:
	var vp := get_viewport_rect().size
	var margin := 28.0
	var side := minf(vp.x - 2.0 * margin, vp.y - 300.0)
	var bx := (vp.x - side) * 0.5
	var by := (vp.y - side) * 0.5
	board.position = Vector2(bx, by)
	board.size = Vector2(side, side)
	caption.position = Vector2(margin, by - 104.0)
	caption.size = Vector2(vp.x - 2.0 * margin, 96.0)
	feedback.position = Vector2(margin, by + side + 18.0)
	feedback.size = Vector2(vp.x - 2.0 * margin, 80.0)


func _label(sz: int, col: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", col)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _run() -> void:
	caption.text = "Every turn, three moves"
	board.set_options([
		{"move": BLUNDER, "quality": "blunder"},
		{"move": DECENT, "quality": "decent"},
		{"move": BEST, "quality": "best"},
	], true)
	await _wait(1.0)
	caption.text = "Find the best one"
	await _wait(2.0)

	caption.text = "Best  ·  OK  ·  blunder"
	board._chosen_move = BEST
	board.reveal()
	await _wait(2.0)

	await board.animate_move(BEST, 0.9)
	rules.make_move(BEST)
	board.set_last_move(BEST, Rules.WHITE)
	board.set_rules(rules)
	board.end_animation()
	board.clear_options()
	feedback.text = "★ Best move!"
	caption.text = "Learn to see them"
	await _wait(2.4)
	get_tree().quit()


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout
