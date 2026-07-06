extends SceneTree

## Dev-only: verify the newly added languages actually RENDER with the bundled OpenDyslexic font
## (Cyrillic, Vietnamese diacritics, Turkish/Polish extended Latin) instead of tofu boxes, and that
## the language picker lists every language in its own script + flag.
##   DISPLAY=:0 godot --path . -s res://scripts/dev/shot_langs.gd
## -> /tmp/limpid_lang_picker.png + /tmp/limpid_home_<code>.png

var vp: SubViewport
var steps := [
	{"lang": "en", "picker": true, "out": "/tmp/limpid_lang_picker13.png"},
	{"lang": "uk", "picker": false, "out": "/tmp/limpid_home_uk.png"},
	{"lang": "el", "picker": false, "out": "/tmp/limpid_home_el.png"},
]
var idx := -1
var home: Node
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
	home = load("res://scenes/home.tscn").instantiate()
	vp.add_child(home)
	wait = 0


func _process(_d: float) -> bool:
	if idx == -1:
		_next()
		return false
	wait += 1
	var s: Dictionary = steps[idx]
	if wait == 6 and bool(s["picker"]):
		home.settings_overlay.visible = true
		home._build_lang_picker()
		home.lang_picker.visible = true
	if wait == 14:
		vp.get_texture().get_image().save_png(s["out"])
		print("saved ", s["out"])
		home.queue_free()
		_next()
	return false
