extends Node

## Autoload singleton: scene navigation + all persistent player state.
##
## Registered in project.godot as "GameManager". Other scripts read/write it via
## GameManager.go_to_bots(), GameManager.can_play_game(), …
##
## Persistence is a single ConfigFile at user://. We deliberately keep the
## "3 free games a day" gate and premium flag LOCAL and low-security — per the
## design, beating it by changing the device clock isn't worth fighting.
##
## Move quality is NOT a currency: each game tracks its own best/average/blunder
## counts (in game.gd) for the end-of-game review. Only the lifetime career
## totals below persist.

signal premium_changed
signal language_changed

const SAVE_PATH := "user://limpid_chess.cfg"

## Shipped UI languages. `name` is shown in its OWN language (never translated).
const LANGUAGES := [
	{"code": "en", "name": "English"},
	{"code": "fr", "name": "Français"},
	{"code": "es", "name": "Español"},
]

const FREE_GAMES_PER_DAY := 3
## A free player can open the moves review once a day, and start one Puzzle Rush run a day; premium
## is unlimited for both.
const FREE_REVIEWS_PER_DAY := 1
const FREE_PUZZLE_RUNS_PER_DAY := 1
## Sentinel "remaining games" for premium players (any value > 0 unlocks play).
const UNLIMITED_GAMES := 999

# --- Persistent state ---
var is_premium := false
var language := ""           ## chosen UI locale code; "" = follow the device language
var sound_enabled := true    ## sound-effect cues on/off
var last_review_prompt_date := "" ## "YYYY-MM-DD" we last auto-showed the rating prompt (cap: once/day)
var review_done := false           ## player engaged with rating once → stops the automatic pre-prompt
var last_bot_id := ""        ## id of the last bot played, so Home offers it again
var games_today := 0
var reviews_today := 0       ## moves reviews opened today (free players are capped, see can_review_today)
var puzzles_today := 0       ## Puzzle Rush runs started today (free players are capped, see can_puzzle_today)
var last_play_date := ""     ## "YYYY-MM-DD" of the last counted game

# Lifetime counters kept for game logic only (no stats are shown to the player).
var games_played := 0         ## gates the review prompt + reset reminder; refunded by cancel_game
var bot_wins: Dictionary = {} ## bot id (String) -> times the human has beaten that bot (int)
var puzzle_highscore := 0     ## longest Puzzle Rush streak ever reached (saved)

# A parked (in-progress) puzzle run, so a player can quit and resume their streak later. We save just
# the streak length and the CURRENT puzzle's data index (the puzzle restarts from move 1 on resume, so
# the move number within it is not saved). puzzle_index < 0 means no run is parked.
var puzzle_streak := 0
var puzzle_index := -1
var pending_puzzle_resume := false  ## transient (not saved): Home's Resume asks puzzle_rush to resume

# --- Current game context (set before entering the Game scene; not persisted) ---
var current_bot: Dictionary = {}     ## a BotRoster entry, or {} for pass-and-play
var player_is_white := true
var pass_and_play := false
var pending_review_check := false  ## set after a positive game; consumed on Home/Bots to ask for a review


func _ready() -> void:
	_load()
	_apply_locale()
	_roll_day()


# --- Language ---

## Apply the saved locale, or fall back to the device language (then English).
func _apply_locale() -> void:
	var code := language if language != "" else _device_language()
	TranslationServer.set_locale(code)


## The device's language IF we ship it, else "en".
func _device_language() -> String:
	var os_lang := OS.get_locale_language()
	for l in LANGUAGES:
		if l["code"] == os_lang:
			return os_lang
	return "en"


## Set + persist the UI language ("" follows the device). Reload the current scene
## (caller's job) so code-built strings re-render in the new language.
func set_language(code: String) -> void:
	language = code
	_apply_locale()
	_save()
	language_changed.emit()


## The locale code actually in effect right now (resolves "" to the device pick).
func current_language() -> String:
	return language if language != "" else _device_language()


func set_sound_enabled(on: bool) -> void:
	sound_enabled = on
	_save()


## DEV ONLY: wipe the local save and reset in-memory state to a fresh first launch
## (non-premium, full daily games, zeroed stats). Caller should reload the scene.
func reset_save() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)
	is_premium = false
	language = ""
	sound_enabled = true
	last_review_prompt_date = ""
	review_done = false
	games_today = 0
	reviews_today = 0
	puzzles_today = 0
	last_play_date = ""
	games_played = 0
	bot_wins.clear()
	puzzle_highscore = 0
	puzzle_streak = 0
	puzzle_index = -1
	current_bot = {}
	last_bot_id = ""
	_apply_locale()
	_roll_day()


# --- Navigation ---

func go_to_home() -> void:
	get_tree().change_scene_to_file("res://scenes/home.tscn")

func go_to_bots() -> void:
	get_tree().change_scene_to_file("res://scenes/bots.tscn")

func go_to_premium() -> void:
	get_tree().change_scene_to_file("res://scenes/premium.tscn")

