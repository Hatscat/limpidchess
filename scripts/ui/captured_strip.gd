extends Control

## A thin strip of the pieces ONE side has captured: small icons grouped by type
## (slightly overlapping, like chess.com) followed by a "+N" material lead.
##
## Custom-drawn rather than a container so it stays cheap (no node churn per move)
## and matches the board's look. Fed by game.gd via [set_data]; it never decides
## anything about the game.

const Rules := preload("res://scripts/chess/chess_rules.gd")
const FONT := preload("res://assets/fonts/OpenDyslexic-Regular.otf")

var _tex := {}
var _items: PackedInt32Array = PackedInt32Array()  ## piece codes, pre-sorted pawns→queen
var _advantage := 0                                ## > 0 → show "+N"


func _ready() -> void:
	_load_textures()


func _load_textures() -> void:
	var names := {
		Rules.PAWN: "pawn", Rules.KNIGHT: "knight", Rules.BISHOP: "bishop",
		Rules.ROOK: "rook", Rules.QUEEN: "queen",
	}
	for t in names:
		_tex[Rules.make_piece(t, Rules.WHITE)] = load("res://assets/pieces/w_%s.png" % names[t])
		_tex[Rules.make_piece(t, Rules.BLACK)] = load("res://assets/pieces/b_%s.png" % names[t])


## items: captured piece codes (sorted by value). advantage: material lead (0 hides it).
func set_data(items: PackedInt32Array, advantage: int) -> void:
	_items = items
	_advantage = advantage
	queue_redraw()


func _draw() -> void:
	var icon: float = minf(size.y, 30.0)
	var y: float = (size.y - icon) * 0.5
	var x: float = 0.0
	var prev_type := -1
	var same_step: float = icon * 0.55  ## overlap within one piece type
	var type_gap: float = icon * 0.28   ## breathing gap when the type changes
	var drew := false
	for code in _items:
		var tex: Texture2D = _tex.get(code)
		if tex == null:
			continue  # no icon for this code (e.g. a king) → reserve no space either
		var t: int = Rules.piece_type(code)
		if prev_type != -1:
			x += same_step if t == prev_type else (icon + type_gap)
		draw_texture_rect(tex, Rect2(x, y, icon, icon), false)
		prev_type = t
		drew = true
	if _advantage > 0:
		var rx: float = (x + icon + 10.0) if drew else 0.0
		draw_string(FONT, Vector2(rx, y + icon * 0.74), "+%d" % _advantage,
			HORIZONTAL_ALIGNMENT_LEFT, -1, UI.FONT_CAPTION, UI.TEXT_DIM)
