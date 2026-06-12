extends SceneTree

## Direct binding test with REAL-TIME waits (bypasses frame-based polling).
## godot --headless --path . -s res://scripts/dev/test_ext_direct.gd

func _initialize() -> void:
	var sf: Object = ClassDB.instantiate("StockfishGD")
	print("start: ", sf.call("start"))
	sf.call("send", "uci")
	sf.call("send", "isready")
	OS.delay_msec(400)
	var lines: PackedStringArray = sf.call("poll_lines")
	print("handshake lines: ", lines.size(), "  last: ", (lines[lines.size() - 1] if lines.size() > 0 else "NONE"))

	sf.call("send", "setoption name MultiPV value 4")
	sf.call("send", "position startpos")
	sf.call("send", "go depth 10")
	var best := ""
	var infos := 0
	for i in 80:
		OS.delay_msec(50)
		for l in sf.call("poll_lines"):
			if l.begins_with("bestmove"):
				best = l
			elif l.begins_with("info ") and l.find(" pv ") != -1:
				infos += 1
		if best != "":
			break
	print("info lines seen: ", infos)
	print("bestmove: ", (best if best != "" else "*** NONE after 4s ***"))
	sf.call("stop")
	quit(0)
