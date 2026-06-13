extends Control

## The game screen. Brain = Stockfish (StockfishEngine, ext or pipe transport),
## fallback = the built-in ChessBot. ChessRules stays the source of truth.
##
## Loop per human turn: analyse → show three neutral option arrows → player taps
## one → grade it, REVEAL qualities (colour + shape symbol), slow-slide the piece
## (bullet-time), commit, then the bot replies. Every game: random player colour,
## and White's first move is an auto-chosen random good opening.

const ChessBotScript := preload("res://scripts/chess/chess_bot.gd")
const CapturedStripScript := preload("res://scripts/ui/captured_strip.gd")
const EvalBarScript := preload("res://scripts/ui/eval_bar.gd")

## Centipawn-ish piece values for the material lead (king excluded). pawn..queen.
const PIECE_VALUE := {1: 1, 2: 3, 3: 3, 4: 5, 5: 9}

## Wide MultiPV pass (every legal move) for the option spread + grading. Kept
## shallow because MultiPV cost explodes with depth; the BEST line is deepened
## separately below.
const ANALYSIS_DEPTH_SF := 10
## The suggested BEST move gets its own deep, single-line search so that "playing
## best" can actually match/beat the opponent (the shallow pass alone often picks
## a sub-optimal best the strong bots punish). Think time scales with the bot.
const BEST_MOVETIME_MARGIN := 250  ## think a little longer than the opponent does
const BEST_MOVETIME_FLOOR := 750   ## floor so suggestions stay sound vs weak bots (teaching)
const BEST_MOVETIME_CAP := 2050    ## ceiling so the strongest bots' turns stay tolerable
const OPENING_WINDOW_CP := 55
const REVEAL_SLIDE_SEC := 0.9   ## slow bullet-time slide of the chosen piece
const REVEAL_HOLD_SEC := 0.55   ## extra pause so the result can be read
const BOT_SLIDE_SEC := 0.35
const END_DELAY := 1.3   ## hold the "Checkmate!" / "Stalemate." message before the review dialog

@onready var board: Control = %Board
@onready var feedback: Label = %Feedback
@onready var status_label: Label = %Status
@onready var opponent_name: Label = %OpponentName
@onready var opponent_avatar: TextureRect = %OpponentAvatar
@onready var result_overlay: Control = %ResultOverlay
@onready var result_title: Label = %ResultTitle
@onready var result_text: Label = %ResultText
@onready var result_quote: Label = %ResultQuote
@onready var review_best: Label = %ReviewBest
@onready var review_avg: Label = %ReviewAvg
@onready var review_blunder: Label = %ReviewBlunder
@onready var confirm_overlay: Control = %ConfirmOverlay
@onready var confirm_title: Label = %ConfirmTitle
@onready var confirm_message: Label = %ConfirmMessage
@onready var menu_overlay: Control = %MenuOverlay
@onready var undo_btn: Button = %UndoBtn

var rules: ChessRules
var bot: ChessBot
var stockfish: StockfishEngine
var _use_sf := false
var bot_def: Dictionary
var player_color: int

var _ranked: Array = []
var _history: Array = []
var _busy := false
var _game_over := false
var _pending_action := ""
## Bumped on every new game; async turn coroutines bail if it changed under them
## (e.g. the player restarts mid-animation or mid-bot-think).
var _gen := 0

# Per-game move-quality tally (reset each game) → the end-of-game review.
var _best_count := 0
var _decent_count := 0
var _blunder_count := 0

# Captured-pieces strips (below the board). Codes accumulated as moves are played:
# _caps_white = the black pieces White has taken, _caps_black = the white pieces
# Black has taken (each side shows its own trophies). Created in _ready.
var cap_top: Control       ## strip for the side at the TOP of the board
var cap_bottom: Control    ## strip for the side at the BOTTOM (the player, vs a bot)
var _caps_white: PackedInt32Array = PackedInt32Array()
var _caps_black: PackedInt32Array = PackedInt32Array()

