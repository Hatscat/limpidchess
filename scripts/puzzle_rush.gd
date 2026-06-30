extends Control

## Puzzle Rush: a rising-difficulty streak of bundled Lichess puzzles (see [Puzzles]). Each puzzle
## offers 3 moves, the solution + 2 plausible distractors (the shallow GDScript ranker's top other
## moves make tempting traps), shuffled and shown neutrally. The first wrong pick ends the run.
## Difficulty (puzzle rating) climbs with the streak; the highscore is the longest streak (saved).
## No eval bar. The daily-run cap (free) is enforced by callers (Home / Retry) via can_puzzle_today().

const ChessRules := preload("res://scripts/chess/chess_rules.gd")
const ChessBotScript := preload("res://scripts/chess/chess_bot.gd")
const DifficultyPips := preload("res://scripts/ui/difficulty_pips.gd")

const START_RATING := 400    ## difficulty of the first puzzle (beginner / kid friendly)
const RATING_STEP := 70       ## +rating per solved puzzle
const MAX_RATING := 2600      ## the difficulty climb caps here (the data goes to 2699)
const SETUP_SLIDE := 0.28     ## the opponent's setup move slides in
const MOVE_SLIDE := 0.28      ## a played move slides
const REPLY_HOLD := 0.35      ## beat between the player's move and the opponent's reply (multi-move)
const CORRECT_HOLD := 0.5     ## beat after fully solving a puzzle before the next one
const WRONG_HOLD := 1.35      ## let the red/green reveal sink in before the result
const RANK_DEPTH := 1         ## 1-ply ranker for the 2 distractors: ~instant, and greedy = tempting traps
const MATE_EXPLODE_SEC := 0.7 ## checkmate: how long the losing king's shatter plays (matches game.gd)

@onready var board: Control = %Board
@onready var diff_pips: DifficultyPips = %DiffPips
@onready var streak_value: Label = %StreakValue
@onready var best_value: Label = %BestValue
@onready var celebrate: TextureRect = %Celebrate
@onready var status_label: Label = %Status
@onready var result_overlay: Control = %ResultOverlay
@onready var result_title: Label = %ResultTitle
@onready var result_stats: Label = %ResultStats
@onready var result_celebrate: TextureRect = %ResultCelebrate
@onready var retry_btn: Button = %RetryBtn
@onready var continue_btn: Button = %ContinueBtn
@onready var menu_btn: Button = %MenuBtn
@onready var menu_overlay: Control = %MenuOverlay
@onready var leave_btn: Button = %LeaveBtn
@onready var keep_btn: Button = %KeepPlayingBtn
@onready var daily_limit: DailyLimitDialog = %DailyLimit

var rules: ChessRules
var bot
var _gen := 0                 ## bumped on each puzzle / end; async steps bail if it changes
var _busy := false
var _over := false
var _streak := 0
var _best_at_start := 0       ## highscore to beat (captured at run start)
var _max_solved := 0          ## hardest puzzle rating solved this run
var _cur_rating := 0
var _solution := -1           ## the correct move (packed int) the player must find right now
var _moves: PackedStringArray = PackedStringArray()  ## the current puzzle's full move list (UCI)
var _move_idx := 0            ## index into _moves of the player's move to solve now (odd indices)
var _used: Dictionary = {}    ## puzzle indices used this run (no repeats)


func _ready() -> void:
	rules = ChessRules.new()
	bot = ChessBotScript.new()
	board.set_rules(rules)
	board.option_chosen.connect(_on_option_chosen)
	result_overlay.visible = false
	celebrate.visible = false
	result_celebrate.visible = false
	retry_btn.icon = load("res://assets/icons/restart.png")
	continue_btn.icon = load("res://assets/icons/home.png")
	menu_btn.icon = load("res://assets/icons/menu.png")
	leave_btn.icon = load("res://assets/icons/home.png")
	keep_btn.icon = load("res://assets/icons/close.png")
	menu_overlay.visible = false
	retry_btn.pressed.connect(_on_retry)
	continue_btn.pressed.connect(_quit_to_home)
	menu_btn.pressed.connect(_open_menu)
	leave_btn.pressed.connect(_quit_to_home)
	keep_btn.pressed.connect(_close_menu)
	_best_at_start = GameManager.puzzle_highscore
	_layout()
	get_viewport().size_changed.connect(_layout)
	_begin()


func _layout() -> void:
	var safe: float = maxf(DisplayServer.get_display_safe_area().position.y, 16.0)
	var top: float = safe + 6.0
	# Top bar: the menu button (left) and the "Puzzle Rush" title beside it.
	menu_btn.offset_top = top
	menu_btn.offset_bottom = top + 80.0
	$Title.offset_top = top
	$Title.offset_bottom = top + 80.0
	# The header (difficulty / streak / best) sits BELOW the top bar so it never overlaps the menu
	# button (an overlapping header would swallow its taps). Status + board follow; all track the safe area.
	var hy: float = top + 92.0
	$Header.offset_top = hy
	$Header.offset_bottom = hy + 88.0
	status_label.offset_top = hy + 96.0
	status_label.offset_bottom = hy + 138.0
	board.offset_top = hy + 148.0


