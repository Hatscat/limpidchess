extends Control

## The game screen. Brain = Stockfish (StockfishEngine, ext or pipe transport),
## fallback = the built-in ChessBot. ChessRules stays the source of truth.
##
## Loop per human turn: analyse → show three neutral option arrows → player taps
## one → grade it, REVEAL qualities (colour + shape symbol), slow-slide the piece
## (bullet-time), commit, then the bot replies. Every game: random player colour,
## and White's first move is an auto-chosen random good opening.

const ChessBotScript := preload("res://scripts/chess/chess_bot.gd")
const CapturedStripScript := preload("res://scripts/ui/captured_strip.gd")
const EvalBarScript := preload("res://scripts/ui/eval_bar.gd")

## Centipawn-ish piece values for the material lead (king excluded). pawn..queen.
const PIECE_VALUE := {1: 1, 2: 3, 3: 3, 4: 5, 5: 9}

## Wide MultiPV pass (every legal move) for the option spread + grading. Kept
## shallow because MultiPV cost explodes with depth; the BEST line is deepened
## separately below.
const ANALYSIS_DEPTH_SF := 10
## The suggested BEST move gets its own deep, single-line search so that "playing
## best" can actually match/beat the opponent (the shallow pass alone often picks
## a sub-optimal best the strong bots punish). Think time scales with the bot.
const BEST_MOVETIME_MARGIN := 400  ## think a little longer than the opponent does
const BEST_MOVETIME_FLOOR := 800   ## floor so suggestions stay sound vs weak bots (teaching)
const BEST_MOVETIME_CAP := 2100    ## ceiling so the strongest bots' turns stay tolerable
## Face to Face has no opponent to scale to, and the best move is prefetched during the
## reveal, so it gets a fixed, generous search for honest teaching (the wait is hidden).
const PASS_PLAY_MOVETIME := 1500
const OPENING_WINDOW_CP := 55
const REVEAL_SLIDE_SEC := 0.7   ## slow bullet-time slide of the chosen piece
const REVEAL_HOLD_SEC := 0.85   ## extra pause so the result can be read
const BOT_SLIDE_SEC := 0.35
const END_DELAY := 1.25   ## hold the "Checkmate!" / "Stalemate." message before the review dialog
const MATE_EXPLODE_SEC := 0.7   ## checkmate: how long the losing king's shatter plays
const EARLY_MOVES := 10   ## below this many player moves, leaving = a free "cancel", not a loss
## Post-game review: how many plies of the engine's best line to show / animate, the per-move
## slide + pause when "Best replies" plays it back, and the quick slide when stepping Prev / Next.
const REVIEW_LINE_PLIES := 10
const REVIEW_STEP_SEC := 0.45
const REVIEW_STEP_HOLD := 0.4
const REVIEW_STEP_FAST := 0.18
## When a stored best line is shorter than REVIEW_MIN_LINE plies (a weak/slow engine on the device
## can return a 1-2 ply stub even though the desktop engine returns 20+), re-fetch the continuation
## after the best move with a DEPTH-based search (depth, not movetime, so the line is long enough to
## explain the position regardless of device speed).
const REVIEW_LINE_DEPTH := 14
const REVIEW_MIN_LINE := 6
## Best-replies playback is a timeline: position runs 0 .. ply-count, integer part = the move index,
## fraction = that move's slide progress. Rate is in moves/sec, signed (negative = rewind), driven by
## the media-control buttons (play/pause/rewind/fast-forward).
const LINE_PLAY_RATE := 1.1        ## normal play speed (forward)
const LINE_MAX_RATE := 8.0         ## speed cap when rewinding / fast-forwarding (each tap ×2)
const REVIEW_HL_SIZE := 28         ## font size of the move currently playing in the best-replies line (base is 20)

@onready var board: Control = %Board
@onready var feedback: Label = %Feedback
@onready var status_label: Label = %Status
@onready var opponent_name: Label = %OpponentName
@onready var opponent_avatar: TextureRect = %OpponentAvatar
@onready var result_overlay: Control = %ResultOverlay
@onready var result_title: Label = %ResultTitle
@onready var result_text: Label = %ResultText
@onready var review_box: Control = %ReviewBox
@onready var review_best: Label = %ReviewBest
@onready var review_avg: Label = %ReviewAvg
@onready var review_blunder: Label = %ReviewBlunder
@onready var review_box_pp: Control = %ReviewBoxPP
@onready var pp_best_w: Label = %PPBestW
@onready var pp_best_b: Label = %PPBestB
@onready var pp_decent_w: Label = %PPDecentW
@onready var pp_decent_b: Label = %PPDecentB
@onready var pp_blunder_w: Label = %PPBlunderW
@onready var pp_blunder_b: Label = %PPBlunderB
@onready var bots_btn: Button = %BotsBtn
@onready var play_again_btn: Button = %PlayAgainBtn
@onready var home_btn: Button = %HomeBtn
@onready var daily_limit: DailyLimitDialog = %DailyLimit
@onready var confirm_overlay: Control = %ConfirmOverlay
@onready var confirm_title: Label = %ConfirmTitle
@onready var confirm_message: Label = %ConfirmMessage
@onready var menu_overlay: Control = %MenuOverlay
@onready var undo_btn: Button = %UndoBtn
@onready var giveup_btn: Button = %GiveUpBtn
@onready var restart_btn: Button = %RestartBtn
@onready var review_overlay: Control = %ReviewOverlay
@onready var review_step: Label = %ReviewStep
@onready var review_avatar: TextureRect = %ReviewAvatar
@onready var review_pawn: TextureRect = %ReviewPawn
@onready var review_move: Label = %ReviewMove
@onready var review_quality: Label = %ReviewQuality
@onready var review_analyse_icon: TextureRect = %ReviewAnalyseIcon
@onready var review_line_label: RichTextLabel = %ReviewBestLine
@onready var review_prev: Button = %ReviewPrev
@onready var review_next: Button = %ReviewNext
@onready var review_line_best: Button = %ReviewLineBest       ## explore the BEST move's line (green)
@onready var review_line_played: Button = %ReviewLinePlayed   ## explore the played move's line (player's or bot's)
var _played_mark: _LineMark                                   ## the played button's quality glyph, re-shaped per ply
var _best_mark: _LineMark                                     ## the best button's ✓ glyph (shown when a played button is also up)
var _best_label: Label                                        ## the best button's "Best replies" text (shown when it stands alone)
@onready var line_rewind: Button = %LineRewind
@onready var line_play: Button = %LinePlayPause
@onready var line_forward: Button = %LineForward
@onready var line_stop: Button = %LineStop
@onready var review_done: Button = %ReviewDone

var rules: ChessRules
var bot: ChessBot
var stockfish: StockfishEngine
var _use_sf := false
var bot_def: Dictionary
var player_color: int

var _ranked: Array = []
var _history: Array = []
# _busy gates input during searches/animations. As a property it also keeps an
# OPEN menu's Undo + Restart buttons live: when the engine/animation finishes
# (_busy -> false) they re-enable without having to close and reopen the menu.
# Restart is locked while busy (it would collide with an in-flight search) AND when a
# free player has no daily game left to start the replay it triggers (see _can_restart).
var _busy := false:
	set(value):
		_busy = value
		if menu_overlay != null and menu_overlay.visible:
			undo_btn.disabled = not _can_undo()
			restart_btn.disabled = value or not _can_restart()
var _game_over := false
var _pending_action := ""
## Bumped on every new game; async turn coroutines bail if it changed under them
## (e.g. the player restarts mid-animation or mid-bot-think).
var _gen := 0

# Per-colour move-quality tally (index 0 = White, 1 = Black), reset each game → the
# end-of-game review. In a bot game only the human picks options, so every count sits
# under the player's colour; in Face to Face they split White vs Black for the comparison.
var _best: Array[int] = [0, 0]
var _decent: Array[int] = [0, 0]
var _blunder: Array[int] = [0, 0]

# Captured-pieces strips (below the board). Codes accumulated as moves are played:
# _caps_white = the black pieces White has taken, _caps_black = the white pieces
# Black has taken (each side shows its own trophies). Created in _ready.
var cap_top: Control       ## strip for the side at the TOP of the board
var cap_bottom: Control    ## strip for the side at the BOTTOM (the player, vs a bot)
var _caps_white: PackedInt32Array = PackedInt32Array()
var _caps_black: PackedInt32Array = PackedInt32Array()

# Undo stack: one entry per committed move {move, undo, captured, mover}. "Undo
# move" rewinds the player's last move AND the opponent's reply (two plies),
# never past White's auto-opening (kept as the first entry).
var _undo_stack: Array = []
# Parallel to _undo_stack: the post-game review entry for each ply ({} for the auto-opening and
# bot replies, which carry no player pick). An entry holds {quality, label, cp_loss, best, best_pv}.
var _review: Array = []
# Review navigation state. _review_gen is bumped on any step / close so a "Best replies" playback
# coroutine in flight bails instead of fighting the new view.
var _review_ply := 0
var _review_gen := 0
var _review_playing := false
var _review_analyzing := {}  ## ply index -> true while an on-demand engine analysis is in flight
var _played_analyzing := {}  ## ply index -> true while the played-move consequence line is searched
var _review_unlocked := false  ## this game's review was already opened (counted) this session
var _review_startpos := ""       ## non-empty (a FEN) when reviewing an injected position (a failed puzzle)
var _puzzle_review_mode := false  ## reviewing a failed Puzzle Rush puzzle (no bot face; close → Home)

# Best-replies scrubbable timeline (see the LINE_* constants).
var _line_active := false
var _line_from_best := true       ## the line currently playing: the best move's line (true) or the played move's
var _line_is_player_move := false ## when playing the played line: was that move the human's (label "Your move") or the bot's ("This move")
var _line_states: Array = []     ## ChessRules after 0 .. k line moves (size k+1)
var _line_moves_arr: Array = []  ## the k line moves (packed ints)
var _line_san := PackedStringArray()  ## SAN of each line move, for the header highlight
var _line_total := 0
var _line_pos := 0.0             ## playback position in [0, k]
var _line_rate := 0.0            ## signed play rate (moves/sec; 0 = paused, <0 = rewind)
var _line_hl_active := -2        ## last move index highlighted in the header (avoids rebuilding it every frame)
var _line_mate_exploded := false ## the best line's mate shatter has played (once per arrival at the end)
var _scan_style_off: StyleBox = null  ## rewind/fast-forward button look when OFF (dark) ...
var _scan_style_on: StyleBox = null   ## ... vs ON (reversed: light fill + dark icon)
var _player_moves := 0  ## moves the human has actually chosen this game (drives early "cancel")

# Bot-reply prefetch: the reveal of the player's pick (slide + hold ~1.5s) is idle
# CPU, so we search the bot's reply to the not-yet-committed move in the background
# and consume it when the bot's turn actually starts — a slow engine bot then answers
# without the player waiting. Keyed by (gen, post-move FEN); dropped if either changes.
var _reply_fen := ""        ## position the prefetch is for ("" = none in flight)
var _reply_gen := -1
var _reply_uci := ""        ## result ("" while still searching)
var _reply_pending := false
signal _reply_ready

# Options prefetch (Face to Face): there's no bot reply to precompute there, so during the
# same reveal idle we rank the position the OTHER player is about to face, and
# _present_options consumes it instead of stalling on a fresh analysis. Bot games skip this
# (they prefetch the bot's reply instead; the player's own next analysis can't be known
# until the bot has moved). Keyed by (gen, post-move FEN); dropped if either changes.
var _opts_fen := ""         ## position the prefetch is for ("" = none in flight)
var _opts_gen := -1
var _opts_ranked: Array = []  ## result (empty while still searching / on miss)
var _opts_pending := false
signal _opts_ready

# Stockfish evaluation bar (bot games only; hidden in Face to Face). Created in _ready.
var eval_bar: Control


