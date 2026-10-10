extends SceneTree

## Dev-only: the web multi-tab save sync in GameManager (_on_other_tab_saved, _merge_other_tab,
## _tabs_changed). The BroadcastChannel and IndexedDB glue cannot run headless; the message
## parsing and the merge rules can.
##   godot --headless --path . -s res://scripts/dev/test_tab_sync.gd
## It resets the in-memory save state, so like test_moved_save.gd it refuses to run outside a
## throwaway HOME:
##   T=$(mktemp -d) && HOME=$T XDG_DATA_HOME=$T/.local/share \
##     godot --headless --path . -s res://scripts/dev/test_tab_sync.gd

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


## What another tab's _tell_other_tabs() posts: its whole save, plus the keys it changed.
func _message(values: Dictionary, changed: Array = []) -> String:
	var cfg := ConfigFile.new()
	for k: String in values:
		var parts := k.split("/")
		cfg.set_value(parts[0], parts[1], values[k])
	return JSON.stringify({"cfg": cfg.encode_to_text(), "changed": changed})


## A tab that booted from a save: fresh state, then a known starting point, then the baseline.
func _tab(setup: Callable) -> void:
	gm.reset_save()
	setup.call()
	gm._join_other_tabs()


func _receive(values: Dictionary, changed: Array = []) -> void:
	gm._on_other_tab_saved([_message(values, changed)])


func _initialize() -> void:
	gm = root.get_node("GameManager")
	if not OS.get_user_data_dir().begins_with("/tmp"):
		print("REFUSING to run: this test resets the save state in ", OS.get_user_data_dir(), ".")
		print("Run it with a throwaway HOME, see the header of this file.")
		quit(2)
		return

	print("=== the checkout case: another tab redeemed Premium ===")
	_tab(func() -> void: gm.games_played = 4)
	_receive({"player/is_premium": true, "premium/license_key": "KEY-1",
			"premium/license_instance": "INST-1", "premium/license_checked_date": _day(0),
			"stats/games_played": 4})
	_ok("this tab is Premium now", gm.is_premium, true)
	_ok("  with the key", gm.license_key, "KEY-1")
	_ok("  and its instance", gm.license_instance, "INST-1")
	_ok("  and check date (no second check today)", gm.license_checked_date, _day(0))
	_ok("so this tab's next save keeps it", gm._to_config().get_value("player", "is_premium"), true)

	print("=== progress made in the other tab ===")
	_tab(func() -> void:
		gm.games_played = 10
		gm.puzzle_highscore = 9
		gm.bot_wins = {"pip": 2, "coco": 1}
		gm.day_streak = 4
		gm.day_streak_best = 6
		gm.last_streak_date = _day(-1)
		gm.last_play_date = _day(0)
		gm.games_today = 1
		gm.bonus_games = 2)
	_receive({"player/is_premium": false, "stats/games_played": 12, "stats/puzzle_highscore": 3,
			"stats/day_streak": 5, "stats/day_streak_best": 5, "stats/last_streak_date": _day(0),
			"daily/last_play_date": _day(0), "daily/games_today": 3, "daily/bonus_games": 1,
			"bot_wins/pip": 1, "bot_wins/rusty": 4})
	_ok("games played: the larger", gm.games_played, 12)
	_ok("puzzle best: the larger", gm.puzzle_highscore, 9)
	_ok("bot wins: per bot, the larger", [gm.bot_wins.get("pip"), gm.bot_wins.get("coco"), gm.bot_wins.get("rusty")], [2, 1, 4])
	_ok("day streak: the run counted most recently", [gm.day_streak, gm.last_streak_date], [5, _day(0)])
	_ok("  best never drops", gm.day_streak_best, 6)
	_ok("today's games: the higher count (same allowance)", gm.games_today, 3)
	_ok("welcome credit: spent in either tab stays spent", gm.bonus_games, 1)

	print("=== a day boundary between the tabs ===")
	_tab(func() -> void:
		gm.last_play_date = _day(-1)
		gm.games_today = 3)
	_receive({"player/is_premium": false, "daily/last_play_date": _day(0), "daily/games_today": 1})
	_ok("their newer day replaces this tab's yesterday", [gm.last_play_date, gm.games_today], [_day(0), 1])
	_receive({"player/is_premium": false, "daily/last_play_date": _day(-2), "daily/games_today": 5})
	_ok("an older day changes nothing", [gm.last_play_date, gm.games_today], [_day(0), 1])

	print("=== never downgrades ===")
	_tab(func() -> void:
		gm.is_premium = true
		gm.license_key = "MINE"
		gm.games_played = 30
		gm.day_streak = 7
		gm.last_streak_date = _day(0))
	_receive({"player/is_premium": false, "premium/license_key": "", "stats/games_played": 2,
			"stats/day_streak": 1, "stats/last_streak_date": _day(-5)})
	_ok("Premium stays", gm.is_premium, true)
	_ok("an empty key never replaces this tab's", gm.license_key, "MINE")
	_ok("lifetime counts do not drop", gm.games_played, 30)
	_ok("an older streak changes nothing", [gm.day_streak, gm.last_streak_date], [7, _day(0)])

	print("=== settings: the last tab that changed them wins ===")
	_tab(func() -> void:
		gm.language = "en"
		gm.sound_enabled = true)
	_receive({"player/is_premium": false, "player/language": "fr", "player/sound_enabled": false})
	_ok("not changed over there: kept here", [gm.language, gm.sound_enabled], ["en", true])
	_receive({"player/is_premium": false, "player/language": "fr", "player/sound_enabled": false},
			["player/language"])
	_ok("changed over there: adopted", gm.language, "fr")
	_ok("  only that one", gm.sound_enabled, true)
	_ok("an adopted value is not announced back as ours", gm._tabs_changed(gm._to_config()), [])
	gm.sound_enabled = false
	_ok("a change made here is", gm._tabs_changed(gm._to_config()), ["player/sound_enabled"])
	_ok("  once", gm._tabs_changed(gm._to_config()), [])
	_receive({"player/is_premium": false, "stats/puzzle_streak": 6, "stats/puzzle_index": 41},
			["stats/puzzle_streak", "stats/puzzle_index"])
	_ok("a run parked over there can be resumed here", [gm.puzzle_streak, gm.puzzle_index], [6, 41])
	_receive({"player/is_premium": false, "stats/games_played": 99}, ["stats/games_played"])
	_ok("a counter listed as changed still merges by max", gm.games_played, 99)

	print("=== what is ignored ===")
	_tab(func() -> void: gm.games_played = 5)
	gm._on_other_tab_saved(["not json"])
	gm._on_other_tab_saved([JSON.stringify({"changed": []})])
	gm._on_other_tab_saved([42])
	gm._on_other_tab_saved([])
	gm._on_other_tab_saved([JSON.stringify({"cfg": "[player]\n\nis_premium=Object(RefCounted,\"script\":null)\n", "changed": []})])
	gm._on_other_tab_saved([JSON.stringify({"cfg": "[player]\n\nis_premium=\"yes\"\n", "changed": []})])
	_ok("garbage, Objects and wrong types change nothing", [gm.games_played, gm.is_premium], [5, false])

	gm.reset_save()
	print("=== DONE ===  failures: ", failures)
	quit(1 if failures > 0 else 0)