func _begin() -> void:
	_streak = 0
	_max_solved = 0
	_over = false
	_used.clear()
	_update_header()
	_next_puzzle()


func _next_puzzle() -> void:
	_busy = true
	_gen += 1
	var g := _gen
	var target: int = mini(START_RATING + _streak * RATING_STEP, MAX_RATING)
	var pz: Dictionary = Puzzles.pick(target, _used)
	if pz.is_empty():
		_used.clear()  # absurdly long streak exhausted the set: allow reuse
		pz = Puzzles.pick(target, _used)
	if pz.is_empty():
		_end_run()
		return
	_cur_rating = int(pz["rating"])
	_moves = pz["moves"]
	rules.set_fen(String(pz["fen"]))
	board.clear_options()
	board.clear_last_moves()
	board.set_check_square(-1)
	# Lichess: moves[0] is the opponent's setup move; the player then solves the odd indices after it
	# (moves[1], moves[3], ...). The player is the side to move AFTER the setup, so orient to them.
	board.flipped = rules.side_to_move == ChessRules.WHITE
	board.set_rules(rules)
	board.end_animation()
	_update_header()
	status_label.modulate = Color(1, 1, 1, 0.65)
	status_label.text = tr("Find the best move!")
	var setup := rules.move_from_uci(_moves[0])
	if setup >= 0:
		var mover := rules.side_to_move
		await board.animate_move(setup, SETUP_SLIDE)
		if g != _gen:
			return
		rules.make_move(setup)
		board.set_rules(rules)
		board.set_last_move(setup, mover)
		_set_check()
		board.end_animation()
	_move_idx = 1
	await _present_move(g)


## Show the 3 options for the player's current move (_moves[_move_idx]). The two frame yields let the
## clean post-move board (a piece the previous move just captured is gone) actually DRAW and present
## before the synchronous ranker briefly blocks the main thread: the first frame submits the clean
## board, the second resumes after it has been presented. The ranker is 1-ply so the block is tiny.
func _present_move(g: int) -> void:
	_solution = rules.move_from_uci(_moves[_move_idx])
	if _solution < 0:
		_next_puzzle()  # malformed entry, skip to a fresh puzzle
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if g != _gen:
		return
	board.set_options(_build_options(), true)
	_busy = false


## The 3 options: the solution + the ranker's two best non-solution moves, all with DISTINCT target
## squares (the board hit-tests a tap by its destination, so two options must never share a target).
## The shallow depth keeps it fast and tends to pick greedy, beginner-tempting wrong moves.
func _build_options() -> Array:
	var ranked: Array = bot.rank_moves(rules, RANK_DEPTH)
	var used_targets := {ChessRules.move_to(_solution): true}
	var wrong: Array = []
	for e: Dictionary in ranked:
		var m := int(e["move"])
		var t := ChessRules.move_to(m)
		if m != _solution and not used_targets.has(t):
			used_targets[t] = true
			wrong.append(m)
			if wrong.size() == 2:
				break
	if wrong.size() < 2:  # quiet/forced position: backfill from any legal move with a free target
		for m: int in rules.generate_legal_moves():
			var t := ChessRules.move_to(m)
			if m != _solution and not used_targets.has(t):
				used_targets[t] = true
				wrong.append(m)
				if wrong.size() == 2:
					break
	var opts: Array = [{"move": _solution, "quality": "best"}]
	for m: int in wrong:
		opts.append({"move": m, "quality": "blunder"})
	opts.shuffle()
	return opts


func _on_option_chosen(opt: Dictionary) -> void:
	if _busy or _over:
		return
	_busy = true
	var g := _gen
	var move := int(opt["move"])
	board.reveal()  # solution turns green, distractors red
	if move != _solution:
		Audio.play("blunder")
		status_label.modulate = _quality_color("blunder")
		status_label.text = tr("Wrong move!")
		await get_tree().create_timer(WRONG_HOLD).timeout
		if g != _gen:
			return
		_end_run()
		return
	# Correct: play the move, then either finish the puzzle or let the opponent reply and continue.
	Audio.play("best")
	status_label.modulate = _quality_color("best")
	status_label.text = tr("Correct!")
	var mover := rules.side_to_move
	await board.animate_move(_solution, MOVE_SLIDE)
	if g != _gen:
		return
	rules.make_move(_solution)
	board.set_rules(rules)
	board.set_last_move(_solution, mover)
	_set_check()
	board.end_animation()
	var nxt := _move_idx + 1
	if nxt >= _moves.size():
		# Final move solved. If it is checkmate, shatter the losing king first (our mate flourish).
		if rules.is_checkmate():
			Audio.play("win")
			await board.explode_piece(rules.king_square(rules.side_to_move), MATE_EXPLODE_SEC)
			if g != _gen:
				return
		_puzzle_solved(g)
		return
	# The opponent's forced reply (_moves[nxt]).
	await get_tree().create_timer(REPLY_HOLD).timeout
	if g != _gen:
		return
	var reply := rules.move_from_uci(_moves[nxt])
	if reply >= 0:
		board.clear_options()  # drop the revealed arrows before the reply slides in
		var rmover := rules.side_to_move
		await board.animate_move(reply, MOVE_SLIDE)
		if g != _gen:
			return
		rules.make_move(reply)
		board.set_rules(rules)
		board.set_last_move(reply, rmover)
		_set_check()
		board.end_animation()
	_move_idx = nxt + 1
	if _move_idx >= _moves.size():
		_puzzle_solved(g)  # defensive: Lichess lines normally end on the player's move
		return
	status_label.modulate = Color(1, 1, 1, 0.65)
	status_label.text = tr("Find the best move!")
	await _present_move(g)


