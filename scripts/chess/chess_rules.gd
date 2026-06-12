class_name ChessRules
extends RefCounted

## Self-contained chess rules engine — the single source of truth for legality.
##
## Pure GDScript, no external dependencies, no engine round-trips: it owns the
## board, generates strictly legal moves, detects all end conditions, and
## converts between FEN / UCI / SAN. The AI ([ChessBot]) and the UI both sit on
## top of this; the board never trusts a move it didn't generate.
##
## Board model: a flat 64-cell array. Index = rank * 8 + file, file 0 = a,
## rank 0 = rank 1. So a1 = 0, h1 = 7, a8 = 56, h8 = 63.
##
## Moves are packed into a single int for speed (no per-node allocations during
## search): from(6) | to(6)<<6 | promo(3)<<12 | flag(3)<<15. Use the move_*()
## helpers to read fields; never decode bits by hand elsewhere.
##
## This file is validated by a perft test suite — see HOW_TO.md. If you touch
## move generation, re-run perft before trusting it.

# --- Colors ---
const WHITE := 0
const BLACK := 1

# --- Piece types (low 3 bits of a piece code) ---
const PAWN := 1
const KNIGHT := 2
const BISHOP := 3
const ROOK := 4
const QUEEN := 5
const KING := 6
# A piece code is `type` for white, `type + 8` for black. 0 = empty.
const BLACK_FLAG := 8

# --- Castling-right bitmask ---
const CR_WK := 1
const CR_WQ := 2
const CR_BK := 4
const CR_BQ := 8

# --- Move flags ---
const F_NORMAL := 0
const F_DOUBLE := 1      ## pawn two-square advance (sets en-passant target)
const F_EP := 2          ## en-passant capture
const F_CASTLE_K := 3    ## king-side castle
const F_CASTLE_Q := 4    ## queen-side castle

# --- Outcome enum (result of a finished position) ---
enum Outcome { ONGOING, CHECKMATE, STALEMATE, DRAW_FIFTY, DRAW_REPETITION, DRAW_INSUFFICIENT }

const START_FEN := "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

# Direction tables (df, dr) reused by generation and attack tests.
const KNIGHT_D := [[1, 2], [2, 1], [2, -1], [1, -2], [-1, -2], [-2, -1], [-2, 1], [-1, 2]]
const KING_D := [[1, 0], [1, 1], [0, 1], [-1, 1], [-1, 0], [-1, -1], [0, -1], [1, -1]]
const BISHOP_D := [[1, 1], [1, -1], [-1, 1], [-1, -1]]
const ROOK_D := [[1, 0], [-1, 0], [0, 1], [0, -1]]

# --- Position state ---
var board: PackedByteArray            ## 64 piece codes
var side_to_move: int = WHITE
var castling: int = 0                 ## CR_* bitmask
var ep_square: int = -1               ## en-passant target square, or -1
var halfmove_clock: int = 0           ## plies since last pawn move / capture (50-move rule)
var fullmove_number: int = 1

# Per-square mask used to clear castling rights when a from/to touches it.
static var _castle_mask: PackedByteArray


func _init() -> void:
	if _castle_mask.is_empty():
		_build_castle_mask()
	reset_startpos()


static func _build_castle_mask() -> void:
	_castle_mask = PackedByteArray()
	_castle_mask.resize(64)
	for i in 64:
		_castle_mask[i] = 15  # keep all rights by default
	_castle_mask[0] = 15 & ~CR_WQ   # a1
	_castle_mask[7] = 15 & ~CR_WK   # h1
	_castle_mask[4] = 15 & ~(CR_WK | CR_WQ)  # e1
	_castle_mask[56] = 15 & ~CR_BQ  # a8
	_castle_mask[63] = 15 & ~CR_BK  # h8
	_castle_mask[60] = 15 & ~(CR_BK | CR_BQ)  # e8


# --- Static helpers on piece codes ---

static func piece_type(p: int) -> int:
	return p & 7

static func piece_color(p: int) -> int:
	return BLACK if (p & BLACK_FLAG) != 0 else WHITE

