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
var _anim_tween: Tween = null  ## the single owned slide tween (killed before a new one starts)
var _anim_active := false
var _anim_from := -1
var _anim_to := -1
var _anim_piece := 0
var _anim_progress := 0.0
# Second slider: the rook during a castle, so it moves WITH the king (same progress).
var _anim2_from := -1
var _anim2_to := -1
var _anim2_piece := 0

# Checkmate "shatter": the losing king's sprite splits into a grid of fragments that fly
# apart, spin, and fade (the satisfying flourish before the review dialog). _explode_t 0→1.
var _explode_active := false
var _explode_sq := -1
var _explode_piece := 0
var _explode_t := 0.0

var _cell := 0.0
var _origin := Vector2.ZERO

# Best-replies "line mode": a cue (accent frame) that the board is replaying the engine's line.
var _in_line_mode := false
const LINE_FRAME_W := 6.0       ## accent frame drawn around the board while the line is showing
var _line_frame: StyleBoxFlat = null

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
	_explode_active = false
	_explode_sq = -1
	queue_redraw()


func reveal() -> void:
	_revealed = true
	_interactive = false
	queue_redraw()


## Turn the best-replies "line mode" frame on/off (review). Just a visual cue that the board is
## replaying the engine's line, the playback is driven by game.gd's media-control buttons.
func set_line_mode(on: bool) -> void:
	_in_line_mode = on
	queue_redraw()  # show/hide the accent frame around the board


## A rounded accent border framing the board while the best-replies line is showing, so it's clear
## the board is a replay of the engine's line rather than the live position.
func _draw_line_frame() -> void:
	if _line_frame == null:
		_line_frame = StyleBoxFlat.new()
		_line_frame.bg_color = Color(0, 0, 0, 0)  # frame only, no fill
		_line_frame.set_border_width_all(int(LINE_FRAME_W))
		_line_frame.border_color = UI.ACCENT
		_line_frame.set_corner_radius_all(16)
	var used := _cell * 8.0
	var g := LINE_FRAME_W * 0.5  # straddle the board edge (half in, half out)
	draw_style_box(_line_frame, Rect2(_origin - Vector2(g, g), Vector2(used + 2.0 * g, used + 2.0 * g)))


## Slide the piece of `move` from its origin to its target over `duration` secs.
## Await-able. The board keeps showing the pre-move position underneath.
func animate_move(move: int, duration: float) -> void:
	if rules == null:
		return
	_setup_slide_targets(move)
	await _run_slide(duration)


## Resolve the from/to squares for the slide overlay (plus the castling rook, slid in sync).
func _setup_slide_targets(move: int) -> void:
	_anim_from = Rules.move_from(move)
	_anim_to = Rules.move_to(move)
	_anim_piece = rules.board[_anim_from]
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


## Park the slide overlay at a specific progress (no tween) for scrubbing the best-replies line
## frame-by-frame: set_rules() to the pre-move position first, then call this each frame.
func show_move_frame(move: int, progress: float) -> void:
	if rules == null:
		return
	if _anim_tween != null and _anim_tween.is_valid():
		_anim_tween.kill()
	_setup_slide_targets(move)
	_anim_active = true
	# Ease in/out (sine) so each move accelerates then decelerates, like the live-play slide, rather
	# than the constant-speed slide the linear timeline would otherwise give.
	var p := clampf(progress, 0.0, 1.0)
	_anim_progress = 0.5 - 0.5 * cos(p * PI)
	queue_redraw()


## Reverse-slide a move, for stepping BACKWARD in the review: the piece sitting on the move's
## destination glides back to its origin. The board still shows the post-move position underneath;
## the caller swaps to the pre-move position once this returns (so a captured piece reappears then,
## and a castled rook snaps back). Kept deliberately simple for a quick review step.
func animate_unmove(move: int, duration: float) -> void:
	if rules == null:
		return
	_anim_from = Rules.move_to(move)    # the piece currently sits on the destination
	_anim_to = Rules.move_from(move)    # glide it back to where it came from
	_anim_piece = rules.board[_anim_from]
	_anim2_from = -1
	await _run_slide(duration)


