extends SceneTree

## Validate StockfishEngine's threaded async API.
## godot --headless --path . -s res://scripts/dev/test_engine.gd

const START := "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

func _initialize() -> void:
	var sf := StockfishEngine.new()
	root.add_child(sf)
	var ok := sf.start()
	print("start=", ok, "  available=", sf.available)
	if not ok:
		quit(1); return

	var lines: Array = await sf.analyse(START, 6, 12)
	print("analyse → ", lines.size(), " ranked moves:")
	for i in mini(6, lines.size()):
		print("  ", lines[i]["uci"], "  cp=", lines[i]["score"])

	for skill in [0, 8, 20]:
		var bm: String = await sf.best_move(START, {"skill": skill, "movetime": 150})
		print("best_move skill=", skill, " → ", bm)

	# Two analyses in a row (reuse the same engine/thread).
	var l2: Array = await sf.analyse("r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3", 4, 12)
	print("2nd analyse (Ruy Lopez) → best=", l2[0]["uci"] if not l2.is_empty() else "?")

	sf.stop()
	print(">>> ENGINE OK")
	quit(0)