static func make_piece(type: int, color: int) -> int:
	return type + (BLACK_FLAG if color == BLACK else 0)

static func file_of(sq: int) -> int:
	return sq & 7

static func rank_of(sq: int) -> int:
	return sq >> 3

static func square_name(sq: int) -> String:
	return "%c%d" % [97 + (sq & 7), (sq >> 3) + 1]


# --- Move packing ---

static func pack_move(from: int, to: int, promo: int = 0, flag: int = 0) -> int:
	return from | (to << 6) | (promo << 12) | (flag << 15)

static func move_from(m: int) -> int:
	return m & 63

static func move_to(m: int) -> int:
	return (m >> 6) & 63

static func move_promo(m: int) -> int:
	return (m >> 12) & 7

static func move_flag(m: int) -> int:
	return (m >> 15) & 7


# --- Setup ---

func reset_startpos() -> void:
	set_fen(START_FEN)


func clone() -> ChessRules:
	var c := ChessRules.new()
	c.board = board.duplicate()
	c.side_to_move = side_to_move
	c.castling = castling
	c.ep_square = ep_square
	c.halfmove_clock = halfmove_clock
	c.fullmove_number = fullmove_number
	return c


func set_fen(fen: String) -> bool:
	var parts := fen.strip_edges().split(" ", false)
	if parts.size() < 4:
		return false
	board = PackedByteArray()
	board.resize(64)
	# Field 1: piece placement, rank 8 first.
	var rows := parts[0].split("/")
	if rows.size() != 8:
		return false
	for i in 8:
		var rank := 7 - i
		var file := 0
		for ch in rows[i]:
			if ch >= "1" and ch <= "8":
				file += ch.to_int()
			else:
				if file > 7:
					return false
				board[rank * 8 + file] = _char_to_piece(ch)
				file += 1
	# Field 2: side to move.
	side_to_move = WHITE if parts[1] == "w" else BLACK
	# Field 3: castling rights.
	castling = 0
	if parts[2] != "-":
		if "K" in parts[2]: castling |= CR_WK
		if "Q" in parts[2]: castling |= CR_WQ
		if "k" in parts[2]: castling |= CR_BK
		if "q" in parts[2]: castling |= CR_BQ
	# Field 4: en-passant target.
	ep_square = -1 if parts[3] == "-" else _name_to_square(parts[3])
	# Fields 5/6: clocks (optional).
	halfmove_clock = parts[4].to_int() if parts.size() > 4 else 0
	fullmove_number = parts[5].to_int() if parts.size() > 5 else 1
	return true


func get_fen() -> String:
	var rows: Array[String] = []
	for i in 8:
		var rank := 7 - i
		var row := ""
		var empty := 0
		for file in 8:
			var p := board[rank * 8 + file]
			if p == 0:
				empty += 1
			else:
				if empty > 0:
					row += str(empty)
					empty = 0
				row += _piece_to_char(p)
		if empty > 0:
			row += str(empty)
		rows.append(row)
	var placement := "/".join(rows)
	var stm := "w" if side_to_move == WHITE else "b"
	var cr := ""
	if castling & CR_WK: cr += "K"
	if castling & CR_WQ: cr += "Q"
	if castling & CR_BK: cr += "k"
	if castling & CR_BQ: cr += "q"
	if cr == "": cr = "-"
	var ep := "-" if ep_square < 0 else square_name(ep_square)
	return "%s %s %s %s %d %d" % [placement, stm, cr, ep, halfmove_clock, fullmove_number]


## A position key for threefold-repetition detection: everything that defines a
## position except the move clocks (placement, side, castling, ep).
func position_key() -> String:
	var f := get_fen().split(" ")
	return "%s %s %s %s" % [f[0], f[1], f[2], f[3]]


func piece_at(sq: int) -> int:
	return board[sq]


# --- Move generation ---

func generate_legal_moves() -> Array:
	var legal: Array = []
	var us := side_to_move
	for m in _generate_pseudo_legal():
		var u := make_move(m)
		if not is_square_attacked(king_square(us), 1 - us):
			legal.append(m)
		undo_move(m, u)
	return legal


