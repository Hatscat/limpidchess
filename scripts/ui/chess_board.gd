extends Control

## Custom-drawn chess board: squares, pieces, highlights, the three guided move
## arrows, and a slow piece-slide animation. Rendering + hit-testing only; game
## flow lives in [game.gd]. The board never decides legality.
##
## The three options are drawn NEUTRALLY before a choice (one accent colour, no
## labels) so the player must FIND the best move. On reveal() each arrow takes
## its quality colour AND a shape symbol (check / dash / cross) so the result is
## readable without relying on colour (colour-blind friendly).

signal option_chosen(option: Dictionary)

const Rules := preload("res://scripts/chess/chess_rules.gd")
const BADGE_FONT := preload("res://assets/fonts/OpenDyslexic-Regular.otf")

var _tex := {}

var rules: ChessRules = null
var flipped := false

# Last move per side, so BOTH the player's and the opponent's last move stay lit.
var _last_white := -1
var _last_black := -1
var check_square := -1

# Options: Array of { move:int, quality:String("best"|"decent"|"blunder") }.
var _options: Array = []
var _revealed := false
var _interactive := false

# Piece-slide animation (used during the reveal).
var _anim_active := false
var _anim_from := -1
var _anim_to := -1
var _anim_piece := 0
var _anim_progress := 0.0
# Second slider: the rook during a castle, so it moves WITH the king (same progress).
var _anim2_from := -1
var _anim2_to := -1
var _anim2_piece := 0

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


## Record the last move of `color` (highlights both sides' latest moves).
func set_last_move(move: int, color: int) -> void:
	if color == Rules.WHITE:
		_last_white = move
	else:
		_last_black = move
	queue_redraw()


func clear_last_moves() -> void:
	_last_white = -1
	_last_black = -1
	queue_redraw()


func set_check_square(sq: int) -> void:
	check_square = sq
	queue_redraw()


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


func reveal() -> void:
	_revealed = true
	_interactive = false
	queue_redraw()


