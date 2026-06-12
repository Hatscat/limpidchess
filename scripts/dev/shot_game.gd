extends SceneTree

## Screenshot the game scene after Stockfish has played the opening and surfaced
## the player's options. Needs a display.
## godot --path . -s res://scripts/dev/shot_game.gd

var scene: Node
var frames := 0

func _initialize() -> void:
	scene = load("res://scenes/game.tscn").instantiate()
	root.add_child(scene)

func _process(_delta: float) -> bool:
	frames += 1
	if frames == 240:  # ~4s: opening + (maybe bot reply) + analysis → options shown
		root.get_texture().get_image().save_png("/tmp/limpid_game.png")
		print("saved /tmp/limpid_game.png")
		return true
	return false
