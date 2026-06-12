extends Control

## The game screen — ties [ChessRules], [ChessBot] and the board together.
##
## Loop per human turn:
##   1. rank every legal move (ChessBot analysis pass)
##   2. pick three options — best / not-bad / blunder — shuffle, show as arrows
##   3. player taps one → grade it, award coins, REVEAL the qualities, feedback
##   4. play it, then the bot replies (or the other human, in pass-and-play)
##
## The whole point: the best move is always on the board in front of you. You
## just have to see it.

const ChessBotScript := preload("res://scripts/chess/chess_bot.gd")

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
var bot: ChessBot
var bot_def: Dictionary
var player_color: int

var _ranked: Array = []          ## current ranked move list (player's turn)
var _history: Array = []         ## position_key()s for threefold detection
var _busy := false               ## blocks input while bot is thinking / animating
var _game_over := false


func _ready() -> void:
	rules = ChessRules.new()
	bot = ChessBotScript.new()
	bot_def = GameManager.current_bot if not GameManager.current_bot.is_empty() else BotRoster.default()
	player_color = ChessRules.WHITE if GameManager.player_is_white else ChessRules.BLACK

	board.flipped = (not GameManager.pass_and_play) and not GameManager.player_is_white
	board.set_rules(rules)
	board.option_chosen.connect(_on_option_chosen)

	_setup_opponent_panel()
	_refresh_coins()
	GameManager.coins_changed.connect(_refresh_coins)
	result_overlay.visible = false

	# Respect the device safe area for the top bar.
	var safe := DisplayServer.get_display_safe_area()
	$TopBar.offset_top = max(safe.position.y, 16)

	_record_position()
	_advance()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		GameManager.go_to_home()


func _setup_opponent_panel() -> void:
	if GameManager.pass_and_play:
		opponent_name.text = "Pass & Play"
		opponent_avatar.texture = load("res://assets/icons/handshake.png")
	else:
		opponent_name.text = "%s  ·  %d" % [bot_def.get("name", "Bot"), bot_def.get("elo", 0)]
		opponent_avatar.texture = load(BotRoster.avatar_path(bot_def))


func _refresh_coins() -> void:
	coins_label.text = str(GameManager.coins_best)


func _exit_tree() -> void:
	# GameManager is an autoload that outlives this scene — disconnect explicitly.
	if GameManager.coins_changed.is_connected(_refresh_coins):
		GameManager.coins_changed.disconnect(_refresh_coins)


# --- Turn flow ---

## Decide whose turn it is and act: present options to a human, or let the bot move.
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


func _present_options() -> void:
	_busy = false
	_ranked = bot.rank_moves(rules, ChessBotScript.ANALYSIS_DEPTH)
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
		status_label.text = "%s to move — find the best!" % mover
	else:
		status_label.text = "Your move — find the best!"
	var n := options.size()
	feedback.text = "Tap one of the %d moves." % n if n != 1 else "Only one move here — tap it."


func _on_option_chosen(opt: Dictionary) -> void:
	if _busy:
		return
	_busy = true

	var move: int = opt["move"]
	var grade := ChessBotScript.grade_move(_ranked, move)
	var best_move: int = grade["best_move"]
	var best_san := rules.to_san(best_move)

	# Rewards + feedback.
	match opt.get("quality", ""):
		"best":
			GameManager.add_best_coin()
			feedback.text = "★ Best move!  +1 coin"
		"decent":
			feedback.text = "%s. Not bad — the best was %s." % [grade["label"], best_san]
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
	# Defer one frame so the "thinking" text paints before the (brief) search.
	await get_tree().process_frame
	await get_tree().create_timer(0.35).timeout

	var move := bot.choose_move(rules, bot_def.get("depth", 2), bot_def.get("weakness", 0.3))
	if move < 0:
		_advance()
		return
	_play_move(move)
	await get_tree().create_timer(0.2).timeout
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
			# Side to move is checkmated → the other side won.
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
			text = "A draw — no legal moves, but no check."
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
	result_quote.text = "“%s”\n— %s" % [q["text"], q["author"]]
	result_overlay.visible = true


# --- Buttons ---

func _on_restart_pressed() -> void:
	rules.reset_startpos()
	_history.clear()
	_game_over = false
	_busy = false
	board.set_last_move(-1)
	board.set_check_square(-1)
	board.clear_options()
	board.set_rules(rules)
	result_overlay.visible = false
	_record_position()
	_advance()


func _on_give_up_pressed() -> void:
	if _game_over:
		return
	_game_over = true
	board.clear_options()
	if not GameManager.pass_and_play:
		GameManager.record_result("loss")
	_show_result("You gave up", "No shame — every game teaches something.", "resign")


func _on_play_again_pressed() -> void:
	_on_restart_pressed()


func _on_home_pressed() -> void:
	GameManager.go_to_home()