func go_to_about() -> void:
	get_tree().change_scene_to_file("res://scenes/about.tscn")


## Begin a game versus a bot. Consumes one of the day's free games for non-premium.
func start_bot_game(bot: Dictionary, player_white := true) -> void:
	current_bot = bot
	last_bot_id = str(bot.get("id", ""))  # remembered so Home offers it again
	player_is_white = player_white
	pass_and_play = false
	_count_game()  # persists (incl. last_bot_id)
	get_tree().change_scene_to_file("res://scenes/game.tscn")


## Begin a local pass-and-play game (premium feature).
func start_pass_and_play() -> void:
	if not is_premium:
		return  # premium-only; callers should gate, but guard here too
	current_bot = {}
	player_is_white = true
	pass_and_play = true
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func go_to_puzzles() -> void:
	get_tree().change_scene_to_file("res://scenes/puzzle_rush.tscn")


## Begin a Puzzle Rush run. A fresh run (resume == false) discards any parked run and consumes the
## day's free run for non-premium (callers gate on can_puzzle_today()). Resuming (resume == true)
## continues a parked run: no daily is charged (it was already paid when the run first started).
func start_puzzle_rush(resume := false) -> void:
	pending_puzzle_resume = resume
	if not resume:
		clear_puzzle_progress()  # a fresh run abandons any parked streak
		count_puzzle()           # consume the day's free run (no-op for premium)
	get_tree().change_scene_to_file("res://scenes/puzzle_rush.tscn")


## True when a run is parked and can be resumed from Home.
func has_puzzle_run() -> bool:
	return puzzle_index >= 0


## Park the in-progress run: the current streak length + the current puzzle's data index (so the exact
## puzzle can be reloaded and restarted). Called each time a new puzzle is presented.
func save_puzzle_progress(streak: int, index: int) -> void:
	puzzle_streak = streak
	puzzle_index = index
	if streak > puzzle_highscore:  # bank the reached streak now, so a hard app-kill can't lose the record
		puzzle_highscore = streak
	_save()


## Discard the parked run (a run ended, or a fresh run replaced it).
func clear_puzzle_progress() -> void:
	puzzle_streak = 0
	puzzle_index = -1
	_save()


## A failed Puzzle Rush puzzle handed to the game scene's moves-review (so the player can "understand
## their mistake"). {} = none; consumed by game.gd on entry. Transient, not saved.
var puzzle_review: Dictionary = {}

## A Puzzle Rush game-over snapshot kept across the mistake review, so closing the review returns to
## the result dialog (like the bot game) instead of Home. {} = none; consumed by puzzle_rush on entry.
var puzzle_result: Dictionary = {}


## Open the game scene's moves-review on a failed puzzle: its start FEN, the played line (UCI, ending
## on the wrong move), and the player's colour. The game scene enters review directly (no live game).
func review_puzzle_mistake(fen: String, moves: PackedStringArray, player_white: bool) -> void:
	puzzle_review = {"fen": fen, "moves": moves, "player_white": player_white}
	get_tree().change_scene_to_file("res://scenes/game.tscn")


# --- Daily free-game gate ---

## Whether the player may start another bot game right now.
func can_play_game() -> bool:
	return is_premium or games_remaining_today() > 0


func games_remaining_today() -> int:
	if is_premium:
		return UNLIMITED_GAMES
	_roll_day()
	return max(0, FREE_GAMES_PER_DAY - games_today)


## A free player can open the moves review FREE_REVIEWS_PER_DAY times a day; premium is unlimited.
func can_review_today() -> bool:
	if is_premium:
		return true
	_roll_day()
	return reviews_today < FREE_REVIEWS_PER_DAY


## Count one moves-review opening against the day's free allowance (no-op accounting for premium).
func count_review() -> void:
	if is_premium:
		return
	_roll_day()
	reviews_today += 1
	_save()


## A free player can start FREE_PUZZLE_RUNS_PER_DAY Puzzle Rush runs a day; premium is unlimited.
func can_puzzle_today() -> bool:
	if is_premium:
		return true
	_roll_day()
	return puzzles_today < FREE_PUZZLE_RUNS_PER_DAY


## Count one Puzzle Rush run against the day's free allowance (no-op accounting for premium).
func count_puzzle() -> void:
	if is_premium:
		return
	_roll_day()
	puzzles_today += 1
	_save()


## Undo the start-time count for a run the player left before the 4th puzzle (barely played), so it
## doesn't burn the daily free run, mirroring cancel_game(). The streak is still saved on leave.
func cancel_puzzle() -> void:
	if not is_premium:
		puzzles_today = max(0, puzzles_today - 1)
	_save()


func _count_game() -> void:
	games_played += 1
	if not is_premium:
		_roll_day()
		games_today += 1
	_save()
	# Free players get a daily "your free games are back" reminder (the games reset every day), so a
	# player who forgets a day still gets nudged the next. Re-anchored to tomorrow on each game, and
	# dropped for Premium (unlimited games). Gated to 2+ games played so the notification-permission
	# ask lands on an engaged player, not on their very first game (matches should_ask_review).
	if is_premium:
		Notifications.cancel_reset_reminder()
	elif games_played >= 2:
		Notifications.schedule_reset_reminder()


