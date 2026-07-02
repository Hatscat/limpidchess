extends SceneTree

## Dev-only: render the Puzzles screen at design scale to check the header (no more "Difficulty", new
## title). godot --path . -s res://scripts/dev/shot_puzzle.gd  (needs a display) -> /tmp/limpid_puzzle.png

var vp: SubViewport
var frames := 0
var setup := false


func _initialize() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(1560, 2778)
	vp.size_2d_override = Vector2i(720, 1280)
	vp.size_2d_override_stretch = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)


func _process(_d: float) -> bool:
	frames += 1
	if not setup:
		var gm: Node = root.get_node("GameManager")
		gm.is_premium = true
		gm.puzzle_highscore = 15
		gm.pending_puzzle_resume = false
		gm.puzzle_result = {}
		gm.puzzle_index = -1
		vp.add_child(load("res://scenes/puzzle_rush.tscn").instantiate())
		setup = true
		frames = 0
		return false
	if frames >= 60:
		vp.get_texture().get_image().save_png("/tmp/limpid_puzzle.png")
		print("saved /tmp/limpid_puzzle.png")
		quit()
	return false