# Undo stack: one entry per committed move {move, undo, captured, mover}. "Undo
# move" rewinds the player's last move AND the opponent's reply (two plies),
# never past White's auto-opening (kept as the first entry).
var _undo_stack: Array = []

# Stockfish evaluation bar (bot games only; hidden in Pass & Play). Created in _ready.
var eval_bar: Control


func _ready() -> void:
	rules = ChessRules.new()
	bot = ChessBotScript.new()
	# Shared, persistent engine (autoload): the embedded native Stockfish is a
	# process-singleton, so every game reuses the one instance instead of spawning
	# a fresh one (a second native engine produces no output).
	stockfish = ChessEngine
	bot_def = GameManager.current_bot if not GameManager.current_bot.is_empty() else BotRoster.default()

	board.set_rules(rules)
	board.option_chosen.connect(_on_option_chosen)

	# Captured-pieces strips: keep them right after the board so the result /
	# confirm overlays (later siblings) still draw on top.
	cap_top = CapturedStripScript.new()
	cap_bottom = CapturedStripScript.new()
	eval_bar = EvalBarScript.new()
	add_child(cap_top)
	add_child(cap_bottom)
	add_child(eval_bar)
	move_child(cap_top, board.get_index() + 1)
	move_child(cap_bottom, board.get_index() + 2)
	move_child(eval_bar, board.get_index() + 3)

	_setup_opponent_panel()
	result_overlay.visible = false
	confirm_overlay.visible = false
	menu_overlay.visible = false

	_layout_for_safe_area()
	get_viewport().size_changed.connect(_layout_for_safe_area)
	feedback.text = ""
	_begin()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		GameManager.go_to_home()


## Layout, top → bottom: top bar (with the big portrait) · breathing room ·
## feedback + status captions · the board (sat in the lower-middle, index-finger
## reach) · a captured-pieces strip per side. Sized from the live viewport so it
## adapts to any phone aspect / notch; re-runs on size_changed.
const _BAR_H := 104.0          ## top bar height (fits the 88px portrait)
const _EVAL_H := 26.0          ## evaluation bar height
const _EVAL_TOP_GAP := 14.0    ## gap from the top bar to the eval bar
const _FEED_H := 96.0          ## feedback box (room for a 2-line OpenDyslexic result)
const _FEED_GAP := 10.0        ## gap between feedback and status
const _STATUS_H := 38.0
const _CAP_STRIP_H := 34.0     ## one captured-pieces strip
const _CAP_GAP := 6.0          ## gap between the two strips
const _CAP_TOP_GAP := 10.0     ## gap from board bottom to the first strip

func _layout_for_safe_area() -> void:
	var vp := get_viewport_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return  # size not established yet; size_changed will call us again
	var top: float = maxf(DisplayServer.get_display_safe_area().position.y, 16.0)
	$TopBar.offset_top = top
	$TopBar.offset_bottom = top + _BAR_H

	var caption_block: float = _FEED_H + _FEED_GAP + _STATUS_H + 12.0  # captions + gap to board
	var captured_block: float = _CAP_TOP_GAP + _CAP_STRIP_H + _CAP_GAP + _CAP_STRIP_H

	# Full-width square, shrunk if a short screen can't fit the whole stack.
	var area_top: float = top + _BAR_H
	# Reserve the eval-bar zone at the very top so the vertically-centred caption
	# stack can never rise into it on short screens.
	var stack_top: float = area_top + _EVAL_TOP_GAP + _EVAL_H

	var board_size: float = minf(vp.x - 16.0,
		vp.y - stack_top - caption_block - captured_block - 24.0)
	board_size = maxf(board_size, 0.0)
	var bx: float = (vp.x - board_size) * 0.5

	# Centre the captioned-board-plus-strips block in the remaining space, biased a
	# touch downward (half the slack above, the rest below) so the board sits in
	# the lower-middle within thumb-and-finger reach, not pinned to either edge.
	var content_h: float = caption_block + board_size + captured_block
	var extra: float = maxf(0.0, vp.y - stack_top - content_h - 16.0)
	var board_top: float = stack_top + extra * 0.5 + caption_block

	board.offset_left = bx
	board.offset_right = -bx
	board.offset_top = board_top
	board.offset_bottom = (board_top + board_size) - vp.y

	# Status hugs the board top; feedback (can wrap to 2 lines) just above it.
	status_label.offset_bottom = board_top - 12.0
	status_label.offset_top = status_label.offset_bottom - _STATUS_H
	feedback.offset_bottom = status_label.offset_top - _FEED_GAP
	feedback.offset_top = feedback.offset_bottom - _FEED_H

	# Eval bar: just under the top bar, aligned with the board's width.
	if eval_bar:
		eval_bar.position = Vector2(bx, area_top + _EVAL_TOP_GAP)
		eval_bar.size = Vector2(board_size, _EVAL_H)

	# Captured strips, aligned with the board's width, just below it.
	var sy: float = board_top + board_size + _CAP_TOP_GAP
	if cap_top:
		cap_top.position = Vector2(bx, sy)
		cap_top.size = Vector2(board_size, _CAP_STRIP_H)
	if cap_bottom:
		cap_bottom.position = Vector2(bx, sy + _CAP_STRIP_H + _CAP_GAP)
		cap_bottom.size = Vector2(board_size, _CAP_STRIP_H)


