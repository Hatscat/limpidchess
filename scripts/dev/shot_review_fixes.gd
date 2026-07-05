extends SceneTree

## Dev-only: render the two screens most touched by the translation-review fixes, to confirm they
## render + no overflow: Premium perks (de "Zu zweit", ru Cyrillic "Премиум") and Bots (ru tiers).
##   DISPLAY=:0 godot --path . -s res://scripts/dev/shot_review_fixes.gd

var vp: SubViewport
var steps := [
	{"lang": "de", "scene": "res://scenes/premium.tscn", "out": "/tmp/limpid_premium_de.png"},
	{"lang": "ru", "scene": "res://scenes/premium.tscn", "out": "/tmp/limpid_premium_ru.png"},
	{"lang": "ru", "scene": "res://scenes/bots.tscn", "out": "/tmp/limpid_bots_ru.png"},
]
var idx := -1
var node: Node
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
	node = load(s["scene"]).instantiate()
	vp.add_child(node)
	wait = 0


func _process(_d: float) -> bool:
	if idx == -1:
		_next()
		return false
	wait += 1
	if wait == 14:
		vp.get_texture().get_image().save_png(steps[idx]["out"])
		print("saved ", steps[idx]["out"])
		node.queue_free()
		_next()
	return false
