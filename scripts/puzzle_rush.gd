extends Control

## Puzzle Rush: a rising-difficulty streak of bundled Lichess puzzles (see [Puzzles]). Each puzzle
## offers 3 moves, the solution + 2 plausible distractors (the shallow GDScript ranker's top other
## moves make tempting traps), shuffled and shown neutrally. The first wrong pick ends the run.
## Difficulty (puzzle rating) climbs with the streak; the highscore is the longest streak (saved).
## No eval bar. The daily-run cap (free) is enforced by callers (Home / Retry) via can_puzzle_today().

const ChessRules := preload("res://scripts/chess/chess_rules.gd")
const ChessBotScript := preload("res://scripts/chess/chess_bot.gd")

const START_RATING := 600    ## difficulty of the first puzzle
const RATING_STEP := 70       ## +rating per solved puzzle
const MAX_RATING := 2600      ## hardest band we sampled
const SETUP_SLIDE := 0.28     ## opponent's setup move slides in
const MOVE_SLIDE := 0.28      ## the player's chosen move slides
const CORRECT_HOLD := 0.45    ## beat after a correct move before the next puzzle
const WRONG_HOLD := 1.35      ## let the red/green reveal sink in before the result

@onready var board: Control = %Board
@onready var diff_value: Label = %DiffValue
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
@onready var exit_btn: Button = %ExitBtn
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
var _solution := -1           ## the correct move (packed int) for the current puzzle
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
	exit_btn.icon = load("res://assets/icons/close.png")
	retry_btn.pressed.connect(_on_retry)
	continue_btn.pressed.connect(_quit_to_home)
	exit_btn.pressed.connect(_quit_to_home)
	_best_at_start = GameManager.puzzle_highscore
	_layout()
	get_viewport().size_changed.connect(_layout)
	_begin()


func _layout() -> void:
	var safe: float = maxf(DisplayServer.get_display_safe_area().position.y, 16.0)
	$Header.offset_top = safe + 8.0
	exit_btn.offset_top = safe + 6.0
	exit_btn.offset_bottom = safe + 62.0


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
	var moves: PackedStringArray = pz["moves"]
	rules.set_fen(String(pz["fen"]))
	board.clear_options()
	board.clear_last_moves()
	board.set_check_square(-1)
	# Lichess: moves[0] is the setup move (opponent); the player then solves moves[1]. The player is
	# the side to move AFTER the setup, so orient the board to them.
	board.flipped = rules.side_to_move == ChessRules.WHITE
	board.set_rules(rules)
	board.end_animation()
	_update_header()
	status_label.modulate = Color(1, 1, 1, 0.65)
	status_label.text = tr("Find the best move!")
	var setup := rules.move_from_uci(moves[0])
	if setup >= 0:
		await board.animate_move(setup, SETUP_SLIDE)
		if g != _gen:
			return
		var mover := rules.side_to_move
		rules.make_move(setup)
		board.set_rules(rules)
		board.set_last_move(setup, mover)
		_set_check()
		board.end_animation()
	_solution = rules.move_from_uci(moves[1])
	if _solution < 0:
		_next_puzzle()  # malformed entry, skip
		return
	board.set_options(_build_options(), true)
	_busy = false


## The 3 options: the solution (correct) + the ranker's two best non-solution moves (tempting wrong
## picks). Falls back to any legal moves if the ranker is short.
func _build_options() -> Array:
	var ranked: Array = bot.rank_moves(rules, ChessBotScript.ANALYSIS_DEPTH)
	var wrong: Array = []
	for e: Dictionary in ranked:
		var m := int(e["move"])
		if m != _solution and not wrong.has(m):
			wrong.append(m)
			if wrong.size() == 2:
				break
	if wrong.size() < 2:
		for m: int in rules.generate_legal_moves():
			if m != _solution and not wrong.has(m):
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
	if move == _solution:
		Audio.play("best")
		status_label.modulate = _quality_color("best")
		status_label.text = tr("Correct!")
		_streak += 1
		_max_solved = maxi(_max_solved, _cur_rating)
		_update_header()
		await board.animate_move(_solution, MOVE_SLIDE)
		if g != _gen:
			return
		var mover := rules.side_to_move
		rules.make_move(_solution)
		board.set_rules(rules)
		board.set_last_move(_solution, mover)
		_set_check()
		board.end_animation()
		await get_tree().create_timer(CORRECT_HOLD).timeout
		if g != _gen:
			return
		_next_puzzle()
	else:
		Audio.play("blunder")
		status_label.modulate = _quality_color("blunder")
		status_label.text = tr("Wrong move!")
		await get_tree().create_timer(WRONG_HOLD).timeout
		if g != _gen:
			return
		_end_run()


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
	diff_value.text = str(_cur_rating) if _cur_rating > 0 else "—"
	streak_value.text = str(_streak)
	best_value.text = str(_best_at_start)
	# Celebrate live once they pass a real previous record (not on a first-ever run).
	celebrate.visible = _best_at_start > 0 and _streak > _best_at_start


func _end_run() -> void:
	_over = true
	_busy = true
	_gen += 1
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


## Leave to Home, banking the streak so far (record_puzzle_score only lifts the highscore if higher,
## so calling it after _end_run already did is harmless).
func _quit_to_home() -> void:
	GameManager.record_puzzle_score(_streak)
	GameManager.go_to_home()


func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	if daily_limit.visible:
		daily_limit.close()
	else:
		_quit_to_home()
