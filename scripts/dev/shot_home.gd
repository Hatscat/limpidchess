extends SceneTree

## Dev-only: render the Home screen at 3x phone res for the website + Play listing.
## Needs a display: godot --path . -s res://scripts/dev/shot_home.gd  -> /tmp/limpid_home.png (1560x2778)

var vp: SubViewport
var home: Node
var frames := 0
var setup_done := false


func _initialize() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(1560, 2778)
	# Render at the game's DESIGN scale (720x1280 + canvas_items stretch, see project.godot) but at high
	# resolution, so the UI fills the frame exactly like on a phone instead of drawing tiny at native px.
	vp.size_2d_override = Vector2i(720, 1280)
	vp.size_2d_override_stretch = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)


func _process(_d: float) -> bool:
	frames += 1
	if not setup_done:
		var gm: Node = root.get_node("GameManager")
		gm.is_premium = false
		gm.games_today = 0                       # -> "3 / 3 today"
		gm.puzzle_highscore = 15                 # -> "Best: 15" on the Puzzles button
		gm.puzzle_index = -1                     # no parked run -> "New puzzle streak" state
		gm.puzzle_streak = 0
		gm.pending_review_check = false          # never pop the rating dialog in a shot
		gm.current_bot = BotRoster.get_by_id("reynard")  # friendly fox, matches old art
		home = load("res://scenes/home.tscn").instantiate()
		vp.add_child(home)
		setup_done = true
		frames = 0
		return false
	if frames >= 24:
		vp.get_texture().get_image().save_png("/tmp/limpid_home.png")
		print("saved /tmp/limpid_home.png")
		quit()
	return false