func generate_legal_moves_from(sq: int) -> Array:
	var out: Array = []
	for m in generate_legal_moves():
		if move_from(m) == sq:
			out.append(m)
	return out


func _generate_pseudo_legal() -> Array:
	var moves: Array = []
	var us := side_to_move
	for sq in 64:
		var p := board[sq]
		if p == 0 or piece_color(p) != us:
			continue
		var t := piece_type(p)
		match t:
			PAWN:
				_gen_pawn(sq, us, moves)
			KNIGHT:
				_gen_jumper(sq, us, KNIGHT_D, moves)
			KING:
				_gen_jumper(sq, us, KING_D, moves)
				_gen_castles(sq, us, moves)
			BISHOP:
				_gen_slider(sq, us, BISHOP_D, moves)
			ROOK:
				_gen_slider(sq, us, ROOK_D, moves)
			QUEEN:
				_gen_slider(sq, us, BISHOP_D, moves)
				_gen_slider(sq, us, ROOK_D, moves)
	return moves


func _gen_pawn(sq: int, us: int, moves: Array) -> void:
	var f := sq & 7
	var r := sq >> 3
	var dir := 1 if us == WHITE else -1
	var start_rank := 1 if us == WHITE else 6
	var promo_rank := 7 if us == WHITE else 0
	# Single push.
	var one := sq + dir * 8
	if _on_board_rank(r + dir) and board[one] == 0:
		_add_pawn_move(sq, one, promo_rank, F_NORMAL, moves)
		# Double push.
		if r == start_rank:
			var two := sq + dir * 16
			if board[two] == 0:
				moves.append(pack_move(sq, two, 0, F_DOUBLE))
	# Captures (incl. promotions and en passant).
	for df in [-1, 1]:
		var nf: int = f + df
		var nr := r + dir
		if nf < 0 or nf > 7 or not _on_board_rank(nr):
			continue
		var to: int = nr * 8 + nf
		var target := board[to]
		if target != 0 and piece_color(target) != us:
			_add_pawn_move(sq, to, promo_rank, F_NORMAL, moves)
		elif to == ep_square:
			moves.append(pack_move(sq, to, 0, F_EP))


func _add_pawn_move(from: int, to: int, promo_rank: int, flag: int, moves: Array) -> void:
	if (to >> 3) == promo_rank:
		for promo in [QUEEN, ROOK, BISHOP, KNIGHT]:
			moves.append(pack_move(from, to, promo, flag))
	else:
		moves.append(pack_move(from, to, 0, flag))


func _gen_jumper(sq: int, us: int, deltas: Array, moves: Array) -> void:
	var f := sq & 7
	var r := sq >> 3
	for d in deltas:
		var nf: int = f + d[0]
		var nr: int = r + d[1]
		if nf < 0 or nf > 7 or nr < 0 or nr > 7:
			continue
		var to: int = nr * 8 + nf
		var target := board[to]
		if target == 0 or piece_color(target) != us:
			moves.append(pack_move(sq, to))


func _gen_slider(sq: int, us: int, dirs: Array, moves: Array) -> void:
	var f := sq & 7
	var r := sq >> 3
	for d in dirs:
		var nf: int = f + d[0]
		var nr: int = r + d[1]
		while nf >= 0 and nf <= 7 and nr >= 0 and nr <= 7:
			var to: int = nr * 8 + nf
			var target := board[to]
			if target == 0:
				moves.append(pack_move(sq, to))
			else:
				if piece_color(target) != us:
					moves.append(pack_move(sq, to))
				break
			nf += d[0]
			nr += d[1]


