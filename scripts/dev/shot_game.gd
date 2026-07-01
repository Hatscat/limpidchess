extends SceneTree

## Dev-only: render the in-game screen at 3x phone res for the Play listing, driven to a FIXED
## obvious position (Scholar's mate). Captures the neutral "before" and the revealed "after".
##   godot --path . -s res://scripts/dev/shot_game.gd   (needs a display)
##   -> /tmp/limpid_game_before.png, /tmp/limpid_game_after.png  (1560x2778)

const Rules := preload("res://scripts/chess/chess_rules.gd")

const FEN := "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4"
const BEST := 39 | (53 << 6)     # Qh5xf7#
const DECENT := 1 | (18 << 6)    # Nb1-c3
const BLUNDER := 39 | (36 << 6)  # Qh5xe5

var vp: SubViewport
var game
var frames := 0


func _initialize() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(1560, 2778)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)


func _process(_d: float) -> bool:
	frames += 1
	if frames == 1:
		var gm: Node = root.get_node("GameManager")
		gm.is_premium = false
		gm.games_today = 0
		gm.player_is_white = true
		gm.pass_and_play = false
		gm.pending_review_check = false
		gm.current_bot = BotRoster.get_by_id("reynard")
		game = load("res://scenes/game.tscn").instantiate()
		vp.add_child(game)
		return false
	if frames == 40:
		_inject()
		return false
	if frames == 58:
		vp.get_texture().get_image().save_png("/tmp/limpid_game_before.png")
		print("saved /tmp/limpid_game_before.png")
		game.board._chosen_move = BEST
		game.board.reveal()
		game.feedback.text = tr("★ Best move!")
		game.status_label.text = ""
		return false
	if frames == 74:
		vp.get_texture().get_image().save_png("/tmp/limpid_game_after.png")
		print("saved /tmp/limpid_game_after.png")
		quit()
	return false


## Force the live game onto our fixed position with consistent chrome, cancelling any in-flight
## turn coroutine (bump _gen so it bails at its guard). No captures happened -> empty trays.
func _inject() -> void:
	game._gen += 1
	game._busy = false
	game._game_over = false
	game.player_color = Rules.WHITE
	game.board.flipped = false
	game.rules.set_fen(FEN)
	game.board.set_rules(game.rules)
	game.board.clear_last_moves()
	game._caps_white = PackedInt32Array()
	game._caps_black = PackedInt32Array()
	game._update_captured()
	game.eval_bar.set_eval(1500)   # White is winning (mate available)
	game.board.set_check_square(-1)
	game.board.set_options([
		{"move": BLUNDER, "quality": "blunder"},
		{"move": DECENT, "quality": "decent"},
		{"move": BEST, "quality": "best"},
	], true)
	game.status_label.text = "Your move, find the best!"
	game.feedback.text = ""