## Reset the daily counter when the local date changes.
func _roll_day() -> void:
	var today := Time.get_date_string_from_system()
	if today != last_play_date:
		last_play_date = today
		games_today = 0
		reviews_today = 0
		puzzles_today = 0


# --- Stats ---

## Record a win against the current bot, for the Bots-screen "beaten" badge (wins_against).
## Called on game end for bot games only (game.gd guards out Face to Face); a loss or draw
## carries no persistent state, so those results are no-ops.
func record_result(result: String) -> void:
	if result != "win":
		return
	var bot_id: String = str(current_bot.get("id", ""))
	if bot_id != "":
		bot_wins[bot_id] = int(bot_wins.get(bot_id, 0)) + 1
		_save()


## How many times the human has beaten this bot (for the Bots screen badge).
func wins_against(bot_id: String) -> int:
	return int(bot_wins.get(bot_id, 0))


## Record a finished Puzzle Rush run; keep the longest streak ever as the highscore.
func record_puzzle_score(streak: int) -> void:
	if streak > puzzle_highscore:
		puzzle_highscore = streak
		_save()


## Undo the start-time count for a game abandoned before it really began (player
## started by mistake / cancelled in the opening). Refunds the daily free game and
## the played tally; does NOT touch the bot-win badge (a cancel is not a defeat).
func cancel_game() -> void:
	games_played = max(0, games_played - 1)
	if not is_premium:
		games_today = max(0, games_today - 1)
	_save()


func set_premium(value: bool) -> void:
	is_premium = value
	premium_changed.emit()
	_save()
	if value:
		Notifications.cancel_reset_reminder()  # unlimited games now → drop any pending reminder


## Auto-prompt for a Play rating at most once per calendar day, only after the player is engaged
## (2+ games), and never once they've already rated via the dialog or the About button.
func should_ask_review() -> bool:
	if review_done or games_played < 2:
		return false
	return last_review_prompt_date != Time.get_date_string_from_system()


func mark_review_prompted() -> void:
	last_review_prompt_date = Time.get_date_string_from_system()
	_save()


func mark_review_done() -> void:
	review_done = true
	_save()


# --- Persistence ---

func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "is_premium", is_premium)
	cfg.set_value("player", "language", language)
	cfg.set_value("player", "sound_enabled", sound_enabled)
	cfg.set_value("player", "last_review_prompt_date", last_review_prompt_date)
	cfg.set_value("player", "review_done", review_done)
	cfg.set_value("player", "last_bot_id", last_bot_id)
	cfg.set_value("daily", "games_today", games_today)
	cfg.set_value("daily", "reviews_today", reviews_today)
	cfg.set_value("daily", "puzzles_today", puzzles_today)
	cfg.set_value("daily", "last_play_date", last_play_date)
	cfg.set_value("stats", "games_played", games_played)
	cfg.set_value("stats", "puzzle_highscore", puzzle_highscore)
	cfg.set_value("stats", "puzzle_streak", puzzle_streak)
	cfg.set_value("stats", "puzzle_index", puzzle_index)
	for bot_id: String in bot_wins:  # ConfigFile has no nested values: one key per bot
		cfg.set_value("bot_wins", bot_id, bot_wins[bot_id])
	cfg.save(SAVE_PATH)


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	# Coerce types defensively — a hand-edited / corrupt save shouldn't crash later math.
	is_premium = bool(cfg.get_value("player", "is_premium", false))
	language = str(cfg.get_value("player", "language", ""))
	sound_enabled = bool(cfg.get_value("player", "sound_enabled", true))
	last_review_prompt_date = str(cfg.get_value("player", "last_review_prompt_date", ""))
	review_done = bool(cfg.get_value("player", "review_done", false))
	last_bot_id = str(cfg.get_value("player", "last_bot_id", ""))
	if last_bot_id != "":
		current_bot = BotRoster.get_by_id(last_bot_id)  # Home offers the last opponent
	games_today = int(cfg.get_value("daily", "games_today", 0))
	reviews_today = int(cfg.get_value("daily", "reviews_today", 0))
	puzzles_today = int(cfg.get_value("daily", "puzzles_today", 0))
	last_play_date = str(cfg.get_value("daily", "last_play_date", ""))
	games_played = int(cfg.get_value("stats", "games_played", 0))
	puzzle_highscore = int(cfg.get_value("stats", "puzzle_highscore", 0))
	puzzle_streak = int(cfg.get_value("stats", "puzzle_streak", 0))
	puzzle_index = int(cfg.get_value("stats", "puzzle_index", -1))
	bot_wins.clear()
	if cfg.has_section("bot_wins"):
		for bot_id: String in cfg.get_section_keys("bot_wins"):
			bot_wins[bot_id] = int(cfg.get_value("bot_wins", bot_id, 0))
