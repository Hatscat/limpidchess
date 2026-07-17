extends Control

## Puzzle Rush: a rising-difficulty streak of bundled Lichess puzzles (see [Puzzles]). Each puzzle
## offers 3 moves, the solution + 2 plausible distractors (the shallow GDScript ranker's top other
## moves make tempting traps), shuffled and shown neutrally. The first wrong pick ends the run.
## Puzzle rating still climbs with the streak (harder puzzles) but is NOT shown: the goal is simply the
## streak, go as far as you can. The highscore is the longest streak (saved).
## No eval bar. The daily-run cap (free) is enforced by callers (Home / Retry) via can_puzzle_today().

const ChessBotScript := preload("res://scripts/chess/chess_bot.gd")
# ChessRules is a global class (class_name in chess_rules.gd) — use it directly, no preload const.

const START_RATING := 400    ## difficulty of the first puzzle (beginner / kid friendly)
const RATING_STEP := 32       ## +rating per solved puzzle
const MAX_RATING := 2600      ## the difficulty climb caps here (the data goes to 2699)
const SETUP_SLIDE := 0.28     ## the opponent's setup move slides in
const MOVE_SLIDE := 0.28      ## a played move slides
const REPLY_HOLD := 0.35      ## beat between the player's move and the opponent's reply (multi-move)
const CORRECT_HOLD := 0.5     ## beat after fully solving a puzzle before the next one
const WRONG_HOLD := 1.35      ## let the red/green reveal sink in before the result
const RANK_DEPTH := 2         ## 2-ply ranker for the distractors: believable (won't pick a move that instantly hangs)
const MATE_EXPLODE_SEC := 0.7 ## checkmate: how long the losing king's shatter plays (matches game.gd)
const MIN_STREAK_TO_COUNT := 3 ## failing OR leaving before solving this many puzzles refunds the daily run (a free retry)

@onready var board: Control = %Board
@onready var streak_value: Label = %StreakValue
@onready var best_value: Label = %BestValue
@onready var celebrate: TextureRect = %Celebrate
@onready var status_label: Label = %Status
@onready var result_overlay: Control = %ResultOverlay
@onready var result_title: Label = %ResultTitle
@onready var result_subtitle: Label = %ResultSubtitle
@onready var streak_stat: Label = %StreakStat
@onready var best_stat: Label = %BestStat
@onready var result_celebrate: TextureRect = %ResultCelebrate
@onready var retry_btn: Button = %RetryBtn
@onready var continue_btn: Button = %ContinueBtn
@onready var understand_btn: Button = %UnderstandBtn
@onready var menu_btn: Button = %MenuBtn
@onready var menu_overlay: Control = %MenuOverlay
@onready var leave_btn: Button = %LeaveBtn
@onready var keep_btn: Button = %KeepPlayingBtn
@onready var confirm_overlay: Control = %ConfirmOverlay
@onready var confirm_message: Label = %ConfirmMessage
@onready var confirm_leave_btn: Button = %ConfirmLeaveBtn
@onready var cancel_btn: Button = %CancelBtn
@onready var daily_limit: DailyLimitDialog = %DailyLimit

var rules: ChessRules
var bot
var _gen := 0                 ## bumped on each puzzle / end; async steps bail if it changes
var _busy := false
var _over := false
var _streak := 0
var _best_at_start := 0       ## highscore to beat (captured at run start)
var _cur_rating := 0
var _solution := -1           ## the correct move (packed int) the player must find right now
var _moves: PackedStringArray = PackedStringArray()  ## the current puzzle's full move list (UCI)
var _move_idx := 0            ## index into _moves of the player's move to solve now (odd indices)
var _used: Dictionary = {}    ## puzzle indices used this run (no repeats)
var _cur_fen := ""            ## current puzzle's start FEN, captured for the mistake review
var _cur_player_white := true ## the player's colour this puzzle
var _fail_fen := ""           ## the failed puzzle (for "Understand your mistake"); _fail_moves empty = none
var _fail_moves: PackedStringArray = PackedStringArray()
var _fail_player_white := true


