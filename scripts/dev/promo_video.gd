extends Node

## Dev-only promo-video driver: plays the REAL app hands-free (scripted taps, drawn
## as touch ripples) so Godot's Movie Maker can record store/YouTube footage of the
## actual gameplay. Nothing here ships. Run one segment per invocation, on a display,
## against a sandboxed save (so the real save file is never touched):
##
##   XDG_DATA_HOME=/tmp/promo_save PROMO_SEG=game godot --path . \
##     --write-movie /tmp/promo/game/f.png --fixed-fps 30 \
##     res://scripts/dev/promo_video.tscn
##
## PROMO_SEG segments:
##   game       home → bots roster → tap Biscuit → full game picking the offered best
##              (one "decent" beat for the blue feedback) → win → result → moves review
##   puzzles    home → Puzzles → a rapid streak of solves (back-to-back, no delay)
##   facetoface home (premium) → Face to Face → a few moves, showing the piece flip
##   endcard    static outro: icon + name + tagline, a few seconds
##
## Movie Maker's --fixed-fps makes every frame an exact 1/30 s tick, so tween/timer
## pacing in the capture is correct no matter how slow the PNG writing is. ffmpeg
## stitching/trimming/music happen outside (see the session notes / store/README.md).

const THINK_SHORT := 0.7   ## human-feel pause before tapping an option
const THINK_FIRST := 1.3   ## slightly longer look at the very first options

var _seg := ""
var _ripple: _TapRipple


## Expanding touch ripple drawn over EVERYTHING (it lives on a high CanvasLayer added
## to the root, so it survives scene changes and is captured into the recording).
class _TapRipple extends Node2D:
	const LIFE := 0.5
	var taps: Array = []  # {pos: Vector2, t: float}

	func add_tap(pos: Vector2) -> void:
		taps.append({"pos": pos, "t": 0.0})

	func _process(delta: float) -> void:
		if taps.is_empty():
			return
		for tp: Dictionary in taps:
			tp["t"] += delta
		taps = taps.filter(func(tp): return float(tp["t"]) < LIFE)
		queue_redraw()

	func _draw() -> void:
		for tp: Dictionary in taps:
			var k: float = float(tp["t"]) / LIFE
			var pos: Vector2 = tp["pos"]
			var r := 20.0 + 52.0 * k
			var a := 1.0 - k
			draw_circle(pos, r, Color(1, 1, 1, 0.30 * a))
			draw_arc(pos, r, 0.0, TAU, 48, Color(1, 1, 1, 0.85 * a), 4.0, true)


func _ready() -> void:
	_seg = OS.get_environment("PROMO_SEG")
	# The recording is English-only (marketing uses high-confidence languages; EN is
	# the listing default). Override whatever the sandbox save / device locale picked.
	GameManager.language = "en"
	TranslationServer.set_locale("en")
	seed(7)  # stable option shuffles etc. between takes
	var layer := CanvasLayer.new()
	layer.layer = 99
	_ripple = _TapRipple.new()
	layer.add_child(_ripple)
	get_tree().root.add_child.call_deferred(layer)
	match _seg:
		"game":
			GameManager.is_premium = true     # show the roster fully unlocked (premium look)
		"puzzles":
			GameManager.puzzle_highscore = 8  # a lived-in "Best" so the streak has a goal
		"facetoface":
			GameManager.is_premium = true     # Face to Face is a premium mode
	_boot.call_deferred()


## The driver boots as the main scene, but scene navigation frees current_scene, so
## first move ourselves to the root (out of the scene slot), THEN enter the app.
func _boot() -> void:
	var tree := get_tree()
	var root := tree.root
	root.remove_child(self)
	root.add_child(self)
	tree.current_scene = null
	if _seg == "endcard":
		_run()  # no app needed, the card draws over the empty window
	else:
		GameManager.go_to_home()
		_run()


func _run() -> void:
	print("promo: segment '", _seg, "' starting")
	match _seg:
		"game": await _seg_game()
		"puzzles": await _seg_puzzles()
		"facetoface": await _seg_facetoface()
		"endcard": await _seg_endcard()
		_:
			push_error("promo: unknown PROMO_SEG '" + _seg + "'")
			get_tree().quit(1)
			return
	print("PROMO_DONE seg=", _seg)
	get_tree().quit()


# --- Small await helpers (movie mode: 1 frame == 1/30 s of video, exactly) ---

func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Poll `cond` each frame; hard-fail the whole take on timeout so a broken run can't
## silently record minutes of nothing.
func _wait_until(cond: Callable, timeout_sec: float, what: String) -> void:
	var waited := 0.0
	while not cond.call():
		await get_tree().process_frame
		waited += get_process_delta_time()
		if waited > timeout_sec:
			push_error("promo: timed out waiting for " + what)
			get_tree().quit(1)
			await _frames(2)  # let quit land
			return


func _scene() -> Node:
	return get_tree().current_scene