func _gen_castles(sq: int, us: int, moves: Array) -> void:
	var them := 1 - us
	if us == WHITE and sq == 4:
		if (castling & CR_WK) and board[5] == 0 and board[6] == 0:
			if not is_square_attacked(4, them) and not is_square_attacked(5, them) and not is_square_attacked(6, them):
				moves.append(pack_move(4, 6, 0, F_CASTLE_K))
		if (castling & CR_WQ) and board[3] == 0 and board[2] == 0 and board[1] == 0:
			if not is_square_attacked(4, them) and not is_square_attacked(3, them) and not is_square_attacked(2, them):
				moves.append(pack_move(4, 2, 0, F_CASTLE_Q))
	elif us == BLACK and sq == 60:
		if (castling & CR_BK) and board[61] == 0 and board[62] == 0:
			if not is_square_attacked(60, them) and not is_square_attacked(61, them) and not is_square_attacked(62, them):
				moves.append(pack_move(60, 62, 0, F_CASTLE_K))
		if (castling & CR_BQ) and board[59] == 0 and board[58] == 0 and board[57] == 0:
			if not is_square_attacked(60, them) and not is_square_attacked(59, them) and not is_square_attacked(58, them):
				moves.append(pack_move(60, 58, 0, F_CASTLE_Q))


func _on_board_rank(r: int) -> bool:
	return r >= 0 and r <= 7


# --- Attack detection ---

## Is `sq` attacked by any piece of color `by`?
func is_square_attacked(sq: int, by: int) -> bool:
	var f := sq & 7
	var r := sq >> 3
	# Pawn attacks: a `by` pawn sits one rank toward its own side and one file over.
	var pdir := -1 if by == WHITE else 1  # rank offset from sq back to the attacking pawn
	for df in [-1, 1]:
		var nf: int = f + df
		var nr := r + pdir
		if nf >= 0 and nf <= 7 and nr >= 0 and nr <= 7:
			if board[nr * 8 + nf] == make_piece(PAWN, by):
				return true
	# Knight attacks.
	for d in KNIGHT_D:
		var nf: int = f + d[0]
		var nr: int = r + d[1]
		if nf >= 0 and nf <= 7 and nr >= 0 and nr <= 7:
			if board[nr * 8 + nf] == make_piece(KNIGHT, by):
				return true
	# King attacks.
	for d in KING_D:
		var nf: int = f + d[0]
		var nr: int = r + d[1]
		if nf >= 0 and nf <= 7 and nr >= 0 and nr <= 7:
			if board[nr * 8 + nf] == make_piece(KING, by):
				return true
	# Sliding attacks: bishops/queens on diagonals, rooks/queens on files/ranks.
	if _ray_hits(f, r, BISHOP_D, by, BISHOP):
		return true
	if _ray_hits(f, r, ROOK_D, by, ROOK):
		return true
	return false


func _ray_hits(f: int, r: int, dirs: Array, by: int, slider_type: int) -> bool:
	var slider := make_piece(slider_type, by)
	var queen := make_piece(QUEEN, by)
	for d in dirs:
		var nf: int = f + d[0]
		var nr: int = r + d[1]
		while nf >= 0 and nf <= 7 and nr >= 0 and nr <= 7:
			var p := board[nr * 8 + nf]
			if p != 0:
				if p == slider or p == queen:
					return true
				break
			nf += d[0]
			nr += d[1]
	return false


func king_square(color: int) -> int:
	var k := make_piece(KING, color)
	for sq in 64:
		if board[sq] == k:
			return sq
	return -1


func is_in_check(color: int = -1) -> bool:
	if color < 0:
		color = side_to_move
	return is_square_attacked(king_square(color), 1 - color)


# --- Make / undo (reversible; safe for recursive search) ---

