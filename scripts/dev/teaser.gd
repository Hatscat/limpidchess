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
# Scholar's mate (White to move), the most recognizable beginner tactic: best = Qxf7#
# (mate, arrow lands right beside the king), OK = Nc3 (develops, misses it), blunder =
# Qxe5 (grabs a pawn but hangs the queen to Nxe5). Near-full board, arrows fan cleanly.
const FEN := "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4"
const BEST := 39 | (53 << 6)     # Qh5xf7#
const DECENT := 1 | (18 << 6)    # Nb1-c3
const BLUNDER := 39 | (36 << 6)  # Qh5xe5

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