func _at(scene_name: String) -> bool:
	var s := _scene()
	return s != null and s.scene_file_path.ends_with(scene_name + ".tscn")


# --- Synthetic touch (real input path: ripple + press, a beat, release) ---

## `pos` is in CANVAS coordinates (what get_global_rect / _square_center return).
## Injected events are parsed in WINDOW coordinates, and the desktop WM can clamp
## the window (stretch scale != 1), so map canvas → window through the final
## transform or the tap lands on the wrong control. Record with a window whose
## aspect matches 720×1280 (e.g. --resolution 540x960) so the canvas stays exact.
func _tap(pos: Vector2) -> void:
	_ripple.add_tap(pos)  # the ripple draws in canvas space, right where the UI is
	var wpos := get_viewport().get_final_transform() * pos
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = wpos
	down.global_position = wpos
	Input.parse_input_event(down)
	await _frames(3)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = wpos
	up.global_position = wpos
	Input.parse_input_event(up)
	await _frames(2)


func _tap_ctrl(c: Control) -> void:
	await _tap(c.get_global_rect().get_center())


## Tap an option arrow on a board: the board hit-tests by DESTINATION square.
func _tap_move(board: Control, move: int) -> void:
	var sq := ChessRules.move_to(move)
	var pos: Vector2 = board.get_global_transform() * board.call("_square_center", sq)
	await _tap(pos)


## The offered option of `quality` (fallback: the best one, always present).
func _find_option(options: Array, quality: String) -> Dictionary:
	for opt: Dictionary in options:
		if String(opt.get("quality", "")) == quality:
			return opt
	for opt: Dictionary in options:
		if String(opt.get("quality", "")) == "best":
			return opt
	return options[0]


# --- Segments ---

## Home → bots (roster glide) → Biscuit → play (best moves; one decent for the blue
## teaching beat) → checkmate → result card → moves review (steps + best-replies line).
func _seg_game() -> void:
	await _wait_until(func(): return _at("home"), 20.0, "home")
	await _wait(1.6)
	await _tap_ctrl(_scene().get_node("Center/VBox/PlayCard"))

	await _wait_until(func(): return _at("bots"), 10.0, "bots")
	await _wait(0.7)
	# Glide the roster so the cast of opponents reads, then settle back on Biscuit.
	var scroll: ScrollContainer = _scene().get_node("%Scroll")
	var tw := create_tween()
	tw.tween_property(scroll, "scroll_vertical", 560, 1.0) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tw.tween_interval(0.3)
	tw.tween_property(scroll, "scroll_vertical", 0, 0.8) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	await tw.finished
	await _wait(0.4)
	var biscuit: Button = _scene().get_node("%List").get_child(3)  # BotRoster.ALL[3]
	await _tap_ctrl(biscuit)

	await _wait_until(func(): return _at("game"), 10.0, "game scene")
	var game := _scene()
	# Deterministic framing: the human plays White (set before the auto-opening lands;
	# nothing has read these yet, _new_game only randomized them a frame ago).
	GameManager.player_is_white = true
	game.player_color = ChessRules.WHITE
	game.board.flipped = false

	var picks := 0
	while not game._game_over:
		await _wait_until(func(): return game._game_over or (
			not game._busy and game.board._interactive and not game.board._options.is_empty()),
			90.0, "options (move %d)" % (picks + 1))
		if game._game_over:
			break
		picks += 1
		await _wait(THINK_FIRST if picks == 1 else THINK_SHORT)
		if game._game_over or game.board._options.is_empty():
			continue
		# The 2nd pick takes the "not bad" option on purpose: the blue reveal + "The
		# best was …" line IS the teaching mechanic, worth 2 seconds of the video.
		var want := "decent" if picks == 2 else "best"
		await _tap_move(game.board, int(_find_option(game.board._options, want)["move"]))
		# The pick is consumed synchronously (busy flips true); wait out reveal + reply.
		await _wait_until(func(): return game._game_over or game.board._options.is_empty(),
			30.0, "move %d commit" % picks)

	await _wait_until(func(): return game.result_overlay.visible, 20.0, "result dialog")
	await _wait(2.0)
	await _tap_ctrl(game.get_node("ResultOverlay/Card/VBox/Buttons/AnalyseBtn"))
	await _wait_until(func(): return game.review_overlay.visible, 10.0, "review overlay")
	await _wait(1.0)
	# The interesting analysis is mid-game where the bot went wrong, not the opening:
	# jump straight before the game's biggest eval swing (Biscuit's blunder), then step
	# ONTO it with an animated Next so the red label + red/green arrows present themselves.
	var blunder_ply := _biggest_swing_ply(game._review)
	game._show_review_ply(blunder_ply - 1, false)
	await _wait(2.0)  # let the on-demand grading land (hourglass → quality arrows)
	await _tap_ctrl(game.review_next)
	await _wait(2.6)  # the mistake panel reads: "Biscuit: … / Blunder!" + both arrows
	# Then the payoff: tap the green best-move arrow → the best-replies line plays out.
	if not game.board._options.is_empty():
		await _tap_move(game.board, int(_find_option(game.board._options, "best")["move"]))
		await _wait(4.5)


