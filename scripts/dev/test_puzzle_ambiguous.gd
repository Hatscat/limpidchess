extends SceneTree

## Dev-only headless check: a puzzle position with more than one mate-in-1 must never offer the OTHER
## mate as a "wrong" distractor (that turned such puzzles into a coin flip). The solution stays present.
##   godot --headless --path . -s res://scripts/dev/test_puzzle_ambiguous.gd

var puz
var frames := 0


func _initialize() -> void:
	root.get_node("GameManager").is_premium = true
	puz = load("res://scenes/puzzle_rush.tscn").instantiate()
	root.add_child(puz)  # _ready builds rules + bot


func _process(_d: float) -> bool:
	frames += 1
	if frames < 4:
		return false
	puz._gen += 1
	puz._over = true
	puz._busy = true
	var ok := true

	# Two different mates-in-1: Ra8# (a1a8) and Re8# (e1e8), a back-rank pair. Solution = a1a8.
	puz.rules.set_fen("6k1/5ppp/8/8/8/8/5PPP/R3R1K1 w - - 0 1")
	puz._solution = puz.rules.move_from_uci("a1a8")
	var alt: int = puz.rules.move_from_uci("e1e8")
	if not puz._move_is_mate(puz._solution):
		ok = false; print("  FAIL: solution a1a8 should be mate (bad test setup)")
	if not puz._move_is_mate(alt):
		ok = false; print("  FAIL: alt e1e8 should be mate (bad test setup)")

	# Build the options repeatedly; no NON-solution option may be a checkmate, and the solution must show.
	for _i in range(25):
		var opts: Array = puz._build_options()
		var has_sol := false
		for o: Dictionary in opts:
			var m := int(o["move"])
			if m == puz._solution:
				has_sol = true
			elif puz._move_is_mate(m):
				ok = false
				print("  FAIL: an alternate MATE was offered as a distractor: ", puz.rules.move_to_uci(m))
		if not has_sol:
			ok = false; print("  FAIL: the solution went missing from the options")

	print("ambiguous mate: solution always offered, no alternate-mate distractor")
	print("PUZZLE MATE TEST: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
	return true
