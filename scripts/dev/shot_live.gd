extends Node
## Render the game at TRUE phone size (720x1280) in a live tree (engine + tweens
## work), regardless of the desktop display. -> /tmp/limpid_game.png
##   godot --path . res://scripts/dev/shot_live.tscn
var vpc: SubViewport
var frames := 0
func _ready() -> void:
	vpc = SubViewport.new()
	vpc.size = Vector2i(720, 1280)
	vpc.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vpc)
	vpc.add_child(load("res://scenes/game.tscn").instantiate())
func _process(_d: float) -> void:
	frames += 1
	if frames == 320:
		vpc.get_texture().get_image().save_png("/tmp/limpid_game.png")
		get_tree().quit()
