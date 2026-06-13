extends Control

## The game screen. Brain = Stockfish (StockfishEngine, ext or pipe transport),
## fallback = the built-in ChessBot. ChessRules stays the source of truth.
##
## Loop per human turn: analyse → show three neutral option arrows → player taps
## one → grade it, REVEAL qualities (colour + shape symbol), slow-slide the piece
## (bullet-time), commit, then the bot replies. Every game: random player colour,
## and White's first move is an auto-chosen random good opening.

const ChessBotScript := preload("res://scripts/chess/chess_bot.gd")
const StockfishEngineScript := preload("res://scripts/chess/stockfish_engine.gd")

const ANALYSIS_DEPTH_SF := 10
const OPENING_WINDOW_CP := 55
const REVEAL_SLIDE_SEC := 1.1   ## slow bullet-time slide of the chosen piece
const REVEAL_HOLD_SEC := 0.55   ## extra pause so the result can be read
const BOT_SLIDE_SEC := 0.35

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
@onready var result_review: Label = %ResultReview
@onready var confirm_overlay: Control = %ConfirmOverlay
@onready var confirm_title: Label = %ConfirmTitle
@onready var confirm_message: Label = %ConfirmMessage

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
	result_overlay.visible = false
	confirm_overlay.visible = false

	var menu := $TopBar/Menu as MenuButton
	var popup := menu.get_popup()
	popup.add_item("Restart", 0)
	popup.add_item("Give up", 1)
	popup.id_pressed.connect(_on_menu)

	_layout_for_safe_area()
	feedback.text = ""
	_begin()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		GameManager.go_to_home()


## Push the top bar / labels / board down past the device notch.
func _layout_for_safe_area() -> void:
	var top: int = max(DisplayServer.get_display_safe_area().position.y, 16)
	$TopBar.offset_top = top
	$TopBar.offset_bottom = top + 68
	# Feedback + status sit just above the board (which is top-aligned), so the
	# text reads as a caption for the board rather than floating near the top bar.
	feedback.offset_top = top + 104
	feedback.offset_bottom = top + 154
	status_label.offset_top = top + 156
	status_label.offset_bottom = top + 192
	board.offset_top = top + 198


func _setup_opponent_panel() -> void:
	if GameManager.pass_and_play:
		opponent_name.text = "Pass & Play"
		opponent_avatar.texture = load("res://assets/icons/handshake.png")
	else:
		opponent_name.text = "%s  ·  %d" % [bot_def.get("name", "Bot"), bot_def.get("elo", 0)]
		opponent_avatar.texture = load(BotRoster.avatar_path(bot_def))


## The top-bar tally shows THIS game's best moves so far (not a persistent score).
func _refresh_coins() -> void:
	coins_label.text = str(_best_count)


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
	_refresh_coins()
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
	status_label.text = "Reading the position…"
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

	if options.size() == 1:
		status_label.text = "Only one move here."
	elif GameManager.pass_and_play:
		var mover := "White" if rules.side_to_move == ChessRules.WHITE else "Black"
		status_label.text = "%s to move, find the best!" % mover
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
			feedback.text = "★ Best move!"
		"decent":
			_decent_count += 1
			feedback.text = "%s. The best was %s." % [grade["label"], best_san]
		"blunder":
			_blunder_count += 1
			feedback.text = "The blunder! The best was %s." % best_san
		_:
			_decent_count += 1
			feedback.text = "%s. Best was %s." % [grade["label"], best_san]
	_refresh_coins()
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
	board.clear_options()
	_advance()


func _bot_move() -> void:
	var g := _gen
	_busy = true
	status_label.text = "%s is thinking…" % bot_def.get("name", "Bot")
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
	rules.make_move(move)
	board.set_last_move(move, mover)
	board.set_rules(rules)
	board.end_animation()  # commit done → drop the slide overlay (piece is now at dest)
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
	result_review.text = "This game:  ★ %d best  ·  ~ %d average  ·  ✗ %d blunder" % [
		_best_count, _decent_count, _blunder_count]
	GameManager.record_game_review(_best_count, _blunder_count)
	var q := Quotes.for_outcome(quote_key)
	result_quote.text = "“%s”\n%s" % [q["text"], q["author"]]
	result_overlay.visible = true


# --- Menu + confirm ---

func _on_menu(id: int) -> void:
	match id:
		0: _ask_confirm("restart", "Restart game?", "Start over from a fresh position?")
		1: _ask_confirm("give_up", "Give up?", "Resign and end this game?")


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
	board.clear_options()
	if not GameManager.pass_and_play:
		GameManager.record_result("loss")
	_show_result("You gave up", "No shame, every game teaches something.", "resign")


func _on_play_again_pressed() -> void:
	_new_game()


func _on_home_pressed() -> void:
	GameManager.go_to_home()
