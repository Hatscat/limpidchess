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
	{"code": "pt", "name": "Português"},
	{"code": "de", "name": "Deutsch"},
	{"code": "it", "name": "Italiano"},
	{"code": "ru", "name": "Русский"},
	{"code": "tr", "name": "Türkçe"},
	{"code": "pl", "name": "Polski"},
	{"code": "id", "name": "Indonesia"},
	{"code": "vi", "name": "Tiếng Việt"},
	{"code": "uk", "name": "Українська"},
	{"code": "el", "name": "Ελληνικά"},
]

const FREE_GAMES_PER_DAY := 3
## A free player can open the moves review once a day, and start one Puzzle Rush run a day; premium
## is unlimited for both.
const FREE_REVIEWS_PER_DAY := 1
const FREE_PUZZLE_RUNS_PER_DAY := 1
## One-time welcome credit on top of the daily allowances, so the first day can hook:
## 3+2 games and 1+2 puzzle runs. Spent only AFTER the day's free allowance, so any
## leftover survives to later days (an extra reason to come back) instead of expiring
## at midnight. Granted via the save-load defaults: a fresh save starts with the full
## credit, and existing players get it once when they update — a small gift, on brand.
const WELCOME_BONUS_GAMES := 2
const WELCOME_BONUS_PUZZLES := 2
## Sentinel "remaining games" for premium players (any value > 0 unlocks play).
const UNLIMITED_GAMES := 999

## Day streak: how large a GAP (in days) still continues the run. 3 means "come back
## within three days and your streak keeps going", which is exactly what it takes to
## survive a weekend (play Friday, next play Monday = a gap of 3). Deliberately generous:
## the audience includes kids whose tablet is put away at weekends, and a counter that
## resets on them every single week would teach them to stop caring about it.
## Lower it to 2 (one day off) or 1 (strictly consecutive) by changing this one number.
const STREAK_GRACE_DAYS := 3

# --- Persistent state ---
var is_premium := false
## Web only: the Lemon Squeezy license key that bought Premium, its activation instance,
## and the last day it was re-checked (see Billing._revalidate). The key doubles as the
## portable proof of purchase: re-pasting it is how a web player "restores" on a new
## browser, or after the browser evicts this save.
var license_key := ""
var license_instance := ""
var license_checked_date := ""
## Set at boot when the player lands back from the checkout (…/play/?ls=ok), so Home can
## take them straight to Premium with "your key is in your email".
var returned_from_checkout := false
var language := ""           ## chosen UI locale code; "" = follow the device language
var sound_enabled := true    ## sound-effect cues on/off
## Daily reminder notification on/off. Premium players can now be nudged too (the
## slot carries the streak reminder as well as the free-games one), so the implicit
## "premium means no notifications" opt-out is replaced by this explicit one.
var reminder_enabled := true
var last_review_prompt_date := "" ## "YYYY-MM-DD" we last auto-showed the rating prompt (cap: once/day)
var review_done := false           ## player engaged with rating once → stops the automatic pre-prompt
var games_today := 0
var reviews_today := 0       ## moves reviews opened today (free players are capped, see can_review_today)
var puzzles_today := 0       ## Puzzle Rush runs started today (free players are capped, see can_puzzle_today)
var last_play_date := ""     ## "YYYY-MM-DD" of the last counted game
# Remaining welcome credit (see WELCOME_BONUS_*). Survives _roll_day on purpose.
var bonus_games := WELCOME_BONUS_GAMES
var bonus_puzzles := WELCOME_BONUS_PUZZLES

# Lifetime counters kept for game logic only (no stats are shown to the player).
var games_played := 0         ## gates the review prompt + reset reminder; refunded by cancel_game
var bot_wins: Dictionary = {} ## bot id (String) -> times the human has beaten that bot (int)
var puzzle_highscore := 0     ## longest Puzzle Rush streak ever reached (saved)

# --- Day streak (the Home flame) ---
# Days the player actually PLAYED, not days elapsed: a gap of up to STREAK_GRACE_DAYS
# keeps the run going. Counted on EFFORT (a move played / a puzzle solved), never on a
# result, because this audience loses most of its games. Distinct from the Puzzle Rush
# "streak" (consecutive solved puzzles) in every way: different field, different save
# key, different user-facing word ("Day streak").
var day_streak := 0           ## current run of played days; 0 = never played / lapsed
var day_streak_best := 0      ## longest run ever reached. Never decreases, never expires.
var last_streak_date := ""    ## "YYYY-MM-DD" of the last day that counted toward the streak

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
	_join_other_tabs()
	_adopt_moved_save()
	_apply_locale()
	_roll_day()
	_check_web_update()
	_check_checkout_return()
	# NB: the boot re-arm of the daily reminder lives in Notifications._on_initialized, not here.
	# Autoloads are added in project.godot order and GameManager is first, so `Notifications`
	# does not resolve yet at this point.