func _ready() -> void:
	rules = ChessRules.new()
	bot = ChessBotScript.new()
	board.set_rules(rules)
	board.option_chosen.connect(_on_option_chosen)
	result_overlay.visible = false
	celebrate.visible = false
	result_celebrate.visible = false
	retry_btn.icon = load("res://assets/icons/muscle.png")  # 💪 encouraging, not a limp "restart"
	continue_btn.icon = load("res://assets/icons/exit.png")  # the white door = leave to Home (action is _quit_to_home); matches leave_btn
	understand_btn.icon = load("res://assets/icons/magnifier.png")  # matches the bot-game "Understand your moves"
	menu_btn.icon = load("res://assets/icons/menu.png")
	leave_btn.icon = load("res://assets/icons/exit.png")  # the white door = leave
	keep_btn.icon = load("res://assets/icons/close.png")
	cancel_btn.icon = load("res://assets/icons/close.png")  # confirm dialog: [Cancel x] [Confirm v], like the bot game
	confirm_leave_btn.icon = load("res://assets/icons/check.png")
	menu_overlay.visible = false
	confirm_overlay.visible = false
	retry_btn.pressed.connect(_on_retry)
	continue_btn.pressed.connect(_quit_to_home)
	understand_btn.pressed.connect(_on_understand)
	menu_btn.pressed.connect(_open_menu)
	leave_btn.pressed.connect(_confirm_leave)
	keep_btn.pressed.connect(_close_menu)
	confirm_leave_btn.pressed.connect(_on_leave)
	cancel_btn.pressed.connect(_close_confirm)
	_best_at_start = GameManager.puzzle_highscore
	_layout()
	get_viewport().size_changed.connect(_layout)
	if not GameManager.puzzle_result.is_empty():
		_restore_result(GameManager.puzzle_result)  # returned from a mistake review: re-show the result
	elif GameManager.pending_puzzle_resume and GameManager.has_puzzle_run():
		_resume()  # Home's "Resume puzzle streak": pick up the parked run
	else:
		_begin()


const _HEADER_H := 92.0        ## streak / best stats row
const _STATUS_H := 44.0        ## "Find the best move!" line
const _STATS_GAP := 22.0       ## gap between the stats and the status
const _BOARD_GAP := 16.0       ## gap between the status and the board top

func _layout() -> void:
	var vp := get_viewport_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return  # size not established yet; size_changed calls us again
	var safe: float = maxf(DisplayServer.get_display_safe_area().position.y, 16.0)
	var top: float = safe + 6.0

	# Like the chess game: a full-width square board biased into the lower-middle, with the streak/best
	# stats and the status line HUGGING its top edge, so the whole caption block reads as one unit above
	# the board (not floating up by the title). The remaining slack falls above the stats.
	var area_top: float = top + 80.0
	var caption_block: float = _HEADER_H + _STATS_GAP + _STATUS_H + _BOARD_GAP
	var board_size: float = minf(vp.x - 16.0, vp.y - area_top - caption_block - 24.0)
	board_size = maxf(board_size, 0.0)
	var bx: float = (vp.x - board_size) * 0.5

	# Top bar: the menu button (left) and the title card beside it. In wide windows
	# (desktop web) the chrome hugs the board's column, like the game scene; phone
	# geometry is unchanged (bx is smaller than the scene margins there). The 12.0
	# floor and the +92 title inset mirror puzzle_rush.tscn's MenuBtn (12..92) and
	# Title (104) offsets — keep them in sync.
	var cx: float = maxf(bx, 12.0)
	menu_btn.offset_left = cx
	menu_btn.offset_right = cx + 80.0
	menu_btn.offset_top = top
	menu_btn.offset_bottom = top + 80.0
	$Title.offset_left = cx + 92.0
	$Title.offset_right = -cx
	$Title.offset_top = top
	$Title.offset_bottom = top + 80.0

	var extra: float = maxf(0.0, vp.y - area_top - caption_block - board_size - 24.0)
	var board_top: float = area_top + extra * 0.5 + caption_block  # biased down (half the slack above)
	board.offset_left = bx
	board.offset_right = -bx
	board.offset_top = board_top
	board.offset_bottom = (board_top + board_size) - vp.y

	status_label.offset_bottom = board_top - _BOARD_GAP
	status_label.offset_top = status_label.offset_bottom - _STATUS_H
	$Header.offset_left = maxf(bx, 100.0)
	$Header.offset_right = -maxf(bx, 100.0)
	$Header.offset_bottom = status_label.offset_top - _STATS_GAP
	$Header.offset_top = $Header.offset_bottom - _HEADER_H


