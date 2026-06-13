extends Node
var game: Node
var frames := 0
var a_frame := -1
var picked := false
var pf := -1
func _ready() -> void:
	game = load("res://scenes/game.tscn").instantiate()
	add_child(game)
func _process(_d: float) -> void:
	frames += 1
	var b = game.get_node("%Board")
	if a_frame < 0 and not b._options.is_empty() and not game._busy:
		a_frame = frames
	if a_frame > 0 and frames == a_frame + 3:
		get_window().get_texture().get_image().save_png("/tmp/limpid_arrows.png")
	if a_frame > 0 and frames == a_frame + 8 and not picked:
		b.option_chosen.emit(b._options[0]); picked = true; pf = frames
	if picked and frames == pf + 90:   # past the ~1.2s slide, into the hold
		get_window().get_texture().get_image().save_png("/tmp/limpid_hold.png")
		get_tree().quit()
	if frames > 800:
		get_tree().quit()