# --- Web/PWA update-at-boot ---

# Kept referenced for the whole app or the bridge silently drops the callback.
var _pwa_solo_cb: JavaScriptObject = null


## The service worker downloads new releases in the background but keeps serving the
## cached version until activated. Activating (pwa_update) reloads EVERY open tab of
## the game, so we do it only at boot, only when this is the sole running instance
## (Web Locks headcount — a second tab could be mid-game), and only online (offline,
## the new version's cache starts empty and the reload would strand the player on
## the offline page instead of the playable cached game). Worst case we run one
## version behind until the next solo online launch: the standard PWA pattern.
func _check_web_update() -> void:
	if not OS.has_feature("web"):
		return
	_pwa_solo_cb = JavaScriptBridge.create_callback(_on_pwa_solo_boot)
	var window: JavaScriptObject = JavaScriptBridge.get_interface("window")
	if window == null or _pwa_solo_cb == null:
		return
	window.set("_limpidPwaSolo", _pwa_solo_cb)
	# Every instance holds the shared lock for its lifetime; querying from inside our
	# own grant means the headcount always includes us, so "1" really means solo.
	JavaScriptBridge.eval("""
		if (navigator.locks) {
			navigator.locks.request('limpid-alive', { mode: 'shared' }, () => {
				navigator.locks.query().then((q) => {
					const held = q.held.filter((l) => l.name === 'limpid-alive').length;
					if (held <= 1 && navigator.onLine) window._limpidPwaSolo();
				});
				return new Promise(() => {});
			});
		}
	""", true)


func _on_pwa_solo_boot(_args: Array) -> void:
	if JavaScriptBridge.pwa_needs_update():
		JavaScriptBridge.pwa_update()


## Did the player just come back from the Lemon Squeezy checkout (…/play/?ls=ok)?
## The flag is read once by Home, which routes them to Premium to redeem their key.
## The parameter is then stripped so a reload (or an installed PWA relaunching its
## start_url) can't re-trigger the prompt forever.
func _check_checkout_return() -> void:
	if not OS.has_feature("web"):
		return
	var flag: Variant = JavaScriptBridge.eval(
		"(new URLSearchParams(location.search).get('ls') === 'ok')", true)
	if typeof(flag) != TYPE_BOOL or not flag:
		return
	returned_from_checkout = true


# --- Web: the save handed over from the old address ---

## Until 2026-10 the web game lived at limpidchess.com. Browser saves are bound to their
## address, so that domain stays up as a Cloudflare Worker (web/old_domain/worker.js) whose
## bridge page reads the save this browser kept there and comes here with it in the URL
## fragment: #lc-move=<base64url of limpid_chess.cfg>. A fragment never reaches a server.
const MOVED_SAVE_PREFIX := "#lc-move="
## A real save is well under 2 KB, so anything much bigger is not one of ours.
const MOVED_SAVE_MAX_CHARS := 16384
## Every line ConfigFile.save() writes for OUR save: a [section], or key=value where the value
## is a bool, an int or a plain string. The payload is untrusted (anyone can craft such a link)
## and ConfigFile.parse() would build Objects and load Resources from text, so any other shape
## is refused before it gets parsed. Saves announced by other tabs go through the same check.
const MOVED_SAVE_LINE := "^(\\[[A-Za-z0-9_]+\\]|[A-Za-z0-9_]+=(true|false|-?[0-9]{1,18}|\"[^\"\\\\]*\"))$"
const MOVED_SAVE_DATE := "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"


## Web boot: adopt the save handed over from limpidchess.com, if this visit carries one.
func _adopt_moved_save() -> void:
	if not OS.has_feature("web"):
		return
	var fragment: Variant = JavaScriptBridge.eval("location.hash", true)
	if typeof(fragment) != TYPE_STRING or not str(fragment).begins_with(MOVED_SAVE_PREFIX):
		return
	# Out of the address bar first, whatever happens next: a reload, a bookmark or an installed
	# shortcut must never replay it.
	JavaScriptBridge.eval("history.replaceState(null, '', location.pathname + location.search)", true)
	var moved := _decode_moved_save(str(fragment))
	if moved != null:
		_take_moved_save(moved)


