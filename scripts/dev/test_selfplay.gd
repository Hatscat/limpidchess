extends SceneTree

## End-to-end check of the Stockfish-driven game pipeline:
## auto-opening → MultiPV analyse → option selection → SAN → bot reply.
## godot --headless --path . -s res://scripts/dev/test_selfplay.gd

func _initialize() -> void:
	var sf := StockfishEngine.new()
	root.add_child(sf)
	if not sf.start():
		print("no stockfish"); quit(1); return
	var rules := ChessRules.new()
	var CB := load("res://scripts/chess/chess_bot.gd")

	# Auto opening for White (random good move).
	var open_lines: Array = await sf.analyse(rules.get_fen(), 6, 10)
	var opening := _pick_good(_ranked(rules, open_lines))
	print("opening move: ", rules.to_san(opening))
	rules.make_move(opening)

	for ply in 10:
		if rules.generate_legal_moves().is_empty():
			print("game over (", rules.outcome(false), ")"); break
		var legal := rules.generate_legal_moves()
		var t0 := Time.get_ticks_msec()
		var lines: Array = await sf.analyse(rules.get_fen(), mini(legal.size(), 40), 12)
		var ms := Time.get_ticks_msec() - t0
		var ranked := _ranked(rules, lines)
		var picks: Dictionary = CB.select_options(ranked)
		var b := _san(rules, picks["best"])
		var d := _san(rules, picks["decent"])
		var bl := _san(rules, picks["blunder"])
		var side := "White" if rules.side_to_move == ChessRules.WHITE else "Black"
		print("ply %d (%s)  best=%s  decent=%s  blunder=%s   [analyse %dms, %d legal]" % [ply, side, b, d, bl, ms, legal.size()])
		# Reply with a mid-skill bot move.
		var uci: String = await sf.best_move(rules.get_fen(), {"skill": 8, "movetime": 150})
		var m := rules.move_from_uci(uci)
		if m == -1:
			print("  bad uci ", uci); break
		rules.make_move(m)

	sf.stop()
	print(">>> SELF-PLAY OK")
	quit(0)


func _ranked(rules: ChessRules, lines: Array) -> Array:
	var by_uci := {}
	for m in rules.generate_legal_moves():
		by_uci[rules.move_to_uci(m)] = m
	var out: Array = []
	for e in lines:
		if by_uci.has(e["uci"]):
			out.append({"move": by_uci[e["uci"]], "score": int(e["score"])})
	out.sort_custom(func(a, b): return a["score"] > b["score"])
	return out


func _pick_good(ranked: Array) -> int:
	if ranked.is_empty(): return -1
	var best: int = ranked[0]["score"]
	var pool: Array = []
	for e in ranked:
		if best - int(e["score"]) <= 55:
			pool.append(e["move"])
	return pool[randi() % pool.size()]


func _san(rules: ChessRules, move: int) -> String:
	return rules.to_san(move) if move >= 0 else "—"