func _setup_opponent_panel() -> void:
	if GameManager.pass_and_play:
		opponent_name.text = "Pass & Play"
		opponent_avatar.texture = load("res://assets/icons/handshake.png")
	else:
		opponent_name.text = bot_def.get("name", "Bot")
		opponent_avatar.texture = load(BotRoster.avatar_path(bot_def))


# --- Game lifecycle ---

func _begin() -> void:
	status_label.text = "Setting up…"
	_busy = true
	_use_sf = stockfish.start()
	_new_game()


func _new_game() -> void:
	_gen += 1  # invalidate any in-flight turn coroutine from the previous game
	board.end_animation()
	if not GameManager.pass_and_play:
		GameManager.player_is_white = randi() % 2 == 0
	player_color = ChessRules.WHITE if GameManager.player_is_white else ChessRules.BLACK
	board.flipped = (not GameManager.pass_and_play) and not GameManager.player_is_white

	rules.reset_startpos()
	_history.clear()
	_game_over = false
	board.clear_last_moves()
	board.set_check_square(-1)
	board.clear_options()
	board.set_rules(rules)
	result_overlay.visible = false
	confirm_overlay.visible = false
	feedback.text = ""
	_best_count = 0
	_decent_count = 0
	_blunder_count = 0
	_caps_white = PackedInt32Array()
	_caps_black = PackedInt32Array()
	_undo_stack.clear()
	_update_captured()
	eval_bar.visible = not GameManager.pass_and_play
	eval_bar.set_eval(0)
	_record_position()
	_play_random_opening()


# --- Turn flow ---

func _advance() -> void:
	_update_check_highlight()
	if _check_game_over():
		return
	if _is_human_turn():
		_present_options()
	else:
		_bot_move()


func _is_human_turn() -> bool:
	return GameManager.pass_and_play or rules.side_to_move == player_color


func _play_random_opening() -> void:
	var g := _gen
	_busy = true
	status_label.text = "A fresh opening…"
	var ranked := await _rank_position()
	if g != _gen:
		return
	var move := _pick_random_good(ranked)
	if move != -1:
		await board.animate_move(move, 0.4)
		if g != _gen:
			return
		_play_move(move)
	_advance()


func _pick_random_good(ranked: Array) -> int:
	if ranked.is_empty():
		return -1
	var best: int = ranked[0]["score"]
	var pool: Array = []
	for e in ranked:
		if best - int(e["score"]) <= OPENING_WINDOW_CP:
			pool.append(e["move"])
	return pool[randi() % pool.size()]