## Slide the piece of `move` from its origin to its target over `duration` secs.
## Await-able. The board keeps showing the pre-move position underneath.
func animate_move(move: int, duration: float) -> void:
	if rules == null:
		return
	_anim_from = Rules.move_from(move)
	_anim_to = Rules.move_to(move)
	_anim_piece = rules.board[_anim_from]
	_anim_progress = 0.0
	_anim_active = true

	# Castle: also slide the rook from its corner to beside the king, in sync.
	_anim2_from = -1
	var flag := Rules.move_flag(move)
	if flag == Rules.F_CASTLE_K or flag == Rules.F_CASTLE_Q:
		var white := Rules.piece_color(_anim_piece) == Rules.WHITE
		if flag == Rules.F_CASTLE_K:
			_anim2_from = 7 if white else 63
			_anim2_to = 5 if white else 61
		else:
			_anim2_from = 0 if white else 56
			_anim2_to = 3 if white else 59
		_anim2_piece = rules.board[_anim2_from]

	var tw := create_tween()
	tw.tween_method(_set_anim_progress, 0.0, 1.0, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tw.finished
	# Leave the piece parked at the destination (anim still active, progress = 1)
	# until the caller commits the move and calls end_animation(). Clearing here
	# would snap the piece back to its origin (move not committed yet).


## Stop the slide overlay; call right after the move is committed to rules.
func end_animation() -> void:
	_anim_active = false
	_anim2_from = -1
	queue_redraw()


func _set_anim_progress(v: float) -> void:
	_anim_progress = v
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
	# The control is sized to the board square by game.gd, so this just centres
	# (and absorbs any rounding remainder).
	_origin = Vector2((size.x - used) * 0.5, (size.y - used) * 0.5)


func _draw_squares() -> void:
	for sq in 64:
		var is_light := ((Rules.file_of(sq) + Rules.rank_of(sq)) % 2) == 1
		var col: Color = UI.BOARD_LIGHT if is_light else UI.BOARD_DARK
		draw_rect(_square_rect(sq), col)


func _draw_highlights() -> void:
	for m in [_last_white, _last_black]:
		if m >= 0:
			draw_rect(_square_rect(Rules.move_from(m)), UI.HL_LAST_MOVE)
			draw_rect(_square_rect(Rules.move_to(m)), UI.HL_LAST_MOVE)
	if check_square >= 0:
		draw_rect(_square_rect(check_square), UI.HL_CHECK)


func _draw_pieces() -> void:
	for sq in 64:
		if _anim_active and (sq == _anim_from or sq == _anim2_from):
			continue  # the moving piece(s) are drawn separately, mid-slide
		var p: int = rules.board[sq]
		if p == 0:
			continue
		var tex: Texture2D = _tex.get(p)
		if tex:
			draw_texture_rect(tex, _square_rect(sq), false)
	if _anim_active:
		_draw_slider(_anim_piece, _anim_from, _anim_to)
		if _anim2_from >= 0:
			_draw_slider(_anim2_piece, _anim2_from, _anim2_to)


## Draw a piece partway from `from_sq` to `to_sq` at the shared slide progress.
func _draw_slider(piece: int, from_sq: int, to_sq: int) -> void:
	var tex: Texture2D = _tex.get(piece)
	if tex == null:
		return
	var pos := _square_rect(from_sq).position.lerp(_square_rect(to_sq).position, _anim_progress)
	draw_texture_rect(tex, Rect2(pos, Vector2(_cell, _cell)), false)


func _draw_options() -> void:
	for opt in _options:
		var col := UI.ACCENT
		if _revealed:
			match opt.get("quality", ""):
				"best": col = UI.MOVE_BEST
				"decent": col = UI.MOVE_DECENT
				"blunder": col = UI.MOVE_BLUNDER
		_draw_arrow(opt["move"], col, opt.get("quality", "") if _revealed else "")


func _draw_arrow(move: int, col: Color, quality: String) -> void:
	var from := _square_center(Rules.move_from(move))
	var to := _square_center(Rules.move_to(move))
	var dir := (to - from).normalized()
	var perp := Vector2(-dir.y, dir.x)

	# Geometry: shaft runs all the way to the target so it joins the head/dot
	# (no gap); a big arrowhead sits over the target dot, hovering it.
	var shaft_w := _cell * 0.11
	var dot_r := _cell * 0.46
	var tip := to + dir * _cell * 0.11
	var base := to - dir * _cell * 0.30
	var hw := _cell * 0.22
	var p1 := base + perp * hw
	var p2 := base - perp * hw
	
	var line_from = from + dir * _cell * 0.15 # little gap from the center of the cell

	# Dark outline pass (slightly larger) so the arrow reads on light or dark squares.
	var outline := Color(0.04, 0.05, 0.08, 0.45)
	var e := _cell * 0.05
	draw_line(line_from, to, outline, shaft_w + e, true)
	#draw_circle(to, dot_r + e, outline)
	draw_colored_polygon(PackedVector2Array([
		tip + dir * e, p1 + (perp * e) - (dir * e), p2 - (perp * e) - (dir * e),
	]), outline)

	# Colour pass.
	draw_circle(to, dot_r, Color(col, 0.42))
	draw_line(line_from, to, Color(col, 0.77), shaft_w, true)
	draw_colored_polygon(PackedVector2Array([tip, p1, p2]), Color(col, 1.0))

	# On reveal, a shape symbol so the result reads without colour.
	if quality != "":
		_draw_quality_symbol(to, quality)


## A small white shape over the dot: check = best, dash = decent, cross = blunder.
func _draw_quality_symbol(c: Vector2, quality: String) -> void:
	var s := _cell * 0.16
	var w := maxf(2.0, _cell * 0.05)
	var white := Color(1, 1, 1, 0.95)
	match quality:
		"best":  # checkmark
			draw_line(c + Vector2(-s, 0), c + Vector2(-s * 0.2, s * 0.7), white, w, true)
			draw_line(c + Vector2(-s * 0.2, s * 0.7), c + Vector2(s, -s * 0.7), white, w, true)
		"decent":  # dash
			draw_line(c + Vector2(-s, 0), c + Vector2(s, 0), white, w, true)
		"blunder":  # cross
			draw_line(c + Vector2(-s, -s), c + Vector2(s, s), white, w, true)
			draw_line(c + Vector2(-s, s), c + Vector2(s, -s), white, w, true)


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
		return -1
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
	# Options have distinct target squares (see ChessBot.select_options), so a tap
	# on a destination unambiguously picks one.
	for opt in _options:
		if Rules.move_to(opt["move"]) == sq:
			option_chosen.emit(opt)
			get_viewport().set_input_as_handled()
			return
