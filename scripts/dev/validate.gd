extends SceneTree

## Whole-project smoke test. Run headless:
##   godot --headless --path . -s res://scripts/dev/validate.gd
## Instantiates every scene (running _ready → catches missing nodes / bad paths /
## parse errors) and drives a few full turns through ChessRules + ChessBot so the
## game pipeline is exercised. Watch the log for ERROR / SCRIPT ERROR lines.
## `... validate.gd -- --itch` runs the same pass as the itch.io build (see Itch), and also
## checks that its Premium screen shows no price and no key button, and leads out: Google Play
## on the main button, the website on the second.
##
## Everything runs on the first frame, not in _initialize(): the root only enters the tree
## after _initialize() returns, so a scene added and freed there never gets its _ready().
## Some _ready()s save (puzzle_rush parks a new run), so the player's save is put back
## exactly as it was afterwards: validate runs against the developer's real save.

var _ran := false


func _process(_delta: float) -> bool:
	if _ran:
		return false
	_ran = true
	# Autoloads are not identifiers in a -s script, hence the lookup.
	var gm: Node = root.get_node("GameManager")
	var save_path: String = gm.get_script().get_script_constant_map()["SAVE_PATH"]
	var had_save := FileAccess.file_exists(save_path)
	var before: PackedByteArray = FileAccess.get_file_as_bytes(save_path) if had_save else PackedByteArray()
	var ok := _validate()
	if had_save:
		var f := FileAccess.open(save_path, FileAccess.WRITE)
		f.store_buffer(before)
		f.close()
	elif FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	print(">>> VALIDATE DONE" if ok else ">>> VALIDATE FAILED")
	quit(0 if ok else 1)
	return false


func _validate() -> bool:
	var ok := true
	print("=== SCENES ===")
	for s in ["home", "bots", "premium", "about", "game", "puzzle_rush"]:
		var ps: PackedScene = load("res://scenes/%s.tscn" % s)
		if ps == null:
			print("  ", s, "  *** LOAD FAILED ***")
			ok = false
			continue
		var inst: Node = ps.instantiate()
		root.add_child(inst)  # inside the tree: runs _ready synchronously
		print("  ", s, "  ready ok" if inst.is_node_ready() else "  *** NOT READY ***")
		ok = ok and inst.is_node_ready()
		if s == "premium" and Itch.on:
			# itch.io: no price, no key button, and two ways out (Google Play first, then the
			# website), unless already Premium.
			var premium: bool = root.get_node("GameManager").get("is_premium")
			var get_button: Button = inst.get_node("%GetButton")
			var secondary_button: Button = inst.get_node("%SecondaryButton")
			var restore_button: Button = inst.get_node("%RestoreButton")
			var price_label: Label = inst.get_node("%PriceLabel")
			var no_price: String = inst.tr("Premium is a one-time purchase in the Android app or on the website.")
			var links_out := not restore_button.visible and price_label.text == no_price \
					and get_button.visible != premium and secondary_button.visible != premium \
					and (premium or (get_button.text == inst.tr("Get it on Google Play")
						and secondary_button.text == inst.tr("Play on the website")))
			print("  premium (itch)  ", "links out ok" if links_out
					else "*** WRONG: '%s' / '%s' / '%s' ***" % [get_button.text, secondary_button.text, price_label.text])
			ok = ok and links_out
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
	return ok
