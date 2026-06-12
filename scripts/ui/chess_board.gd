extends Control

## Custom-drawn chess board: squares, pieces, highlights, and the three guided
## move "arrows". It owns rendering + hit-testing only; game flow lives in
## [game.gd]. The board never decides legality — it draws what it's given.
##
## The three options are drawn NEUTRALLY (numbered badges, one accent colour) so
## the player has to *find* the best move. Quality colours (green/blue/red) only
## appear after reveal(). Options are passed pre-shuffled so slot order leaks
## nothing.

signal option_chosen(option: Dictionary)

const Rules := preload("res://scripts/chess/chess_rules.gd")
const BADGE_FONT := preload("res://assets/fonts/OpenDyslexic-Regular.otf")

# Piece textures keyed by ChessRules piece code.
var _tex := {}

var rules: ChessRules = null
var flipped := false                 ## true → black at the bottom
var last_move := -1                  ## highlight both squares of this move
var check_square := -1               ## highlight king in check

# Options: Array of { move:int, quality:String("best"|"decent"|"blunder") }.
var _options: Array = []
var _revealed := false               ## once revealed, arrows show quality colours
var _interactive := false            ## accept taps on options

# Cached layout (recomputed each _draw).
var _cell := 0.0
var _origin := Vector2.ZERO


func _ready() -> void:
	_load_textures()
	resized.connect(queue_redraw)


func _load_textures() -> void:
	var names := {
		Rules.PAWN: "pawn", Rules.KNIGHT: "knight", Rules.BISHOP: "bishop",
		Rules.ROOK: "rook", Rules.QUEEN: "queen", Rules.KING: "king",
	}
	for t in names:
		_tex[Rules.make_piece(t, Rules.WHITE)] = load("res://assets/pieces/w_%s.png" % names[t])
		_tex[Rules.make_piece(t, Rules.BLACK)] = load("res://assets/pieces/b_%s.png" % names[t])


# --- Public API ---

func set_rules(r: ChessRules) -> void:
	rules = r
	queue_redraw()


func set_last_move(move: int) -> void:
	last_move = move
	queue_redraw()


func set_check_square(sq: int) -> void:
	check_square = sq
	queue_redraw()


## Present the three options (pre-shuffled). interactive=true lets the player tap.
func set_options(options: Array, interactive := true) -> void:
	_options = options
	_revealed = false
	_interactive = interactive
	queue_redraw()


func clear_options() -> void:
	_options = []
	_revealed = false
	_interactive = false
	queue_redraw()


## Recolour the arrows by quality (after the player has chosen).
func reveal() -> void:
	_revealed = true
	_interactive = false
	queue_redraw()


# --- Drawing ---

func _draw() -> void:
	if rules == null:
		return
	_recompute_layout()
	_draw_squares()
	_draw_highlights()
	_draw_pieces()
	_draw_options()


func _recompute_layout() -> void:
	var board_px := minf(size.x, size.y)
	_cell = floorf(board_px / 8.0)
	var used := _cell * 8.0
	_origin = Vector2((size.x - used) * 0.5, (size.y - used) * 0.5)


func _draw_squares() -> void:
	for sq in 64:
		var is_light := ((Rules.file_of(sq) + Rules.rank_of(sq)) % 2) == 1
		var col: Color = UI.BOARD_LIGHT if is_light else UI.BOARD_DARK
		draw_rect(_square_rect(sq), col)


func _draw_highlights() -> void:
	if last_move >= 0:
		draw_rect(_square_rect(Rules.move_from(last_move)), UI.HL_LAST_MOVE)
		draw_rect(_square_rect(Rules.move_to(last_move)), UI.HL_LAST_MOVE)
	if check_square >= 0:
		draw_rect(_square_rect(check_square), UI.HL_CHECK)


func _draw_pieces() -> void:
	for sq in 64:
		var p: int = rules.board[sq]
		if p == 0:
			continue
		var tex: Texture2D = _tex.get(p)
		if tex:
			draw_texture_rect(tex, _square_rect(sq), false)


func _draw_options() -> void:
	for i in _options.size():
		var opt: Dictionary = _options[i]
		var col := UI.ACCENT
		if _revealed:
			match opt.get("quality", ""):
				"best": col = UI.MOVE_BEST
				"decent": col = UI.MOVE_DECENT
				"blunder": col = UI.MOVE_BLUNDER
		_draw_arrow(opt["move"], col, i + 1)


func _draw_arrow(move: int, col: Color, number: int) -> void:
	var from := _square_center(Rules.move_from(move))
	var to := _square_center(Rules.move_to(move))
	var dir := (to - from).normalized()
	var head := _cell * 0.30
	# Stop the shaft short of the target so the head sits cleanly on the square.
	var shaft_end := to - dir * head * 0.9
	var width := _cell * 0.16
	draw_line(from, shaft_end, Color(col, 0.85), width, true)
	# Arrowhead.
	var perp := Vector2(-dir.y, dir.x)
	var p1 := to - dir * head + perp * head * 0.6
	var p2 := to - dir * head - perp * head * 0.6
	draw_colored_polygon(PackedVector2Array([to, p1, p2]), Color(col, 0.9))
	# Numbered badge at the target so the player can pick by number.
	var badge_r := _cell * 0.22
	draw_circle(to, badge_r, Color(0.07, 0.08, 0.10, 0.92))
	draw_arc(to, badge_r, 0, TAU, 24, Color(col, 1.0), 2.0, true)
	var label := str(number)
	var fs := int(_cell * 0.34)
	var ts := BADGE_FONT.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
	draw_string(BADGE_FONT, to - ts * 0.5 + Vector2(0, ts.y * 0.35), label,
		HORIZONTAL_ALIGNMENT_CENTER, -1, fs, Color(1, 1, 1, 1))


# --- Geometry ---

func _square_rect(sq: int) -> Rect2:
	var f := Rules.file_of(sq)
	var r := Rules.rank_of(sq)
	var col := f if not flipped else 7 - f
	var row := (7 - r) if not flipped else r
	return Rect2(_origin + Vector2(col * _cell, row * _cell), Vector2(_cell, _cell))


func _square_center(sq: int) -> Vector2:
	var rect := _square_rect(sq)
	return rect.position + rect.size * 0.5


func _point_to_square(pos: Vector2) -> int:
	if _cell <= 0:
		return -1  # board hasn't been laid out yet (no _draw has run)
	var local := pos - _origin
	if local.x < 0 or local.y < 0 or local.x >= _cell * 8 or local.y >= _cell * 8:
		return -1
	var col := int(local.x / _cell)
	var row := int(local.y / _cell)
	var f := col if not flipped else 7 - col
	var r := (7 - row) if not flipped else row
	return r * 8 + f


# --- Input ---

func _gui_input(event: InputEvent) -> void:
	if not _interactive or _options.is_empty():
		return
	var pressed := false
	var pos := Vector2.ZERO
	if event is InputEventScreenTouch and event.pressed:
		pressed = true
		pos = event.position
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pressed = true
		pos = event.position
	if not pressed:
		return

	var sq := _point_to_square(pos)
	if sq < 0:
		return
	# A tap on an option's target square (or its badge) plays that option.
	# Options are guaranteed distinct target squares (see ChessBot.select_options).
	for opt in _options:
		if Rules.move_to(opt["move"]) == sq:
			option_chosen.emit(opt)
			get_viewport().set_input_as_handled()
			return