func _begin() -> void:
	if Puzzles.count() == 0:
		# Puzzle data failed to load (e.g. assets/puzzles.txt missing from the build). Refund the run
		# they never got to play and bail to Home, rather than faking a "Run over" + burning the daily.
		GameManager.cancel_puzzle()  # no-op for premium
		push_warning("Puzzles: data unavailable (assets/puzzles.txt not loaded); returning Home")
		GameManager.go_to_home()
		return
	_streak = 0
	_over = false
	_fail_moves = PackedStringArray()  # no mistake captured yet this run
	_used.clear()
	_update_header()
	_next_puzzle()


## Resume a parked run (Home's "Resume puzzle streak"): restore the streak and reload the current
## puzzle from move 1. The move number within a multi-move puzzle isn't saved, so it simply restarts.
func _resume() -> void:
	var pz: Dictionary = Puzzles.get_by_index(GameManager.puzzle_index)
	if pz.is_empty():
		# Puzzle set changed / bad index: drop the stale run and start a fresh one so nobody gets stuck.
		GameManager.clear_puzzle_progress()
		_begin()
		return
	_busy = true
	_streak = GameManager.puzzle_streak
	_cur_rating = int(pz["rating"])
	_over = false
	_fail_moves = PackedStringArray()
	_used = {GameManager.puzzle_index: true}  # don't re-serve the resumed puzzle later this run
	_update_header()
	_gen += 1
	_start_puzzle(pz, _gen)


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
	_start_puzzle(pz, g)


## Load a specific puzzle (from pick(), or from get_by_index() on resume): park it so the run survives
## a quit, then play its setup move and present the player's first move.
func _start_puzzle(pz: Dictionary, g: int) -> void:
	_cur_rating = int(pz["rating"])
	_moves = pz["moves"]
	_cur_fen = String(pz["fen"])
	GameManager.save_puzzle_progress(_streak, int(pz["index"]))  # park THIS puzzle at THIS streak length
	rules.set_fen(_cur_fen)
	_cur_player_white = rules.side_to_move != ChessRules.WHITE  # the player is the side to move AFTER the setup
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
		_play_move_sound(setup)  # the opponent's setup move should sound like a real move
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
## before the synchronous ranker blocks the main thread: the first frame submits the clean board, the
## second resumes after it has been presented. The 2-ply ranker can take tens of ms, so this matters.
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


## The 3 options: the solution + 2 distractors. We bias the distractors toward "tempting" moves a
## beginner is drawn to (captures and checks), taking the most believable ones first via the 2-ply
## rank (so a distractor never instantly hands material back). All three land on DISTINCT target
## squares (the board hit-tests a tap by its destination). Falls back to the best remaining moves,
## then any legal move, when a position has no tempting wrong move.
func _build_options() -> Array:
	var ranked: Array = bot.rank_moves(rules, RANK_DEPTH)
	var used_targets := {ChessRules.move_to(_solution): true}
	var wrong: Array = []
	_take_distractors(ranked, used_targets, wrong, true)    # captures / checks first (most tempting)
	_take_distractors(ranked, used_targets, wrong, false)   # then the best remaining non-solution moves
	if wrong.size() < 2:  # quiet/forced position: backfill from any legal move with a free target
		for m: int in rules.generate_legal_moves():
			if wrong.size() >= 2:
				break
			var t := ChessRules.move_to(m)
			if m != _solution and not used_targets.has(t) and not _move_is_mate(m):
				used_targets[t] = true
				wrong.append(m)
	var opts: Array = [{"move": _solution, "quality": "best"}]
	for m: int in wrong:
		opts.append({"move": m, "quality": "blunder"})
	opts.shuffle()
	return opts


