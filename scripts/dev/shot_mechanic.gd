extends SceneTree

## Dev-only: render the "how it works" board pair (neutral -> revealed) at 760x760 for the
## website. Needs a display (renders _draw): godot --path . -s res://scripts/dev/shot_mechanic.gd
##
## Scholar's mate example (White to move): best = Qxf7# (mate), OK = Nc3 (develops, misses it),
## blunder = Qxe5 (hangs the queen to Nxe5). Near-full board, universally recognizable.

const Rules := preload("res://scripts/chess/chess_rules.gd")
const BoardScript := preload("res://scripts/ui/chess_board.gd")

const FEN := "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4"
const BEST := 39 | (53 << 6)     # Qh5xf7#
const DECENT := 1 | (18 << 6)    # Nb1-c3
const BLUNDER := 39 | (36 << 6)  # Qh5xe5??

var vp: SubViewport
var board
var rules
var frames := 0
var revealed := false


func _initialize() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(760, 760)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	board = BoardScript.new()
	vp.add_child(board)
	board.position = Vector2.ZERO
	board.size = Vector2(760, 760)
	rules = Rules.new()
	rules.set_fen(FEN)
	board.set_rules(rules)
	board.set_check_square(-1)
	board.set_options([
		{"move": BLUNDER, "quality": "blunder"},
		{"move": DECENT, "quality": "decent"},
		{"move": BEST, "quality": "best"},
	], false)


func _process(_d: float) -> bool:
	frames += 1
	if frames < 8:
		return false
	if not revealed:
		vp.get_texture().get_image().save_png("/tmp/limpid_mechanic_neutral.png")
		print("saved /tmp/limpid_mechanic_neutral.png")
		board.reveal()
		revealed = true
		frames = 0
		return false
	vp.get_texture().get_image().save_png("/tmp/limpid_mechanic_revealed.png")
	print("saved /tmp/limpid_mechanic_revealed.png")
	quit()
	return false
