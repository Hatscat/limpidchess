extends Node

## Live-tree test of the embedded engine (run as a scene, not a -s script):
##   godot --headless --path . res://scripts/dev/test_live.tscn
const START := "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

func _ready() -> void:
	print("live tree=", get_tree() != null, "  inside=", is_inside_tree())
	var sf := StockfishEngine.new()
	add_child(sf)
	var ok := sf.start()
	print("start=", ok, "  transport=", sf._mode)
	var lines: Array = await sf.analyse(START, 5, 10)
	print("analyse → ", lines.size(), " moves")
	for i in mini(5, lines.size()):
		print("  ", lines[i]["uci"], "  cp=", lines[i]["score"])
	var bm: String = await sf.best_move(START, {"skill": 6, "movetime": 150})
	print("best_move(skill 6) → ", bm)
	print(">>> LIVE OK")
	get_tree().quit()