func _present_options() -> void:
	_busy = true
	var g := _gen
	status_label.text = "Reading the position…"
	_ranked = await _rank_position()
	if g != _gen:
		return  # a new game / undo / game-end happened during analysis
	await _promote_deep_best()
	if g != _gen:
		return
	_push_eval_from_ranked()

	var picks := ChessBotScript.select_options(_ranked)
	var options: Array = []
	if picks["best"] >= 0:
		options.append({"move": picks["best"], "quality": "best"})
	if picks["decent"] >= 0:
		options.append({"move": picks["decent"], "quality": "decent"})
	if picks["blunder"] >= 0:
		options.append({"move": picks["blunder"], "quality": "blunder"})
	options.shuffle()
	board.set_options(options, true)

	if options.size() == 1:
		status_label.text = "Only one move here."
	elif GameManager.pass_and_play:
		var mover := tr("White") if rules.side_to_move == ChessRules.WHITE else tr("Black")
		status_label.text = tr("%s to move, find the best!") % mover
	else:
		status_label.text = "Your move, find the best!"
	_busy = false


func _rank_position() -> Array:
	if _use_sf and stockfish.available:
		var legal := rules.generate_legal_moves()
		var mpv := maxi(1, mini(legal.size(), 50))
		var lines: Array = await stockfish.analyse(rules.get_fen(), mpv, ANALYSIS_DEPTH_SF)
		var ranked := _ranked_from_sf(lines)
		if not ranked.is_empty():
			return ranked
	return bot.rank_moves(rules, ChessBotScript.ANALYSIS_DEPTH)


## Deepen ONLY the best line: a single full-strength search (think time scaled to
## the opponent) replaces the shallow pass's #1, lifted to the front of _ranked as
## the reference best. So "best" is genuinely strong vs deep-searching bots, while
## the wide spread (decent / blunder / grading) stays cheap. Fallback path is a
## no-op (the GDScript ranker has no separate deep search).
func _promote_deep_best() -> void:
	if not (_use_sf and stockfish.available) or _ranked.is_empty():
		return
	var g := _gen
	var mt: int = clampi(int(bot_def.get("movetime", 400)) + BEST_MOVETIME_MARGIN,
		BEST_MOVETIME_FLOOR, BEST_MOVETIME_CAP)
	var uci: String = await stockfish.best_move(rules.get_fen(), {"skill": 20, "movetime": mt})
	if g != _gen:
		return  # undo / restart / game-end happened during the deep search → don't touch _ranked
	var best_move := rules.move_from_uci(uci)
	if best_move < 0:
		return
	var top_score: int = int(_ranked[0]["score"])
	for i in _ranked.size():
		if int(_ranked[i]["move"]) == best_move:
			var e: Dictionary = _ranked[i]
			_ranked.remove_at(i)
			_ranked.insert(0, e)
			break
	if int(_ranked[0]["move"]) != best_move:  # wasn't in the spread → prepend it
		_ranked.insert(0, {"move": best_move, "score": top_score})
	# It is the true best, so it must carry the top score (keeps cp-loss grading sane).
	_ranked[0]["score"] = maxi(int(_ranked[0]["score"]), top_score)


func _ranked_from_sf(lines: Array) -> Array:
	var by_uci := {}
	for m in rules.generate_legal_moves():
		by_uci[rules.move_to_uci(m)] = m
	var ranked: Array = []
	for e in lines:
		if by_uci.has(e["uci"]):
			ranked.append({"move": by_uci[e["uci"]], "score": int(e["score"])})
	ranked.sort_custom(func(a, b): return a["score"] > b["score"])
	return ranked