func _ready() -> void:
	rules = ChessRules.new()
	bot = ChessBotScript.new()
	# Shared, persistent engine (autoload): the embedded native Stockfish is a
	# process-singleton, so every game reuses the one instance instead of spawning
	# a fresh one (a second native engine produces no output).
	stockfish = ChessEngine
	bot_def = GameManager.current_bot if not GameManager.current_bot.is_empty() else BotRoster.default()

	board.set_rules(rules)
	board.option_chosen.connect(_on_option_chosen)

	# Captured-pieces strips: keep them right after the board so the result /
	# confirm overlays (later siblings) still draw on top.
	cap_top = CapturedStripScript.new()
	cap_bottom = CapturedStripScript.new()
	eval_bar = EvalBarScript.new()
	add_child(cap_top)
	add_child(cap_bottom)
	add_child(eval_bar)
	move_child(cap_top, board.get_index() + 1)
	move_child(cap_bottom, board.get_index() + 2)
	move_child(eval_bar, board.get_index() + 3)

	# Face to Face: the "Black to move" area, fixed above the board at 180° (White's uses status_label).
	_pp_top = Label.new()
	_pp_top.add_theme_font_size_override("font_size", 20)
	_pp_top.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pp_top.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_pp_top.anchor_right = 1.0
	_pp_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pp_top.visible = false
	add_child(_pp_top)
	move_child(_pp_top, board.get_index() + 4)

	_setup_opponent_panel()
	result_overlay.visible = false
	confirm_overlay.visible = false
	menu_overlay.visible = false
	review_overlay.visible = false
	_setup_review_buttons()

	_layout_for_safe_area()
	get_viewport().size_changed.connect(_layout_for_safe_area)
	feedback.text = ""
	if not GameManager.puzzle_review.is_empty():
		_enter_puzzle_review()  # came from a failed Puzzle Rush puzzle: jump straight into the review
	else:
		_begin()


func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	# The Android back gesture is often involuntary, so it must never drop out of a
	# game by accident. Instead it peels off one layer at a time: close an open
	# confirm, then the menu, and from the bare board it opens the menu so the player
	# decides explicitly (Cancel game / Give up / …). Only leave once the game is over.
	if daily_limit.visible:
		daily_limit.close()   # dismiss the daily-limit dialog, back to the result
	elif _line_active:
		_on_line_stop()       # exit best-replies first (peel one layer), staying in the review
	elif review_overlay.visible:
		_close_review()       # back from the review to the result dialog
	elif confirm_overlay.visible:
		_on_confirm_no()      # dismiss the confirm (takes no action)
	elif menu_overlay.visible:
		_on_menu_close()      # close the menu, back to the game
	elif _game_over:
		GameManager.go_to_home()  # result is shown / game ended → leaving is fine
	else:
		_open_menu()          # pause the game so a stray gesture can't lose it


## Layout, top → bottom: top bar (with the big portrait) · breathing room ·
## feedback + status captions · the board (sat in the lower-middle, index-finger
## reach) · a captured-pieces strip per side. Sized from the live viewport so it
## adapts to any phone aspect / notch; re-runs on size_changed.
const _BAR_H := 104.0          ## top bar height (fits the 88px portrait)
const _EVAL_H := 26.0          ## evaluation bar height
const _EVAL_TOP_GAP := 14.0    ## gap from the top bar to the eval bar
const _FEED_H := 96.0          ## feedback box (room for a 2-line OpenDyslexic result)
const _FEED_GAP := 24.0        ## gap between feedback and status
const _STATUS_H := 38.0
const _CAP_STRIP_H := 34.0     ## one captured-pieces strip
const _CAP_GAP := 6.0          ## gap between the two strips
const _CAP_TOP_GAP := 10.0     ## gap from board bottom to the first strip

func _layout_for_safe_area() -> void:
	var vp := get_viewport_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return  # size not established yet; size_changed will call us again
	var top: float = maxf(DisplayServer.get_display_safe_area().position.y, 16.0)
	if GameManager.pass_and_play and (review_overlay == null or not review_overlay.visible):
		_layout_face_to_face(vp, top)  # live Face to Face: board perfectly centred; pieces flip, chrome fixed
		return
	# Bot games AND the Face to Face review use the normal (biased-down) layout below, so the review's
	# top panels (move / quality / best replies) have room above the board instead of overlapping it.
	$TopBar.offset_top = top
	$TopBar.offset_bottom = top + _BAR_H

	var caption_block: float = _FEED_H + _FEED_GAP + _STATUS_H + 12.0  # captions + gap to board
	var captured_block: float = _CAP_TOP_GAP + _CAP_STRIP_H + _CAP_GAP + _CAP_STRIP_H

	# Full-width square, shrunk if a short screen can't fit the whole stack.
	var area_top: float = top + _BAR_H
	# Reserve the eval-bar zone at the very top so the vertically-centred caption
	# stack can never rise into it on short screens.
	var stack_top: float = area_top + _EVAL_TOP_GAP + _EVAL_H

	var board_size: float = minf(vp.x - 16.0,
		vp.y - stack_top - caption_block - captured_block - 24.0)
	board_size = maxf(board_size, 0.0)
	var bx: float = (vp.x - board_size) * 0.5

	# Centre the captioned-board-plus-strips block in the remaining space, biased a
	# touch downward (half the slack above, the rest below) so the board sits in
	# the lower-middle within thumb-and-finger reach, not pinned to either edge.
	var content_h: float = caption_block + board_size + captured_block
	var extra: float = maxf(0.0, vp.y - stack_top - content_h - 16.0)
	var board_top: float = stack_top + extra * 0.5 + caption_block

	board.offset_left = bx
	board.offset_right = -bx
	board.offset_top = board_top
	board.offset_bottom = (board_top + board_size) - vp.y

	# Status hugs the board top; feedback (can wrap to 2 lines) just above it.
	status_label.offset_bottom = board_top - 12.0
	status_label.offset_top = status_label.offset_bottom - _STATUS_H
	feedback.offset_bottom = status_label.offset_top - _FEED_GAP
	feedback.offset_top = feedback.offset_bottom - _FEED_H

	# Eval bar: just under the top bar, aligned with the board's width.
	if eval_bar:
		eval_bar.position = Vector2(bx, area_top + _EVAL_TOP_GAP)
		eval_bar.size = Vector2(board_size, _EVAL_H)

	# Captured strips, aligned with the board's width, just below it.
	var sy: float = board_top + board_size + _CAP_TOP_GAP
	if cap_top:
		cap_top.position = Vector2(bx, sy)
		cap_top.size = Vector2(board_size, _CAP_STRIP_H)
	if cap_bottom:
		cap_bottom.position = Vector2(bx, sy + _CAP_STRIP_H + _CAP_GAP)
		cap_bottom.size = Vector2(board_size, _CAP_STRIP_H)

	# Keep the review's board-relative panels aligned when the viewport changes.
	if review_overlay != null and review_overlay.visible:
		_position_review_ui()


# --- Face to Face: board fixed + centred. Only the pieces + coordinate labels flip to the
# side to move; everything else is FIXED per side — two "X to move" areas (White below, upright; Black
# above, 180°) and the captured strips (each side's captures on that side, oriented for that player). ---

const _FACE_SPIN_SEC := 0.35
const _PP_MSG_H := 30.0        ## height of the small "X to move" area
var _face_turn := 0            ## accumulated half-turns; parity (even = White-up, odd = Black-up)
var _pp_top: Label = null      ## "Black to move" area, fixed above the board at 180° (White's uses status_label)


## Layout for Face to Face: the board is PERFECTLY centred. Below it (White's side, upright): "White to
## move" then White's captured (black) pieces. Above it (Black's side, 180°): Black's captured (white)
## pieces then "Black to move". Only the menu button remains in the header (OpponentChip hidden).
func _layout_face_to_face(vp: Vector2, top: float) -> void:
	$TopBar.offset_top = top
	$TopBar.offset_bottom = top + _BAR_H
	var side_reserve: float = _CAP_TOP_GAP + _PP_MSG_H + _CAP_GAP + _CAP_STRIP_H + 8.0  # label + strip, one side
	var pad: float = maxf(top + _BAR_H, top + side_reserve)  # keep the menu button clear of the board too
	var board_size: float = minf(vp.x - 16.0, vp.y - 2.0 * pad)
	board_size = maxf(board_size, 0.0)
	var bx: float = (vp.x - board_size) * 0.5
	var board_top: float = (vp.y - board_size) * 0.5  # screen-centred
	board.offset_left = bx
	board.offset_right = -bx
	board.offset_top = board_top
	board.offset_bottom = (board_top + board_size) - vp.y
	var b_bot: float = board_top + board_size
	# White (below the board, upright): "White to move" then White's captured (black) pieces.
	status_label.rotation = 0.0
	status_label.offset_top = b_bot + _CAP_TOP_GAP
	status_label.offset_bottom = status_label.offset_top + _PP_MSG_H
	cap_bottom.rotation = 0.0
	cap_bottom.position = Vector2(bx, status_label.offset_bottom + _CAP_GAP)
	cap_bottom.size = Vector2(board_size, _CAP_STRIP_H)
	# Black (above the board, fixed 180°): captures then "Black to move", each spun about its own centre.
	if _pp_top:
		_pp_top.offset_left = bx
		_pp_top.offset_right = -bx
		_pp_top.offset_top = board_top - _CAP_TOP_GAP - _PP_MSG_H
		_pp_top.offset_bottom = _pp_top.offset_top + _PP_MSG_H
		_pp_top.pivot_offset = Vector2(board_size * 0.5, _PP_MSG_H * 0.5)
		_pp_top.rotation = PI
	cap_top.position = Vector2(bx, board_top - _CAP_TOP_GAP - _PP_MSG_H - _CAP_GAP - _CAP_STRIP_H)
	cap_top.size = Vector2(board_size, _CAP_STRIP_H)
	cap_top.pivot_offset = Vector2(board_size * 0.5, _CAP_STRIP_H * 0.5)
	cap_top.rotation = PI


## Flip only the pieces + coordinate labels to face the side now to move (the chrome is fixed per side).
func _face_rotate() -> void:
	if not GameManager.pass_and_play:
		return
	var from: float = PI * float(_face_turn & 1)
	_face_turn += 1
	board.face_pieces(from + PI, _FACE_SPIN_SEC)
	await get_tree().create_timer(_FACE_SPIN_SEC).timeout
	board.face_pieces(PI * float(_face_turn & 1), 0.0)  # normalise to 0 / PI


## Set the "X to move" area for the side to move; clear the other (only one shows at a time).
func _pp_set_turn(loading := false) -> void:
	var white := rules.side_to_move == ChessRules.WHITE
	var msg := ""
	if loading:
		msg = tr("Reading the position…")  # a hint on the mover's side while analysing (esp. the opening)
	elif white:
		msg = tr("White to move")
	else:
		msg = tr("Black to move")
	if white:
		status_label.text = msg
		if _pp_top:
			_pp_top.text = ""
	else:
		if _pp_top:
			_pp_top.text = msg
		status_label.text = ""


## Flip to face the side to move, unless the board already faces them (the opening, or an undo back to
## the same side). No-op outside Face to Face.
func _face_to_side() -> void:
	if not GameManager.pass_and_play:
		return
	var target: int = 0 if rules.side_to_move == ChessRules.WHITE else 1
	if (_face_turn & 1) == target:
		return
	await _face_rotate()


func _setup_opponent_panel() -> void:
	if GameManager.pass_and_play:
		# Face to Face: only the menu button in the header; the two "X to move" areas carry the turn.
		$TopBar/OpponentChip.visible = false
		feedback.visible = false
		status_label.add_theme_font_size_override("font_size", 20)  # small "White to move"
		if _pp_top:
			_pp_top.visible = true
	else:
		opponent_name.text = bot_def.get("name", "Bot")
		opponent_avatar.texture = load(BotRoster.avatar_path(bot_def))
		if _pp_top:
			_pp_top.visible = false


# --- Game lifecycle ---

func _begin() -> void:
	status_label.text = "Setting up…"
	_busy = true
	_use_sf = stockfish.start()
	_new_game()


