extends SceneTree

## Whole-project smoke test. Run headless:
##   godot --headless --path . -s res://scripts/dev/validate.gd
## Instantiates every scene (running _ready → catches missing nodes / bad paths /
## parse errors) and drives a few full turns through ChessRules + ChessBot so the
## game pipeline is exercised. Watch the log for ERROR / SCRIPT ERROR lines.

func _initialize() -> void:
	print("=== SCENES ===")
	for s in ["nav_bar", "home", "bots", "premium", "about", "game", "puzzle_rush"]:
		var ps: PackedScene = load("res://scenes/%s.tscn" % s)
		if ps == null:
			print("  ", s, "  *** LOAD FAILED ***")
			continue
		var inst: Node = ps.instantiate()
		root.add_child(inst)  # runs _ready synchronously
		print("  ", s, "  ready ok")
		root.remove_child(inst)
		inst.free()

	print("=== ENGINE + BOT PIPELINE ===")
	var rules := ChessRules.new()
	var bot := ChessBot.new()
	var ChessBotS := load("res://scripts/chess/chess_bot.gd")

	# A handful of full plies: rank, pick options, grade best, play bot reply.
	for ply in 6:
		var ranked: Array = bot.rank_moves(rules, ChessBot.ANALYSIS_DEPTH)
		if ranked.is_empty():
			print("  ply ", ply, " no legal moves (game over)")
			break
		var opts: Dictionary = ChessBotS.select_options(ranked)
		var best_uci := rules.move_to_uci(opts["best"])
		var best_san := rules.to_san(opts["best"])
		var grade: Dictionary = ChessBotS.grade_move(ranked, opts["best"])
		print("  ply ", ply, "  legal=", ranked.size(),
			"  best=", best_san, " (", best_uci, ")",
			"  decent=", (rules.move_to_uci(opts["decent"]) if opts["decent"] >= 0 else "-"),
			"  blunder=", (rules.move_to_uci(opts["blunder"]) if opts["blunder"] >= 0 else "-"),
			"  grade=", grade["label"])
		var mv := bot.choose_move(rules, 2, 0.3)
		rules.make_move(mv)

	print("=== FEN round-trip ===")
	var r2 := ChessRules.new()
	r2.set_fen("r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3")
	print("  fen: ", r2.get_fen())

	print(">>> VALIDATE DONE")
	quit(0)
