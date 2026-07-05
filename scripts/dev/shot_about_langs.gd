extends SceneTree

## Dev-only: render the About screen (multi-line bbcode credits block) in two non-Latin locales to
## confirm the credits translated AND the [url=...]/[b] tags + license names survived the CSV import.
##   DISPLAY=:0 godot --path . -s res://scripts/dev/shot_about_langs.gd

var vp: SubViewport
var steps := [
	{"lang": "fr", "out": "/tmp/limpid_about_fr.png"},
	{"lang": "ru", "out": "/tmp/limpid_about_ru.png"},
	{"lang": "vi", "out": "/tmp/limpid_about_vi.png"},
]
var idx := -1
var about: Node
var wait := 0


func _initialize() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(1560, 2778)
	vp.size_2d_override = Vector2i(720, 1280)
	vp.size_2d_override_stretch = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)


func _next() -> void:
	idx += 1
	if idx >= steps.size():
		quit()
		return
	var s: Dictionary = steps[idx]
	root.get_node("GameManager").set_language(s["lang"])
	about = load("res://scenes/about.tscn").instantiate()
	vp.add_child(about)
	wait = 0


func _process(_d: float) -> bool:
	if idx == -1:
		_next()
		return false
	wait += 1
	if wait == 14:
		vp.get_texture().get_image().save_png(steps[idx]["out"])
		print("saved ", steps[idx]["out"])
		about.queue_free()
		_next()
	return false