## "#lc-move=<base64url>" -> the parsed save, or null if anything about it is off.
func _decode_moved_save(fragment: String) -> ConfigFile:
	if not fragment.begins_with(MOVED_SAVE_PREFIX):
		return null
	var b64 := fragment.substr(MOVED_SAVE_PREFIX.length()).replace("-", "+").replace("_", "/")
	if b64.is_empty() or b64.length() > MOVED_SAVE_MAX_CHARS or b64.length() % 4 == 1:
		return null
	if RegEx.create_from_string("^[A-Za-z0-9+/]+$").search(b64) == null:
		return null
	while b64.length() % 4 != 0:
		b64 += "="
	return _parse_save_text(Marshalls.base64_to_raw(b64).get_string_from_utf8())


## A save's text -> the parsed save, or null unless it has exactly the plain shape and the
## types this game writes.
func _parse_save_text(text: String) -> ConfigFile:
	var plain := RegEx.create_from_string(MOVED_SAVE_LINE)
	for line: String in text.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed != "" and plain.search(trimmed) == null:
			return null
	var cfg := ConfigFile.new()
	if cfg.parse(text) != OK or not cfg.has_section("player"):
		return null
	# _load() and the merge run bool() and int() on these values: bool() of a String is a script
	# error and int() would quietly coerce one ("12abc" -> 12), so every key this game saves must
	# arrive with the type it saves it with. Keys it no longer saves (older versions) are never
	# read, so any plain value is fine there.
	var reference := _to_config()
	for section: String in cfg.get_sections():
		for key: String in cfg.get_section_keys(section):
			var want: int = TYPE_NIL
			if section == "bot_wins":
				want = TYPE_INT
			elif reference.has_section_key(section, key):
				want = typeof(reference.get_value(section, key))
			if want != TYPE_NIL and typeof(cfg.get_value(section, key)) != want:
				return null
	return cfg


## The first save at this address is the old one, as is. If the player already started here
## too, keep this save and merge in only what can never hurt them, UPGRADE-ONLY: Premium, the
## day streak and the lifetime records. Daily counters, the welcome credit, a parked puzzle run
## and settings stay as they are here. The bridge hands the old save over on every visit to the
## old address, and browser history can replay the link, so this must stay idempotent.
func _take_moved_save(moved: ConfigFile) -> void:
	_sanitize_moved_save(moved)
	if not FileAccess.file_exists(SAVE_PATH):
		moved.save(SAVE_PATH)
		_load()
		return
	_merge_moved_streak(moved)
	_merge_premium_from(moved)
	if license_key == "":  # a revoked key is still proof of purchase: Billing re-checks it at boot
		license_key = str(moved.get_value("premium", "license_key", ""))
		license_instance = str(moved.get_value("premium", "license_instance", ""))
	games_played = maxi(games_played, int(moved.get_value("stats", "games_played", 0)))
	puzzle_highscore = maxi(puzzle_highscore, int(moved.get_value("stats", "puzzle_highscore", 0)))
	if moved.has_section("bot_wins"):
		for bot_id: String in moved.get_section_keys("bot_wins"):
			var wins: int = int(moved.get_value("bot_wins", bot_id, 0))
			bot_wins[bot_id] = maxi(int(bot_wins.get(bot_id, 0)), wins)
	review_done = review_done or bool(moved.get_value("player", "review_done", false))
	_save()


## Anyone can craft a hand-over link, so before it is adopted or merged: Premium crosses only
## together with the license key that bought it (every web unlock has one), and Billing
## re-checks that key on this very boot, so a made-up key comes back INVALID while an offline
## boot keeps it, fail-open as designed. Counters stay in range and dates in the past, so a
## link can neither hand out free games nor freeze the day streak.
func _sanitize_moved_save(moved: ConfigFile) -> void:
	if str(moved.get_value("premium", "license_key", "")) == "":
		moved.set_value("player", "is_premium", false)
	moved.set_value("premium", "license_checked_date", "")
	var today := Time.get_date_string_from_system()
	var date_shape := RegEx.create_from_string(MOVED_SAVE_DATE)
	for section: String in moved.get_sections():
		for key: String in moved.get_section_keys(section):
			var value: Variant = moved.get_value(section, key)
			if typeof(value) == TYPE_INT:
				moved.set_value(section, key, maxi(int(value), -1 if key == "puzzle_index" else 0))
			elif typeof(value) == TYPE_STRING and key.ends_with("_date"):
				var date := str(value)
				if date != "" and date_shape.search(date) == null:
					moved.set_value(section, key, "")
				elif date > today:  # ISO dates sort lexicographically
					moved.set_value(section, key, today)
	for credit: Array in [["bonus_games", WELCOME_BONUS_GAMES], ["bonus_puzzles", WELCOME_BONUS_PUZZLES]]:
		if moved.has_section_key("daily", credit[0]):
			moved.set_value("daily", credit[0], mini(int(moved.get_value("daily", credit[0])), int(credit[1])))
	var code := str(moved.get_value("player", "language", ""))
	if code != "" and not LANGUAGES.any(func(l: Dictionary) -> bool: return l["code"] == code):
		moved.set_value("player", "language", "")


