extends Control

## The game screen — ties ChessRules, the engine, and the board together.
##
## The BRAIN is Stockfish (via [StockfishEngine]) when available, otherwise the
## built-in GDScript [ChessBot]. Either way, [ChessRules] stays the source of
## truth for legality / SAN / draws / highlights.
##
## Loop per human turn:
##   1. analyse the position (full-strength MultiPV)
##   2. pick three options — best / not-bad / blunder — shuffle, show as arrows
##   3. player taps one → grade it, award coins, REVEAL the qualities, feedback
##   4. play it, then the bot replies (or the other human, in pass-and-play)
##
## Every game: the player's colour is RANDOM, and White's first move is an
## auto-chosen random good opening — so you keep meeting fresh positions.

const ChessBotScript := preload("res://scripts/chess/chess_bot.gd")
const StockfishEngineScript := preload("res://scripts/chess/stockfish_engine.gd")

## Depth of the full-strength teaching/analysis pass (the 3 options + grading).
## Depth 10 keeps the move ranking solid while keeping the per-turn wait short.
const ANALYSIS_DEPTH_SF := 10
## Moves within this many centipawns of the best count as "good" openings.
const OPENING_WINDOW_CP := 55

@onready var board: Control = %Board
@onready var feedback: Label = %Feedback
@onready var status_label: Label = %Status
@onready var opponent_name: Label = %OpponentName
@onready var opponent_avatar: TextureRect = %OpponentAvatar
@onready var coins_label: Label = %CoinsLabel
@onready var result_overlay: Control = %ResultOverlay
@onready var result_title: Label = %ResultTitle
@onready var result_text: Label = %ResultText
@onready var result_quote: Label = %ResultQuote

var rules: ChessRules
var bot: ChessBot                 ## fallback engine (used only if Stockfish absent)
var stockfish: StockfishEngine
var _use_sf := false
var bot_def: Dictionary
var player_color: int

var _ranked: Array = []
var _history: Array = []
var _busy := false
var _game_over := false


func _ready() -> void:
	rules = ChessRules.new()
	bot = ChessBotScript.new()
	stockfish = StockfishEngineScript.new()
	add_child(stockfish)
	bot_def = GameManager.current_bot if not GameManager.current_bot.is_empty() else BotRoster.default()

	board.set_rules(rules)
	board.option_chosen.connect(_on_option_chosen)
	_setup_opponent_panel()
	_refresh_coins()
	GameManager.coins_changed.connect(_refresh_coins)
	result_overlay.visible = false

	var safe := DisplayServer.get_display_safe_area()
	$TopBar.offset_top = max(safe.position.y, 16)

	_begin()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		GameManager.go_to_home()


func _exit_tree() -> void:
	if GameManager.coins_changed.is_connected(_refresh_coins):
		GameManager.coins_changed.disconnect(_refresh_coins)
	# stockfish stops itself in its own _exit_tree.


func _setup_opponent_panel() -> void:
	if GameManager.pass_and_play:
		opponent_name.text = "Pass & Play"
		opponent_avatar.texture = load("res://assets/icons/handshake.png")
	else:
		opponent_name.text = "%s  ·  %d" % [bot_def.get("name", "Bot"), bot_def.get("elo", 0)]
		opponent_avatar.texture = load(BotRoster.avatar_path(bot_def))


func _refresh_coins() -> void:
	coins_label.text = str(GameManager.coins_best)


# --- Game lifecycle ---

func _begin() -> void:
	status_label.text = "Setting up…"
	feedback.text = ""
	_busy = true
	_use_sf = stockfish.start()
	_new_game()


## Start a fresh board: random colour, random opening for White, then play.
func _new_game() -> void:
	if not GameManager.pass_and_play:
		GameManager.player_is_white = randi() % 2 == 0
	player_color = ChessRules.WHITE if GameManager.player_is_white else ChessRules.BLACK
	board.flipped = (not GameManager.pass_and_play) and not GameManager.player_is_white

	rules.reset_startpos()
	_history.clear()
	_game_over = false
	board.set_last_move(-1)
	board.set_check_square(-1)
	board.clear_options()
	board.set_rules(rules)
	result_overlay.visible = false
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