## A full puzzle is solved: bump the streak, advance the difficulty, beat, then the next puzzle.
func _puzzle_solved(g: int) -> void:
	_streak += 1
	_max_solved = maxi(_max_solved, _cur_rating)
	_update_header()
	await get_tree().create_timer(CORRECT_HOLD).timeout
	if g != _gen:
		return
	_next_puzzle()


func _set_check() -> void:
	if rules.is_in_check():
		board.set_check_square(rules.king_square(rules.side_to_move))
	else:
		board.set_check_square(-1)


func _quality_color(quality: String) -> Color:
	match quality:
		"best": return UI.MOVE_BEST
		"blunder": return UI.MOVE_BLUNDER
		_: return Color(1, 1, 1, 0.65)


func _update_header() -> void:
	streak_value.text = str(_streak)
	best_value.text = str(_best_at_start)
	diff_pips.set_level(_difficulty_level(_cur_rating))
	# Make the dots row exactly as tall as a number row so all three captions share a baseline (the
	# 32px label's real line box is ~59px, not 32 - track it from the actual label, not a magic number).
	diff_pips.custom_minimum_size.y = maxf(streak_value.get_combined_minimum_size().y, 42.0)
	# Celebrate live once they pass a real previous record (not on a first-ever run).
	celebrate.visible = _best_at_start > 0 and _streak > _best_at_start


## Map a puzzle rating (400..2600) onto 1-6 dots (like the Bots screen) so difficulty reads at a
## glance for beginners instead of an opaque Elo number. 0 (no filled dots) before the first puzzle.
func _difficulty_level(rating: int) -> int:
	if rating <= 0:
		return 0
	var lvl: int = (rating - START_RATING) * 6 / maxi(MAX_RATING - START_RATING, 1) + 1
	return clampi(lvl, 1, 6)


func _end_run() -> void:
	_over = true
	_busy = true
	_gen += 1
	menu_overlay.visible = false  # the result dialog owns the screen; never leave the menu stacked under it
	board.clear_options()
	GameManager.record_puzzle_score(_streak)
	var beaten := _streak > _best_at_start
	if beaten:
		Audio.play("win")
	result_title.text = tr("New best!") if beaten else tr("Run over")
	result_celebrate.visible = beaten
	var lines: PackedStringArray = []
	lines.append("%s: %d" % [tr("Streak"), _streak])
	lines.append("%s: %d" % [tr("Best"), GameManager.puzzle_highscore])
	if _max_solved > 0:
		lines.append("%s: %d" % [tr("Hardest solved"), _max_solved])
	result_stats.text = "\n".join(lines)
	result_overlay.visible = true


func _on_retry() -> void:
	if GameManager.can_puzzle_today():
		GameManager.start_puzzle_rush()  # counts the run (no-op for premium) + reloads the scene
	else:
		daily_limit.open("puzzle")


## The menu (top-left, like the bot game / Pass & Play): a Leave / Keep-playing choice. Leaving banks
## the streak so far. The run keeps going underneath the dim, so the player loses nothing by peeking.
func _open_menu() -> void:
	if _over:
		return  # the result overlay is already up
	menu_overlay.visible = true


func _close_menu() -> void:
	menu_overlay.visible = false


## Leave to Home, banking the streak so far (record_puzzle_score only lifts the highscore if higher,
## so calling it after _end_run already did is harmless). Invalidate any in-flight puzzle coroutine
## first (set _over + bump _gen, like _end_run) so a mid-line exit can't resume on the freed scene.
func _quit_to_home() -> void:
	_over = true
	_gen += 1
	GameManager.record_puzzle_score(_streak)
	GameManager.go_to_home()


func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	if daily_limit.visible:
		daily_limit.close()
	elif menu_overlay.visible:
		_close_menu()
	elif result_overlay.visible:
		_quit_to_home()  # game over: leaving is fine
	else:
		_open_menu()  # mid-run: open the menu (Leave from there) rather than quitting straight away