## The two addresses kept two separate runs, so "the most recent one wins" (the tab rule) could
## show a smaller live streak. Runs whose last days are within the grace window chain together:
## keep the longer one. Otherwise the more recent run is the live one.
func _merge_moved_streak(moved: ConfigFile) -> void:
	var their_streak: int = int(moved.get_value("stats", "day_streak", 0))
	var their_date: String = str(moved.get_value("stats", "last_streak_date", ""))
	day_streak_best = maxi(day_streak_best, int(moved.get_value("stats", "day_streak_best", 0)))
	if their_date == "":
		return
	if last_streak_date != "" and absi(_days_since(their_date) - _days_since(last_streak_date)) <= STREAK_GRACE_DAYS:
		day_streak = maxi(day_streak, their_streak)
	elif their_date > last_streak_date:
		day_streak = their_streak
	if their_date > last_streak_date:
		last_streak_date = their_date
	day_streak_best = maxi(day_streak_best, day_streak)


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


# --- Web license (Lemon Squeezy; see Billing) ---

# --- Web: the other open tabs of the game ---

## Every tab or installed window of the web game is its own Godot instance, and each one reads
## IndexedDB once, at boot. So a tab never sees what another tab saved (the key just redeemed in
## the tab that came back from the checkout, a game played elsewhere), and its next _save() puts
## its own stale copy back over it: IDBFS rewrites every file whose timestamp differs. Each save
## is therefore announced on a BroadcastChannel and merged into the running state of the others,
## and a tab coming back into view re-reads the save from IndexedDB for anything it missed while
## frozen. (Godot never sends NOTIFICATION_APPLICATION_FOCUS_IN on the web, so a focus-based
## re-read cannot work.)

## These follow whichever tab changed them last; everything else merges upgrade-only.
const TAB_LATEST_WINS := ["player/language", "player/sound_enabled", "player/reminder_enabled",
		"stats/puzzle_streak", "stats/puzzle_index"]

var _tabs: JavaScriptObject = null      ## the BroadcastChannel this tab posts on
var _tabs_cb: JavaScriptObject = null   ## kept referenced, or the bridge drops the callback
var _tab_values := {}                   ## TAB_LATEST_WINS values as last saved or adopted


func _join_other_tabs() -> void:
	_tab_values.clear()
	_tabs_changed(_to_config())  # the baseline: what this tab starts from is not "changed"
	if not OS.has_feature("web"):
		return
	_tabs_cb = JavaScriptBridge.create_callback(_on_other_tab_saved)
	var window: JavaScriptObject = JavaScriptBridge.get_interface("window")
	if window == null or _tabs_cb == null:
		return
	window.set("_limpidOtherTabSaved", _tabs_cb)
	# The IndexedDB read is the old-domain bridge's (web/old_domain/worker.js): versionless, so
	# it can never upgrade or block Godot's own database, and a missing one is never created.
	JavaScriptBridge.eval("""
		(function (path) {
			if (window.BroadcastChannel) {
				window._limpidTabs = new BroadcastChannel('limpid-save');
				window._limpidTabs.onmessage = function (e) {
					if (typeof e.data === 'string') window._limpidOtherTabSaved(e.data);
				};
			}
			document.addEventListener('visibilitychange', function () {
				if (document.visibilityState !== 'visible' || !window.indexedDB) return;
				var req = indexedDB.open('/userfs');
				req.onupgradeneeded = function () { req.transaction.abort(); };
				req.onerror = function (e) { e.preventDefault(); };
				req.onsuccess = function () {
					var db = req.result;
					if (!db.objectStoreNames.contains('FILE_DATA')) { db.close(); return; }
					var get = db.transaction('FILE_DATA', 'readonly').objectStore('FILE_DATA').get(path);
					get.onsuccess = function () {
						db.close();
						var c = get.result && get.result.contents;
						if (c && ArrayBuffer.isView(c)) {
							window._limpidOtherTabSaved(JSON.stringify({ changed: [],
								cfg: new TextDecoder().decode(new Uint8Array(c.buffer, c.byteOffset, c.byteLength)) }));
						}
					};
					get.onerror = function () { db.close(); };
				};
			});
		})(%s);
	""" % JSON.stringify(ProjectSettings.globalize_path(SAVE_PATH)), true)
	_tabs = JavaScriptBridge.get_interface("_limpidTabs")


