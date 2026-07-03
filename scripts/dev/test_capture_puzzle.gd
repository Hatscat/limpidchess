extends SceneTree

## Dev-only headless check: the PUZZLE scene's board fires the capture smash via burst_capture_for, the
## same shared path the bot game uses.  godot --headless --path . -s res://scripts/dev/test_capture_puzzle.gd

const Rules := preload("res://scripts/chess/chess_rules.gd")

var puz
var frames := 0


func _initialize() -> void:
	puz = load("res://scenes/puzzle_rush.tscn").instantiate()
	root.add_child(puz)


func _process(_d: float) -> bool:
	frames += 1
	if frames < 3:
		return false  # let the puzzle scene finish _ready
	puz._gen += 1
	puz._over = true
	puz._busy = true
	# A capture position: white bishop b5 x knight c6 (Bxc6), the puzzle's board holding it pre-move.
	puz.rules.set_fen("r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 4")
	puz.board.set_rules(puz.rules)
	puz.board.burst_capture_for(puz.rules.move_from_uci("b5c6"))
	var c6: int = 5 * 8 + 2
	var ok: bool = puz.board._cap_active and puz.board._cap_sq == c6 and puz.board._cap_hide_sq == c6 \
		and puz.board._cap_piece == (Rules.KNIGHT | Rules.BLACK_FLAG)
	print("puzzle capture: active=%s sq=%d(c6=%d) hide=%d piece=%d -> %s" % [
		puz.board._cap_active, puz.board._cap_sq, c6, puz.board._cap_hide_sq, puz.board._cap_piece,
		"PASS" if ok else "FAIL"])
	quit(0 if ok else 1)
	return true