## Shared slide driver: one owned tween (killed before a new one starts, so two never race over the
## shared _anim_progress). Leaves the piece parked at the destination until end_animation().
func _run_slide(duration: float) -> void:
	_anim_progress = 0.0
	_anim_active = true
	if _anim_tween != null and _anim_tween.is_valid():
		_anim_tween.kill()
	_anim_tween = create_tween()
	_anim_tween.tween_method(_set_anim_progress, 0.0, 1.0, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await _anim_tween.finished
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


## Shatter the piece on `square` into spinning, fading fragments of its own sprite (the
## checkmate flourish before the review dialog). Await-able; the piece is lifted out of the
## static draw while it bursts and stays gone until the next game (clear_options resets it).
## No-op on an empty square.
func explode_piece(square: int, duration := 0.7) -> void:
	if rules == null or square < 0 or rules.board[square] == 0:
		return
	_explode_sq = square
	_explode_piece = rules.board[square]
	_explode_t = 0.0
	_explode_active = true
	var tw := create_tween()
	tw.tween_method(_set_explode_t, 0.0, 1.0, duration)
	await tw.finished
	# Leave it parked (fragments fully faded → nothing drawn, king stays gone) until the
	# review dialog covers the board and the next game calls clear_options().


func _set_explode_t(v: float) -> void:
	_explode_t = v
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
	if _in_line_mode:
		_draw_line_frame()  # cue that the board is replaying the best-replies line
	if _explode_active:
		_draw_explosion()


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
		if _explode_active and sq == _explode_sq:
			continue  # the shattering king is drawn by _draw_explosion()
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


## Draw a piece partway from `from_sq` to `to_sq` at the shared (eased) slide progress.
func _draw_slider(piece: int, from_sq: int, to_sq: int) -> void:
	var tex: Texture2D = _tex.get(piece)
	if tex == null:
		return
	var pos := _square_rect(from_sq).position.lerp(_square_rect(to_sq).position, _anim_progress)
	draw_texture_rect(tex, Rect2(pos, Vector2(_cell, _cell)), false)


## The checkmate shatter: a quick flash + shockwave ring, then the king's sprite split into
## an N×N grid of fragments flung radially with gravity, each spinning and fading out. The
## per-fragment jitter is a deterministic function of its index, so it's stable frame to frame.
func _draw_explosion() -> void:
	var tex: Texture2D = _tex.get(_explode_piece)
	if tex == null:
		return
	var rect := _square_rect(_explode_sq)
	var center := rect.position + rect.size * 0.5
	var t := _explode_t
	# Flash, then an expanding shockwave ring, both under the debris.
	if t < 0.15:
		draw_circle(center, _cell * 0.55, Color(1.0, 1.0, 0.85, (0.15 - t) / 0.15 * 0.6))
	if t < 0.6:
		var rt := t / 0.6
		draw_arc(center, _cell * (0.25 + rt * 1.1), 0.0, TAU, 40,
			Color(1.0, 0.95, 0.75, (1.0 - rt) * 0.5), maxf(2.0, _cell * 0.06 * (1.0 - rt)), true)
	# Sprite fragments.
	var n := 4
	var frag := rect.size / float(n)
	var src_cell := tex.get_size() / float(n)
	var burst := 1.0 - pow(1.0 - t, 2.0)                  # fast out, slowing
	var fade: float = clampf((1.0 - t) / 0.45, 0.0, 1.0)  # hold, then fade over the last 45%
	var gravity := _cell * 2.4
	for i in n:
		for j in n:
			var home := rect.position + Vector2((j + 0.5) * frag.x, (i + 0.5) * frag.y)
			var fseed := i * n + j
			var ang := atan2(home.y - center.y, home.x - center.x) + sin(fseed * 2.3) * 0.5
			var dir := Vector2(cos(ang), sin(ang))
			if home.distance_to(center) < 1.0:            # the middle fragment: shoot it up
				dir = Vector2(sin(fseed) * 0.4, -1.0).normalized()
			var speed := _cell * (1.0 + 0.6 * absf(sin(fseed * 1.7)))
			var spin := (1.0 if fseed % 2 == 0 else -1.0) * (PI * 1.5 + absf(cos(fseed)) * PI)
			var pos := home + dir * speed * burst + Vector2(0.0, gravity * t * t * 0.5)
			draw_set_transform(pos, spin * t, Vector2.ONE)
			draw_texture_rect_region(tex, Rect2(-frag * 0.5, frag),
				Rect2(Vector2(j, i) * src_cell, src_cell), Color(1, 1, 1, fade))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


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
	# Resolve the tap by destination square. Options are built with DISTINCT targets (puzzle
	# _build_options / ChessBot.select_options), so normally exactly one matches. Best-effort guard if
	# two ever share a target: prefer the "best" option, so an ambiguous tap gives the player the right
	# move instead of picking at random.
	var hit: Dictionary = {}
	for opt in _options:
		if Rules.move_to(opt["move"]) == sq:
			var is_best: bool = String(opt.get("quality", "")) == "best"
			if hit.is_empty() or is_best:
				hit = opt
			if is_best:
				break
	if hit.is_empty():
		return
	_chosen_move = int(hit["move"])  # so reveal() draws it on top of the others
	option_chosen.emit(hit)
	get_viewport().set_input_as_handled()