## Announce a save to the other tabs, with the TAB_LATEST_WINS keys this tab itself changed.
func _tell_other_tabs(cfg: ConfigFile) -> void:
	var changed := _tabs_changed(cfg)
	if _tabs != null:
		_tabs.postMessage(JSON.stringify({"cfg": cfg.encode_to_text(), "changed": changed}))


## The TAB_LATEST_WINS keys whose value in `cfg` differs from the last saved or adopted one,
## which becomes `cfg`'s.
func _tabs_changed(cfg: ConfigFile) -> Array[String]:
	var changed: Array[String] = []
	for k: String in TAB_LATEST_WINS:
		var parts := k.split("/")
		var value: Variant = cfg.get_value(parts[0], parts[1])
		if not _tab_values.has(k) or _tab_values[k] != value:
			changed.append(k)
		_tab_values[k] = value
	return changed


## From another tab: '{"cfg": <save text>, "changed": [...]}', posted by its _tell_other_tabs(),
## or read back from IndexedDB when this tab comes into view (then nothing counts as changed).
func _on_other_tab_saved(args: Array) -> void:
	if args.is_empty() or typeof(args[0]) != TYPE_STRING:
		return
	var json := JSON.new()
	if json.parse(str(args[0])) != OK:
		return
	var msg: Variant = json.data
	if typeof(msg) != TYPE_DICTIONARY or typeof(msg.get("cfg")) != TYPE_STRING:
		return
	var cfg := _parse_save_text(str(msg["cfg"]))
	if cfg == null:
		return
	var changed: Array = []
	if typeof(msg.get("changed")) == TYPE_ARRAY:
		changed = msg["changed"]
	_merge_other_tab(cfg, changed)


## Merge another tab's save into this tab's running state. Nothing is saved here: this tab's
## next _save() carries both tabs' progress, and saving now would only echo between tabs.
func _merge_other_tab(cfg: ConfigFile, changed: Array) -> void:
	_merge_premium_from(cfg)
	if license_key == "":  # a revoked key is still proof of purchase: Billing re-checks it at boot
		license_key = str(cfg.get_value("premium", "license_key", ""))
		license_instance = str(cfg.get_value("premium", "license_instance", ""))
	_merge_streak_from_disk(cfg)
	games_played = maxi(games_played, int(cfg.get_value("stats", "games_played", 0)))
	puzzle_highscore = maxi(puzzle_highscore, int(cfg.get_value("stats", "puzzle_highscore", 0)))
	if cfg.has_section("bot_wins"):
		for bot_id: String in cfg.get_section_keys("bot_wins"):
			var wins: int = int(cfg.get_value("bot_wins", bot_id, 0))
			bot_wins[bot_id] = maxi(int(bot_wins.get(bot_id, 0)), wins)
	review_done = review_done or bool(cfg.get_value("player", "review_done", false))
	var their_prompt := str(cfg.get_value("player", "last_review_prompt_date", ""))
	if their_prompt > last_review_prompt_date:
		last_review_prompt_date = their_prompt
	# Both tabs spend the same day's allowance and the same welcome credit.
	var their_day := str(cfg.get_value("daily", "last_play_date", ""))
	if their_day > last_play_date:
		last_play_date = their_day
		games_today = int(cfg.get_value("daily", "games_today", 0))
		reviews_today = int(cfg.get_value("daily", "reviews_today", 0))
		puzzles_today = int(cfg.get_value("daily", "puzzles_today", 0))
	elif their_day == last_play_date:
		games_today = maxi(games_today, int(cfg.get_value("daily", "games_today", 0)))
		reviews_today = maxi(reviews_today, int(cfg.get_value("daily", "reviews_today", 0)))
		puzzles_today = maxi(puzzles_today, int(cfg.get_value("daily", "puzzles_today", 0)))
	if cfg.has_section_key("daily", "bonus_games"):
		bonus_games = mini(bonus_games, int(cfg.get_value("daily", "bonus_games")))
	if cfg.has_section_key("daily", "bonus_puzzles"):
		bonus_puzzles = mini(bonus_puzzles, int(cfg.get_value("daily", "bonus_puzzles")))
	for k: Variant in changed:
		var key := str(k)
		var parts := key.split("/")
		if key not in TAB_LATEST_WINS or not cfg.has_section_key(parts[0], parts[1]):
			continue
		var value: Variant = cfg.get_value(parts[0], parts[1])
		_tab_values[key] = value  # adopted, not changed here: never announced back as ours
		match key:
			"player/language":
				language = str(value)
				_apply_locale()
			"player/sound_enabled":
				sound_enabled = bool(value)
			"player/reminder_enabled":
				reminder_enabled = bool(value)
			"stats/puzzle_streak":
				puzzle_streak = int(value)
			"stats/puzzle_index":
				puzzle_index = int(value)


