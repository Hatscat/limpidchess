extends SceneTree

## Visual smoke test: render each scene to a real window and save a PNG.
## Run on a machine with a display:
##   godot --path . -s res://scripts/dev/screenshot.gd
## Exercises _draw() (board, arrows, pieces) which the headless dummy renderer
## skips. Outputs /tmp/limpid_<scene>.png.

var shots := ["game", "home", "bots", "premium", "about"]
var idx := 0
var current: Node = null
var wait := 0

func _initialize() -> void:
	_load_next()

func _load_next() -> void:
	if current:
		root.remove_child(current)
		current.free()
		current = null
	if idx >= shots.size():
		quit()
		return
	current = load("res://scenes/%s.tscn" % shots[idx]).instantiate()
	root.add_child(current)
	wait = 0

func _process(_delta: float) -> bool:
	if current == null:
		return false
	wait += 1
	if wait == 12:
		var img := root.get_texture().get_image()
		img.save_png("/tmp/limpid_%s.png" % shots[idx])
		print("saved /tmp/limpid_%s.png" % shots[idx])
		idx += 1
		call_deferred("_load_next")
	return false