func _new_game() -> void:
	_gen += 1  # invalidate any in-flight turn coroutine from the previous game
	board.end_animation()
	if not GameManager.pass_and_play:
		GameManager.player_is_white = randi() % 2 == 0
	player_color = ChessRules.WHITE if GameManager.player_is_white else ChessRules.BLACK
	board.flipped = (not GameManager.pass_and_play) and not GameManager.player_is_white

	rules.reset_startpos()
	_history.clear()
	_game_over = false
	board.clear_last_moves()
	board.set_check_square(-1)
	board.clear_options()
	board.set_rules(rules)
	result_overlay.visible = false
	confirm_overlay.visible = false
	feedback.text = ""
	_best.fill(0)
	_decent.fill(0)
	_blunder.fill(0)
	_caps_white = PackedInt32Array()
	_caps_black = PackedInt32Array()
	_undo_stack.clear()
	_review.clear()
	_review_unlocked = false
	_player_moves = 0
	_reply_fen = ""
	_reply_pending = false
	_opts_fen = ""
	_opts_pending = false
	_opts_ranked = []
	_update_captured()
	eval_bar.visible = not GameManager.pass_and_play
	eval_bar.set_eval(0)
	_record_position()
	if GameManager.pass_and_play:
		# Face to Face: White (a human) plays the opening too — no auto-move. Start facing White.
		_face_turn = 0
		board.face_pieces(0.0, 0.0)
		_advance()  # presents White's first options at parity 0 (no flip: already facing White)
	else:
		_play_random_opening()


# --- Turn flow ---

func _advance() -> void:
	_update_check_highlight()
	if _check_game_over():
		return
	# Face to Face: spin pieces + chrome to the player now to move BEFORE showing their options (no-op
	# when already facing them, e.g. the opening). A mate is handled above, so it never triggers a flip.
	if GameManager.pass_and_play:
		var g := _gen
		await _face_to_side()
		if g != _gen:
			return
	if _is_human_turn():
		_present_options()
	else:
		_bot_move()


func _is_human_turn() -> bool:
	return GameManager.pass_and_play or rules.side_to_move == player_color


func _play_random_opening() -> void:
	var g := _gen
	_busy = true
	status_label.text = "A fresh opening…"
	var ranked := await _rank_position()
	if g != _gen:
		return
	var move := _pick_random_good(ranked)
	if move != -1:
		await board.animate_move(move, 0.4)
		if g != _gen:
			return
		_play_move(move)
	_advance()


func _pick_random_good(ranked: Array) -> int:
	if ranked.is_empty():
		return -1
	var best: int = ranked[0]["score"]
	var pool: Array = []
	for e in ranked:
		if best - int(e["score"]) <= OPENING_WINDOW_CP:
			pool.append(e["move"])
	return pool[randi() % pool.size()]


func _present_options() -> void:
	_busy = true
	var g := _gen
	if GameManager.pass_and_play:
		_pp_set_turn(true)  # "reading…" on the mover's side while analysing (esp. the un-prefetched opening)
	else:
		status_label.text = "Reading the position…"
	_ranked = await _take_options(g)
	if g != _gen:
		return  # a new game / undo / game-end happened during analysis
	_push_eval_from_ranked()

	var picks := ChessBotScript.select_options(_ranked)
	var options: Array = []
	if picks["best"] >= 0:
		options.append({"move": picks["best"], "quality": "best"})
	if picks["decent"] >= 0:
		options.append({"move": picks["decent"], "quality": "decent"})
	if picks["blunder"] >= 0:
		options.append({"move": picks["blunder"], "quality": "blunder"})
	options.shuffle()
	board.set_options(options, true)

	if GameManager.pass_and_play:
		_pp_set_turn()  # keep the side-to-move caption (no "find the best!" clutter)
	elif options.size() == 1:
		status_label.text = "Only one move here."
	else:
		status_label.text = "Your move, find the best!"
	_busy = false


func _rank_position(r: ChessRules = null) -> Array:
	if r == null:
		r = rules
	if _use_sf and stockfish.available:
		var legal := r.generate_legal_moves()
		var mpv := maxi(1, mini(legal.size(), 50))
		var lines: Array = await stockfish.analyse(r.get_fen(), mpv, ANALYSIS_DEPTH_SF)
		var ranked := _ranked_from_sf(lines, r)
		if not ranked.is_empty():
			return ranked
	return bot.rank_moves(r, ChessBotScript.ANALYSIS_DEPTH)


## Deepen ONLY the best line: a single full-strength search (think time scaled to
## the opponent) replaces the shallow pass's #1, lifted to the front of the ranked
## list as the reference best. So "best" is genuinely strong vs deep-searching bots,
## while the wide spread (decent / blunder / grading) stays cheap. Fallback path is a
## no-op (the GDScript ranker has no separate deep search). Operates on the given rules
## (the live board, or a throwaway clone for the Face to Face prefetch) and returns the
## reordered list.
func _deep_promote(ranked: Array, r: ChessRules, g: int) -> Array:
	if not (_use_sf and stockfish.available) or ranked.is_empty():
		return ranked
	var mt: int = PASS_PLAY_MOVETIME if GameManager.pass_and_play else clampi(
		int(bot_def.get("movetime", 400)) + BEST_MOVETIME_MARGIN,
		BEST_MOVETIME_FLOOR, BEST_MOVETIME_CAP)
	var line: Dictionary = await stockfish.best_line(r.get_fen(), {"skill": 20, "movetime": mt})
	if g != _gen:
		return ranked  # undo / restart / game-end during the deep search → leave it untouched
	var uci: String = String(line.get("move", ""))
	var best_move := r.move_from_uci(uci)
	if best_move < 0:
		return ranked
	var deep_pv: PackedStringArray = line.get("pv", PackedStringArray())
	var top_score: int = int(ranked[0]["score"])
	for i in ranked.size():
		if int(ranked[i]["move"]) == best_move:
			var e: Dictionary = ranked[i]
			ranked.remove_at(i)
			ranked.insert(0, e)
			break
	if int(ranked[0]["move"]) != best_move:  # wasn't in the spread → prepend it
		ranked.insert(0, {"move": best_move, "score": top_score, "pv": deep_pv})
	# It is the true best, so it must carry the top score (keeps cp-loss grading sane).
	ranked[0]["score"] = maxi(int(ranked[0]["score"]), top_score)
	# Prefer the deep search's line for the best move (longer / stronger than the shallow pass).
	if not deep_pv.is_empty():
		ranked[0]["pv"] = deep_pv
	return ranked


func _ranked_from_sf(lines: Array, r: ChessRules) -> Array:
	var by_uci := {}
	for m in r.generate_legal_moves():
		by_uci[r.move_to_uci(m)] = m
	var ranked: Array = []
	for e in lines:
		if by_uci.has(e["uci"]):
			ranked.append({"move": by_uci[e["uci"]], "score": int(e["score"]), "pv": e.get("pv", PackedStringArray())})
	ranked.sort_custom(func(a, b): return a["score"] > b["score"])
	return ranked


func _on_option_chosen(opt: Dictionary) -> void:
	# In the post-game review, tapping a coloured arrow launches its best-replies line (the best-move
	# arrow → the best line; the player's own arrow → where their move leads). Live play falls through.
	if review_overlay.visible:
		if not _line_active:
			var rv: Dictionary = _review[_review_ply] if _review_ply < _review.size() else {}
			var is_best: bool = int(opt.get("move", -1)) == int(rv.get("best", -1))
			# The best-move arrow → the best line; the other (played-move) arrow → that move's line, whether
			# it was the player's mistake or the bot's blunder. (Match by MOVE, not the quality label: an
			# on-demand-graded move can be quality "best" yet not be the engine's #1.)
			_play_line(is_best)
		return
	if _busy:
		return
	_busy = true
	var g := _gen

	var move: int = opt["move"]
	var mover := rules.side_to_move  # whose quality this pick counts toward (White/Black)
	var grade := ChessBotScript.grade_move(_ranked, move)
	var best_san := rules.to_san(grade["best_move"])

	# Capture this pick for the post-game review: the quality, the best move, and the engine's
	# best line (PV) so the review can replay the better continuation. Everything here is already
	# computed for the live feedback, so recording it costs nothing extra.
	var best_pv := PackedStringArray()
	for e in _ranked:
		if int(e["move"]) == int(grade["best_move"]):
			best_pv = e.get("pv", PackedStringArray())
			break
	var review_entry := {
		"quality": String(opt.get("quality", "")),
		"label": String(grade["label"]),
		"cp_loss": int(grade["cp_loss"]),
		"best": int(grade["best_move"]),
		"best_pv": best_pv,
		# Position eval (best play) as White-relative cp, for the review's eval bar.
		"eval_cp": int(_ranked[0]["score"]) * (1 if mover == ChessRules.WHITE else -1),
	}

	match opt.get("quality", ""):
		"best":
			_best[mover] += 1
			feedback.text = tr("★ Best move!")
			Audio.play("best")
		"decent":
			_decent[mover] += 1
			feedback.text = tr("%s. The best was %s.") % [tr(grade["label"]), best_san]
			Audio.play("decent")
		"blunder":
			_blunder[mover] += 1
			feedback.text = tr("The blunder! The best was %s.") % best_san
			Audio.play("blunder")
		_:
			_decent[mover] += 1
			feedback.text = tr("%s. Best was %s.") % [tr(grade["label"]), best_san]
			Audio.play("decent")
	status_label.text = ""
	if GameManager.pass_and_play and _pp_top:
		_pp_top.text = ""  # clear both "X to move" areas once a move is picked (board colours show quality)

	# Reveal the qualities, then slow-slide the chosen piece (bullet time). While the
	# reveal plays (~1.5s of idle CPU), search the bot's reply in the background.
	board.reveal()
	_prefetch_bot_reply(move, g)   # bot games: search the reply while the reveal plays
	_prefetch_options(move, g)     # Face to Face: rank the next player's position instead
	await board.animate_move(move, REVEAL_SLIDE_SEC)
	if g != _gen:
		return
	board.burst_capture_for(move)  # smash the taken piece the instant the slide lands, before the hold
	await get_tree().create_timer(REVEAL_HOLD_SEC).timeout
	if g != _gen:
		return

	_play_move(move, review_entry)
	_player_moves += 1  # a move the human actually chose (not the auto-opening / bot)
	_push_eval_after_move(move)
	board.clear_options()
	_advance()


func _bot_move() -> void:
	var g := _gen
	_busy = true
	status_label.text = tr("%s is thinking…") % bot_def.get("name", "Bot")
	await get_tree().process_frame
	if g != _gen:
		return

	var move := -1
	# Weakest bots play a random legal move part of the time. Stockfish even at
	# Skill 0 is far too strong for a true beginner / child, so genuine ease needs
	# weakening beyond Skill Level. A short beat keeps the move from feeling instant.
	var rc: float = float(bot_def.get("random_chance", 0.0))
	if rc > 0.0 and randf() < rc:
		await get_tree().create_timer(0.35).timeout
		if g != _gen:
			return
		var legal := rules.generate_legal_moves()
		if not legal.is_empty():
			move = int(legal[randi() % legal.size()])
	if move == -1 and _use_sf and stockfish.available:
		var uci: String = await _take_bot_reply(rules.get_fen(), g)
		if g != _gen:
			return
		move = rules.move_from_uci(uci)
	if move == -1:
		await get_tree().create_timer(0.2).timeout
		if g != _gen:
			return
		move = bot.choose_move(rules, bot_def.get("depth", 2), bot_def.get("weakness", 0.3))
	if move < 0:
		_advance()
		return

	await board.animate_move(move, BOT_SLIDE_SEC)
	if g != _gen:
		return
	board.burst_capture_for(move)  # smash the taken piece as the bot's piece lands
	_play_move(move)
	_busy = false
	_advance()


## Search the bot's reply to the player's (not-yet-committed) move during the reveal,
## so the bot can answer without the player waiting. Skipped in Face to Face, without
## an engine, or for bots that may play a random move (the result could go unused).
func _prefetch_bot_reply(player_move: int, g: int) -> void:
	_reply_fen = ""
	if GameManager.pass_and_play or not (_use_sf and stockfish.available):
		return
	if float(bot_def.get("random_chance", 0.0)) > 0.0:
		return
	var undo := rules.make_move(player_move)
	var fen := rules.get_fen()
	rules.undo_move(player_move, undo)  # leave the board exactly as drawn (no redraw between)
	_reply_fen = fen
	_reply_gen = g
	_reply_uci = ""
	_reply_pending = true
	_search_reply(fen, g)  # fire-and-forget; lands in _reply_uci


