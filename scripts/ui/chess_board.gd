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
const BADGE_FONT := preload("res://assets/fonts/OpenDyslexic-Bold.otf")

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
var _chosen_move := -1  # the move the player tapped; drawn on top after the reveal

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

# Cached coordinate labels (a1..h8 numbers/letters), shaped once into TextLines and
# rebuilt only when the cell size or board orientation changes (see _ensure_coords).
var _coord_cache: Array = []
var _coord_key := ""


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
	_chosen_move = -1
	queue_redraw()


func clear_options() -> void:
	_options = []
	_revealed = false
	_interactive = false
	_chosen_move = -1
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
	_draw_coords()
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


## Rank numbers (1-8) down the left column, file letters (a-h) along the bottom
## row, like printed boards. Labels are shaped ONCE into cached TextLines (offsets
## relative to _origin) and only rebuilt when the cell size or orientation changes,
## so the per-frame slide animation just blits them, no per-frame text shaping.
func _draw_coords() -> void:
	_ensure_coords()
	var ci := get_canvas_item()
	for e in _coord_cache:
		var tl: TextLine = e["tl"]
		var off: Vector2 = e["off"]
		var col: Color = e["color"]
		tl.draw(ci, _origin + off, col)


func _ensure_coords() -> void:
	var key := "%d:%s" % [int(_cell), flipped]
	if key == _coord_key:
		return
	_coord_key = key
	_coord_cache.clear()
	if _cell <= 0.0:
		return
	# Each label takes the OPPOSITE square's shade so it reads on light or dark.
	var fs := int(maxf(11.0, _cell * 0.2))
	var m := _cell * 0.06
	for v in 8:
		# Rank number in the top-left of the left-column square.
		var rank := (7 - v) if not flipped else v
		var rfile := 0 if not flipped else 7
		var rlight := ((rfile + rank) % 2) == 1
		var rtl := TextLine.new()
		rtl.add_string(str(rank + 1), BADGE_FONT, fs)
		_coord_cache.append({
			"tl": rtl,
			"off": Vector2(m, v * _cell + m),
			"color": UI.BOARD_DARK if rlight else UI.BOARD_LIGHT,
		})
		# File letter in the bottom-right of the bottom-row square.
		var file := v if not flipped else 7 - v
		var frank := 0 if not flipped else 7
		var flight := ((file + frank) % 2) == 1
		var ftl := TextLine.new()
		ftl.add_string(String.chr(97 + file), BADGE_FONT, fs)
		ftl.width = _cell - 2.0 * m
		ftl.alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_coord_cache.append({
			"tl": ftl,
			"off": Vector2(v * _cell + m, 8.0 * _cell - ftl.get_size().y - m),
			"color": UI.BOARD_DARK if flight else UI.BOARD_LIGHT,
		})


func _draw_highlights() -> void:
	# Each side's last move gets its own tint (amber = White, violet = Black).
	_draw_last_move(_last_white, UI.HL_LAST_WHITE)
	_draw_last_move(_last_black, UI.HL_LAST_BLACK)
	if check_square >= 0:
		draw_rect(_square_rect(check_square), UI.HL_CHECK)


func _draw_last_move(m: int, col: Color) -> void:
	if m >= 0:
		draw_rect(_square_rect(Rules.move_from(m)), col)
		draw_rect(_square_rect(Rules.move_to(m)), col)


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
	# Strict bottom-to-top layering: landing dots, then shafts, then heads. The dot
	# stays UNDER both the line and the triangle; a head must sit above every shaft
	# (two options can share a row/column). The player's chosen arrow is drawn last
	# and whole so it stays on top even where arrows cross.
	var others: Array = []
	var chosen: Dictionary = {}
	for opt in _options:
		if _revealed and int(opt["move"]) == _chosen_move:
			chosen = opt
		else:
			others.append(opt)
	for opt in others:  # pass 1: landing dots (bottom of everything)
		_draw_arrow_dot(int(opt["move"]), _arrow_color(opt))
	for opt in others:  # pass 2: shafts
		_draw_arrow_shaft(int(opt["move"]), _arrow_color(opt))
	for opt in others:  # pass 3: heads, above every shaft
		_draw_arrow_head(int(opt["move"]), _arrow_color(opt), _arrow_quality(opt))
	if not chosen.is_empty():  # the chosen arrow, whole, on top of everything
		_draw_arrow(int(chosen["move"]), _arrow_color(chosen), _arrow_quality(chosen))


## Arrow colour: one neutral accent before the reveal, the quality colour after.
func _arrow_color(opt: Dictionary) -> Color:
	if not _revealed:
		return UI.ACCENT
	match opt.get("quality", ""):
		"best": return UI.MOVE_BEST
		"decent": return UI.MOVE_DECENT
		"blunder": return UI.MOVE_BLUNDER
	return UI.ACCENT


func _arrow_quality(opt: Dictionary) -> String:
	return String(opt.get("quality", "")) if _revealed else ""


## The thin shaft line (dark outline + colour), drawn under every head. Geometry is
## kept inline (plain Vector2 locals, no per-frame heap allocation) since _draw_options
## runs every frame of the reveal slide.
func _draw_arrow_shaft(move: int, col: Color) -> void:
	var from := _square_center(Rules.move_from(move))
	var to := _square_center(Rules.move_to(move))
	var dir := (to - from).normalized()
	var line_from := from + dir * _cell * 0.15  # small gap from the source center
	var shaft_w := _cell * 0.11
	var e := _cell * 0.05
	draw_line(line_from, to, Color(0.04, 0.05, 0.08, 0.45), shaft_w + e, true)  # outline, slightly larger
	draw_line(line_from, to, Color(col, 1.0), shaft_w, true)


## The translucent landing circle at the target. Its own pass (before the shafts)
## so it sits UNDER both the line and the arrowhead, never between them.
func _draw_arrow_dot(move: int, col: Color) -> void:
	draw_circle(_square_center(Rules.move_to(move)), _cell * 0.46, Color(col, 0.42))


## The arrowhead: a dark shadow on the two LEADING edges only (base left open so the
## shaft flows into the head with no seam), then the solid colour triangle + symbol.
func _draw_arrow_head(move: int, col: Color, quality: String) -> void:
	var from := _square_center(Rules.move_from(move))
	var to := _square_center(Rules.move_to(move))
	var dir := (to - from).normalized()
	var perp := Vector2(-dir.y, dir.x)
	var base := to - dir * _cell * 0.30
	var hw := _cell * 0.22
	var tip := to + dir * _cell * 0.11
	var p1 := base + perp * hw
	var p2 := base - perp * hw
	var e := _cell * 0.05
	var outline := Color(0.04, 0.05, 0.08, 0.45)
	# Shadow only p1->tip and p2->tip (tip nudged forward); the base p1->p2 is left
	# open, so no dark bar is drawn across where the shaft meets the head.
	#var otip := tip + dir * e
	draw_line(p1, tip, outline, e, true)
	draw_line(p2, tip, outline, e, true)
	draw_colored_polygon(PackedVector2Array([tip, p1, p2]), Color(col, 1.0))
	if quality != "":
		_draw_quality_symbol(to, quality)


## A whole arrow (dot, shaft, head) for the chosen move, drawn last so nothing overlaps it.
func _draw_arrow(move: int, col: Color, quality: String) -> void:
	_draw_arrow_dot(move, col)
	_draw_arrow_shaft(move, col)
	_draw_arrow_head(move, col, quality)


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
			_chosen_move = int(opt["move"])  # so reveal() draws it on top of the others
			option_chosen.emit(opt)
			get_viewport().set_input_as_handled()
			return
