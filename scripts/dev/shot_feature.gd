extends SceneTree

## Dev-only: compose the Google Play feature graphic (1024x500) with the updated tagline and the
## obvious Scholar's-mate mechanic (Your move -> The answer).
##   godot --path . -s res://scripts/dev/shot_feature.gd   (needs a display) -> /tmp/limpid_feature.png

const Rules := preload("res://scripts/chess/chess_rules.gd")
const BoardScript := preload("res://scripts/ui/chess_board.gd")
const BOLD := "res://assets/fonts/OpenDyslexic-Bold.otf"

const FEN := "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4"
const BEST := 39 | (53 << 6)
const DECENT := 1 | (18 << 6)
const BLUNDER := 39 | (36 << 6)

var vp: SubViewport
var frames := 0


func _initialize() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(1024, 500)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var host := Control.new()
	host.size = Vector2(1024, 500)
	vp.add_child(host)

	# Gradient background (dark navy -> subtle teal glow toward bottom-right).
	var grad := Gradient.new()
	grad.set_color(0, Color(0.05, 0.06, 0.09))
	grad.set_color(1, Color(0.09, 0.16, 0.21))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.width = 1024
	gt.height = 500
	gt.fill = GradientTexture2D.FILL_LINEAR
	gt.fill_from = Vector2(0.1, 0.0)
	gt.fill_to = Vector2(1.0, 1.0)
	var bg := TextureRect.new()
	bg.texture = gt
	bg.size = Vector2(1024, 500)
	host.add_child(bg)

	# Left text block (OpenDyslexic is very wide, so keep it well clear of the boards at x=586).
	_text(host, "Limpid Chess", 48, Color(0.93, 0.95, 0.97), Vector2(56, 150), 500, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(host, "Find the best move", 32, UI.ACCENT, Vector2(58, 222), 500, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(host, "Smooth chess that grows with you.", 20, Color(0.72, 0.77, 0.81), Vector2(58, 278), 510, HORIZONTAL_ALIGNMENT_LEFT, false)

	# Two mini-boards on the right: neutral "Your move" -> revealed "The answer".
	var ba := _board(false)
	ba.position = Vector2(586, 110)
	ba.size = Vector2(180, 180)
	host.add_child(ba)
	var bb := _board(true)
	bb.position = Vector2(812, 110)
	bb.size = Vector2(180, 180)
	host.add_child(bb)
	_text(host, "Your move", 20, Color(0.80, 0.84, 0.88), Vector2(586, 298), 180, HORIZONTAL_ALIGNMENT_CENTER, false)
	_text(host, "The answer", 20, Color(0.80, 0.84, 0.88), Vector2(812, 298), 180, HORIZONTAL_ALIGNMENT_CENTER, false)

	var arrow := TextureRect.new()
	arrow.texture = load("res://assets/icons/chevron_right.svg")
	arrow.modulate = UI.ACCENT
	arrow.position = Vector2(770, 182)
	arrow.size = Vector2(36, 44)
	arrow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	arrow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	host.add_child(arrow)


func _text(parent: Node, s: String, sz: int, col: Color, pos: Vector2, w: int, align: int, bold: bool) -> void:
	var l := Label.new()
	l.text = s
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", col)
	if bold:
		l.add_theme_font_override("font", load(BOLD))
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
		vp.get_texture().get_image().save_png("/tmp/limpid_feature.png")
		print("saved /tmp/limpid_feature.png")
		quit()
	return false
