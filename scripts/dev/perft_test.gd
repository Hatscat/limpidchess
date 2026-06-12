extends SceneTree

## Move-generation self-test. Run headless:
##   godot --headless --path . -s res://scripts/dev/perft_test.gd
## Validates ChessRules against published perft node counts (covers castling,
## en passant, promotions, pins, checks). Exits non-zero on any mismatch.
##
## Depths are kept to a ~minute of runtime. For a deeper check bump the last
## entry of each row (startpos d5 = 4865609, Kiwipete d4 = 4085603).

func _initialize() -> void:
	var cases := [
		# [fen, [expected nodes at depth 1, 2, 3, ...]]
		["rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", [20, 400, 8902]],
		["r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", [48, 2039, 97862]],
		["8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", [14, 191, 2812, 43238]],
		["rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", [44, 1486, 62379]],
		["r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10", [46, 2079, 89890]],
	]

	var all_ok := true
	for case in cases:
		var fen: String = case[0]
		var expected: Array = case[1]
		var rules := ChessRules.new()
		rules.set_fen(fen)
		for i in expected.size():
			var depth := i + 1
			var got := rules.perft(depth)
			var want: int = expected[i]
			var ok := got == want
			all_ok = all_ok and ok
			print("%s  perft(%d) = %d  (expected %d)  %s" % [
				fen.substr(0, 28), depth, got, want, "OK" if ok else "*** FAIL ***"])
		print("")

	if all_ok:
		print(">>> PERFT: ALL TESTS PASSED")
		quit(0)
	else:
		print(">>> PERFT: FAILURES DETECTED")
		quit(1)
