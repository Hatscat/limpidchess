extends SceneTree

## Dev-only: verify the marketing-screenshot position is legal and the three chosen
## moves do what the copy claims (best = Qxf7 mate, blunder = Qxe5 hangs the queen).
##   godot --headless --path . -s res://scripts/dev/verify_shot_position.gd

const Rules := preload("res://scripts/chess/chess_rules.gd")

func _init() -> void:
	var r := Rules.new()
	var fen := "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4"
	var ok := r.set_fen(fen)
	print("set_fen ok=", ok, "  white to move=", r.side_to_move == Rules.WHITE, "  in check now=", r.is_in_check())

	for uci in ["h5f7", "b1c3", "h5e5"]:
		var m: int = r.move_from_uci(uci)
		print("  ", uci, "  packed=", m, "  from=", (m & 63), "  to=", ((m >> 6) & 63), "  legal=", m >= 0)

	# best = Qxf7 must be checkmate
	var mf: int = r.move_from_uci("h5f7")
	var uf: Dictionary = r.make_move(mf)
	print("after Qxf7:  black in check=", r.is_in_check(), "  checkmate=", r.is_checkmate())
	r.undo_move(mf, uf)

	# blunder = Qxe5 must let Black win the queen with Nc6xe5
	var mb: int = r.move_from_uci("h5e5")
	var ub: Dictionary = r.make_move(mb)
	var reply: int = r.move_from_uci("c6e5")
	print("after Qxe5:  Nxe5 legal (queen hangs)=", reply >= 0)
	r.undo_move(mb, ub)

	# sanity: fen round-trips
	print("fen round-trip ok=", r.get_fen().begins_with("r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w"))
	quit()