## Take the Premium unlock found in `cfg` (another tab's save, or the one handed over from
## the old address), UPGRADE-ONLY: never downgrades, only the store revokes.
func _merge_premium_from(cfg: ConfigFile) -> void:
	if is_premium or not bool(cfg.get_value("player", "is_premium", false)):
		return
	license_key = str(cfg.get_value("premium", "license_key", license_key))
	license_instance = str(cfg.get_value("premium", "license_instance", license_instance))
	license_checked_date = str(cfg.get_value("premium", "license_checked_date", license_checked_date))
	is_premium = true
	premium_changed.emit()


## Web multi-tab: the other tab may have played (and bumped the streak) while this tab sat
## idle with a stale copy (see _merge_other_tab). Merge UPGRADE-ONLY, so this tab's next
## full-file _save() can't roll the count back. Same reasoning as the premium merge: never
## downgrade.
func _merge_streak_from_disk(cfg: ConfigFile) -> void:
	var disk_streak: int = int(cfg.get_value("stats", "day_streak", 0))
	var disk_date: String = str(cfg.get_value("stats", "last_streak_date", ""))
	if disk_date > last_streak_date:  # ISO dates sort lexicographically, so > means "more recent"
		last_streak_date = disk_date
		day_streak = disk_streak
	day_streak_best = maxi(day_streak_best, int(cfg.get_value("stats", "day_streak_best", 0)))


func set_license(key: String, instance_id: String) -> void:
	license_key = key
	license_instance = instance_id
	license_checked_date = Time.get_date_string_from_system()
	_save()


func set_license_checked(date: String) -> void:
	license_checked_date = date
	_save()


func clear_license() -> void:
	license_key = ""
	license_instance = ""
	license_checked_date = ""
	_save()


## DEV ONLY: wipe the local save and reset in-memory state to a fresh first launch
## (non-premium, full daily games, zeroed stats). Caller should reload the scene.
func reset_save() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)
	is_premium = false
	language = ""
	sound_enabled = true
	reminder_enabled = true
	last_review_prompt_date = ""
	review_done = false
	games_today = 0
	reviews_today = 0
	puzzles_today = 0
	last_play_date = ""
	bonus_games = WELCOME_BONUS_GAMES
	bonus_puzzles = WELCOME_BONUS_PUZZLES
	license_key = ""
	license_instance = ""
	license_checked_date = ""
	games_played = 0
	bot_wins.clear()
	puzzle_highscore = 0
	day_streak = 0
	day_streak_best = 0
	last_streak_date = ""
	puzzle_streak = 0
	puzzle_index = -1
	current_bot = {}
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
	player_is_white = player_white
	pass_and_play = false
	_count_game()  # persists the daily counter
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
	return max(0, FREE_GAMES_PER_DAY - games_today) + bonus_games


## Today's full free allowance (the daily baseline plus any welcome credit left) —
## the denominator of the Home pill, so it reads "5 / 5" on day one, not "5 / 3".
func games_allowance_today() -> int:
	return FREE_GAMES_PER_DAY + bonus_games


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
	return puzzles_today < FREE_PUZZLE_RUNS_PER_DAY or bonus_puzzles > 0


## Count one Puzzle Rush run against the day's free allowance (no-op accounting for
## premium). The daily allowance is spent first; the welcome credit covers overflow.
func count_puzzle() -> void:
	if is_premium:
		return
	_roll_day()
	if puzzles_today < FREE_PUZZLE_RUNS_PER_DAY:
		puzzles_today += 1
	else:
		bonus_puzzles = max(0, bonus_puzzles - 1)
	_save()
	# Starting a run is a polite moment to ask for the notification permission, same as starting a
	# game. Without this a puzzles-only player would never be asked (they never reach _count_game).
	Notifications.refresh_daily_nudge(true)


