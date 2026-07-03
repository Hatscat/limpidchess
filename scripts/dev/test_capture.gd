extends SceneTree

## Dev-only headless check: driving a real capture (and an en-passant capture) through game._play_move
## must fire board.capture_burst on the RIGHT square, including en passant where the taken pawn is not on
## the move's destination.  godot --headless --path . -s res://scripts/dev/test_capture.gd

const Rules := preload("res://scripts/chess/chess_rules.gd")

var game
var frames := 0
var ok := true


func _fail(msg: String) -> void:
	ok = false
	print("  FAIL: ", msg)


func _initialize() -> void:
	var gm: Node = root.get_node("GameManager")
	gm.is_premium = true
	gm.player_is_white = true
	gm.pass_and_play = false
	gm.current_bot = BotRoster.get_by_id("reynard")
	game = load("res://scenes/game.tscn").instantiate()
	root.add_child(game)


func _process(_d: float) -> bool:
	frames += 1
	if frames < 3:
		return false  # let the scene finish _ready / its opening
	game._gen += 1
	game._game_over = true
	game._busy = false

	# --- Normal capture: white bishop on b5 takes the knight on c6 (Bxc6). ---
	game.rules.set_fen("r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 4")
	game.board.set_rules(game.rules)
	game.board._end_capture_burst()
	var bxc6: int = game.rules.move_from_uci("b5c6")
	game._play_move(bxc6)
	var c6: int = 5 * 8 + 2  # c6
	var black_knight: int = Rules.KNIGHT | Rules.BLACK_FLAG
	if not game.board._cap_active:
		_fail("normal capture did not start a burst")
	if game.board._cap_sq != c6:
		_fail("normal capture burst on sq %d, expected c6=%d" % [game.board._cap_sq, c6])
	if game.board._cap_piece != black_knight:
		_fail("normal capture burst piece=%d, expected black knight=%d" % [game.board._cap_piece, black_knight])
	print("normal capture: burst active=%s sq=%d(c6=%d) piece=%d" % [
		game.board._cap_active, game.board._cap_sq, c6, game.board._cap_piece])

	# --- En passant: white pawn e5 takes d6 e.p.; the taken black pawn sits on d5, NOT d6. ---
	game.board._end_capture_burst()
	game.rules.set_fen("rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3")
	game.board.set_rules(game.rules)
	var exd6: int = game.rules.move_from_uci("e5d6")
	game._play_move(exd6)
	var d5: int = 4 * 8 + 3  # d5, where the captured pawn actually was
	var d6: int = 5 * 8 + 3
	if not game.board._cap_active:
		_fail("en passant did not start a burst")
	if game.board._cap_sq != d5:
		_fail("en passant burst on sq %d, expected d5=%d (NOT d6=%d)" % [game.board._cap_sq, d5, d6])
	print("en passant: burst active=%s sq=%d(d5=%d, d6=%d) piece=%d" % [
		game.board._cap_active, game.board._cap_sq, d5, d6, game.board._cap_piece])

	# --- Non-capture: a quiet move must NOT start a burst. ---
	game.board._end_capture_burst()
	game.rules.set_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
	game.board.set_rules(game.rules)
	game._play_move(game.rules.move_from_uci("e2e4"))
	if game.board._cap_active:
		_fail("a quiet move wrongly started a burst")
	print("quiet move: burst active=%s (expected false)" % game.board._cap_active)

	print("CAPTURE TEST: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
	return true
