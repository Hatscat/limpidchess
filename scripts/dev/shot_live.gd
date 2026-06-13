extends Node
## Screenshot the running game in a LIVE tree (engine + tween animations work):
##   godot --path . res://scripts/dev/shot_live.tscn   → /tmp/limpid_game.png
var frames := 0
func _ready() -> void:
	add_child(load("res://scenes/game.tscn").instantiate())
func _process(_d: float) -> void:
	frames += 1
	if frames == 320:
		get_window().get_texture().get_image().save_png("/tmp/limpid_game.png")
		get_tree().quit()
