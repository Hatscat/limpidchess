extends SceneTree

## Probe: can we drive Stockfish over a UCI pipe from Godot 4.6?
## godot --headless --path . -s res://scripts/dev/test_stockfish.gd

const SF := "/usr/games/stockfish"

func _initialize() -> void:
	var sf := OS.execute_with_pipe(SF, [])
	if sf.is_empty():
		print("*** FAILED to launch ", SF)
		quit(1); return
	var io: FileAccess = sf["stdio"]
	print("launched pid=", sf.get("pid", -1))

	io.store_line("uci")
	io.store_line("isready")
	var handshake := 0
	while io.is_open() and not io.eof_reached():
		var line := io.get_line()
		handshake += 1
		if line == "readyok":
			break
	print("handshake lines until readyok: ", handshake)

	io.store_line("setoption name MultiPV value 5")
	io.store_line("position startpos")
	io.store_line("go depth 12")

	var multipv := {}  # multipv index -> last info line
	var best := ""
	while io.is_open() and not io.eof_reached():
		var line := io.get_line()
		if line.begins_with("info ") and line.find(" multipv ") != -1 and line.find(" pv ") != -1:
			var parts := line.split(" ")
			var k := int(parts[parts.find("multipv") + 1])
			multipv[k] = line
		elif line.begins_with("bestmove"):
			best = line
			break

	print("bestmove: ", best)
	print("MultiPV top moves from startpos:")
	for k in [1, 2, 3, 4, 5]:
		if multipv.has(k):
			var p: PackedStringArray = multipv[k].split(" ")
			var mv := p[p.find("pv") + 1]
			var sc := ""
			var si := p.find("score")
			if si != -1:
				sc = "%s %s" % [p[si + 1], p[si + 2]]
			print("  multipv %d  move=%s  score=%s" % [k, mv, sc])

	io.store_line("quit")
	print(">>> STOCKFISH PIPE OK")
	quit(0)