## Append distractors from `ranked` (each {move:int,...}) into `wrong` (up to 2 total), in rank order,
## skipping the solution and target squares already taken. When `tempting_only`, take only captures or
## checking moves: the wrong picks a beginner is most drawn to.
func _take_distractors(ranked: Array, used_targets: Dictionary, wrong: Array, tempting_only: bool) -> void:
	for e: Dictionary in ranked:
		if wrong.size() >= 2:
			return
		var m := int(e["move"])
		if m == _solution:
			continue
		var t := ChessRules.move_to(m)
		if used_targets.has(t):
			continue
		if _move_is_mate(m):
			continue  # an alternate checkmate is as good as the solution: never a "wrong" option
		if tempting_only and not _is_tempting(m):
			continue
		used_targets[t] = true
		wrong.append(m)


## True if `move` delivers checkmate. A mate is the best possible result, so it is at least as good as
## any puzzle solution and must never be offered as a "wrong" distractor: that is what turned a position
## with two different mates-in-1 into a coin flip. Transient make / is_checkmate / undo (fully restored).
func _move_is_mate(move: int) -> bool:
	var undo := rules.make_move(move)
	var mate := rules.is_checkmate()
	rules.undo_move(move, undo)
	return mate


## A move a beginner is drawn to: a capture (incl. en passant) or a move that gives check. The
## check test is a transient make / is_in_check / undo on the live rules (fully restored).
func _is_tempting(move: int) -> bool:
	if rules.board[ChessRules.move_to(move)] != 0 or ChessRules.move_flag(move) == ChessRules.F_EP:
		return true
	var undo := rules.make_move(move)
	var checks := rules.is_in_check()  # after the move the side to move is the opponent
	rules.undo_move(move, undo)
	return checks


func _on_option_chosen(opt: Dictionary) -> void:
	if _busy or _over:
		return
	_busy = true
	var g := _gen
	var move := int(opt["move"])
	board.reveal()  # solution turns green, distractors red
	if move != _solution:
		Audio.play("blunder")
		_capture_mistake(move)  # save the failed line for the optional "Understand your mistake" review
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
	board.burst_capture_for(_solution)  # smash the taken piece as the solution lands (same as the bot game)
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
		_play_move_sound(reply)
		await board.animate_move(reply, MOVE_SLIDE)
		if g != _gen:
			return
		board.burst_capture_for(reply)  # smash the taken piece as the opponent's reply lands
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


## Move / capture sound for an opponent move (the setup move + forced replies), matching game.gd's
## cue. Call BEFORE make_move so the destination square still holds the piece being captured.
func _play_move_sound(move: int) -> void:
	var captured := rules.board[ChessRules.move_to(move)] != 0 or ChessRules.move_flag(move) == ChessRules.F_EP
	Audio.play("capture" if captured else "move")


func _quality_color(quality: String) -> Color:
	match quality:
		"best": return UI.MOVE_BEST
		"blunder": return UI.MOVE_BLUNDER
		_: return Color(1, 1, 1, 0.65)


func _update_header() -> void:
	streak_value.text = str(_streak)
	best_value.text = str(_best_at_start)
	# Celebrate live once they pass a real previous record (not on a first-ever run).
	celebrate.visible = _best_at_start > 0 and _streak > _best_at_start


func _end_run() -> void:
	_over = true
	_busy = true
	_gen += 1
	menu_overlay.visible = false  # the result dialog owns the screen; never leave a dialog stacked under it
	confirm_overlay.visible = false
	board.clear_options()
	# A free player who fails before the 4th puzzle gets the day's run back (an early stumble isn't
	# punished, mirroring the leave-before-4th refund), so they can retry. From the 4th on it counts.
	if _streak < MIN_STREAK_TO_COUNT:
		GameManager.cancel_puzzle()  # no-op for premium
	GameManager.record_puzzle_score(_streak)
	GameManager.clear_puzzle_progress()  # the run is over (failed): nothing parked to resume
	var beaten := _streak > _best_at_start
	if beaten:
		Audio.play("win")
	_show_result_dialog(beaten)


## Populate + show the result dialog (shared by a fresh end and the restore after a mistake review).
func _show_result_dialog(beaten: bool) -> void:
	result_title.text = tr("New best!") if beaten else tr("Run over")
	result_subtitle.text = _result_subtitle(beaten)
	result_celebrate.visible = beaten
	streak_stat.text = "%s: %d" % [tr("Streak"), _streak]
	best_stat.text = "%s: %d" % [tr("Best"), GameManager.puzzle_highscore]
	understand_btn.visible = not _fail_moves.is_empty()  # only when the run ended on a wrong move
	result_overlay.visible = true