func make_move(m: int) -> Dictionary:
	var from := m & 63
	var to := (m >> 6) & 63
	var promo := (m >> 12) & 7
	var flag := (m >> 15) & 7
	var piece := board[from]
	var us := side_to_move
	var ptype := piece & 7

	var undo := {
		"captured_piece": 0,
		"captured_sq": -1,
		"castling": castling,
		"ep": ep_square,
		"halfmove": halfmove_clock,
	}

	# Capture (normal or en passant).
	if flag == F_EP:
		var cap_sq := to - 8 if us == WHITE else to + 8
		undo["captured_piece"] = board[cap_sq]
		undo["captured_sq"] = cap_sq
		board[cap_sq] = 0
	elif board[to] != 0:
		undo["captured_piece"] = board[to]
		undo["captured_sq"] = to

	# 50-move clock.
	if ptype == PAWN or undo["captured_piece"] != 0:
		halfmove_clock = 0
	else:
		halfmove_clock += 1

	# Move the piece.
	board[to] = piece
	board[from] = 0

	# Promotion.
	if promo != 0:
		board[to] = make_piece(promo, us)

	# Castling: relocate the rook.
	if flag == F_CASTLE_K:
		if us == WHITE:
			board[5] = board[7]; board[7] = 0
		else:
			board[61] = board[63]; board[63] = 0
	elif flag == F_CASTLE_Q:
		if us == WHITE:
			board[3] = board[0]; board[0] = 0
		else:
			board[59] = board[56]; board[56] = 0

	# En-passant target (only after a double push).
	ep_square = -1
	if flag == F_DOUBLE:
		ep_square = (from + 8) if us == WHITE else (from - 8)

	# Update castling rights from the squares touched.
	castling &= _castle_mask[from]
	castling &= _castle_mask[to]

	# Flip side, advance move number.
	side_to_move = 1 - us
	if us == BLACK:
		fullmove_number += 1

	return undo


func undo_move(m: int, undo: Dictionary) -> void:
	var from := m & 63
	var to := (m >> 6) & 63
	var promo := (m >> 12) & 7
	var flag := (m >> 15) & 7

	side_to_move = 1 - side_to_move
	var us := side_to_move
	if us == BLACK:
		fullmove_number -= 1

	# Move the piece back (promotions revert to a pawn).
	var moved := board[to]
	if promo != 0:
		moved = make_piece(PAWN, us)
	board[from] = moved
	board[to] = 0

	# Restore any captured piece (en passant restores on a different square).
	if undo["captured_piece"] != 0:
		board[undo["captured_sq"]] = undo["captured_piece"]

	# Undo the rook relocation for castling.
	if flag == F_CASTLE_K:
		if us == WHITE:
			board[7] = board[5]; board[5] = 0
		else:
			board[63] = board[61]; board[61] = 0
	elif flag == F_CASTLE_Q:
		if us == WHITE:
			board[0] = board[3]; board[3] = 0
		else:
			board[56] = board[59]; board[59] = 0

	castling = undo["castling"]
	ep_square = undo["ep"]
	halfmove_clock = undo["halfmove"]


# --- Outcomes ---

func is_checkmate() -> bool:
	return is_in_check() and generate_legal_moves().is_empty()


func is_stalemate() -> bool:
	return not is_in_check() and generate_legal_moves().is_empty()


## Dead-drawn material: K vs K, K+single-minor vs K, and any number of bishops
## confined to a SINGLE square colour with no knights (e.g. KB vs KB same colour).
func is_insufficient_material() -> bool:
	var knights := 0
	var bishops := 0
	var bishop_colors := 0  # bit 0 = a bishop on a dark square, bit 1 = on a light square
	for sq in 64:
		var p := board[sq]
		if p == 0:
			continue
		var t := piece_type(p)
		if t == PAWN or t == ROOK or t == QUEEN:
			return false
		if t == KNIGHT:
			knights += 1
		elif t == BISHOP:
			bishops += 1
			bishop_colors |= 1 << (((sq & 7) + (sq >> 3)) & 1)
	if knights + bishops <= 1:
		return true
	# Bishops only, all on one colour → no checkmate is possible.
	if knights == 0 and bishop_colors != 3:
		return true
	return false


## Compose the final outcome. `threefold` is supplied by the game layer, which
## tracks the history of [position_key]s across real moves.
func outcome(threefold: bool = false) -> Outcome:
	if generate_legal_moves().is_empty():
		return Outcome.CHECKMATE if is_in_check() else Outcome.STALEMATE
	if is_insufficient_material():
		return Outcome.DRAW_INSUFFICIENT
	if halfmove_clock >= 100:
		return Outcome.DRAW_FIFTY
	if threefold:
		return Outcome.DRAW_REPETITION
	return Outcome.ONGOING


# --- Notation ---

func move_to_uci(m: int) -> String:
	var s := square_name(m & 63) + square_name((m >> 6) & 63)
	var promo := (m >> 12) & 7
	if promo != 0:
		s += _promo_char(promo)
	return s