## Undo the start-time count for a run the player left before the 4th puzzle (barely played), so it
## doesn't burn the daily free run, mirroring cancel_game(). The streak is still saved on leave.
## Refunding the daily side is equivalent even when the spend hit the welcome credit:
## the total remaining (daily left + credit) changes by the same +1 either way, and a
## credit spend implies the daily side is full, so the decrement always has room.
func cancel_puzzle() -> void:
	if not is_premium:
		puzzles_today = max(0, puzzles_today - 1)
	_save()


func _count_game() -> void:
	games_played += 1
	if not is_premium:
		_roll_day()
		# The daily allowance is spent first; the welcome credit covers overflow (and
		# thereby survives every day the player stays within the daily baseline).
		if games_today < FREE_GAMES_PER_DAY:
			games_today += 1
		else:
			bonus_games = max(0, bonus_games - 1)
	_save()
	# One alarm slot carries whichever daily nudge is currently true (keep-your-streak, or
	# "your free games are back"), so the two can never double-nag. Notifications decides which.
	# Starting a game is the one moment we allow the Android permission dialog: the player is
	# between screens, not mid-move, and a reminder about coming back makes sense to them here.
	Notifications.refresh_daily_nudge(true)


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
		# Refunding the daily side is equivalent even when the spend hit the welcome
		# credit (see cancel_puzzle): total remaining changes by the same +1.
		games_today = max(0, games_today - 1)
	_save()


func set_premium(value: bool) -> void:
	is_premium = value
	premium_changed.emit()
	_save()
	# Premium drops the free-games nudge but keeps the streak one, so re-decide rather than cancel.
	Notifications.refresh_daily_nudge()


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


# --- Day streak ---

## Whole days between a stored "YYYY-MM-DD" and today, in LOCAL time. Returns a large
## number for an empty / malformed date so callers treat it as "no streak to continue".
## Both ends are anchored at 12:00 so a daylight-saving shift (max 1h) can never round a
## 1-day gap to 0 or 2. The dicts go through the same UTC conversion, so the difference
## is correct even though neither instant is really noon UTC.
func _days_since(date_str: String) -> int:
	if date_str == "":
		return 9999
	var parts := date_str.split("-")
	if parts.size() != 3:
		return 9999  # corrupt / hand-edited save: don't crash, just don't continue a streak
	var then := {"year": int(parts[0]), "month": int(parts[1]), "day": int(parts[2]),
			"hour": 12, "minute": 0, "second": 0}
	var now_parts := Time.get_date_string_from_system().split("-")
	var now := {"year": int(now_parts[0]), "month": int(now_parts[1]), "day": int(now_parts[2]),
			"hour": 12, "minute": 0, "second": 0}
	var delta: int = Time.get_unix_time_from_datetime_dict(now) - Time.get_unix_time_from_datetime_dict(then)
	return int(round(float(delta) / 86400.0))


## The streak to SHOW right now. A pure reader: it never mutates and never saves, so Home
## can call it on every repaint. A lapsed run reads as 0 here while day_streak still holds
## the old value; the reset is only written when the player next plays (see mark_played_today),
## so the app can never greet someone by taking their streak away.
func day_streak_now() -> int:
	if last_streak_date == "":
		return 0
	return day_streak if _days_since(last_streak_date) <= STREAK_GRACE_DAYS else 0


## Count today toward the day streak. Idempotent for the rest of the day, so every caller can
## fire it freely. Called on EFFORT (the first move of a game, the first puzzle solved), never
## on a result: a beginner who loses all three games still kept their streak, which is the
## whole point. See STREAK_GRACE_DAYS for how large a gap still continues the run.
func mark_played_today() -> void:
	var today := Time.get_date_string_from_system()
	if last_streak_date == today:
		return  # already counted today
	var gap: int = _days_since(last_streak_date)
	if gap <= 0:
		return  # clock moved backwards (or flew west over the date line): never break, never grow
	day_streak = day_streak + 1 if gap <= STREAK_GRACE_DAYS else 1
	last_streak_date = today
	if day_streak > day_streak_best:
		day_streak_best = day_streak
	_save()
	Notifications.refresh_daily_nudge()  # re-anchor the reminder to the new deadline


