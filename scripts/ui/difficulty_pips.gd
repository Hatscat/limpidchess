extends Control

## A small RELATIVE difficulty meter: `level` filled dots out of TOTAL. Deliberately
## not an Elo (the bot strengths aren't calibrated) — just a "how hard, roughly" cue.

const TOTAL := 6
const _DOT_R := 4.5
const _STEP := 14.0

var level := 1


func set_level(l: int) -> void:
	level = clampi(l, 0, TOTAL)
	custom_minimum_size = Vector2(TOTAL * _STEP, 16.0)
	queue_redraw()


func _draw() -> void:
	var y := size.y * 0.5
	for i in TOTAL:
		var cx := _DOT_R + i * _STEP
		var col: Color = UI.ACCENT if i < level else Color(1, 1, 1, 0.16)
		draw_circle(Vector2(cx, y), _DOT_R, col)
