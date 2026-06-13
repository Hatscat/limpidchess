class_name ChessBot
extends RefCounted

## The opponent's brain AND the move-ranking oracle behind the 3-option mechanic.
##
## A compact negamax + alpha-beta search over [ChessRules], with a material +
## piece-square-table evaluation. Two public jobs:
##   1. choose_move()  — pick the bot's reply, weakened per its `weakness` so the
##      easy bots feel human and beatable.
##   2. rank_moves() / select_options() / grade_move() — evaluate every legal
##      move for the PLAYER so we can show "best / not bad / blunder" arrows and
##      grade what they actually played.
##
## Scores are in centipawns. Inside the search they are relative to the side to
## move (negamax). rank_moves() returns scores from the moving side's view, so a
## bigger score is always "better for whoever is choosing".

const INF := 1000000
const MATE := 100000

## Fixed depth used to analyse the player's options & grade their move, so the
## quality of the three arrows doesn't depend on which bot they're facing.
const ANALYSIS_DEPTH := 3

# Centipawn-loss bands (vs the best move) for the three options and for grading.
const DECENT_MIN := 20
const DECENT_MAX := 90
const BLUNDER_MIN := 120
const BLUNDER_MAX := 500

# Material values, indexed by ChessRules piece type (1=pawn … 6=king).
const VALUES := [0, 100, 320, 330, 500, 900, 0]

# --- Piece-square tables (Michniewski, written rank-8-first) ---
# White reads TABLE[sq ^ 56]; Black reads TABLE[sq]. See _evaluate_white().
const PST := {
	ChessRules.PAWN: [
		0, 0, 0, 0, 0, 0, 0, 0,
		50, 50, 50, 50, 50, 50, 50, 50,
		10, 10, 20, 30, 30, 20, 10, 10,
		5, 5, 10, 25, 25, 10, 5, 5,
		0, 0, 0, 20, 20, 0, 0, 0,
		5, -5, -10, 0, 0, -10, -5, 5,
		5, 10, 10, -20, -20, 10, 10, 5,
		0, 0, 0, 0, 0, 0, 0, 0,
	],
	ChessRules.KNIGHT: [
		-50, -40, -30, -30, -30, -30, -40, -50,
		-40, -20, 0, 0, 0, 0, -20, -40,
		-30, 0, 10, 15, 15, 10, 0, -30,
		-30, 5, 15, 20, 20, 15, 5, -30,
		-30, 0, 15, 20, 20, 15, 0, -30,
		-30, 5, 10, 15, 15, 10, 5, -30,
		-40, -20, 0, 5, 5, 0, -20, -40,
		-50, -40, -30, -30, -30, -30, -40, -50,
	],
	ChessRules.BISHOP: [
		-20, -10, -10, -10, -10, -10, -10, -20,
		-10, 0, 0, 0, 0, 0, 0, -10,
		-10, 0, 5, 10, 10, 5, 0, -10,
		-10, 5, 5, 10, 10, 5, 5, -10,
		-10, 0, 10, 10, 10, 10, 0, -10,
		-10, 10, 10, 10, 10, 10, 10, -10,
		-10, 5, 0, 0, 0, 0, 5, -10,
		-20, -10, -10, -10, -10, -10, -10, -20,
	],
	ChessRules.ROOK: [
		0, 0, 0, 0, 0, 0, 0, 0,
		5, 10, 10, 10, 10, 10, 10, 5,
		-5, 0, 0, 0, 0, 0, 0, -5,
		-5, 0, 0, 0, 0, 0, 0, -5,
		-5, 0, 0, 0, 0, 0, 0, -5,
		-5, 0, 0, 0, 0, 0, 0, -5,
		-5, 0, 0, 0, 0, 0, 0, -5,
		0, 0, 0, 5, 5, 0, 0, 0,
	],
	ChessRules.QUEEN: [
		-20, -10, -10, -5, -5, -10, -10, -20,
		-10, 0, 0, 0, 0, 0, 0, -10,
		-10, 0, 5, 5, 5, 5, 0, -10,
		-5, 0, 5, 5, 5, 5, 0, -5,
		0, 0, 5, 5, 5, 5, 0, -5,
		-10, 5, 5, 5, 5, 5, 0, -10,
		-10, 0, 5, 0, 0, 0, 0, -10,
		-20, -10, -10, -5, -5, -10, -10, -20,
	],
	ChessRules.KING: [
		-30, -40, -40, -50, -50, -40, -40, -30,
		-30, -40, -40, -50, -50, -40, -40, -30,
		-30, -40, -40, -50, -50, -40, -40, -30,
		-30, -40, -40, -50, -50, -40, -40, -30,
		-20, -30, -30, -40, -40, -30, -30, -20,
		-10, -20, -20, -20, -20, -20, -20, -10,
		20, 20, 0, 0, 0, 0, 20, 20,
		20, 30, 10, 0, 0, 10, 30, 20,
	],
}