func _on_option_chosen(opt: Dictionary) -> void:
	if _busy:
		return
	_busy = true
	var g := _gen

	var move: int = opt["move"]
	var grade := ChessBotScript.grade_move(_ranked, move)
	var best_san := rules.to_san(grade["best_move"])

	match opt.get("quality", ""):
		"best":
			_best_count += 1
			feedback.text = tr("★ Best move!")
		"decent":
			_decent_count += 1
			feedback.text = tr("%s. The best was %s.") % [tr(grade["label"]), best_san]
		"blunder":
			_blunder_count += 1
			feedback.text = tr("The blunder! The best was %s.") % best_san
		_:
			_decent_count += 1
			feedback.text = tr("%s. Best was %s.") % [tr(grade["label"]), best_san]
	status_label.text = ""

	# Reveal the qualities, then slow-slide the chosen piece (bullet time).
	board.reveal()
	await board.animate_move(move, REVEAL_SLIDE_SEC)
	if g != _gen:
		return
	await get_tree().create_timer(REVEAL_HOLD_SEC).timeout
	if g != _gen:
		return

	_play_move(move)
	_push_eval_after_move(move)
	board.clear_options()
	_advance()


func _bot_move() -> void:
	var g := _gen
	_busy = true
	status_label.text = tr("%s is thinking…") % bot_def.get("name", "Bot")
	await get_tree().process_frame
	if g != _gen:
		return

	var move := -1
	if _use_sf and stockfish.available:
		var uci: String = await stockfish.best_move(rules.get_fen(), {
			"skill": bot_def.get("sf_skill", 10),
			"movetime": bot_def.get("movetime", 200),
		})
		if g != _gen:
			return
		move = rules.move_from_uci(uci)
	if move == -1:
		await get_tree().create_timer(0.2).timeout
		if g != _gen:
			return
		move = bot.choose_move(rules, bot_def.get("depth", 2), bot_def.get("weakness", 0.3))
	if move < 0:
		_advance()
		return

	await board.animate_move(move, BOT_SLIDE_SEC)
	if g != _gen:
		return
	_play_move(move)
	_busy = false
	_advance()


func _play_move(move: int) -> void:
	var mover := rules.side_to_move
	var undo := rules.make_move(move)
	var captured: int = undo.get("captured_piece", 0)
	if captured != 0:
		if mover == ChessRules.WHITE:
			_caps_white.append(captured)
		else:
			_caps_black.append(captured)
	_undo_stack.append({"move": move, "undo": undo, "captured": captured, "mover": mover})
	board.set_last_move(move, mover)
	board.set_rules(rules)
	board.end_animation()  # commit done → drop the slide overlay (piece is now at dest)
	_update_captured()
	_record_position()


func _record_position() -> void:
	_history.append(rules.position_key())


## Feed the eval bar the current position's score, converted to White's point of
## view (+ = White better). _ranked[0] is the best line from the side-to-move's
## view; flip its sign for Black. No-op in Pass & Play (the bar stays hidden).
func _push_eval_from_ranked() -> void:
	if GameManager.pass_and_play or _ranked.is_empty():
		return
	var score: int = int(_ranked[0]["score"])
	eval_bar.set_eval(score if rules.side_to_move == ChessRules.WHITE else -score)


## Right after the human commits their pick, show that move's evaluation so the bar
## reacts immediately (a blunder visibly drops it) instead of looking stale through
## the bot's reply. The chosen move's score comes from the analysis just shown, in
## the human's (the mover's) point of view → flip for Black.
func _push_eval_after_move(move: int) -> void:
	if GameManager.pass_and_play:
		return
	var score := 0
	for e in _ranked:
		if int(e["move"]) == move:
			score = int(e["score"])
			break
	eval_bar.set_eval(score if player_color == ChessRules.WHITE else -score)


## Refresh both captured-pieces strips from the current board + accumulated trophies.
## The material lead is read from on-board material (correct even after a promotion);
## the trophy icons come from the actual pieces captured.
func _update_captured() -> void:
	if cap_top == null or cap_bottom == null:
		return
	var wmat := 0
	var bmat := 0
	for sq in 64:
		var p: int = rules.board[sq]
		if p == 0:
			continue
		var t: int = ChessRules.piece_type(p)
		if t < ChessRules.PAWN or t > ChessRules.QUEEN:
			continue  # skip kings
		var v: int = PIECE_VALUE[t]
		if ChessRules.piece_color(p) == ChessRules.WHITE:
			wmat += v
		else:
			bmat += v

	# The board flips to keep the player at the bottom, so the bottom strip is the
	# player's (White in pass & play); the top strip is the opponent's.
	var bottom_color: int = ChessRules.WHITE if GameManager.pass_and_play else player_color
	var top_color: int = 1 - bottom_color
	cap_bottom.set_data(_sorted_caps(bottom_color), maxi(0, _material_lead(bottom_color, wmat, bmat)))
	cap_top.set_data(_sorted_caps(top_color), maxi(0, _material_lead(top_color, wmat, bmat)))


