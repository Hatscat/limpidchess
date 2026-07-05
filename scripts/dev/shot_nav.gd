extends SceneTree

## Dev-only: render the reworked navigation scenes at design scale.
##   DISPLAY=:0 godot --path . -s res://scripts/dev/shot_nav.gd  -> /tmp/limpid_nav_*.png

# (scene, is_premium, mode)  mode: "" | "settings" | "langpicker"
var shots := [
	["home", true, ""],
	["home", true, "settings"],   # settings dialog (shows the single Language row + About)
	["home", true, "langpicker"], # the scrollable language picker open
	["bots", false, ""],          # non-premium: shows locked bots + new title/spacing
	["premium", false, ""],
	["about", true, ""],
]
var idx := 0
var vp: SubViewport
var cur: Node
var frames := 0


func _initialize() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(1560, 2778)
	vp.size_2d_override = Vector2i(720, 1280)
	vp.size_2d_override_stretch = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	_load()


func _load() -> void:
	if cur:
		vp.remove_child(cur)
		cur.free()
		cur = null
	if idx >= shots.size():
		quit()
		return
	var gm: Node = root.get_node("GameManager")
	gm.is_premium = bool(shots[idx][1])
	cur = load("res://scenes/%s.tscn" % shots[idx][0]).instantiate()
	vp.add_child(cur)
	frames = 0


func _process(_d: float) -> bool:
	if cur == null:
		return false
	frames += 1
	var mode: String = shots[idx][2]
	if frames == 6 and mode != "":
		cur._on_settings_pressed()  # open the settings dialog
		if mode == "langpicker":
			cur._on_language_btn_pressed()  # then open the language picker on top
	if frames == 14:
		var name := "%s%s" % [shots[idx][0], "_" + mode if mode != "" else ""]
		vp.get_texture().get_image().save_png("/tmp/limpid_nav_%s.png" % name)
		print("saved /tmp/limpid_nav_%s.png" % name)
		idx += 1
		call_deferred("_load")
	return false
