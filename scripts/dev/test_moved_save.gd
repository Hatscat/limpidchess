extends SceneTree

## Dev-only: the save handed over from the old address limpidchess.com (GameManager.
## _decode_moved_save and _take_moved_save). The web glue that reads location.hash cannot run
## headless; the decoding, the safety filter and the adopt-or-merge rules can.
##   godot --headless --path . -s res://scripts/dev/test_moved_save.gd
## It overwrites user://limpid_chess.cfg, so it refuses to run outside a throwaway HOME:
##   T=$(mktemp -d) && HOME=$T XDG_DATA_HOME=$T/.local/share \
##     godot --headless --path . -s res://scripts/dev/test_moved_save.gd

var gm: Node
var failures := 0


func _ok(label: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok    ", label, "  (", got, ")")
	else:
		failures += 1
		print("  FAIL  ", label, "  got=", got, " want=", want)


## "YYYY-MM-DD" for `offset` days from today, local (same construction as test_day_streak).
func _day(offset: int) -> String:
	var now := Time.get_datetime_dict_from_system(false)
	var noon := {"year": now["year"], "month": now["month"], "day": now["day"],
			"hour": 12, "minute": 0, "second": 0}
	var t: int = Time.get_unix_time_from_datetime_dict(noon) + offset * 86400
	return Time.get_datetime_string_from_unix_time(t).substr(0, 10)


## The fragment the bridge page builds: base64url without padding, behind the prefix.
func _frag(text: String) -> String:
	var b64 := Marshalls.utf8_to_base64(text).replace("+", "-").replace("/", "_").replace("=", "")
	return gm.MOVED_SAVE_PREFIX + b64


## A save exactly as the old site wrote it: ConfigFile's own text, never hand-typed.
## Keys are "section/key".
func _save_text(values: Dictionary) -> String:
	var cfg := ConfigFile.new()
	for k: String in values:
		var parts := k.split("/")
		cfg.set_value(parts[0], parts[1], values[k])
	return cfg.encode_to_text()


func _old_save() -> Dictionary:
	return {
		"player/is_premium": true, "player/language": "fr", "player/sound_enabled": false,
		"player/reminder_enabled": true, "player/last_review_prompt_date": "",
		"player/review_done": true,
		"daily/games_today": 1, "daily/reviews_today": 0, "daily/puzzles_today": 0,
		"daily/last_play_date": _day(-1), "daily/bonus_games": 0, "daily/bonus_puzzles": 1,
		"premium/license_key": "38b1460a-5104-4067-a91d-77b872934d51",
		"premium/license_instance": "f90ec370-fd83-46a5-8bbd-44a241e78665",
		"premium/license_checked_date": "2026-09-01",
		"stats/games_played": 42, "stats/puzzle_highscore": 7, "stats/day_streak": 5,
		"stats/day_streak_best": 9, "stats/last_streak_date": _day(-1),
		"stats/puzzle_streak": 4, "stats/puzzle_index": 12,
		"bot_wins/pip": 3,
	}


func _decode(text: String) -> ConfigFile:
	return gm._decode_moved_save(_frag(text))


func _fresh() -> void:
	gm.reset_save()  # deletes the save file and resets every field


func _initialize() -> void:
	gm = root.get_node("GameManager")
	if not OS.get_user_data_dir().begins_with("/tmp"):
		print("REFUSING to run: this test overwrites ", OS.get_user_data_dir(), "/limpid_chess.cfg.")
		print("Run it with a throwaway HOME, see the header of this file.")
		quit(2)
		return

	print("=== _decode_moved_save: accepts what the old site wrote ===")
	var real := _save_text(_old_save())
	var cfg := _decode(real)
	_ok("a real save decodes", cfg != null, true)
	if cfg != null:
		_ok("  bool", cfg.get_value("player", "is_premium"), true)
		_ok("  int", cfg.get_value("stats", "games_played"), 42)
		_ok("  int (puzzle_index)", cfg.get_value("stats", "puzzle_index"), 12)
		_ok("  string", cfg.get_value("premium", "license_key"), "38b1460a-5104-4067-a91d-77b872934d51")
		_ok("  empty string", cfg.get_value("player", "last_review_prompt_date"), "")
		_ok("  bot_wins", cfg.get_value("bot_wins", "pip"), 3)
	var parked := _save_text({"player/is_premium": false, "stats/puzzle_index": -1})
	var p := _decode(parked)
	_ok("puzzle_index -1 decodes", p != null and p.get_value("stats", "puzzle_index") == -1, true)
	# Every base64 tail length the bridge can produce (no padding: len % 4 in {0, 2, 3}).
	var tails_ok := true
	for n in 6:
		if _decode(_save_text({"player/language": "x".repeat(n)})) == null:
			tails_ok = false
	_ok("all unpadded base64 lengths decode", tails_ok, true)
	var oldest := "[player]\n\nis_premium=false\n\n[stats]\n\ngames_played=3\n"
	_ok("a minimal early-version save decodes", _decode(oldest) != null, true)

	print("=== _decode_moved_save: refuses everything else ===")
	_ok("empty fragment", gm._decode_moved_save(""), null)
	_ok("other fragment", gm._decode_moved_save("#features"), null)
	_ok("prefix only", gm._decode_moved_save(gm.MOVED_SAVE_PREFIX), null)
	_ok("not base64", gm._decode_moved_save(gm.MOVED_SAVE_PREFIX + "abc$%^&*"), null)
	_ok("impossible base64 length", gm._decode_moved_save(gm.MOVED_SAVE_PREFIX + "QUJDR"), null)
	_ok("oversized", gm._decode_moved_save(gm.MOVED_SAVE_PREFIX + "A".repeat(gm.MOVED_SAVE_MAX_CHARS + 4)), null)
	_ok("binary garbage", gm._decode_moved_save(gm.MOVED_SAVE_PREFIX + "_-8AAQID_w"), null)
	_ok("Object(...) value", _decode("[player]\n\nis_premium=Object(RefCounted,\"script\":null)\n"), null)
	_ok("Resource(...) value", _decode("[player]\n\nlanguage=Resource(\"res://icon.svg\")\n"), null)
	_ok("array value", _decode("[player]\n\nis_premium=[true]\n"), null)
	_ok("escaped quote in a string", _decode("[player]\n\nlanguage=\"f\\\"r\"\n"), null)
	_ok("float value", _decode("[player]\n\nis_premium=false\n\n[stats]\n\ngames_played=1.5\n"), null)
	_ok("no [player] section", _decode("[stats]\n\ngames_played=3\n"), null)
	_ok("not a config at all", _decode("hello world"), null)
	# bool() of a String is a script error (it would leave _load() half done) and int() would quietly
	# coerce one, so every key the game saves must arrive with its saved type.
	_ok("string where the game saves a bool", _decode("[player]\n\nis_premium=\"yes\"\n"), null)
	_ok("int where the game saves a bool", _decode("[player]\n\nis_premium=1\n"), null)
	_ok("string where the game saves an int", _decode("[player]\n\nis_premium=false\n\n[stats]\n\ngames_played=\"12\"\n"), null)
	_ok("int where the game saves a string", _decode("[player]\n\nlanguage=7\n"), null)
	_ok("bot wins must be ints", _decode("[player]\n\nis_premium=false\n\n[bot_wins]\n\npip=true\n"), null)
	var legacy := "[player]\n\nis_premium=false\ncoins_best=\"x\"\n\n[stats]\n\nwins=3\nblunders_made=true\n"
	_ok("keys the game no longer saves may hold any plain value", _decode(legacy) != null, true)

	print("=== _take_moved_save: first save here -> adopted as is ===")
	_fresh()
	_ok("starts with no save file", FileAccess.file_exists(gm.SAVE_PATH), false)
	gm._take_moved_save(_decode(real))
	_ok("save file written", FileAccess.file_exists(gm.SAVE_PATH), true)
	_ok("premium", gm.is_premium, true)
	_ok("license key", gm.license_key, "38b1460a-5104-4067-a91d-77b872934d51")
	_ok("license instance", gm.license_instance, "f90ec370-fd83-46a5-8bbd-44a241e78665")
	_ok("language", gm.language, "fr")
	_ok("sound setting", gm.sound_enabled, false)
	_ok("games played", gm.games_played, 42)
	_ok("welcome credit already spent stays spent", gm.bonus_games, 0)
	_ok("day streak", gm.day_streak, 5)
	_ok("parked puzzle run", gm.puzzle_index, 12)
	_ok("bot wins", gm.bot_wins.get("pip", 0), 3)

	print("=== _take_moved_save: a save here already -> upgrade-only merge ===")
	_fresh()
	gm.language = "de"
	gm.games_played = 50
	gm.puzzle_highscore = 3
	gm.day_streak = 2
	gm.day_streak_best = 4
	gm.last_streak_date = _day(0)
	gm.bot_wins = {"pip": 1, "coco": 2}
	gm.puzzle_index = -1
	gm._save()
	gm._take_moved_save(_decode(real))
	_ok("games played keeps the larger", gm.games_played, 50)
	_ok("puzzle best takes the larger", gm.puzzle_highscore, 7)
	_ok("a live old run (5, yesterday) and a run here (2, today) chain: the longer counts", gm.day_streak, 5)
	_ok("  dated today", gm.last_streak_date, _day(0))
	_ok("best streak takes the larger", gm.day_streak_best, 9)
	_ok("premium carried over", gm.is_premium, true)
	_ok("  with its key", gm.license_key, "38b1460a-5104-4067-a91d-77b872934d51")
	_ok("  with its check date cleared, so Billing re-checks the key on this boot", gm.license_checked_date, "")
	_ok("bot wins per bot: larger", gm.bot_wins.get("pip", 0), 3)
	_ok("bot wins per bot: local-only kept", gm.bot_wins.get("coco", 0), 2)
	_ok("review_done", gm.review_done, true)
	_ok("local language kept", gm.language, "de")
	_ok("local welcome credit kept", gm.bonus_games, gm.WELCOME_BONUS_GAMES)
	_ok("no parked run imported into a save that has its own", gm.puzzle_index, -1)
	gm._load()
	_ok("merge is persisted (reloaded from disk)", [gm.games_played, gm.day_streak_best, gm.is_premium], [50, 9, true])
	gm._take_moved_save(_decode(real))
	_ok("idempotent: a second handover changes nothing",
			[gm.games_played, gm.puzzle_highscore, gm.day_streak, gm.day_streak_best, gm.bot_wins.get("pip", 0)],
			[50, 7, 5, 9, 3])

	print("=== _take_moved_save: never downgrades ===")
	_fresh()
	gm.is_premium = true
	gm.license_key = "LOCAL-KEY"
	gm.license_instance = "LOCAL-INSTANCE"
	gm.day_streak = 3
	gm.day_streak_best = 3
	gm.last_streak_date = _day(-1)
	gm._save()
	var stale := _save_text({"player/is_premium": false, "premium/license_key": "OLD-KEY",
			"stats/day_streak": 8, "stats/day_streak_best": 8, "stats/last_streak_date": _day(-20)})
	gm._take_moved_save(_decode(stale))
	_ok("premium stays", gm.is_premium, true)
	_ok("local key stays", gm.license_key, "LOCAL-KEY")
	_ok("a stale longer streak does not replace the current one", gm.day_streak, 3)
	_ok("  but its best still counts", gm.day_streak_best, 8)

	print("=== _take_moved_save: a revoked key is still carried ===")
	_fresh()
	gm.language = "es"
	gm._save()
	var revoked := _save_text({"player/is_premium": false, "premium/license_key": "REVOKED-KEY",
			"premium/license_instance": "REVOKED-INSTANCE"})
	gm._take_moved_save(_decode(revoked))
	_ok("not premium", gm.is_premium, false)
	_ok("key kept for Billing to re-check", gm.license_key, "REVOKED-KEY")
	_ok("instance kept", gm.license_instance, "REVOKED-INSTANCE")

	print("=== _take_moved_save: a crafted link cannot unlock anything ===")
	_fresh()
	gm._take_moved_save(_decode("[player]\n\nis_premium=true\n"))
	_ok("Premium without a key is not adopted", gm.is_premium, false)
	_fresh()
	gm.license_key = "MY-REVOKED-KEY"
	gm._save()
	gm._take_moved_save(_decode("[player]\n\nis_premium=true\n\n[premium]\n\nlicense_key=\"\"\n"))
	_ok("...nor merged", gm.is_premium, false)
	_ok("  and an empty key never replaces the one here", gm.license_key, "MY-REVOKED-KEY")
	_fresh()
	gm._take_moved_save(_decode(_save_text({"player/is_premium": true, "premium/license_key": "MADE-UP",
			"premium/license_checked_date": _day(0)})))
	_ok("a key with today's check date is still checked on this boot", gm.license_checked_date, "")
	_fresh()
	gm._take_moved_save(_decode(_save_text({"player/is_premium": false, "player/language": "xx",
			"daily/bonus_games": 999999, "daily/bonus_puzzles": -5, "daily/games_today": -999999,
			"stats/puzzle_index": -7, "stats/games_played": -3, "stats/last_streak_date": "9999-12-31",
			"stats/day_streak": 3, "daily/last_play_date": "not-a-date"})))
	_ok("welcome credit capped", gm.bonus_games, gm.WELCOME_BONUS_GAMES)
	_ok("negative credit raised to 0", gm.bonus_puzzles, 0)
	_ok("negative counter raised to 0", gm.games_played, 0)
	_ok("puzzle_index floor is -1", gm.puzzle_index, -1)
	_ok("a future streak date is brought back to today", gm.last_streak_date, _day(0))
	_ok("  so the streak keeps counting from tomorrow", gm.day_streak_now(), 3)
	_ok("a malformed date is dropped (the boot's _roll_day then stamps today)", gm.last_play_date, "")
	_ok("an unknown language falls back to the device's", gm.language, "")
	_ok("free play stays limited", gm.games_remaining_today() <= gm.FREE_GAMES_PER_DAY + gm.WELCOME_BONUS_GAMES, true)

	print("=== _take_moved_save: streaks of the two addresses ===")
	_fresh()
	gm.day_streak = 1
	gm.day_streak_best = 1
	gm.last_streak_date = _day(0)
	gm._save()
	gm._take_moved_save(_decode(_save_text({"player/is_premium": false, "stats/day_streak": 30,
			"stats/day_streak_best": 30, "stats/last_streak_date": _day(-1)})))
	_ok("fresh run here, 30-day run alive yesterday there: 30 shown", gm.day_streak_now(), 30)
	_fresh()
	gm.day_streak = 10
	gm.day_streak_best = 10
	gm.last_streak_date = _day(-2)
	gm._save()
	gm._take_moved_save(_decode(_save_text({"player/is_premium": false, "stats/day_streak": 1,
			"stats/day_streak_best": 4, "stats/last_streak_date": _day(-1)})))
	_ok("10-day run here, a 1-day restart there yesterday: still 10", gm.day_streak, 10)
	_ok("  and the later date is kept", gm.last_streak_date, _day(-1))
	_ok("  best untouched", gm.day_streak_best, 10)

	_fresh()
	print("=== DONE ===  failures: ", failures)
	quit(1 if failures > 0 else 0)