func _search_reply(fen: String, g: int) -> void:
	var uci: String = await stockfish.best_move(fen, {
		"skill": bot_def.get("sf_skill", 10),
		"movetime": bot_def.get("movetime", 200),
	})
	# Clear pending only for the live generation: an orphaned search (gen bumped under it)
	# must not reset the flag a fresh prefetch already set, or a waiter could wake early.
	if g == _gen:
		_reply_pending = false
		if fen == _reply_fen:
			_reply_uci = uci
	_reply_ready.emit()  # always wake a waiter; staleness is checked by the consumer


## The bot's engine reply: the prefetched search if it's for this exact position, else
## a fresh one. Awaits a still-running prefetch (never starts a second search).
func _take_bot_reply(fen: String, g: int) -> String:
	if _reply_gen == g and _reply_fen == fen:
		# while (not if): only our keyed search clears _reply_pending, so a stray wake from an
		# unrelated _search_reply re-awaits instead of returning a half-done result.
		while _reply_pending:
			await _reply_ready
		_reply_fen = ""  # consumed
		return "" if g != _gen else _reply_uci
	return await stockfish.best_move(fen, {
		"skill": bot_def.get("sf_skill", 10),
		"movetime": bot_def.get("movetime", 200),
	})


## Face to Face has no bot reply to precompute, so during the reveal we instead rank the
## position the OTHER player will face on a throwaway ChessRules clone (the live board is
## left exactly as drawn), and _present_options consumes it. Bot games skip this.
func _prefetch_options(player_move: int, g: int) -> void:
	_opts_fen = ""
	if not GameManager.pass_and_play or not (_use_sf and stockfish.available):
		return
	var undo := rules.make_move(player_move)
	var fen := rules.get_fen()
	rules.undo_move(player_move, undo)  # leave the board exactly as drawn (no redraw between)
	var probe := ChessRules.new()
	probe.set_fen(fen)
	_opts_fen = fen
	_opts_gen = g
	_opts_ranked = []
	_opts_pending = true
	_search_options(probe, g)  # fire-and-forget; lands in _opts_ranked


func _search_options(probe: ChessRules, g: int) -> void:
	var ranked: Array = await _rank_position(probe)
	if g == _gen:
		ranked = await _deep_promote(ranked, probe, g)
	# Clear pending only for the live generation (see _search_reply): an orphan must not
	# reset the flag a fresh prefetch already set.
	if g == _gen:
		_opts_pending = false
		if probe.get_fen() == _opts_fen:
			_opts_ranked = ranked
	_opts_ready.emit()  # always wake a waiter; staleness is checked by the consumer


## The ranked option spread for the current position: the Face to Face prefetch if it's for
## this exact position, else a fresh analysis. Awaits a still-running prefetch (never starts
## a second analysis for it). Mirrors _take_bot_reply for the options channel.
func _take_options(g: int) -> Array:
	if _opts_gen == g and _opts_fen == rules.get_fen():
		# while (not if): only our keyed search clears _opts_pending; a stray wake re-awaits.
		while _opts_pending:
			await _opts_ready
		var ranked: Array = _opts_ranked
		_opts_ranked = []
		_opts_fen = ""  # consumed
		if g != _gen:
			return []
		if not ranked.is_empty():
			return ranked
	var fresh: Array = await _rank_position()
	if g != _gen:
		return fresh
	# The opening (Face to Face move 1) is never prefetched and has no animation to hide behind, so
	# skip the ~1.5s deep best-line search: from the start position any top move is a fine "best".
	# Keeps the very first move snappy; every later move is prefetched during the flip (see _search_options).
	if _undo_stack.is_empty():
		return fresh
	return await _deep_promote(fresh, rules, g)


func _play_move(move: int, review := {}) -> void:
	var mover := rules.side_to_move
	var undo := rules.make_move(move)
	var captured: int = undo.get("captured_piece", 0)
	if captured != 0:
		if mover == ChessRules.WHITE:
			_caps_white.append(captured)
		else:
			_caps_black.append(captured)
	_undo_stack.append({"move": move, "undo": undo, "captured": captured, "mover": mover})
	_review.append(review)  # parallel to _undo_stack; {} for the opening / bot plies
	Audio.play("capture" if captured != 0 else "move")
	board.set_last_move(move, mover)
	board.set_rules(rules)
	board.end_animation()  # commit done → drop the slide overlay (piece is now at dest)
	_update_captured()
	_record_position()


func _record_position() -> void:
	_history.append(rules.position_key())


## Feed the eval bar the current position's score, converted to White's point of
## view (+ = White better). _ranked[0] is the best line from the side-to-move's
## view; flip its sign for Black. No-op in Face to Face (the bar stays hidden).
func _push_eval_from_ranked() -> void:
	if GameManager.pass_and_play or _ranked.is_empty():
		return
	var score: int = int(_ranked[0]["score"])
	eval_bar.set_eval(score if rules.side_to_move == ChessRules.WHITE else -score)


## Right after the human commits their pick, show that move's evaluation so the bar
## reacts immediately (a blunder visibly drops it) instead of looking stale through
## the bot's reply. The chosen move's score comes from the analysis just shown, in
## the human's (the mover's) point of view → flip for Black.
func _push_eval_after_move(move: int) -> void:
	if GameManager.pass_and_play:
		return
	var score := 0
	for e in _ranked:
		if int(e["move"]) == move:
			score = int(e["score"])
			break
	eval_bar.set_eval(score if player_color == ChessRules.WHITE else -score)


## Refresh both captured-pieces strips from the current board + accumulated trophies.
## The material lead is read from on-board material (correct even after a promotion);
## the trophy icons come from the actual pieces captured.
func _update_captured() -> void:
	if cap_top == null or cap_bottom == null:
		return
	var wmat := 0
	var bmat := 0
	for sq in 64:
		var p: int = rules.board[sq]
		if p == 0:
			continue
		var t: int = ChessRules.piece_type(p)
		if t < ChessRules.PAWN or t > ChessRules.QUEEN:
			continue  # skip kings
		var v: int = PIECE_VALUE[t]
		if ChessRules.piece_color(p) == ChessRules.WHITE:
			wmat += v
		else:
			bmat += v

	# The board flips to keep the player at the bottom, so the bottom strip is the
	# player's (White in Face to Face); the top strip is the opponent's.
	var bottom_color: int = ChessRules.WHITE if GameManager.pass_and_play else player_color
	var top_color: int = 1 - bottom_color
	cap_bottom.set_data(_sorted_caps(bottom_color), maxi(0, _material_lead(bottom_color, wmat, bmat)))
	cap_top.set_data(_sorted_caps(top_color), maxi(0, _material_lead(top_color, wmat, bmat)))


## Material lead (in points) for `color`, given total on-board material per side.
func _material_lead(color: int, wmat: int, bmat: int) -> int:
	return (wmat - bmat) if color == ChessRules.WHITE else (bmat - wmat)


## The pieces `capturer` has taken, ordered pawns → queen for display.
func _sorted_caps(capturer: int) -> PackedInt32Array:
	var src: PackedInt32Array = _caps_white if capturer == ChessRules.WHITE else _caps_black
	var out: PackedInt32Array = PackedInt32Array()
	for t in [ChessRules.PAWN, ChessRules.KNIGHT, ChessRules.BISHOP, ChessRules.ROOK, ChessRules.QUEEN]:
		for c in src:
			if ChessRules.piece_type(c) == t:
				out.append(c)
	return out


func _update_check_highlight() -> void:
	if rules.is_in_check():
		board.set_check_square(rules.king_square(rules.side_to_move))
	else:
		board.set_check_square(-1)


# --- End of game ---

func _check_game_over() -> bool:
	var threefold := _history.count(rules.position_key()) >= 3
	var outcome := rules.outcome(threefold)
	if outcome == ChessRules.Outcome.ONGOING:
		return false
	_game_over = true
	_busy = false
	_gen += 1  # invalidate any in-flight turn coroutine
	board.clear_options()
	menu_overlay.visible = false
	confirm_overlay.visible = false

	var title := ""
	var text := ""
	var quote_key := "draw"
	match outcome:
		ChessRules.Outcome.CHECKMATE:
			var winner := 1 - rules.side_to_move
			var human_won := (not GameManager.pass_and_play) and winner == player_color
			if GameManager.pass_and_play:
				title = "Checkmate"
				text = tr("%s wins!") % (tr("White") if winner == ChessRules.WHITE else tr("Black"))
			elif human_won:
				title = "You win!"
				text = "Checkmate. Well played."
				quote_key = "win"
				GameManager.record_result("win")
			else:
				title = "Checkmate"
				text = tr("%s got you this time.") % bot_def.get("name", "The bot")
				quote_key = "loss"
				GameManager.record_result("loss")
		ChessRules.Outcome.STALEMATE:
			title = "Stalemate"
			text = "A draw: no legal moves, but no check."
			if not GameManager.pass_and_play: GameManager.record_result("draw")
		ChessRules.Outcome.DRAW_FIFTY:
			title = "Draw"
			text = "Fifty moves without a pawn move or capture."
			if not GameManager.pass_and_play: GameManager.record_result("draw")
		ChessRules.Outcome.DRAW_REPETITION:
			title = "Draw"
			text = "The same position, three times over."
			if not GameManager.pass_and_play: GameManager.record_result("draw")
		ChessRules.Outcome.DRAW_INSUFFICIENT:
			title = "Draw"
			text = "Not enough material to checkmate."
			if not GameManager.pass_and_play: GameManager.record_result("draw")

	# Celebratory cue for a checkmate win (incl. Face to Face); a calm one otherwise
	# (a loss / draw is never scolded, per the design).
	var sfx := "end"
	if outcome == ChessRules.Outcome.CHECKMATE and quote_key != "loss":
		sfx = "win"
	Audio.play(sfx)

	# Announce the ending explicitly on the board, hold a beat, THEN the review. On a
	# checkmate, shatter the losing king (the side to move, who has no escape) first.
	feedback.text = _outcome_headline(outcome)
	status_label.text = ""
	var mate_king := rules.king_square(rules.side_to_move) if outcome == ChessRules.Outcome.CHECKMATE else -1
	_finish_game_after_delay(title, text, quote_key, mate_king)
	return true


## Short, explicit board headline shown before the review dialog.
func _outcome_headline(outcome: int) -> String:
	match outcome:
		ChessRules.Outcome.CHECKMATE: return "Checkmate!"
		ChessRules.Outcome.STALEMATE: return "Stalemate."
		_: return "Draw."


func _finish_game_after_delay(title: String, text: String, quote_key: String, mate_king := -1) -> void:
	var g := _gen
	if mate_king >= 0:
		await board.explode_piece(mate_king, MATE_EXPLODE_SEC)  # checkmate shatter
		if g != _gen:
			return
		await get_tree().create_timer(0.2).timeout  # let the burst settle before the dialog
	else:
		await get_tree().create_timer(END_DELAY).timeout  # calm hold for a draw / stalemate
	if g != _gen:
		return  # a restart / undo happened during the hold
	_show_result(title, text, quote_key)