## The review ply right before the game's biggest White-ward eval jump between two
## consecutive graded (human) plies: that in-between ply is the opponent's worst move.
## Falls back to ~60% through the game. Kept away from the opening and the mate.
func _biggest_swing_ply(review: Array) -> int:
	var fallback := int(review.size() * 0.6)
	var last_eval := 0
	var last_i := -1
	var best_ply := fallback
	var best_jump := 0
	for i in review.size():
		var e: Dictionary = review[i]
		if e.is_empty():
			continue  # bot / auto-opening plies carry no live grade
		var ev := int(e.get("eval_cp", 0))
		if last_i >= 0 and i > 8 and i < review.size() - 4:
			var jump := ev - last_eval  # positive = the position swung toward the player
			if jump > best_jump:
				best_jump = jump
				best_ply = i - 1  # the bot ply between the two graded ones
		last_eval = ev
		last_i = i
	return clampi(best_ply, 1, review.size() - 1)


## Home → Puzzles → ONE uncut run, shown whole: three complete solves back-to-back,
## then a deliberate wrong pick, so the streak ends on the result dialog instead of
## auto-rolling into a fourth puzzle the video would have to cut mid-air.
func _seg_puzzles() -> void:
	await _wait_until(func(): return _at("home"), 20.0, "home")
	await _wait(1.2)
	await _tap_ctrl(_scene().get_node("Center/VBox/PuzzleRush"))
	await _wait_until(func(): return _at("puzzle_rush"), 10.0, "puzzle scene")
	var pz := _scene()
	# Two whole puzzles, checked when each new move is PRESENTED (checking right after a
	# tap raced the solve animation and overshot the count by one puzzle in an early take).
	var taps := 0
	while taps < 10:
		await _wait_until(func(): return not pz._busy and not pz.board._options.is_empty(),
			30.0, "puzzle options (tap %d)" % (taps + 1))
		if pz._streak >= 2:
			break
		taps += 1
		await _wait(0.5)  # snappy: the point is the no-delay flow
		await _tap_move(pz.board, pz._solution)
		await _wait_until(func(): return pz._busy or pz.board._options.is_empty(),
			15.0, "puzzle tap %d commit" % taps)
	# Third puzzle: pick a distractor on purpose → red reveal, "Wrong move!", and the
	# run-over dialog (streak 2). Errors are the lesson, and it ends on a readable screen.
	await _wait(0.8)
	var wrong: Dictionary = {}
	for opt: Dictionary in pz.board._options:
		if String(opt.get("quality", "")) != "best":
			wrong = opt
			break
	if wrong.is_empty():
		wrong = _find_option(pz.board._options, "best")  # no distractor: end on a solve instead
	await _tap_move(pz.board, int(wrong["move"]))
	await _wait_until(func(): return pz.result_overlay.visible, 15.0, "puzzle result dialog")
	await _wait(2.4)


## Home → Face to Face: a few moves so the pieces-flip (real-board feel) shows.
func _seg_facetoface() -> void:
	await _wait_until(func(): return _at("home"), 20.0, "home")
	await _wait(1.2)
	await _tap_ctrl(_scene().get_node("Center/VBox/PassPlay"))
	await _wait_until(func(): return _at("game"), 10.0, "face to face scene")
	var game := _scene()
	for ply in 4:
		await _wait_until(func(): return game._game_over or (
			not game._busy and game.board._interactive and not game.board._options.is_empty()),
			60.0, "f2f options (ply %d)" % (ply + 1))
		if game._game_over:
			break
		await _wait(0.9)
		await _tap_move(game.board, int(_find_option(game.board._options, "best")["move"]))
		await _wait_until(func(): return game._game_over or game.board._options.is_empty(),
			30.0, "f2f ply %d commit" % (ply + 1))
	await _wait(1.0)


## Static outro card: icon + name + tagline, in the app's own theme.
func _seg_endcard() -> void:
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = UI.BG_DARK
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(bg)
	var center := VBoxContainer.new()
	center.set_anchors_preset(Control.PRESET_CENTER)
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_theme_constant_override("separation", 28)
	var icon := TextureRect.new()
	icon.texture = load("res://assets/icon/adaptive_fg_432.png")
	icon.custom_minimum_size = Vector2(300, 300)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	center.add_child(icon)
	var title := Label.new()
	title.text = "Limpid Chess"
	title.add_theme_font_size_override("font_size", 64)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center.add_child(title)
	var tag := Label.new()
	tag.text = "Find the best move."
	tag.add_theme_font_size_override("font_size", 32)
	tag.modulate = UI.TEXT_DIM
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center.add_child(tag)
	host.add_child(center)
	get_tree().root.add_child(host)
	center.reset_size()
	await _frames(2)
	center.position = (host.size - center.size) * 0.5
	await _wait(4.0)