# --- Public API ---

## The bot's reply for the given position, weakened by `weakness` (0..1).
func choose_move(rules: ChessRules, depth: int, weakness: float) -> int:
	var ranked := rank_moves(rules, depth)
	if ranked.is_empty():
		return -1
	if weakness <= 0.001 or ranked.size() == 1:
		return ranked[0]["move"]
	# Real beginners sometimes just blunder outright.
	if randf() < weakness * 0.25:
		return ranked[randi() % ranked.size()]["move"]
	# Otherwise sample from moves within a weakness-widened window, biased to good ones.
	var best_score: int = ranked[0]["score"]
	var max_drop := int(round(weakness * 250.0))
	var pool: Array = []
	for e in ranked:
		if best_score - int(e["score"]) <= max_drop:
			pool.append(e)
	var temp: float = lerp(40.0, 200.0, weakness)
	var total := 0.0
	var weights: Array = []
	for e in pool:
		var w: float = exp(float(int(e["score"]) - best_score) / temp)
		weights.append(w)
		total += w
	var r := randf() * total
	var acc := 0.0
	for i in pool.size():
		acc += weights[i]
		if r <= acc:
			return pool[i]["move"]
	return pool[0]["move"]


## Every legal move scored from the moving side's perspective, sorted best→worst.
## Used for the 3-option arrows and for grading the player's move.
func rank_moves(rules: ChessRules, depth: int) -> Array:
	var moves := rules.generate_legal_moves()
	_order_moves(rules, moves)
	var out: Array = []
	for m in moves:
		var u := rules.make_move(m)
		# Full window at the root so every move gets an exact (un-pruned) score.
		var score := -_negamax(rules, depth - 1, -INF, INF, 1)
		rules.undo_move(m, u)
		out.append({"move": m, "score": score})
	out.sort_custom(func(a, b): return a["score"] > b["score"])
	return out


## From a ranked list, pick three distinct options for the arrows:
## best, a "not bad" alternative, and a believable blunder. Returns a dict with
## keys best/decent/blunder, each a move int (decent/blunder may be -1 if the
## position is too forcing to offer a real alternative).
static func select_options(ranked: Array) -> Dictionary:
	var result := {"best": -1, "decent": -1, "blunder": -1}
	if ranked.is_empty():
		return result
	var best_move: int = ranked[0]["move"]
	var best_score: int = ranked[0]["score"]
	result["best"] = best_move
	# Every option must land on a DISTINCT target square, so a tap on the board
	# unambiguously identifies one move (incl. promotion variants e8=Q vs e8=N,
	# and two pieces that can reach the same square).
	var used: Array = [ChessRules.move_to(best_move)]

	# "Not bad": closest move to the middle of the decent band; else the best
	# remaining move with a distinct target.
	var decent := _pick_in_band(ranked, best_score, DECENT_MIN, DECENT_MAX, used)
	if decent == -1:
		decent = _pick_first_distinct(ranked, used)
	result["decent"] = decent
	if decent != -1:
		used.append(ChessRules.move_to(decent))

	# "Blunder": loses real material but isn't necessarily the single worst, so it
	# stays a believable trap rather than an obvious giveaway.
	var blunder := _pick_in_band(ranked, best_score, BLUNDER_MIN, BLUNDER_MAX, used)
	if blunder == -1:
		blunder = _pick_worst_distinct(ranked, best_score, used)
	result["blunder"] = blunder
	return result