## Material lead (in points) for `color`, given total on-board material per side.
func _material_lead(color: int, wmat: int, bmat: int) -> int:
	return (wmat - bmat) if color == ChessRules.WHITE else (bmat - wmat)


## The pieces `capturer` has taken, ordered pawns → queen for display.
func _sorted_caps(capturer: int) -> PackedInt32Array:
	var src: PackedInt32Array = _caps_white if capturer == ChessRules.WHITE else _caps_black
	var out: PackedInt32Array = PackedInt32Array()
	for t in [ChessRules.PAWN, ChessRules.KNIGHT, ChessRules.BISHOP, ChessRules.ROOK, ChessRules.QUEEN]:
		for c in src:
			if ChessRules.piece_type(c) == t:
				out.append(c)
	return out


func _update_check_highlight() -> void:
	if rules.is_in_check():
		board.set_check_square(rules.king_square(rules.side_to_move))
	else:
		board.set_check_square(-1)


# --- End of game ---

func _check_game_over() -> bool:
	var threefold := _history.count(rules.position_key()) >= 3
	var outcome := rules.outcome(threefold)
	if outcome == ChessRules.Outcome.ONGOING:
		return false
	_game_over = true
	_busy = false
	_gen += 1  # invalidate any in-flight turn coroutine
	board.clear_options()
	menu_overlay.visible = false
	confirm_overlay.visible = false

	var title := ""
	var text := ""
	var quote_key := "draw"
	match outcome:
		ChessRules.Outcome.CHECKMATE:
			var winner := 1 - rules.side_to_move
			var human_won := (not GameManager.pass_and_play) and winner == player_color
			if GameManager.pass_and_play:
				title = "Checkmate"
				text = tr("%s wins!") % (tr("White") if winner == ChessRules.WHITE else tr("Black"))
			elif human_won:
				title = "You win!"
				text = "Checkmate. Well played."
				quote_key = "win"
				GameManager.record_result("win")
			else:
				title = "Checkmate"
				text = tr("%s got you this time.") % bot_def.get("name", "The bot")
				quote_key = "loss"
				GameManager.record_result("loss")
		ChessRules.Outcome.STALEMATE:
			title = "Stalemate"
			text = "A draw: no legal moves, but no check."
			if not GameManager.pass_and_play: GameManager.record_result("draw")
		ChessRules.Outcome.DRAW_FIFTY:
			title = "Draw"
			text = "Fifty moves without a pawn move or capture."
			if not GameManager.pass_and_play: GameManager.record_result("draw")
		ChessRules.Outcome.DRAW_REPETITION:
			title = "Draw"
			text = "The same position, three times over."
			if not GameManager.pass_and_play: GameManager.record_result("draw")
		ChessRules.Outcome.DRAW_INSUFFICIENT:
			title = "Draw"
			text = "Not enough material to checkmate."
			if not GameManager.pass_and_play: GameManager.record_result("draw")

	# Announce the ending explicitly on the board, hold a beat, THEN the review.
	feedback.text = _outcome_headline(outcome)
	status_label.text = ""
	_finish_game_after_delay(title, text, quote_key)
	return true


## Short, explicit board headline shown before the review dialog.
func _outcome_headline(outcome: int) -> String:
	match outcome:
		ChessRules.Outcome.CHECKMATE: return "Checkmate!"
		ChessRules.Outcome.STALEMATE: return "Stalemate."
		_: return "Draw."


func _finish_game_after_delay(title: String, text: String, quote_key: String) -> void:
	var g := _gen
	await get_tree().create_timer(END_DELAY).timeout
	if g != _gen:
		return  # a restart / undo happened during the hold
	_show_result(title, text, quote_key)