func _show_result(title: String, text: String, quote_key: String) -> void:
	result_title.text = title
	result_text.text = text
	# Face to Face shows a White-vs-Black comparison; a bot game shows the single tally.
	# Make "Play again" concrete for kids who can't read yet: show WHO you'd replay,
	# the opponent's avatar + name (the handshake for Face to Face).
	if GameManager.pass_and_play:
		# Face to Face: White/Black tally, Play again + Leave, no opponent to change.
		review_box.visible = false
		review_box_pp.visible = true
		bots_btn.visible = false
		home_btn.visible = true
		home_btn.icon = load("res://assets/icons/exit.png")  # white door = leave, matching the Puzzles end modal
		play_again_btn.visible = true
		pp_best_w.text = str(_best[0]); pp_best_b.text = str(_best[1])
		pp_decent_w.text = str(_decent[0]); pp_decent_b.text = str(_decent[1])
		pp_blunder_w.text = str(_blunder[0]); pp_blunder_b.text = str(_blunder[1])
		play_again_btn.icon = load("res://assets/icons/handshake.png")
		play_again_btn.text = tr("Play again")
	else:
		# Bot game: guide the player onward. "Continue" (→ pick another bot) replaces Home, which is
		# dropped here. "Retry with <bot>" sits above Continue and is offered on anything but a win
		# (a defeat or a draw can be replayed); a win pushes them onward to the next opponent.
		review_box.visible = true
		review_box_pp.visible = false
		bots_btn.visible = true
		home_btn.visible = false
		review_best.text = tr("%d best") % (_best[0] + _best[1])
		review_avg.text = tr("%d average") % (_decent[0] + _decent[1])
		review_blunder.text = tr("%d blunder") % (_blunder[0] + _blunder[1])
		var can_retry := quote_key != "win"
		play_again_btn.visible = can_retry
		if can_retry:
			var nm: String = bot_def.get("name", "Bot")
			play_again_btn.icon = load(BotRoster.avatar_path(bot_def))
			play_again_btn.text = tr("Retry") + " " + tr("with") + " " + nm
	result_overlay.visible = true
	# Just used the last free game of the day: explain the daily reload on top of the result (some
	# players think 3 games = the end / must pay). Bot games only; premium has no limit.
	if not GameManager.pass_and_play and not GameManager.is_premium and GameManager.games_remaining_today() == 0:
		daily_limit.open()
	# Defer the rating ask to the next calm screen (Home / Bots), not over the result dialog. Only
	# after a positive finish (skip a loss / resign); the prompt itself is still gated to once.
	if quote_key != "loss" and quote_key != "resign":
		GameManager.pending_review_check = true


# --- Menu + confirm ---

func _open_menu() -> void:
	if _game_over:
		return  # the result dialog owns the screen once the game has ended
	undo_btn.disabled = not _can_undo()
	restart_btn.disabled = _busy or not _can_restart()
	_refresh_leave_btn()
	menu_overlay.visible = true


## True while the game is young enough that leaving counts as a no-penalty cancel
## (the player likely started by mistake) rather than a resignation.
func _is_early_game() -> bool:
	return _player_moves < EARLY_MOVES


## Restart always ends in a NEW counted game with the same opponent (it must never be a free
## re-roll past the daily limit). An early restart refunds first, so a slot is always free; a
## late restart needs a daily slot for the replay. Face to Face has no gate.
func _can_restart() -> bool:
	return GameManager.pass_and_play or _is_early_game() or GameManager.can_play_game()


## The resign button is a gentle "Cancel game" (no loss, no game spent) early on,
## and the real "Give up" (a recorded loss) once the player is invested.
func _refresh_leave_btn() -> void:
	if _is_early_game():
		giveup_btn.text = tr("Cancel game")
		giveup_btn.icon = load("res://assets/icons/exit.png")
	else:
		giveup_btn.text = tr("Give up")
		giveup_btn.icon = load("res://assets/icons/flag.png")


func _on_menu_close() -> void:
	menu_overlay.visible = false


func _on_menu_restart() -> void:
	menu_overlay.visible = false
	if GameManager.pass_and_play:
		_ask_confirm("restart", "Restart game?", "Start over from a fresh position?")
	elif _is_early_game():
		_ask_confirm("restart", "Restart game?", "Start a fresh game?")
	else:
		_ask_confirm("restart", "Restart game?", "Resign and start a new game?")


func _on_menu_giveup() -> void:
	menu_overlay.visible = false
	if _is_early_game():
		_ask_confirm("cancel", "Cancel game?", "This game won't count.")
	else:
		_ask_confirm("give_up", "Give up?", "Resign and end this game?")


func _on_menu_undo() -> void:
	menu_overlay.visible = false
	_undo_last()


# --- Undo ---

## How many plies one undo rewinds: in a bot game, the player's move AND the bot's reply
## (two); in Face to Face, just the single last human move (the other side is also human).
func _undo_plies() -> int:
	return 1 if GameManager.pass_and_play else 2


## Plies to keep beneath an undo: a bot game keeps its auto-opening (ply 0) so undo can't pop it; Face
## to Face has NO auto-opening (White plays it), so undo may rewind all the way back to the start.
func _undo_keep_floor() -> int:
	return 0 if GameManager.pass_and_play else 1


## Can we undo? Only while it's a human turn (not mid-think / not over) and there are enough plies
## above the keep-floor to rewind.
func _can_undo() -> bool:
	return not _busy and not _game_over and _undo_stack.size() >= _undo_plies() + _undo_keep_floor()


## Rewind one undo's worth of plies, keeping the opening, then re-offer options for the
## restored position.
func _undo_last() -> void:
	if not _can_undo():
		return
	_gen += 1  # invalidate any stray coroutine
	# Drop any in-flight prefetch keyed to the pre-undo position (mirrors _new_game).
	_reply_fen = ""
	_reply_pending = false
	_opts_fen = ""
	_opts_pending = false
	_opts_ranked = []
	board.end_animation()
	var plies := 0
	var to_rewind := _undo_plies()
	while plies < to_rewind and _undo_stack.size() > _undo_keep_floor():  # never pop a bot game's opening
		var e: Dictionary = _undo_stack.pop_back()
		if not _review.is_empty():
			_review.pop_back()  # keep the review log in lockstep with the move stack
		rules.undo_move(int(e["move"]), e["undo"])
		var cap: int = e["captured"]
		if cap != 0:
			if int(e["mover"]) == ChessRules.WHITE:
				_caps_white = _remove_last(_caps_white, cap)
			else:
				_caps_black = _remove_last(_caps_black, cap)
		if not _history.is_empty():
			_history.pop_back()
		plies += 1

	_player_moves = max(0, _player_moves - 1)  # one player move was rewound (keeps the early "cancel" honest)
	_game_over = false
	_busy = false
	feedback.text = ""
	board.set_rules(rules)
	board.clear_options()
	board.clear_last_moves()
	if not _undo_stack.is_empty():
		var top: Dictionary = _undo_stack.back()
		board.set_last_move(int(top["move"]), int(top["mover"]))
	_update_check_highlight()
	_update_captured()
	_advance()


## Drop the last occurrence of `code` from a captured list (it was appended on the
## capture being undone). Returns the new array (PackedInt32Array is copy-on-write).
func _remove_last(arr: PackedInt32Array, code: int) -> PackedInt32Array:
	for i in range(arr.size() - 1, -1, -1):
		if arr[i] == code:
			arr.remove_at(i)
			break
	return arr


func _ask_confirm(action: String, title: String, message: String) -> void:
	_pending_action = action
	confirm_title.text = title
	confirm_message.text = message
	confirm_overlay.visible = true


func _on_confirm_no() -> void:
	confirm_overlay.visible = false
	_pending_action = ""


func _on_confirm_yes() -> void:
	confirm_overlay.visible = false
	var action := _pending_action
	_pending_action = ""
	match action:
		"restart": _do_restart()
		"give_up": _do_give_up()
		"cancel": _do_cancel_game()


func _do_give_up() -> void:
	if _game_over:
		return
	_game_over = true
	_gen += 1  # invalidate any in-flight bot-think / analysis coroutine
	board.clear_options()
	Audio.play("end")
	# Face to Face: the side to move is the one resigning, so the other colour wins.
	if GameManager.pass_and_play:
		var loser := rules.side_to_move
		var winner := ChessRules.BLACK if loser == ChessRules.WHITE else ChessRules.WHITE
		var loser_name := tr("White") if loser == ChessRules.WHITE else tr("Black")
		var winner_name := tr("White") if winner == ChessRules.WHITE else tr("Black")
		_show_result(tr("%s resigned") % loser_name, tr("%s wins!") % winner_name, "resign")
		return
	GameManager.record_result("loss")
	_show_result("You gave up", "No shame, every game teaches something.", "resign")


## Leave a game the player barely started (likely by mistake): no loss, no review
## stats, and refund the daily free game + played count that starting consumed.
func _do_cancel_game() -> void:
	if _game_over:
		return
	_game_over = true
	_gen += 1  # invalidate any in-flight bot-think / analysis coroutine
	board.clear_options()
	if not GameManager.pass_and_play:
		GameManager.cancel_game()
	GameManager.go_to_home()


## Restart = leave the current game AND immediately play another with the SAME opponent, so it
## can never be a free re-roll. Late (invested) → resign, a recorded loss; early → cancel, a
## refund. Either way start_bot_game counts the fresh game against the daily limit. Face to Face
## has no gate / no result, so it just resets. Gated by _can_restart (the button is disabled
## when a late free player has no slot for the replay), so the counted start always has room.
func _do_restart() -> void:
	if _game_over:
		return
	_game_over = true
	_gen += 1  # stop any in-flight coroutine before the scene reloads
	board.clear_options()
	if GameManager.pass_and_play:
		GameManager.start_pass_and_play()
		return
	if _is_early_game():
		GameManager.cancel_game()           # refund the barely-started game
	else:
		GameManager.record_result("loss")   # resign the invested game
	GameManager.start_bot_game(bot_def)     # counts as a new game; same bot, fresh random colour


func _on_play_again_pressed() -> void:
	# A replay is a NEW game and must consume a daily slot (the previous game already ended and
	# was counted), so route through start_bot_game like Home/Bots do; out of games → Premium.
	if GameManager.pass_and_play:
		GameManager.start_pass_and_play()
	elif GameManager.can_play_game():
		GameManager.start_bot_game(bot_def)
	else:
		daily_limit.open()  # explain the daily reload + premium, not a silent jump to the store


func _on_home_pressed() -> void:
	GameManager.go_to_home()


func _on_bots_pressed() -> void:
	GameManager.go_to_bots()  # pick a different opponent from the review dialog


# --- Post-game review: step through the game and replay the engine's best lines ---

## Give the review buttons their icons (chevrons for Prev/Next, a star for Best replies). Done keeps
## the close icon from the scene. Done once in _ready.
func _setup_review_buttons() -> void:
	review_prev.icon = load("res://assets/icons/chevron_left.svg")
	review_next.icon = load("res://assets/icons/chevron_right.svg")
	# Prev / Next are icon-only with a centred chevron (so they stay short in every language). The two
	# best-replies buttons fill the middle: a GREEN one starts the best move's line, a quality-coloured
	# one starts the played move's line (the player's mistake OR the bot's blunder). Both are text-free
	# (no wrapping in any language): a magnifier (starts an analysis-style walk-through) beside the mark (✓ / ✗).
	review_prev.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	review_next.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	review_prev.add_theme_constant_override("icon_max_width", 40)
	review_next.add_theme_constant_override("icon_max_width", 40)
	_color_line_button(review_line_best, _quality_color("best"))     # fixed green
	_best_mark = _set_line_button_icons(review_line_best, "best")    # 🔍 + ✓ when paired with a played button
	# Standing alone (the reviewed move WAS the best, so no second button), the green button has room for
	# a label: swap the ✓ for "Best replies" text, keeping the magnifier. Added to the same row, hidden
	# until _refresh_line_buttons decides the button is solo.
	_best_label = Label.new()
	_best_label.text = tr("Best replies")
	_best_label.add_theme_font_size_override("font_size", UI.FONT_BODY)
	_best_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_best_label.visible = false
	_best_mark.get_parent().add_child(_best_label)  # into the row, right after the ✓ mark
	_played_mark = _set_line_button_icons(review_line_played, "blunder")  # 🔍 + a mark re-shaped per ply
	review_line_best.pressed.connect(_on_line_best)
	review_line_played.pressed.connect(_on_line_played)
	# The 4 media controls shown while the line plays (rewind · play/pause · fast-forward · stop):
	# icon-only, centred, equal width.
	line_rewind.icon = load("res://assets/icons/rewind.svg")
	line_play.icon = load("res://assets/icons/play.svg")
	line_forward.icon = load("res://assets/icons/forward.svg")
	line_stop.icon = load("res://assets/icons/close.png")  # ✕ = leave the line, back to the move
	for b: Button in [line_rewind, line_play, line_forward, line_stop]:
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.add_theme_constant_override("icon_max_width", 36)
	# line_play.add_theme_constant_override("icon_max_width", 48)  # the primary control: bigger icon
	line_rewind.pressed.connect(_on_line_rewind)
	line_play.pressed.connect(_on_line_play_pause)
	line_forward.pressed.connect(_on_line_forward)
	line_stop.pressed.connect(_on_line_stop)
	# Rewind / fast-forward are toggles: an "on" look that reverses the colours (light fill + dark
	# icon) when that direction is active.
	_scan_style_off = line_rewind.get_theme_stylebox("normal")
	var on_sb := (_scan_style_off as StyleBoxFlat).duplicate() as StyleBoxFlat
	on_sb.bg_color = Color(0.9, 0.91, 0.93)
	_scan_style_on = on_sb