## Daily reminder notification on/off (Settings). Re-arms or cancels the single alarm slot.
func set_reminder_enabled(value: bool) -> void:
	reminder_enabled = value
	_save()
	# Switching it ON is an explicit request for notifications, so the permission dialog is welcome
	# here; switching it off never needs one.
	Notifications.refresh_daily_nudge(value)


# --- Persistence ---

func _save() -> void:
	var cfg := _to_config()
	cfg.save(SAVE_PATH)
	_tell_other_tabs(cfg)


## The whole persistent state, as _save() writes it.
func _to_config() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "is_premium", is_premium)
	cfg.set_value("player", "language", language)
	cfg.set_value("player", "sound_enabled", sound_enabled)
	cfg.set_value("player", "reminder_enabled", reminder_enabled)
	cfg.set_value("player", "last_review_prompt_date", last_review_prompt_date)
	cfg.set_value("player", "review_done", review_done)
	cfg.set_value("daily", "games_today", games_today)
	cfg.set_value("daily", "reviews_today", reviews_today)
	cfg.set_value("daily", "puzzles_today", puzzles_today)
	cfg.set_value("daily", "last_play_date", last_play_date)
	cfg.set_value("daily", "bonus_games", bonus_games)
	cfg.set_value("daily", "bonus_puzzles", bonus_puzzles)
	cfg.set_value("premium", "license_key", license_key)
	cfg.set_value("premium", "license_instance", license_instance)
	cfg.set_value("premium", "license_checked_date", license_checked_date)
	cfg.set_value("stats", "games_played", games_played)
	cfg.set_value("stats", "puzzle_highscore", puzzle_highscore)
	cfg.set_value("stats", "day_streak", day_streak)
	cfg.set_value("stats", "day_streak_best", day_streak_best)
	cfg.set_value("stats", "last_streak_date", last_streak_date)
	cfg.set_value("stats", "puzzle_streak", puzzle_streak)
	cfg.set_value("stats", "puzzle_index", puzzle_index)
	for bot_id: String in bot_wins:  # ConfigFile has no nested values: one key per bot
		cfg.set_value("bot_wins", bot_id, bot_wins[bot_id])
	return cfg


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	# Coerce types defensively — a hand-edited / corrupt save shouldn't crash later math.
	is_premium = bool(cfg.get_value("player", "is_premium", false))
	language = str(cfg.get_value("player", "language", ""))
	sound_enabled = bool(cfg.get_value("player", "sound_enabled", true))
	reminder_enabled = bool(cfg.get_value("player", "reminder_enabled", true))
	last_review_prompt_date = str(cfg.get_value("player", "last_review_prompt_date", ""))
	review_done = bool(cfg.get_value("player", "review_done", false))
	games_today = int(cfg.get_value("daily", "games_today", 0))
	reviews_today = int(cfg.get_value("daily", "reviews_today", 0))
	puzzles_today = int(cfg.get_value("daily", "puzzles_today", 0))
	last_play_date = str(cfg.get_value("daily", "last_play_date", ""))
	# Defaults = the full grant: that's how the welcome credit is handed out, both to
	# fresh installs and (once) to existing saves that predate the feature.
	bonus_games = int(cfg.get_value("daily", "bonus_games", WELCOME_BONUS_GAMES))
	bonus_puzzles = int(cfg.get_value("daily", "bonus_puzzles", WELCOME_BONUS_PUZZLES))
	license_key = str(cfg.get_value("premium", "license_key", ""))
	license_instance = str(cfg.get_value("premium", "license_instance", ""))
	license_checked_date = str(cfg.get_value("premium", "license_checked_date", ""))
	games_played = int(cfg.get_value("stats", "games_played", 0))
	puzzle_highscore = int(cfg.get_value("stats", "puzzle_highscore", 0))
	# Defaults of 0 / "" mean a save that predates the day streak starts at zero and counts
	# 1 on the player's next move. We deliberately do NOT backfill from last_play_date or
	# games_played: a number the player didn't earn would read as a bug, not a gift.
	day_streak = int(cfg.get_value("stats", "day_streak", 0))
	day_streak_best = int(cfg.get_value("stats", "day_streak_best", 0))
	last_streak_date = str(cfg.get_value("stats", "last_streak_date", ""))
	puzzle_streak = int(cfg.get_value("stats", "puzzle_streak", 0))
	puzzle_index = int(cfg.get_value("stats", "puzzle_index", -1))
	bot_wins.clear()
	if cfg.has_section("bot_wins"):
		for bot_id: String in cfg.get_section_keys("bot_wins"):
			bot_wins[bot_id] = int(cfg.get_value("bot_wins", bot_id, 0))