func _promo_char(promo: int) -> String:
	match promo:
		QUEEN: return "q"
		ROOK: return "r"
		BISHOP: return "b"
		KNIGHT: return "n"
	return ""


## Parse a UCI move string against the current position; returns the matching
## legal move (with correct flags) or -1 if it isn't legal here.
func move_from_uci(uci: String) -> int:
	if uci.length() < 4:
		return -1
	var from := _name_to_square(uci.substr(0, 2))
	var to := _name_to_square(uci.substr(2, 2))
	var promo := 0
	if uci.length() >= 5:
		match uci[4]:
			"q": promo = QUEEN
			"r": promo = ROOK
			"b": promo = BISHOP
			"n": promo = KNIGHT
	for m in generate_legal_moves():
		if move_from(m) == from and move_to(m) == to and move_promo(m) == promo:
			return m
	return -1


## Standard Algebraic Notation, with check/mate suffix. Pass the current legal
## move list to avoid regenerating it (used for disambiguation).
func to_san(m: int, legal: Array = []) -> String:
	if legal.is_empty():
		legal = generate_legal_moves()
	var from := move_from(m)
	var to := move_to(m)
	var flag := move_flag(m)
	if flag == F_CASTLE_K:
		return _san_suffix("O-O", m)
	if flag == F_CASTLE_Q:
		return _san_suffix("O-O-O", m)

	var piece := board[from]
	var ptype := piece_type(piece)
	var is_capture := board[to] != 0 or flag == F_EP
	var san := ""

	if ptype == PAWN:
		if is_capture:
			san += "abcdefgh"[file_of(from)] + "x"
		san += square_name(to)
		var promo := move_promo(m)
		if promo != 0:
			san += "=" + _promo_char(promo).to_upper()
	else:
		san += "  NBRQK"[ptype]  # index 2..6 -> N,B,R,Q,K
		san += _disambiguation(m, ptype, from, to, legal)
		if is_capture:
			san += "x"
		san += square_name(to)
	return _san_suffix(san, m)


func _disambiguation(m: int, ptype: int, from: int, to: int, legal: Array) -> String:
	var same_file := false
	var same_rank := false
	var ambiguous := false
	for other in legal:
		if other == m:
			continue
		if move_to(other) != to:
			continue
		var of := move_from(other)
		if piece_type(board[of]) != ptype:
			continue
		ambiguous = true
		if file_of(of) == file_of(from):
			same_file = true
		if rank_of(of) == rank_of(from):
			same_rank = true
	if not ambiguous:
		return ""
	if not same_file:
		return "abcdefgh"[file_of(from)]
	if not same_rank:
		return str(rank_of(from) + 1)
	return square_name(from)


func _san_suffix(san: String, m: int) -> String:
	# Make the move to test for check / checkmate, then revert.
	var u := make_move(m)
	var suffix := ""
	if is_in_check():
		suffix = "#" if generate_legal_moves().is_empty() else "+"
	undo_move(m, u)
	return san + suffix


# --- perft (move-generation self-test; see HOW_TO.md) ---

func perft(depth: int) -> int:
	if depth == 0:
		return 1
	var nodes := 0
	for m in generate_legal_moves():
		var u := make_move(m)
		nodes += perft(depth - 1)
		undo_move(m, u)
	return nodes


# --- Char <-> piece helpers ---

func _char_to_piece(ch: String) -> int:
	var color := WHITE if ch == ch.to_upper() else BLACK
	var t := 0
	match ch.to_upper():
		"P": t = PAWN
		"N": t = KNIGHT
		"B": t = BISHOP
		"R": t = ROOK
		"Q": t = QUEEN
		"K": t = KING
	return make_piece(t, color)


func _piece_to_char(p: int) -> String:
	var c := " pnbrqk"[piece_type(p)]
	return c.to_upper() if piece_color(p) == WHITE else c


func _name_to_square(name: String) -> int:
	var file := name.unicode_at(0) - 97  # 'a'
	var rank := name.unicode_at(1) - 49   # '1'
	return rank * 8 + file
