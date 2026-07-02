extends Control

## A thin horizontal evaluation bar (chess.com style): a white slice grows from the
## left as White stands better, with the eval printed on the leading side. Fed the
## current White-relative centipawn score by game.gd; shown only for bot games (an
## eval would spoil a two-player Face to Face). Purely a readout, never game logic.

const FONT := preload("res://assets/fonts/OpenDyslexic-Regular.otf")

## |score| at or above this is a forced mate (SF folds mate to ~1e6, fallback ~1e5).
const MATE_CP := 50000
## Centipawns that map to (nearly) a full bar either way (~10 pawns).
const FULL_CP := 1000.0

var _white_cp := 0  ## > 0 → White better, < 0 → Black better


func set_eval(white_cp: int) -> void:
	_white_cp = white_cp
	queue_redraw()


func _draw() -> void:
	var c: float = clampf(float(_white_cp), -FULL_CP, FULL_CP)
	var frac: float = 0.5 + (c / FULL_CP) * 0.46  # keep a sliver of both ends visible
	var wx: float = size.x * frac

	# Black side fills the whole bar; the white slice is painted over the left.
	draw_rect(Rect2(0.0, 0.0, size.x, size.y), UI.SURFACE)
	draw_rect(Rect2(0.0, 0.0, wx, size.y), UI.BOARD_LIGHT)

	var txt := _label()
	var ty: float = size.y * 0.5 + UI.FONT_CAPTION * 0.36
	if _white_cp >= 0:
		draw_string(FONT, Vector2(10.0, ty), txt, HORIZONTAL_ALIGNMENT_LEFT, -1,
			UI.FONT_CAPTION, UI.BG_DARK)
	else:
		draw_string(FONT, Vector2(0.0, ty), txt, HORIZONTAL_ALIGNMENT_RIGHT, size.x - 10.0,
			UI.FONT_CAPTION, UI.BOARD_LIGHT)


func _label() -> String:
	if absi(_white_cp) >= MATE_CP:
		return "M"  # which side is shown by the fill + which end the label sits on
	var p: float = float(_white_cp) / 100.0
	if _white_cp > 0:
		return "+%.1f" % p
	if _white_cp < 0:
		return "%.1f" % p
	return "0.0"
