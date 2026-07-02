extends SceneTree

## Dev-only: render the Face to Face (Pass & Play) end-game result dialog, to check the "Leave" button
## now carries the white-door (exit.png) icon like the Puzzles end modal.
##   DISPLAY=:0 godot --path . -s res://scripts/dev/shot_faceoff_result.gd   -> /tmp/limpid_faceoff_result.png

var vp: SubViewport
var game
var frames := 0


func _initialize() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(1560, 2778)
	vp.size_2d_override = Vector2i(720, 1280)
	vp.size_2d_override_stretch = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)


func _process(_d: float) -> bool:
	frames += 1
	if frames == 1:
		TranslationServer.set_locale("fr")  # the user's screenshot is French
		var gm: Node = root.get_node("GameManager")
		gm.is_premium = true
		gm.pass_and_play = true
		gm.player_is_white = true
		game = load("res://scenes/game.tscn").instantiate()
		vp.add_child(game)
		return false
	if frames == 30:
		# Fabricate a finished game with a plausible tally, then show the checkmate result dialog.
		game._game_over = true
		game._best[0] = 11; game._best[1] = 6
		game._decent[0] = 2; game._decent[1] = 3
		game._blunder[0] = 1; game._blunder[1] = 4
		game._show_result(tr("Checkmate"), tr("White wins!"), "win")
		return false
	if frames == 40:
		vp.get_texture().get_image().save_png("/tmp/limpid_faceoff_result.png")
		print("saved /tmp/limpid_faceoff_result.png")
		print("HomeBtn text=%s icon=%s (expect Quitter + exit.png)" % [
			game.home_btn.text, game.home_btn.icon.resource_path if game.home_btn.icon else "<none>"])
		quit()
	return false