## Light a scan button (rewind / fast-forward) when its direction is active, reversing its colours.
func _set_scan_active(btn: Button, on: bool) -> void:
	var sb: StyleBox = _scan_style_on if on else _scan_style_off
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", sb)
	btn.add_theme_stylebox_override("pressed", sb)
	var ic := Color(0.13, 0.14, 0.17) if on else Color(1, 1, 1)  # dark icon on light, white on dark
	btn.add_theme_color_override("icon_normal_color", ic)
	btn.add_theme_color_override("icon_pressed_color", ic)
	btn.add_theme_color_override("icon_hover_color", ic)


## Give a best-replies button a solid quality-coloured fill (green best / red-or-blue played) so the
## two buttons echo the two coloured arrows on the board.
func _color_line_button(btn: Button, bg: Color) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(16)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 16.0
	sb.content_margin_bottom = 16.0
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", sb)
	btn.add_theme_stylebox_override("pressed", sb)
	var dim := sb.duplicate() as StyleBoxFlat
	dim.bg_color = Color(bg.r * 0.4, bg.g * 0.4, bg.b * 0.4, 1.0)
	btn.add_theme_stylebox_override("disabled", dim)


## Put a centred glyph on a best-replies button: a magnifier (signals "start an analysis-style
## walk-through") beside a quality mark drawn identically to the board's arrow symbol (✓ best / – decent /
## ✗ blunder), so the button matches its arrow. No text, so the pair never wraps in any language. The
## glyph lives in a mouse-transparent child so taps hit the button. Returns the mark (to re-shape per ply).
func _set_line_button_icons(btn: Button, quality: String) -> _LineMark:
	btn.icon = null
	btn.text = ""
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 12)
	var mag := TextureRect.new()
	mag.texture = load("res://assets/icons/magnifier.png")
	mag.custom_minimum_size = Vector2(46, 46)
	mag.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mag.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	mag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mark := _LineMark.new()
	mark.quality = quality
	mark.custom_minimum_size = Vector2(42, 42)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark.resized.connect(mark.queue_redraw)  # keep the shape crisp when the container sizes it
	row.add_child(mag)
	row.add_child(mark)
	center.add_child(row)
	btn.add_child(center)
	return mark


## Show the 4 line-playback controls in the nav (and hide Prev/the two line buttons/Next), or vice versa.
func _set_line_controls(on: bool) -> void:
	review_prev.visible = not on
	review_line_best.visible = not on
	# The played-line button only exists when the reviewed move wasn't the best; _refresh_line_buttons
	# owns its visibility, so restoring the nav re-runs that instead of force-showing it.
	if on:
		review_line_played.visible = false
	review_next.visible = not on
	line_rewind.visible = on
	line_play.visible = on
	line_forward.visible = on
	line_stop.visible = on
	# Hide the top "close analysis" ✕ while in the line, so the only ✕ is the line's own exit: the
	# player leaves best-replies first, then can close the review.
	review_done.visible = not on


## Refresh the media controls from the current rate: play/pause icon + the rewind/fast-forward
## "on" highlight (rewind active when going backward, fast-forward when faster than normal play).
func _update_line_buttons() -> void:
	var playing := _line_active and _line_rate != 0.0
	line_play.icon = load("res://assets/icons/pause.svg" if playing else "res://assets/icons/play.svg")
	_set_scan_active(line_rewind, _line_active and _line_rate < 0.0)
	_set_scan_active(line_forward, _line_active and _line_rate > LINE_PLAY_RATE)


## Entry point from the result dialog's "Understand your moves" button (in-app, replacing the old
## external Chess.com link).
func _on_review_pressed() -> void:
	if _undo_stack.is_empty():
		return
	# Free players get one moves review a day. Reopening THIS game's review (already unlocked this
	# session) is free; the first open of a new game's review spends the daily allowance.
	if GameManager.is_premium or _review_unlocked:
		_open_review()
	elif GameManager.can_review_today():
		GameManager.count_review()
		_review_unlocked = true
		_open_review()
	else:
		daily_limit.open("review")


## Toggle the live-game chrome (everything the review hides while it owns the board): the top bar,
## the feedback / status captions, the eval bar (bot games only), and the captured-pieces strips.
func _set_live_chrome(vis: bool) -> void:
	$TopBar.visible = vis
	feedback.visible = vis
	status_label.visible = vis
	if eval_bar: eval_bar.visible = vis and not GameManager.pass_and_play
	if cap_top: cap_top.visible = vis
	if cap_bottom: cap_bottom.visible = vis
	if _pp_top: _pp_top.visible = vis and GameManager.pass_and_play  # Face to Face "Black to move" area


## Enter the moves-review for a failed Puzzle Rush puzzle (handed over via GameManager.puzzle_review):
## replay its line into the review's undo stack, then open the review on the LAST ply (the mistake).
## No live game is started; closing the review returns Home.
func _enter_puzzle_review() -> void:
	var payload: Dictionary = GameManager.puzzle_review
	GameManager.puzzle_review = {}  # consume so a later normal game start isn't hijacked
	_puzzle_review_mode = true
	GameManager.pass_and_play = false  # the puzzle review owns the "You"/"Opponent" framing, not P&P
	_game_over = true
	_use_sf = stockfish.start()  # _begin is skipped here, so start the engine ourselves: the review
	# needs Stockfish for a fast, accurate analysis with a full best-line PV (the fallback ranker is
	# slow and returns no continuation, so the "best replies" line would be a single move).
	_review_startpos = String(payload["fen"])
	player_color = ChessRules.WHITE if bool(payload["player_white"]) else ChessRules.BLACK
	board.flipped = player_color == ChessRules.BLACK  # show the puzzle from the side the player solved
	var r := ChessRules.new()
	r.set_fen(_review_startpos)
	var moves: PackedStringArray = payload["moves"]
	for uci: String in moves:
		var m := r.move_from_uci(uci)
		if m < 0:
			break
		var mover := r.side_to_move
		var undo := r.make_move(m)
		_undo_stack.append({"move": m, "undo": undo, "captured": int(undo.get("captured_piece", 0)), "mover": mover})
		_review.append({})  # graded on demand inside the review
	if _undo_stack.is_empty():
		GameManager.puzzle_result = {}  # don't leave a stale result snapshot to hijack the next run
		GameManager.go_to_home()
		return
	rules.set_fen(r.get_fen())  # the final position, so the review's close-restore stays consistent
	_open_review(_undo_stack.size() - 1)  # open straight on the player's wrong move (the last ply); they can step back for the earlier line


func _open_review(start_ply := 0) -> void:
	_exit_line()
	_set_live_chrome(false)  # the review owns the board and shows its own panels
	board.face_pieces(0.0, 0.0)  # the review is shown upright even after a Face to Face game
	result_overlay.visible = false
	_review_gen += 1
	_review_playing = false
	review_overlay.visible = true
	_layout_for_safe_area()  # review open → board drops to the normal (lower) position; panels get room above
	_show_review_ply(start_ply, false)


func _close_review() -> void:
	if _puzzle_review_mode:
		GameManager.go_to_puzzles()  # back to the Puzzle Rush result dialog (restored from puzzle_result)
		return
	_exit_line()
	_review_gen += 1        # abort any best-line playback in flight
	_review_playing = false
	review_overlay.visible = false
	# Restore the finished game's final position + chrome, so nothing stale (a reviewed ply, or a
	# mid-best-line frame) shows through the result overlay's translucent dim.
	board.set_rules(rules)
	board.clear_options()
	board.clear_last_moves()
	if not _undo_stack.is_empty():
		var top: Dictionary = _undo_stack.back()
		board.set_last_move(int(top["move"]), int(top["mover"]))
	_update_check_highlight()
	board.end_animation()
	_set_live_chrome(true)
	_layout_for_safe_area()  # restore the live eval-bar / chrome positions moved during review
	result_overlay.visible = true


## Place the top info band (between the safe area and the board) and the close button: both depend
## on the live safe area / board rect. The nav bar is bottom-anchored in the scene. Re-run from
## _layout_for_safe_area while the review is open.
func _position_review_ui() -> void:
	if review_overlay == null or not review_overlay.visible:
		return
	var safe_top: float = maxf(DisplayServer.get_display_safe_area().position.y, 16.0)
	# Eval bar: the classic strip just above the board (helps see where the game turned). It is
	# hidden during live play's review-chrome teardown, so re-show + reposition it here.
	var bar_top: float = board.offset_top
	if eval_bar != null:
		eval_bar.visible = true
		bar_top = board.offset_top - _EVAL_H - 6.0
		eval_bar.position = Vector2(board.offset_left, bar_top)
		eval_bar.size = Vector2(board.size.x, _EVAL_H)
	var info := review_step.get_parent() as Control
	if info != null:
		info.offset_top = safe_top + 8.0
		info.offset_bottom = maxf(info.offset_top + 132.0, bar_top - 8.0)
	# Match the menu button (80x80, vertically centred in the top bar) but on the RIGHT, so quitting the
	# review is as big and easy to hit as opening the menu (the small button was hard for kids to tap).
	review_done.offset_top = safe_top + (_BAR_H - 80.0) * 0.5
	review_done.offset_bottom = review_done.offset_top + 80.0
	review_done.offset_left = -96.0
	review_done.offset_right = -16.0


## Step the review to ply `i`. A single-step transition gets a quick slide (forward for Next, in
## reverse for Prev); a jump (open / snap-back) renders instantly. Each ply shows the position the
## mover FACED, with the played move (its quality colour) and the best move (green) drawn as arrows.
func _show_review_ply(i: int, animate := true) -> void:
	if _undo_stack.is_empty():
		return
	_exit_line()  # any direct ply view leaves best-replies playback
	var from_ply := _review_ply
	_review_ply = clampi(i, 0, _undo_stack.size() - 1)
	_review_playing = false
	review_prev.disabled = _review_ply <= 0
	review_next.disabled = _review_ply >= _undo_stack.size() - 1
	_update_review_panel()
	if animate and _review_ply == from_ply + 1:
		_render_review_step(from_ply, false)   # forward: play the move we were looking at
	elif animate and _review_ply == from_ply - 1:
		_render_review_step(_review_ply, true)  # reverse: take the just-undone move back
	else:
		_render_review_view()


## Draw the reviewed ply: the position the mover faced, with the played move (its quality colour)
## and, when known, the best move (green) as arrows. The opening (ply 0) is shown neutrally with no
## best, since the first move is always fine and too early to second-guess.
func _render_review_view() -> void:
	var pre := _rules_after(_review_ply)
	var played := int(_undo_stack[_review_ply]["move"])
	board.set_rules(pre)
	board.clear_options()  # also clears any lingering checkmate-explosion state from game-end
	board.clear_last_moves()
	_set_review_check(pre)
	board.end_animation()
	if _review_ply == 0:
		board.set_options([{"move": played, "quality": ""}], false)  # neutral; no best
		return
	var rv: Dictionary = _review[_review_ply] if _review_ply < _review.size() else {}
	if rv.is_empty():
		# Analysis in flight: show the played move with an hourglass on its arrow (so it reads without
		# the "Analysing…" header). _analyse_review_ply redraws with the real quality when it lands.
		board.set_options([{"move": played, "quality": "loading"}], false)
		board.reveal()
		return
	var opts: Array = [{"move": played, "quality": String(rv.get("quality", ""))}]
	var best := int(rv.get("best", -1))
	if best >= 0 and best != played:
		opts.append({"move": best, "quality": "best"})  # the green best-move arrow
	board.set_options(opts, false)
	board.reveal()  # colour the arrows + draw the quality symbols
	board.set_interactive(true)  # keep both arrows tappable: a tap launches that move's best-replies line