## Move (after the best) closest to the middle of [lo, hi] centipawn-loss, whose
## target square isn't already used. -1 if none.
static func _pick_in_band(ranked: Array, best_score: int, lo: int, hi: int, used: Array) -> int:
	var pick := -1
	var dist := 1 << 30
	@warning_ignore("integer_division")
	var mid: int = (lo + hi) / 2
	for i in range(1, ranked.size()):
		var m: int = ranked[i]["move"]
		if ChessRules.move_to(m) in used:
			continue
		var loss: int = best_score - int(ranked[i]["score"])
		if loss >= lo and loss <= hi:
			var d: int = abs(loss - mid)
			if d < dist:
				dist = d
				pick = m
	return pick


## First move after the best whose target square isn't already used.
static func _pick_first_distinct(ranked: Array, used: Array) -> int:
	for i in range(1, ranked.size()):
		var m: int = ranked[i]["move"]
		if not (ChessRules.move_to(m) in used):
			return m
	return -1


## Worst-scoring move (distinct target) that loses at least DECENT_MAX cp.
static func _pick_worst_distinct(ranked: Array, best_score: int, used: Array) -> int:
	for i in range(ranked.size() - 1, 0, -1):
		var m: int = ranked[i]["move"]
		if ChessRules.move_to(m) in used:
			continue
		if best_score - int(ranked[i]["score"]) >= DECENT_MAX:
			return m
	return -1


## Grade a move the player actually made, against the ranked list.
## Returns { label, cp_loss, best_move }. label ∈ Best/Great/Good/Inaccuracy/Mistake/Blunder.
static func grade_move(ranked: Array, played: int) -> Dictionary:
	if ranked.is_empty():
		return {"label": "Good", "cp_loss": 0, "best_move": -1}
	var best_score: int = ranked[0]["score"]
	var best_move: int = ranked[0]["move"]
	var played_score: int = best_score
	for e in ranked:
		if e["move"] == played:
			played_score = e["score"]
			break
	var cp_loss: int = max(0, best_score - played_score)
	var label := "Blunder"
	if cp_loss <= 10:
		label = "Best"
	elif cp_loss <= 40:
		label = "Great"
	elif cp_loss <= DECENT_MAX:
		label = "Good"
	elif cp_loss <= BLUNDER_MIN:
		label = "Inaccuracy"
	elif cp_loss <= 250:
		label = "Mistake"
	return {"label": label, "cp_loss": cp_loss, "best_move": best_move}


# --- Search ---

func _negamax(rules: ChessRules, depth: int, alpha: int, beta: int, ply: int) -> int:
	if depth <= 0:
		return _eval_side_to_move(rules)
	var moves := rules.generate_legal_moves()
	if moves.is_empty():
		# Checkmate (prefer slower mates via ply) or stalemate.
		return -MATE + ply if rules.is_in_check() else 0
	_order_moves(rules, moves)
	var best := -INF
	for m in moves:
		var u := rules.make_move(m)
		var score := -_negamax(rules, depth - 1, -beta, -alpha, ply + 1)
		rules.undo_move(m, u)
		if score > best:
			best = score
		if best > alpha:
			alpha = best
		if alpha >= beta:
			break
	return best


func _eval_side_to_move(rules: ChessRules) -> int:
	var s := _evaluate_white(rules)
	return s if rules.side_to_move == ChessRules.WHITE else -s


## Static evaluation from White's perspective (positive = good for White).
func _evaluate_white(rules: ChessRules) -> int:
	var score := 0
	for sq in 64:
		var p: int = rules.board[sq]
		if p == 0:
			continue
		var t := ChessRules.piece_type(p)
		var val: int = VALUES[t] + PST[t][sq ^ 56] if ChessRules.piece_color(p) == ChessRules.WHITE else -(VALUES[t] + PST[t][sq])
		score += val
	return score


## Order moves: captures first (MVV-LVA), then the rest. Speeds up alpha-beta.
func _order_moves(rules: ChessRules, moves: Array) -> void:
	moves.sort_custom(func(a, b): return _move_order_key(rules, a) > _move_order_key(rules, b))


func _move_order_key(rules: ChessRules, m: int) -> int:
	var to := ChessRules.move_to(m)
	var victim: int = rules.board[to]
	var key := 0
	if victim != 0:
		key = 10000 + VALUES[ChessRules.piece_type(victim)] * 16 - VALUES[ChessRules.piece_type(rules.board[ChessRules.move_from(m)])]
	if ChessRules.move_promo(m) != 0:
		key += 9000
	return key
