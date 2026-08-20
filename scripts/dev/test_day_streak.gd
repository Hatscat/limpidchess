extends SceneTree

## Dev-only: exercise the day-streak date maths in GameManager, which is the first date
## arithmetic in this codebase and the one part of the feature that headless CAN prove.
##   godot --headless --path . -s res://scripts/dev/test_day_streak.gd
## Run it with a throwaway HOME (it writes user://limpid_chess.cfg through mark_played_today):
##   HOME=$(mktemp -d) godot --headless --path . -s res://scripts/dev/test_day_streak.gd

var gm: Node
var notif: Node
var failures := 0


func _ok(label: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok    ", label, "  (", got, ")")
	else:
		failures += 1
		print("  FAIL  ", label, "  got=", got, " want=", want)


## "YYYY-MM-DD" for `offset` days from today, local. Built the same way the code under test
## reads the clock, so the tests stay correct on any date the maintainer happens to run them.
func _day(offset: int) -> String:
	var now := Time.get_datetime_dict_from_system(false)
	var noon := {"year": now["year"], "month": now["month"], "day": now["day"],
			"hour": 12, "minute": 0, "second": 0}
	var t: int = Time.get_unix_time_from_datetime_dict(noon) + offset * 86400
	return Time.get_datetime_string_from_unix_time(t).substr(0, 10)


## Put the streak in a known state without going through the save file.
func _seed(streak: int, best: int, date: String) -> void:
	gm.day_streak = streak
	gm.day_streak_best = best
	gm.last_streak_date = date


## Local wall-clock hour that a delay in seconds from now lands on. Uses the same
## dict->unix convention as the code under test, so it reads back as local time.
func _hour_after(delay: int) -> int:
	var now := Time.get_datetime_dict_from_system(false)
	var t: int = Time.get_unix_time_from_datetime_dict(now) + delay
	return int(Time.get_datetime_dict_from_unix_time(t)["hour"])


## Seconds from now until tonight's EVENING_HOUR (negative once it has passed).
func _until_tonight() -> int:
	var n := Time.get_datetime_dict_from_system(false)
	return (notif.EVENING_HOUR - int(n["hour"])) * 3600 - int(n["minute"]) * 60 - int(n["second"])


## Which of the two payloads the single alarm slot decides to carry. This is the part that
## cannot be exercised on the dev box (no Android), so the DECISION at least gets tested.
func _test_nudge() -> void:
	print("=== notification _decide ===")
	var g: Node = gm
	g.reminder_enabled = true

	g.is_premium = false
	g.games_played = 5
	_seed(0, 0, "")
	var plan: Dictionary = notif._decide()
	_ok("no streak, free, engaged -> free-games nudge", plan.get("title", ""), tr("Your free games are back!"))
	_ok("  repeats daily", plan.get("repeating", false), true)
	_ok("  lands in the morning", _hour_after(int(plan["delay"])), notif.MORNING_HOUR)

	g.games_played = 1
	_ok("no streak, barely played -> nothing (permission politeness)", notif._decide().is_empty(), true)

	g.games_played = 5
	g.is_premium = true
	_ok("no streak, premium -> nothing", notif._decide().is_empty(), true)

	g.is_premium = false
	_seed(4, 4, _day(0))
	plan = notif._decide()
	_ok("streak, played today -> streak nudge", plan.get("title", ""), tr("A game today?"))
	# One-shot on purpose: the message is only true on the deadline evening, so a repeat would
	# tell a lapsed player their days were still counting.
	_ok("  does NOT repeat", plan.get("repeating", true), false)
	_ok("  lands in the evening", _hour_after(int(plan["delay"])), notif.EVENING_HOUR)
	# The whole point of anchoring on the DEADLINE rather than on tomorrow: while the streak is
	# still safe, no nudge is scheduled anywhere near tonight. Played today with a 3-day grace
	# window, the first fire is the evening of today+3, so it is always more than 2 days out
	# whatever the current time of day. This is what stops a nightly player being nagged daily.
	_ok("  not scheduled while the streak is safe", int(plan["delay"]) > 2 * 86400, true)
	_ok("  skips tonight", int(plan["delay"]) > _until_tonight(), true)

	_seed(4, 4, _day(-1))
	plan = notif._decide()
	_ok("streak, played yesterday -> streak nudge", plan.get("title", ""), tr("A game today?"))
	_ok("  lands in the evening", _hour_after(int(plan["delay"])), notif.EVENING_HOUR)
	_ok("  still 1+ day out (2 grace days left)", int(plan["delay"]) > 86400, true)

	# On the deadline day itself the nudge is finally due: this is the one evening it is true.
	# (Before EVENING_HOUR it is scheduled for tonight; run after 19:00 local it has passed, and the
	# fall-through to the allowance nudge is the correct answer rather than a late nag.)
	_seed(4, 4, _day(-gm.STREAK_GRACE_DAYS))
	plan = notif._decide()
	if _until_tonight() >= notif.MIN_LEAD_SECONDS:
		_ok("streak on its last day -> nudged tonight", plan.get("title", ""), tr("A game today?"))
		_ok("  lands in the evening", _hour_after(int(plan["delay"])), notif.EVENING_HOUR)
		_ok("  and is tonight, not a later one", int(plan["delay"]) <= 86400, true)
	else:
		_ok("deadline evening already passed -> no late nag",
				plan.get("title", ""), tr("Your free games are back!"))

	# A future-dated save (timezone travel, clock set forward then back) must not park the single
	# alarm slot months out and suppress the allowance nudge for that whole time.
	_seed(4, 4, _day(300))
	plan = notif._decide()
	_ok("future-dated save -> falls through, slot not parked",
			plan.get("title", ""), tr("Your free games are back!"))

	# A premium player has no free-games nudge, but does have a streak worth keeping.
	_seed(4, 4, _day(-1))  # re-seed: the future-dated case above left an unusable date
	g.is_premium = true
	plan = notif._decide()
	_ok("streak, premium -> still nudged", plan.get("title", ""), tr("A game today?"))
	g.is_premium = false

	_seed(9, 9, _day(-5))  # lapsed: day_streak_now() reads 0
	plan = notif._decide()
	_ok("lapsed streak -> falls back to free-games nudge", plan.get("title", ""), tr("Your free games are back!"))

	_seed(4, 4, _day(0))
	g.reminder_enabled = false
	_ok("reminder off -> nothing at all", notif._decide().is_empty(), true)
	g.reminder_enabled = true

	_seed(4, 4, "garbage")
	plan = notif._decide()
	_ok("corrupt date -> no streak, so no crash", plan.is_empty() or plan.get("title", "") == tr("Your free games are back!"), true)


func _initialize() -> void:
	gm = root.get_node("GameManager")
	notif = root.get_node("Notifications")

	print("=== _days_since ===")
	_ok("today", gm._days_since(_day(0)), 0)
	_ok("yesterday", gm._days_since(_day(-1)), 1)
	_ok("3 days ago", gm._days_since(_day(-3)), 3)
	_ok("tomorrow (clock moved back)", gm._days_since(_day(1)), -1)
	_ok("a year ago", gm._days_since(_day(-365)), 365)
	_ok("empty date", gm._days_since(""), 9999)
	_ok("malformed date", gm._days_since("not-a-date-at-all"), 9999)
	_ok("short date", gm._days_since("2026-08"), 9999)
	# Fixed dates that cross awkward boundaries; only the sign/order matters here, but a
	# mis-parse would blow these up rather than return a plausible number.
	_ok("year boundary", gm._days_since("2000-12-31") > 0, true)
	_ok("leap day", gm._days_since("2024-02-29") > 0, true)

	print("=== mark_played_today ===")
	_seed(0, 0, "")
	gm.mark_played_today()
	_ok("first ever play starts at 1", gm.day_streak, 1)
	_ok("  and stamps today", gm.last_streak_date, _day(0))
	_ok("  and seeds the best", gm.day_streak_best, 1)

	gm.mark_played_today()
	_ok("second play the same day is idempotent", gm.day_streak, 1)

	_seed(4, 9, _day(-1))
	gm.mark_played_today()
	_ok("played yesterday continues", gm.day_streak, 5)
	_ok("  best is not lowered by a shorter run", gm.day_streak_best, 9)

	_seed(4, 4, _day(-3))
	gm.mark_played_today()
	_ok("gap of 3 (a weekend) still continues", gm.day_streak, 5)
	_ok("  and raises the best", gm.day_streak_best, 5)

	_seed(40, 40, _day(-4))
	gm.mark_played_today()
	_ok("gap of 4 starts over at 1", gm.day_streak, 1)
	_ok("  but the best is kept forever", gm.day_streak_best, 40)

	_seed(7, 7, _day(2))
	gm.mark_played_today()
	_ok("clock moved back: streak unchanged", gm.day_streak, 7)
	_ok("  and the stamp is not rewritten", gm.last_streak_date, _day(2))

	print("=== day_streak_now (pure reader) ===")
	_seed(6, 6, _day(0))
	_ok("played today", gm.day_streak_now(), 6)
	_seed(6, 6, _day(-3))
	_ok("inside the grace window", gm.day_streak_now(), 6)
	_seed(6, 6, _day(-4))
	_ok("lapsed reads as 0", gm.day_streak_now(), 0)
	_ok("  without mutating the stored value", gm.day_streak, 6)
	_seed(0, 0, "")
	_ok("never played", gm.day_streak_now(), 0)

	_test_nudge()

	print("=== DONE ===  failures: ", failures)
	quit(1 if failures > 0 else 0)