## One encouraging line under the title, qualifying the run (calm, never scolding).
func _result_subtitle(beaten: bool) -> String:
	if beaten:
		return tr("A new personal best!")
	if _streak <= 1:
		return tr("Even the best miss one!")
	return tr("You solved %d in a row!") % _streak


func _on_retry() -> void:
	if GameManager.can_puzzle_today():
		GameManager.start_puzzle_rush()  # counts the run (no-op for premium) + reloads the scene
	else:
		daily_limit.open("puzzle")


## Save the failed puzzle for an optional "Understand your mistake" review: its start FEN, the line
## solved so far ending on the wrong move, and the player's colour.
func _capture_mistake(wrong_move: int) -> void:
	_fail_fen = _cur_fen
	_fail_player_white = _cur_player_white
	var line := PackedStringArray()
	for i in _move_idx:
		line.append(_moves[i])
	line.append(rules.move_to_uci(wrong_move))
	_fail_moves = line


## Open the bot game's moves-review on the failed puzzle (the wrong move vs the solution + analysis).
func _on_understand() -> void:
	if _fail_moves.is_empty():
		return
	# Stash the result so closing the review returns to this dialog (like the bot game), not Home.
	GameManager.puzzle_result = {
		"streak": _streak, "best_at_start": _best_at_start,
		"fail_fen": _fail_fen, "fail_moves": _fail_moves, "fail_player_white": _fail_player_white,
	}
	GameManager.review_puzzle_mistake(_fail_fen, _fail_moves, _fail_player_white)


## Re-show the game-over dialog after returning from a mistake review (so closing the review lands
## back here, consistent with the bot game) instead of starting a fresh run.
func _restore_result(snap: Dictionary) -> void:
	GameManager.puzzle_result = {}  # consume
	_over = true
	_streak = int(snap["streak"])
	_best_at_start = int(snap["best_at_start"])
	_fail_fen = String(snap["fail_fen"])
	_fail_moves = snap["fail_moves"]
	_fail_player_white = bool(snap["fail_player_white"])
	# Put the failed position behind the dialog, matching the board shown when the run first ended.
	rules.set_fen(_fail_fen)
	for uci: String in _fail_moves:
		var m := rules.move_from_uci(uci)
		if m < 0:
			break
		rules.make_move(m)
	board.flipped = not _fail_player_white
	board.set_rules(rules)
	board.clear_options()
	board.clear_last_moves()
	board.end_animation()
	_update_header()
	_show_result_dialog(_streak > _best_at_start)


## The menu (top-left, like the bot game / Face to Face) doubles as the leave confirmation: Leave /
## Keep-playing, with a message making the consequence clear. The run keeps going underneath the dim,
## so the player loses nothing by peeking. Leaving banks the streak either way.
func _open_menu() -> void:
	if _over:
		return  # the result overlay is already up
	menu_overlay.visible = true


func _close_menu() -> void:
	menu_overlay.visible = false


## Step 2 of leaving (the menu's "Save and leave" opens this): a confirmation, matching the chess
## game's Cancel/Give-up confirm. The message makes clear the run is parked and can be resumed later.
func _confirm_leave() -> void:
	menu_overlay.visible = false
	confirm_message.text = tr("Your streak is saved. Resume it any time.")
	confirm_overlay.visible = true


func _close_confirm() -> void:
	confirm_overlay.visible = false


## Confirmed leave. The run is PARKED (saved) to resume from Home, so the day's run stays spent on it,
## no refund: a run you can finish later isn't wasted, and refunding here would let a free player farm
## unlimited runs (start, leave, resume). _start_puzzle already saved the streak + current puzzle.
func _on_leave() -> void:
	if _over:
		return  # re-entry guard: a double-tap must not act twice (mirrors game.gd _do_cancel_game)
	_over = true
	_quit_to_home()


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
	elif confirm_overlay.visible:
		_close_confirm()
	elif menu_overlay.visible:
		_close_menu()
	elif result_overlay.visible:
		_quit_to_home()  # game over: leaving is fine
	else:
		_open_menu()  # mid-run: open the menu (Leave from there) rather than quitting straight away