## Quick slide for one Prev/Next step. forward (reverse=false): play move[idx] from its pre-position;
## reverse=true: un-play move[idx] from its post-position. Guarded so a rapid step / close interrupts.
func _render_review_step(idx: int, reverse: bool) -> void:
	_review_gen += 1
	var g := _review_gen
	var mv := int(_undo_stack[idx]["move"])
	board.clear_options()
	board.clear_last_moves()
	board.set_check_square(-1)
	if reverse:
		board.set_rules(_rules_after(idx + 1))  # post: the piece sits on its destination
		board.end_animation()
		await board.animate_unmove(mv, REVIEW_STEP_FAST)
	else:
		board.set_rules(_rules_after(idx))       # pre-move position
		board.end_animation()
		await board.animate_move(mv, REVIEW_STEP_FAST)
	if g != _review_gen:
		return
	_render_review_view()


func _set_review_check(r: ChessRules) -> void:
	if r.is_in_check():
		board.set_check_square(r.king_square(r.side_to_move))
	else:
		board.set_check_square(-1)


func _update_review_panel() -> void:
	var total := _undo_stack.size()
	var e: Dictionary = _undo_stack[_review_ply]
	var move := int(e["move"])
	var mover := int(e["mover"])
	var pre := _rules_after(_review_ply)
	var san := pre.to_san(move)
	review_step.text = "%s %d / %d" % [tr("Move"), _review_ply + 1, total]
	review_move.text = "%s: %s" % [_review_who(mover), san]
	# Eval bar reflects this position (best play, White-relative); 0/even until a score exists.
	if eval_bar != null:
		var ev: Dictionary = _review[_review_ply] if _review_ply < _review.size() else {}
		eval_bar.set_eval(int(ev.get("eval_cp", 0)))
	# The opponent's avatar sits beside its move (bot games only; the player's own moves and Pass &
	# Play don't map to one opponent face).
	var is_bot_move := not GameManager.pass_and_play and not _puzzle_review_mode and _review_ply > 0 and mover != player_color
	review_avatar.visible = is_bot_move
	if is_bot_move:
		review_avatar.texture = load(BotRoster.avatar_path(bot_def))
	# A pawn in the mover's colour marks the human player's own rows: beside "You:" vs a bot, and
	# beside both "White:"/"Black:" in Face to Face (both sides are human there). Same piece art as
	# the board. The opening (ply 0) and the bot's own moves get no pawn.
	var is_player_row := _review_ply > 0 and (GameManager.pass_and_play or mover == player_color)
	review_pawn.visible = is_player_row
	if is_player_row:
		var side := "w" if mover == ChessRules.WHITE else "b"
		review_pawn.texture = load("res://assets/pieces/%s_pawn.png" % side)
	review_analyse_icon.visible = false  # only shown beside "Analysing…"
	# The opening is always a fine first move: no quality / best line for it.
	if _review_ply == 0:
		review_quality.visible = false
		review_line_label.visible = false
		review_line_best.disabled = true
		review_line_played.visible = false
		return
	var rv: Dictionary = _review[_review_ply] if _review_ply < _review.size() else {}
	if rv.is_empty():
		# A bot reply not graded during play: analyse it on demand (engine, else GDScript fallback)
		# so the review covers BOTH sides.
		review_line_label.visible = false
		review_line_best.disabled = true
		review_line_played.visible = false
		review_quality.visible = true
		review_analyse_icon.visible = true  # the magnifier beside "Analysing…"
		review_quality.text = tr("Analysing…")
		review_quality.modulate = Color(1, 1, 1, 0.5)
		_analyse_review_ply(_review_ply)
		return
	review_quality.visible = true
	if int(rv.get("best", -1)) == move:
		review_quality.text = tr("★ Best move!")
		review_quality.modulate = _quality_color("best")
	else:
		review_quality.text = tr(String(rv.get("label", "")))
		review_quality.modulate = _quality_color(String(rv.get("quality", "")))
	_refresh_line_buttons(rv, pre, move)
	_ensure_review_line(_review_ply)   # lengthen the best line in the background if it's too short
	if move != int(rv.get("best", -1)) and move >= 0:
		_ensure_played_line(_review_ply)  # any wrong move (player's or bot's) gets a consequence line


## Set up the two best-replies buttons for the current ply: the GREEN one (whenever a best move exists)
## explores the best move's line; the quality-coloured one explores the actually-played move's line
## (whenever it differs from the best), so the player can walk into either a mistake of their own OR the
## bot's blunder and see the consequence. The info panel shows the best line by default.
func _refresh_line_buttons(rv: Dictionary, pre: ChessRules, played: int) -> void:
	var best := int(rv.get("best", -1))
	var best_parts := _best_line_san_parts(pre, rv.get("best_pv", PackedStringArray()), best)
	review_line_best.disabled = best_parts.is_empty()
	if not best_parts.is_empty():
		review_line_label.visible = true
		review_line_label.text = _best_replies_markup(best_parts, -1)  # static: nothing highlighted
	else:
		review_line_label.visible = false
	# The played-move line exists for any wrong move (the player's OR the bot's), not just the player's.
	# Always launchable, matching the tappable arrow: at least the move itself, extended once its
	# continuation search lands (see _ensure_played_line).
	var has_played := played != best and played >= 0
	review_line_played.visible = has_played
	# Best button solo (played == best): show the "Best replies" label; paired: keep it icon-only (✓).
	if _best_mark != null:
		_best_mark.visible = has_played
	if _best_label != null:
		_best_label.visible = not has_played
	if has_played:
		review_line_played.disabled = false
		var q := String(rv.get("quality", ""))
		_color_line_button(review_line_played, _quality_color(q))
		if _played_mark != null:
			_played_mark.quality = q  # match the button glyph to this move's board arrow (✓ / – / ✗)
			_played_mark.queue_redraw()


## Grade an un-reviewed ply (the auto-opening or a bot reply) on demand and fill its _review entry,
## so the review shows a quality + best line for BOTH sides. Async (engine, or the GDScript
## fallback); refreshes the panel if the player is still on that ply when it lands.
func _analyse_review_ply(i: int) -> void:
	if i <= 0 or i >= _undo_stack.size():
		return  # the opening (ply 0) is never graded
	if i < _review.size() and not (_review[i] as Dictionary).is_empty():
		return  # already a captured pick, or already analysed
	if _review_analyzing.has(i):
		return  # one is already in flight for this ply
	_review_analyzing[i] = true
	var pre := _rules_after(i)
	var played := int(_undo_stack[i]["move"])
	var ranked: Array = await _rank_position(pre)
	if not ranked.is_empty():
		ranked = await _deep_promote(ranked, pre, _gen)
	_review_analyzing.erase(i)
	if ranked.is_empty() or i >= _review.size():
		return
	var grade := ChessBotScript.grade_move(ranked, played)
	var best_pv := PackedStringArray()
	for entry in ranked:
		if int(entry["move"]) == int(grade["best_move"]):
			best_pv = entry.get("pv", PackedStringArray())
			break
	_review[i] = {
		"quality": _quality_from_label(String(grade["label"])),
		"label": String(grade["label"]),
		"cp_loss": int(grade["cp_loss"]),
		"best": int(grade["best_move"]),
		"best_pv": best_pv,
		"eval_cp": int(ranked[0]["score"]) * (1 if pre.side_to_move == ChessRules.WHITE else -1),
	}
	if review_overlay.visible and _review_ply == i and not _review_playing:
		_update_review_panel()
		_render_review_view()  # redraw with the played + best-move arrows now that we have data


## If a ply's stored best line is too short (a slow device engine can return a 1-2 ply stub), play
## the best move on a clone and search the continuation at a fixed DEPTH, then store the full line
## (best move + continuation). Cached via a "deepened" flag so it runs at most once per ply. Keeps
## the displayed best move (the green arrow) unchanged, just lengthens its line.
func _ensure_review_line(i: int) -> void:
	if i <= 0 or i >= _review.size():
		return
	var rv: Dictionary = _review[i]
	if rv.is_empty() or bool(rv.get("deepened", false)):
		return
	var pv: PackedStringArray = rv.get("best_pv", PackedStringArray())
	if pv.size() >= REVIEW_MIN_LINE:
		rv["deepened"] = true
		_review[i] = rv
		return
	if not (_use_sf and stockfish.available) or _review_analyzing.has(i):
		return
	var best := int(rv.get("best", -1))
	if best < 0:
		return
	_review_analyzing[i] = true
	var pre := _rules_after(i)
	var after := ChessRules.new()
	after.set_fen(pre.get_fen())
	after.make_move(best)  # play the best move, then search the continuation deeply
	var lines: Array = await stockfish.analyse(after.get_fen(), 1, REVIEW_LINE_DEPTH)
	_review_analyzing.erase(i)
	if i >= _review.size():
		return
	var deep := PackedStringArray([pre.move_to_uci(best)])  # line always starts with the best move
	if not lines.is_empty():
		for uci in lines[0].get("pv", PackedStringArray()):
			deep.append(uci)
	var ent: Dictionary = _review[i]
	ent["best_pv"] = deep
	ent["deepened"] = true
	_review[i] = ent
	if review_overlay.visible and _review_ply == i and not _review_playing:
		_update_review_panel()
		_render_review_view()


## Compute (and cache) the "played line": the player's OWN move followed by the engine's best
## continuation, so the review can replay where the mistake leads. Only meaningful when the played
## move wasn't already the best; runs once per ply in the background (needs the engine).
func _ensure_played_line(i: int) -> void:
	if i <= 0 or i >= _review.size():
		return
	var rv: Dictionary = _review[i]
	if rv.is_empty() or rv.has("played_pv"):
		return
	var played := int(_undo_stack[i]["move"])
	if played == int(rv.get("best", -1)):
		return  # played the best: the "played line" IS the best line, no separate one needed
	if not (_use_sf and stockfish.available) or _played_analyzing.has(i):
		return
	_played_analyzing[i] = true
	var pre := _rules_after(i)
	var after := ChessRules.new()
	after.set_fen(pre.get_fen())
	after.make_move(played)  # play the mistake, then search the opponent's best exploitation
	var lines: Array = await stockfish.analyse(after.get_fen(), 1, REVIEW_LINE_DEPTH)
	_played_analyzing.erase(i)
	if i >= _review.size():
		return
	var pv := PackedStringArray([pre.move_to_uci(played)])  # the line always starts with the played move
	if not lines.is_empty():
		for uci in lines[0].get("pv", PackedStringArray()):
			pv.append(uci)
	var ent: Dictionary = _review[i]
	ent["played_pv"] = pv
	_review[i] = ent
	if review_overlay.visible and _review_ply == i and not _line_active:
		_update_review_panel()  # enable the played-move button now that its line is ready


## The two best-replies entry points (buttons + board-arrow taps): the best move's line, or the
## played move's line (the player's or the bot's).
func _on_line_best() -> void:
	_play_line(true)


func _on_line_played() -> void:
	_play_line(false)


## Map a grade label to one of the three option-quality buckets, for colouring an analysed move.
func _quality_from_label(label: String) -> String:
	match label:
		"Best", "Great": return "best"
		"Good", "Inaccuracy": return "decent"
		_: return "blunder"  # Mistake / Blunder


