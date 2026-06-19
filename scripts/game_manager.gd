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
## Sentinel "remaining games" for premium players (any value > 0 unlocks play).
const UNLIMITED_GAMES := 999

# --- Persistent state ---
var is_premium := false
var language := ""           ## chosen UI locale code; "" = follow the device language
var sound_enabled := true    ## sound-effect cues on/off
var review_prompted := false ## already asked for a Play rating once (don't nag again)
var last_bot_id := ""        ## id of the last bot played, so Home offers it again
var games_today := 0
var last_play_date := ""     ## "YYYY-MM-DD" of the last counted game

# Lifetime career stats (for the About surface). NOT spendable currency.
var games_played := 0
var wins := 0
var draws := 0
var losses := 0
var best_moves_found := 0     ## total best moves found across all games
var blunders_made := 0        ## total blunders chosen across all games

# --- Current game context (set before entering the Game scene; not persisted) ---
var current_bot: Dictionary = {}     ## a BotRoster entry, or {} for pass-and-play
var player_is_white := true
var pass_and_play := false


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
	review_prompted = false
	games_today = 0
	last_play_date = ""
	games_played = 0
	wins = 0
	draws = 0
	losses = 0
	best_moves_found = 0
	blunders_made = 0
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


# --- Daily free-game gate ---

## Whether the player may start another bot game right now.
func can_play_game() -> bool:
	return is_premium or games_remaining_today() > 0


func games_remaining_today() -> int:
	if is_premium:
		return UNLIMITED_GAMES
	_roll_day()
	return max(0, FREE_GAMES_PER_DAY - games_today)


func _count_game() -> void:
	games_played += 1
	if not is_premium:
		_roll_day()
		games_today += 1
	_save()
	# Remind a free player when their games refill; cancel if they still have some (or are premium).
	if not is_premium and games_remaining_today() == 0:
		Notifications.schedule_reset_reminder()
	else:
		Notifications.cancel_reset_reminder()


## Reset the daily counter when the local date changes.
func _roll_day() -> void:
	var today := Time.get_date_string_from_system()
	if today != last_play_date:
		last_play_date = today
		games_today = 0


# --- Stats ---

## Fold a finished game's per-game review into the lifetime career totals.
func record_game_review(best_moves: int, blunders: int) -> void:
	best_moves_found += best_moves
	blunders_made += blunders
	_save()


## result: "win" | "loss" | "draw" from the human player's perspective.
func record_result(result: String) -> void:
	match result:
		"win": wins += 1
		"loss": losses += 1
		"draw": draws += 1
	_save()


## Undo the start-time count for a game abandoned before it really began (player
## started by mistake / cancelled in the opening). Refunds the daily free game and
## the played tally; does NOT touch wins/losses (a cancel is not a defeat).
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


## Ask for a Play rating only once, and only after the player is engaged (2+ games started).
func should_ask_review() -> bool:
	return not review_prompted and games_played >= 2


func mark_review_prompted() -> void:
	review_prompted = true
	_save()


# --- Persistence ---

func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "is_premium", is_premium)
	cfg.set_value("player", "language", language)
	cfg.set_value("player", "sound_enabled", sound_enabled)
	cfg.set_value("player", "review_prompted", review_prompted)
	cfg.set_value("player", "last_bot_id", last_bot_id)
	cfg.set_value("daily", "games_today", games_today)
	cfg.set_value("daily", "last_play_date", last_play_date)
	cfg.set_value("stats", "games_played", games_played)
	cfg.set_value("stats", "wins", wins)
	cfg.set_value("stats", "draws", draws)
	cfg.set_value("stats", "losses", losses)
	cfg.set_value("stats", "best_moves_found", best_moves_found)
	cfg.set_value("stats", "blunders_made", blunders_made)
	cfg.save(SAVE_PATH)


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	# Coerce types defensively — a hand-edited / corrupt save shouldn't crash later math.
	is_premium = bool(cfg.get_value("player", "is_premium", false))
	language = str(cfg.get_value("player", "language", ""))
	sound_enabled = bool(cfg.get_value("player", "sound_enabled", true))
	review_prompted = bool(cfg.get_value("player", "review_prompted", false))
	last_bot_id = str(cfg.get_value("player", "last_bot_id", ""))
	if last_bot_id != "":
		current_bot = BotRoster.get_by_id(last_bot_id)  # Home offers the last opponent
	games_today = int(cfg.get_value("daily", "games_today", 0))
	last_play_date = str(cfg.get_value("daily", "last_play_date", ""))
	games_played = int(cfg.get_value("stats", "games_played", 0))
	wins = int(cfg.get_value("stats", "wins", 0))
	draws = int(cfg.get_value("stats", "draws", 0))
	losses = int(cfg.get_value("stats", "losses", 0))
	best_moves_found = int(cfg.get_value("stats", "best_moves_found", 0))
	blunders_made = int(cfg.get_value("stats", "blunders_made", 0))
