extends SceneTree

## Dev-only headless check: the checked-king shake state machine (processing toggled with the check,
## phase advances, resets on a new/cleared check, and freezes while the mated king explodes).
##   godot --headless --path . -s res://scripts/dev/test_check_shake.gd

const BoardScript := preload("res://scripts/ui/chess_board.gd")

var ok := true


func _fail(m: String) -> void:
	ok = false
	print("  FAIL: ", m)


func _initialize() -> void:
	var b: Node = BoardScript.new()
	root.add_child(b)  # runs _ready -> set_process(false)

	if b.is_processing():
		_fail("processing should be OFF with no check")

	b.set_check_square(4)  # e1
	if b.check_square != 4:
		_fail("check_square not set")
	if not b.is_processing():
		_fail("processing should be ON while in check")

	b._check_shake = 0.0
	b._process(0.1)
	if b._check_shake <= 0.0:
		_fail("shake phase must advance in _process while checked")

	b._check_shake = 0.5
	b.set_check_square(4)  # same square
	if absf(b._check_shake - 0.5) > 0.0001:
		_fail("same check square should NOT restart the phase")

	b.set_check_square(5)  # different square
	if b._check_shake != 0.0:
		_fail("a new checked king should restart the phase")

	# A mated king shatters instead of shaking: the phase must not advance during the explosion.
	b.set_check_square(4)
	b._explode_active = true
	b._check_shake = 0.0
	b._process(0.1)
	if b._check_shake != 0.0:
		_fail("shake must freeze while the king is exploding")
	b._explode_active = false

	b.set_check_square(-1)  # check clears
	if b.is_processing():
		_fail("processing should be OFF once the check clears")

	# A game/run ending WHILE in check (draw / wrong puzzle pick) must not leave the board processing:
	# clear_options() has to drop the check state, not just the options.
	b.set_check_square(4)
	if not b.is_processing():
		_fail("precondition: should be processing while checked")
	b.clear_options()
	if b.check_square != -1:
		_fail("clear_options must drop check_square (game/run ended in check)")
	if b.is_processing():
		_fail("clear_options must stop the shake tick (no forever-redraw behind the result overlay)")

	print("check shake: processing/phase/reset/explode-gate/clear-options all correct")
	print("CHECK SHAKE TEST: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