## Replay the engine's best line for the move under review, branching from the position the player
## faced. Snaps back to the reviewed move when done (or bails if the player navigates / closes).
## "Best replies": build the scrubbable timeline for the reviewed ply's best line, then auto-play it
## forward. The stepping happens in _process so the player can grab the board to scrub (rewind /
## pause / fast-forward) at any time. It's a toggle: re-tapping leaves the line and restores the
## played + best-move arrows on the same move.
func _play_line(from_best: bool) -> void:
	if _undo_stack.is_empty() or _line_active or _review_ply <= 0:  # controls hide while active; exit via Stop
		return
	var rv: Dictionary = _review[_review_ply] if _review_ply < _review.size() else {}
	if rv.is_empty():
		return
	var pre := _rules_after(_review_ply)
	# from_best: the engine's best move + its continuation. else: the player's OWN move + where it leads
	# (the consequence of the mistake), so they can compare the two lines.
	var first: int
	var pv: PackedStringArray
	if from_best:
		first = int(rv.get("best", -1))
		pv = rv.get("best_pv", PackedStringArray())
	else:
		first = int(_undo_stack[_review_ply]["move"])
		pv = rv.get("played_pv", PackedStringArray())
		if pv.is_empty():
			pv = PackedStringArray([pre.move_to_uci(first)])  # not analysed yet: at least the move itself
		# Whose move this line starts from decides the header wording ("Your move" vs "This move").
		var mover: int = int(_undo_stack[_review_ply].get("mover", -1))
		_line_is_player_move = GameManager.pass_and_play or mover == player_color
	if first < 0:
		return
	_line_from_best = from_best
	_line_moves_arr = _line_moves(pre, pv, first)
	if _line_moves_arr.is_empty():
		return
	_line_total = _line_moves_arr.size()
	_line_san = _best_line_san_parts(pre, pv, first)
	# Precompute the position after each prefix once, so per-frame rendering is just refs/ints.
	_line_states.clear()
	var sim := ChessRules.new()
	sim.set_fen(pre.get_fen())
	_line_states.append(_dup_rules(sim))
	for m: int in _line_moves_arr:
		sim.make_move(m)
		_line_states.append(_dup_rules(sim))
	_review_gen += 1            # cancel any step animation in flight
	_line_active = true
	_review_playing = true      # keep existing "line busy" guards satisfied
	_line_mate_exploded = false
	_line_pos = 0.0
	_line_rate = LINE_PLAY_RATE  # auto-play forward on enter (so it's obviously animating)
	_line_hl_active = -2
	board.clear_options()  # once: the line frames never add option arrows
	board.set_line_mode(true)
	_set_line_controls(true)    # swap nav to the media controls
	_update_line_buttons()
	_render_line_frame()


func _process(delta: float) -> void:
	if not _line_active or _line_rate == 0.0:
		return
	_line_pos = clampf(_line_pos + _line_rate * delta, 0.0, float(_line_total))
	if _line_pos < float(_line_total) and _line_mate_exploded:
		board.clear_explosion()  # scrubbed back off the mate: the king reappears
		_line_mate_exploded = false
	_render_line_frame()
	# Auto-pause at either end (so the play button reappears when it runs out).
	if _line_rate > 0.0 and _line_pos >= float(_line_total):
		_line_rate = 0.0
		_update_line_buttons()
		_maybe_explode_line_mate()  # the line ends in mate: shatter the king so it reads as mate, not check
	elif _line_rate < 0.0 and _line_pos <= 0.0:
		_line_rate = 0.0
		_update_line_buttons()


## If the best line ends in checkmate, shatter the mated king (like the live game / a solved mate
## puzzle) so a viewer sees it is mate, not just check. Fire-and-forget: the line is paused at the end
## here, so the per-frame render won't redraw over it. Guarded so it plays once per arrival at the end.
func _maybe_explode_line_mate() -> void:
	if _line_mate_exploded or _line_total <= 0:
		return
	var final_state: ChessRules = _line_states[_line_total]
	if not final_state.is_checkmate():
		return
	_line_mate_exploded = true
	board.explode_piece(final_state.king_square(final_state.side_to_move), MATE_EXPLODE_SEC)


## Draw the timeline at _line_pos: base position after floor(pos) moves, the current move sliding at
## the fractional part, the matching SAN highlighted in the header.
func _render_line_frame() -> void:
	var k := _line_total
	var i: int = clampi(int(floor(_line_pos)), 0, k)
	if i >= k:
		board.set_rules(_line_states[k])
		_line_last_move_and_check(k)
		board.end_animation()
		_highlight_line_san(k - 1)
		return
	board.set_rules(_line_states[i])
	_line_last_move_and_check(i)
	board.show_move_frame(int(_line_moves_arr[i]), _line_pos - float(i))
	_highlight_line_san(i)


## Light the last completed line move and flag a check, from the precomputed states.
func _line_last_move_and_check(i: int) -> void:
	board.clear_last_moves()
	if i > 0:
		var prev: ChessRules = _line_states[i - 1]
		board.set_last_move(int(_line_moves_arr[i - 1]), prev.side_to_move)
	var st: ChessRules = _line_states[i]
	if st.is_in_check():
		board.set_check_square(st.king_square(st.side_to_move))
	else:
		board.set_check_square(-1)


func _highlight_line_san(active: int) -> void:
	if _line_san.is_empty() or active == _line_hl_active:
		return  # only rebuild the markup when the highlighted move actually changes
	_line_hl_active = active
	review_line_label.visible = true
	review_line_label.text = _best_replies_markup(_line_san, active, not _line_from_best, _line_is_player_move)


func _dup_rules(r: ChessRules) -> ChessRules:
	var c := ChessRules.new()
	c.set_fen(r.get_fen())
	return c


## Leave best-replies mode (restore the Prev/Best-replies/Next nav + the live frame).
func _exit_line() -> void:
	if not _line_active:
		return
	_line_active = false
	_review_playing = false
	_line_rate = 0.0
	if _line_mate_exploded:
		board.clear_explosion()  # don't leave a shattered king on the restored ply view
		_line_mate_exploded = false
	board.set_line_mode(false)
	_set_line_controls(false)


# --- Best-replies media controls (shown only while the line plays) ---

## Stop: leave the line and restore the played + best-move arrows on the same move.
func _on_line_stop() -> void:
	_show_review_ply(_review_ply, false)  # calls _exit_line, then renders the arrows view


## Play/Pause: toggle playback. Tapping play from the end replays from the start.
func _on_line_play_pause() -> void:
	if not _line_active:
		return
	if _line_rate != 0.0:
		_line_rate = 0.0
	else:
		if _line_pos >= float(_line_total):
			_line_pos = 0.0
		_line_rate = LINE_PLAY_RATE
	_update_line_buttons()


## Rewind: play backward; each tap doubles the rewind speed (capped).
func _on_line_rewind() -> void:
	if not _line_active:
		return
	_line_rate = maxf(minf(_line_rate, -LINE_PLAY_RATE) * 2.0, -LINE_MAX_RATE)
	_update_line_buttons()


## Fast-forward: play forward faster; each tap doubles the speed (capped, ×2 the spec).
func _on_line_forward() -> void:
	if not _line_active:
		return
	_line_rate = minf(maxf(_line_rate, LINE_PLAY_RATE) * 2.0, LINE_MAX_RATE)
	_update_line_buttons()


## "Best replies: m0 m1 …" as centred BBCode, the active move bold + accent-coloured (active < 0 =
## none, the static display).
func _best_replies_markup(parts: PackedStringArray, active: int, played := false, player_move := true) -> String:
	var out := PackedStringArray()
	for j in parts.size():
		# Non-breaking hyphen so castling ("O-O" / "O-O-O") never wraps across two lines.
		var san := parts[j].replace("-", "‑")
		if j == active:
			# The move currently sliding: full white, a bit larger, bold. Its own colour overrides
			# the dim wrap below.
			out.append("[color=#ffffff][font_size=%d][b]%s[/b][/font_size][/color]" % [REVIEW_HL_SIZE, san])
		else:
			out.append(san)
	# Everything else stays dim (the prefix + the other moves); the active move overrides to white.
	# The played line is worded "Your move" for the human's own move and the neutral "This move" for the
	# bot's (it isn't "yours"); the best line is always "Best replies".
	var fmt: String
	if not played:
		fmt = tr("Best replies: %s")
	elif player_move:
		fmt = tr("Your move: %s")
	else:
		fmt = tr("This move: %s")
	return "[center][color=#ffffff99]%s[/color][/center]" % (fmt % " ".join(out))


func _on_review_prev() -> void:
	_exit_line()  # tapping a step leaves best-replies playback
	_review_gen += 1
	_show_review_ply(_review_ply - 1)


func _on_review_next() -> void:
	_exit_line()
	_review_gen += 1
	_show_review_ply(_review_ply + 1)


## Who made ply `_review_ply`: the auto-opening, "You" / the bot in a bot game, or White / Black
## in Face to Face.
func _review_who(mover: int) -> String:
	if _review_ply == 0:
		# A puzzle's ply 0 is the opponent's setup move from a midgame position, not a chess opening.
		return tr("Opponent") if _puzzle_review_mode else tr("Opening")
	if GameManager.pass_and_play:
		return tr("White") if mover == ChessRules.WHITE else tr("Black")
	if mover == player_color:
		return tr("You")
	return tr("Opponent") if _puzzle_review_mode else String(bot_def.get("name", "Bot"))


func _quality_color(quality: String) -> Color:
	match quality:
		"best": return UI.MOVE_BEST
		"decent": return UI.MOVE_DECENT
		"blunder": return UI.MOVE_BLUNDER
	return Color(1, 1, 1, 1)


## A fresh ChessRules at the position after the first `n` plies of the played game.
func _rules_after(n: int) -> ChessRules:
	var r := ChessRules.new()
	if _review_startpos.is_empty():
		r.reset_startpos()
	else:
		r.set_fen(_review_startpos)  # a failed puzzle starts from its own position, not the chess start
	for i in clampi(n, 0, _undo_stack.size()):
		r.make_move(int(_undo_stack[i]["move"]))
	return r


## The engine's best line as packed moves from `base`, capped at REVIEW_LINE_PLIES. Uses the PV if
## present, else the single best move. Never mutates `base`.
func _line_moves(base: ChessRules, pv: PackedStringArray, best: int) -> Array:
	var sim := ChessRules.new()
	sim.set_fen(base.get_fen())
	var out: Array = []
	for uci in pv:
		if out.size() >= REVIEW_LINE_PLIES:
			break
		var m := sim.move_from_uci(uci)
		if m < 0:
			break
		out.append(m)
		sim.make_move(m)
	if out.is_empty() and best >= 0:
		out.append(best)
	return out


## SAN text of the best line for the info panel (e.g. "Bb5 a6 Bxc6 dxc6").
func _best_line_san_parts(base: ChessRules, pv: PackedStringArray, best: int) -> PackedStringArray:
	var moves := _line_moves(base, pv, best)
	var sim := ChessRules.new()
	sim.set_fen(base.get_fen())
	var parts := PackedStringArray()
	for m: int in moves:
		parts.append(sim.to_san(m))
		sim.make_move(m)
	return parts


func _best_line_san(base: ChessRules, pv: PackedStringArray, best: int) -> String:
	return " ".join(_best_line_san_parts(base, pv, best))


## A small procedural quality mark for the best-replies buttons, drawn as the SAME white check / dash /
## cross the board paints on each arrow (see chess_board.gd `_draw_quality_symbol`), so a button's glyph
## always matches its arrow: ✓ = best, – = decent/average, ✗ = blunder.
class _LineMark extends Control:
	var quality := "best"

	func _draw() -> void:
		var c := size * 0.5
		var s := minf(size.x, size.y) * 0.36
		var w := maxf(3.0, s * 0.34)
		var white := Color(1, 1, 1, 0.95)
		match quality:
			"best":  # checkmark
				draw_line(c + Vector2(-s, 0), c + Vector2(-s * 0.2, s * 0.7), white, w, true)
				draw_line(c + Vector2(-s * 0.2, s * 0.7), c + Vector2(s, -s * 0.7), white, w, true)
			"decent":  # dash
				draw_line(c + Vector2(-s, 0), c + Vector2(s, 0), white, w, true)
			_:  # blunder (and any unknown): cross
				draw_line(c + Vector2(-s, -s), c + Vector2(s, s), white, w, true)
				draw_line(c + Vector2(-s, s), c + Vector2(s, -s), white, w, true)