## Auto-play White's first move (a random good opening) so games never start
## identically and the White player keeps discovering openings.
func _play_random_opening() -> void:
	_busy = true
	status_label.text = "A fresh opening…"
	feedback.text = ""
	var ranked := await _rank_position()
	var move := _pick_random_good(ranked)
	if move != -1:
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
	status_label.text = "Reading the position…"
	feedback.text = ""
	_ranked = await _rank_position()

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

	var mover := "White" if rules.side_to_move == ChessRules.WHITE else "Black"
	if GameManager.pass_and_play:
		status_label.text = "%s to move, find the best!" % mover
	else:
		status_label.text = "Your move, find the best!"
	var n := options.size()
	feedback.text = "Tap one of the %d moves." % n if n != 1 else "Only one move here, tap it."
	_busy = false


## Rank every legal move from the moving side's view (best first). Stockfish when
## available, else the built-in engine.
func _rank_position() -> Array:
	if _use_sf and stockfish.available:
		var legal := rules.generate_legal_moves()
		var mpv := maxi(1, mini(legal.size(), 50))
		var lines: Array = await stockfish.analyse(rules.get_fen(), mpv, ANALYSIS_DEPTH_SF)
		var ranked := _ranked_from_sf(lines)
		if not ranked.is_empty():
			return ranked
	return bot.rank_moves(rules, ChessBotScript.ANALYSIS_DEPTH)


## Convert Stockfish's UCI/centipawn lines into our {move, score} ranked list.
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

	var move: int = opt["move"]
	var grade := ChessBotScript.grade_move(_ranked, move)
	var best_move: int = grade["best_move"]
	var best_san := rules.to_san(best_move)

	match opt.get("quality", ""):
		"best":
			GameManager.add_best_coin()
			feedback.text = "★ Best move!  +1 coin"
		"decent":
			feedback.text = "%s. Not bad, the best was %s." % [grade["label"], best_san]
		"blunder":
			GameManager.add_blunder_coin()
			feedback.text = "The blunder! The best was %s." % best_san
		_:
			feedback.text = "%s. Best was %s." % [grade["label"], best_san]

	board.reveal()
	await get_tree().create_timer(1.4).timeout

	_play_move(move)
	board.clear_options()
	_advance()


func _bot_move() -> void:
	_busy = true
	status_label.text = "%s is thinking…" % bot_def.get("name", "Bot")
	feedback.text = ""
	await get_tree().process_frame

	var move := -1
	if _use_sf and stockfish.available:
		var uci: String = await stockfish.best_move(rules.get_fen(), {
			"skill": bot_def.get("sf_skill", 10),
			"movetime": bot_def.get("movetime", 200),
		})
		move = rules.move_from_uci(uci)
	if move == -1:
		await get_tree().create_timer(0.2).timeout
		move = bot.choose_move(rules, bot_def.get("depth", 2), bot_def.get("weakness", 0.3))
	if move < 0:
		_advance()
		return

	_play_move(move)
	await get_tree().create_timer(0.15).timeout
	_busy = false
	_advance()


func _play_move(move: int) -> void:
	rules.make_move(move)
	board.set_last_move(move)
	board.set_rules(rules)
	_record_position()


func _record_position() -> void:
	_history.append(rules.position_key())


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
	board.clear_options()

	var title := ""
	var text := ""
	var quote_key := "draw"
	match outcome:
		ChessRules.Outcome.CHECKMATE:
			var winner := 1 - rules.side_to_move
			var human_won := (not GameManager.pass_and_play) and winner == player_color
			if GameManager.pass_and_play:
				title = "Checkmate"
				text = "%s wins!" % ("White" if winner == ChessRules.WHITE else "Black")
			elif human_won:
				title = "You win!"
				text = "Checkmate. Well played."
				quote_key = "win"
				GameManager.record_result("win")
			else:
				title = "Checkmate"
				text = "%s got you this time." % bot_def.get("name", "The bot")
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
	_show_result(title, text, quote_key)
	return true


func _show_result(title: String, text: String, quote_key: String) -> void:
	result_title.text = title
	result_text.text = text
	var q := Quotes.for_outcome(quote_key)
	result_quote.text = "“%s”\n%s" % [q["text"], q["author"]]
	result_overlay.visible = true


# --- Buttons ---

func _on_restart_pressed() -> void:
	if _busy and not _game_over:
		return  # don't restart mid-think
	_new_game()


func _on_give_up_pressed() -> void:
	if _game_over:
		return
	_game_over = true
	board.clear_options()
	if not GameManager.pass_and_play:
		GameManager.record_result("loss")
	_show_result("You gave up", "No shame, every game teaches something.", "resign")


func _on_play_again_pressed() -> void:
	_new_game()


func _on_home_pressed() -> void:
	GameManager.go_to_home()
