extends SceneTree

## Rebuild assets/puzzles.res (the SHIPPED puzzle data) from assets/puzzles.txt (the editable source).
## Run after changing the puzzle set:
##   godot --headless --path . -s res://scripts/dev/build_puzzles.gd
## See [PuzzleData] for why the data ships as a resource rather than the plain .txt.

const SRC := "res://assets/puzzles.txt"
const OUT := "res://assets/puzzles.res"


func _initialize() -> void:
	var f := FileAccess.open(SRC, FileAccess.READ)
	if f == null:
		push_error("build_puzzles: cannot open %s" % SRC)
		quit()
		return
	var text := f.get_as_text()
	var d := PuzzleData.new()
	d.raw = text
	# FLAG_COMPRESS keeps the bundled resource small (the data compresses well); load() is transparent.
	var err := ResourceSaver.save(d, OUT, ResourceSaver.FLAG_COMPRESS)
	var lines := text.split("\n", false)
	print("build_puzzles: saved %s err=%d chars=%d lines=%d" % [OUT, err, text.length(), lines.size()])
	quit()