func _show_result(title: String, text: String, quote_key: String) -> void:
	result_title.text = title
	result_text.text = text
	review_best.text = tr("%d best") % _best_count
	review_avg.text = tr("%d average") % _decent_count
	review_blunder.text = tr("%d blunder") % _blunder_count
	GameManager.record_game_review(_best_count, _blunder_count)
	var q := Quotes.for_outcome(quote_key)
	result_quote.text = "“%s”\n%s" % [tr(q["text"]), q["author"]]
	result_overlay.visible = true


# --- Menu + confirm ---

func _open_menu() -> void:
	if _game_over:
		return  # the result dialog owns the screen once the game has ended
	undo_btn.disabled = not _can_undo()
	menu_overlay.visible = true


func _on_menu_close() -> void:
	menu_overlay.visible = false


func _on_menu_restart() -> void:
	menu_overlay.visible = false
	_ask_confirm("restart", "Restart game?", "Start over from a fresh position?")


func _on_menu_giveup() -> void:
	menu_overlay.visible = false
	_ask_confirm("give_up", "Give up?", "Resign and end this game?")


func _on_menu_undo() -> void:
	menu_overlay.visible = false
	_undo_last()


# --- Undo ---

## Can we rewind the player's last move + the reply? Only while it's the player's
## turn (not mid-think / not over) and there are 2 plies above the auto-opening.
func _can_undo() -> bool:
	return not _busy and not _game_over and _undo_stack.size() >= 3


## Rewind two plies (the player's move and the opponent's reply), keeping the
## opening, then re-offer options for the restored position.
func _undo_last() -> void:
	if not _can_undo():
		return
	_gen += 1  # invalidate any stray coroutine
	board.end_animation()
	var plies := 0
	while plies < 2 and _undo_stack.size() > 1:  # never pop the opening
		var e: Dictionary = _undo_stack.pop_back()
		rules.undo_move(int(e["move"]), e["undo"])
		var cap: int = e["captured"]
		if cap != 0:
			if int(e["mover"]) == ChessRules.WHITE:
				_caps_white = _remove_last(_caps_white, cap)
			else:
				_caps_black = _remove_last(_caps_black, cap)
		if not _history.is_empty():
			_history.pop_back()
		plies += 1

	_game_over = false
	_busy = false
	feedback.text = ""
	board.set_rules(rules)
	board.clear_options()
	board.clear_last_moves()
	if not _undo_stack.is_empty():
		var top: Dictionary = _undo_stack.back()
		board.set_last_move(int(top["move"]), int(top["mover"]))
	_update_check_highlight()
	_update_captured()
	_advance()


## Drop the last occurrence of `code` from a captured list (it was appended on the
## capture being undone). Returns the new array (PackedInt32Array is copy-on-write).
func _remove_last(arr: PackedInt32Array, code: int) -> PackedInt32Array:
	for i in range(arr.size() - 1, -1, -1):
		if arr[i] == code:
			arr.remove_at(i)
			break
	return arr


func _ask_confirm(action: String, title: String, message: String) -> void:
	_pending_action = action
	confirm_title.text = title
	confirm_message.text = message
	confirm_overlay.visible = true


func _on_confirm_no() -> void:
	confirm_overlay.visible = false
	_pending_action = ""


func _on_confirm_yes() -> void:
	confirm_overlay.visible = false
	var action := _pending_action
	_pending_action = ""
	match action:
		"restart": _new_game()
		"give_up": _do_give_up()


func _do_give_up() -> void:
	if _game_over:
		return
	_game_over = true
	_gen += 1  # invalidate any in-flight bot-think / analysis coroutine
	board.clear_options()
	if not GameManager.pass_and_play:
		GameManager.record_result("loss")
	_show_result("You gave up", "No shame, every game teaches something.", "resign")


func _on_play_again_pressed() -> void:
	_new_game()


func _on_home_pressed() -> void:
	GameManager.go_to_home()
