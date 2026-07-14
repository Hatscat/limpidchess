extends SceneTree

## Dev-only: compose the Google Play feature graphic (1024x500). Row-based layout: title + subtitle on
## one centered top row, then two LARGE Scholar's-mate boards (Your move -> The answer) with a real
## arrow between them, so the boards dominate the image.
##   godot --path . -s res://scripts/dev/shot_feature.gd   (needs a display) -> /tmp/limpid_feature.png
##
## Size + output are env-overridable so the SAME layout can render other aspect ratios (e.g. a 1270x760
## Product Hunt social/gallery card) without touching the Play Store 1024x500 default. The design scales
## off the WIDTH (so the one-line title always fits) and the whole block is vertically centred:
##   LIMPID_FEAT_W / LIMPID_FEAT_H  -> canvas size   (default 1024 x 500)
##   LIMPID_FEAT_OUT                -> output png     (default /tmp/limpid_feature.png)

const Rules := preload("res://scripts/chess/chess_rules.gd")
const BoardScript := preload("res://scripts/ui/chess_board.gd")
const BOLD := "res://assets/fonts/OpenDyslexic-Bold.otf"

const FEN := "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4"
const BEST := 39 | (53 << 6)
const DECENT := 1 | (18 << 6)
const BLUNDER := 39 | (36 << 6)

var W := 1024
var H := 500
var OUT := "/tmp/limpid_feature.png"
var scale := 1.0        ## sized off the width, 1024 == the original design (keeps the title one line)
var y_off := 0.0        ## vertical centring offset when the canvas is taller than the scaled design
var BOARD := 314.0
var GAP := 92.0          ## space between the two boards (holds the arrow)

var vp: SubViewport
var frames := 0


## A clean right-pointing arrow (shaft + triangular head) in the accent colour, so it reads as a real
## arrow rather than a chevron ">".
class Arrow extends Control:
	func _draw() -> void:
		var col: Color = UI.ACCENT
		var mid := size.y * 0.5
		var shaft_h := size.y * (15.0 / 56.0)  # keeps the 1024x500 default's 15px shaft exact, scales up
		var head_w := size.x * 0.44
		var head_h := size.y * 0.86
		draw_rect(Rect2(0.0, mid - shaft_h * 0.5, size.x - head_w + 2.0, shaft_h), col)
		draw_colored_polygon(PackedVector2Array([
			Vector2(size.x - head_w, mid - head_h * 0.5),
			Vector2(size.x, mid),
			Vector2(size.x - head_w, mid + head_h * 0.5),
		]), col)


## A small filled dot separator (OpenDyslexic's "•" glyph renders as an odd bar, so draw our own).
class Dot extends Control:
	var radius := 6.0
	func _draw() -> void:
		draw_circle(size * 0.5, radius, Color(0.50, 0.57, 0.63))


func _initialize() -> void:
	W = int(OS.get_environment("LIMPID_FEAT_W")) if OS.has_environment("LIMPID_FEAT_W") else 1024
	H = int(OS.get_environment("LIMPID_FEAT_H")) if OS.has_environment("LIMPID_FEAT_H") else 500
	OUT = OS.get_environment("LIMPID_FEAT_OUT") if OS.has_environment("LIMPID_FEAT_OUT") else "/tmp/limpid_feature.png"
	scale = float(W) / 1024.0
	y_off = (float(H) - 500.0 * scale) / 2.0
	BOARD = 314.0 * scale
	GAP = 92.0 * scale

	vp = SubViewport.new()
	vp.size = Vector2i(W, H)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var host := Control.new()
	host.size = Vector2(W, H)
	vp.add_child(host)

	# Gradient background (dark navy -> subtle teal glow toward bottom-right).
	var grad := Gradient.new()
	grad.set_color(0, Color(0.05, 0.06, 0.09))
	grad.set_color(1, Color(0.09, 0.16, 0.21))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.width = W
	gt.height = H
	gt.fill = GradientTexture2D.FILL_LINEAR
	gt.fill_from = Vector2(0.1, 0.0)
	gt.fill_to = Vector2(1.0, 1.0)
	var bg := TextureRect.new()
	bg.texture = gt
	bg.size = Vector2(W, H)
	host.add_child(bg)

	# Row 1: "Limpid Chess  •  find the best move" on a single centred line.
	var cc := CenterContainer.new()
	cc.position = Vector2(0, 10.0 * scale + y_off)
	cc.size = Vector2(W, 86.0 * scale)
	host.add_child(cc)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", int(round(18 * scale)))
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	cc.add_child(hb)
	hb.add_child(_lbl("Limpid Chess", int(round(34 * scale)), Color(0.93, 0.95, 0.97)))
	var dot := Dot.new()
	dot.radius = 6.0 * scale
	dot.custom_minimum_size = Vector2(24, 48) * scale
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(dot)
	hb.add_child(_lbl("find the best move", int(round(32 * scale)), UI.ACCENT))

	# Row 2: two large boards, centred, with the arrow in the gap.
	var total := BOARD * 2 + GAP
	var left := (W - total) / 2.0
	var top := 118.0 * scale + y_off
	var bx := left + BOARD + GAP

	var ba := _board(false)
	ba.position = Vector2(left, top)
	ba.size = Vector2(BOARD, BOARD)
	host.add_child(ba)
	var bb := _board(true)
	bb.position = Vector2(bx, top)
	bb.size = Vector2(BOARD, BOARD)
	host.add_child(bb)

	var arrow := Arrow.new()
	arrow.size = Vector2(76, 56) * scale
	arrow.position = Vector2(left + BOARD + (GAP - 76 * scale) * 0.5, top + BOARD * 0.5 - 28.0 * scale)
	host.add_child(arrow)
	arrow.queue_redraw()

	var cap_sz := int(round(22 * scale))
	var cap_col := Color(0.80, 0.84, 0.88)
	_text(host, "Your move", cap_sz, cap_col, Vector2(left, top + BOARD + 12.0 * scale), BOARD, HORIZONTAL_ALIGNMENT_CENTER)
	_text(host, "The answer", cap_sz, cap_col, Vector2(bx, top + BOARD + 12.0 * scale), BOARD, HORIZONTAL_ALIGNMENT_CENTER)


func _lbl(s: String, sz: int, col: Color) -> Label:
	var l := Label.new()
	l.text = s
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", col)
	l.add_theme_font_override("font", load(BOLD))
	return l


func _text(parent: Node, s: String, sz: int, col: Color, pos: Vector2, w: float, align: int) -> void:
	var l := Label.new()
	l.text = s
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", col)
	l.position = pos
	l.size = Vector2(w, sz * 1.5)
	l.horizontal_alignment = align
	parent.add_child(l)


func _board(reveal: bool) -> Control:
	var b = BoardScript.new()
	var r := Rules.new()
	r.set_fen(FEN)
	b.set_rules(r)
	b.set_check_square(-1)
	b.set_options([
		{"move": BLUNDER, "quality": "blunder"},
		{"move": DECENT, "quality": "decent"},
		{"move": BEST, "quality": "best"},
	], false)
	if reveal:
		b.reveal()
	return b


func _process(_d: float) -> bool:
	frames += 1
	if frames >= 12:
		vp.get_texture().get_image().save_png(OUT)
		print("saved ", OUT, " (", W, "x", H, ")")
		quit()
	return false
