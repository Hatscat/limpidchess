extends Node

## The one daily local notification (autoload "Notifications").
##
## Wraps the godot-notification-scheduler plugin's `NotificationScheduler` + `NotificationData`
## nodes when installed; a harmless no-op on desktop/dev or without the plugin.
##
## ONE ALARM SLOT, ON PURPOSE. There is a single notification id and a single channel, and
## refresh_daily_nudge() decides which of two messages that slot currently carries:
##   PROTECT   "A game today?"            one nudge, on the evening of the last day the streak can
##                                        still be continued. Playing pushes that deadline further
##                                        out, so an active player never reaches it.
##   ALLOWANCE "Your free games are back" the original nudge, repeating daily each morning.
## Because there is only one slot, the two can never fire on the same day: double-nagging is
## structurally impossible rather than a rule someone has to remember. Re-scheduling the same id
## replaces the pending alarm, its payload AND its interval in place, so there is no cancel dance.
##
## A player who plays every day never sees the PROTECT nudge at all, because each game re-anchors
## it past the coming evening. No countdown, no number, no "last chance", nothing red, and a
## Settings switch (GameManager.reminder_enabled) turns the whole slot off.
##
## The Android 13+ POST_NOTIFICATIONS dialog is only ever raised from a game/puzzle start or from
## the Settings switch (see refresh_daily_nudge's `may_prompt`), never mid-move and never at boot.
##
## We schedule via set_delay/set_interval and never request SCHEDULE_EXACT_ALARM, so the
## plugin falls back to an inexact while-idle alarm: it still fires while the app is closed and
## survives a reboot, but may land up to ~1h late (fine for either nudge). The plugin's
## class_name nodes only exist once the addon is added, so we resolve + instantiate them
## dynamically to stay parse-safe when it isn't.

const REMINDER_ID := 1001
const DAY_SECONDS := 86400  # repeat interval: a daily nudge
const CHANNEL_ID := "limpid_daily"
const MORNING_HOUR := 10  # ALLOWANCE nudge: after the midnight free-games reset
const EVENING_HOUR := 19  # PROTECT nudge: early evening, still time to play a game
## Don't post a PROTECT nudge that lands within minutes of its own deadline: a reminder
## the player can't realistically act on is just noise.
const MIN_LEAD_SECONDS := 300
## Sentinel for an unusable date. Not -1: a lead is a signed second count and -1 is a legal value
## (the target passed one second ago), which would otherwise be misread as a parse failure.
const BAD_DATE := -0x7FFFFFFF
const CHANNEL_IMPORTANCE_DEFAULT := 3  # NotificationChannel.Importance.DEFAULT (literal = parse-safe)

var _scheduler = null
var _initialized := false
var _channel_ready := false
var _pending := false  # a schedule is waiting on a precondition (init, or the async permission grant)
## Whether the deferred schedule above is allowed to raise the permission dialog when it runs.
## initialize() is async, so a player can tap Play within a second of a cold launch and reach
## refresh_daily_nudge(true) before we are ready; without remembering that intent, the prompt for
## the session's first game would be silently dropped. Only ever set from a real game / puzzle /
## Settings moment, so deferring it cannot turn a bare boot into a prompt.
var _pending_prompt := false


func _ready() -> void:
	# Only touch the plugin when its Android singleton exists; on desktop/dev the
	# NotificationScheduler node would push "singleton not initialized" errors on every call.
	if not Engine.has_singleton("NotificationSchedulerPlugin"):
		return
	_scheduler = _instantiate_plugin("NotificationScheduler")
	if _scheduler == null:
		return
	add_child(_scheduler)
	_scheduler.connect("initialization_completed", _on_initialized)
	# The POST_NOTIFICATIONS grant is async; (re)flush a deferred schedule once the user answers.
	_scheduler.connect("post_notifications_permission_granted", _on_permission_granted)
	_scheduler.connect("post_notifications_permission_denied", _on_permission_denied)
	# REQUIRED: initialize() acquires the JNI singleton + wires its signals, then (async) emits
	# initialization_completed. Without this call nothing downstream runs (no permission prompt, no
	# channel, no scheduled notification), which was exactly why no reminder ever fired.
	_scheduler.initialize()


func _on_initialized() -> void:
	_initialized = true
	_pending = false
	_ensure_channel()
	# Always re-decide at boot, so the alarm's deadline tracks the calendar and its text follows a
	# language change. GameManager is an earlier autoload, so by the time this async callback lands
	# its save is loaded. The prompt is raised only if a real game / puzzle / Settings moment asked
	# for one while we were still initializing; a bare cold launch passes false and stays silent.
	var prompt := _pending_prompt
	_pending_prompt = false
	_do_schedule(prompt)


## True when local notifications can actually be delivered on this platform, i.e. the Android
## plugin is present. False on desktop and on the web build, where the whole feature is inert and
## the Settings row for it should not be offered at all.
func is_available() -> bool:
	return _scheduler != null


## Re-decide what the single daily alarm should carry, and (re)schedule or cancel it.
## Safe to call at any time, including before the plugin has initialized (it defers) and on
## desktop/web (no-op).
##
## `may_prompt` gates the Android 13+ POST_NOTIFICATIONS request, which puts a system dialog on
## screen. Only pass true from a moment where an interruption is acceptable and the ask makes
## sense to the player: starting a game or a puzzle run, or switching the reminder on in Settings.
## Never from a mid-move hook or from boot, where the dialog would land on top of the board or on
## a cold launch. When the permission is missing and we may not prompt, the schedule is simply
## skipped; the next game start re-enters here and asks then.
func refresh_daily_nudge(may_prompt := false) -> void:
	if _scheduler == null:
		return
	if not _initialized:
		_pending = true  # flushed on initialization_completed
		_pending_prompt = _pending_prompt or may_prompt
		return
	_do_schedule(may_prompt)


## Which message the slot should carry right now, as {title, content, delay, repeating}, or {} to
## cancel. Pure decision logic, kept apart from the plugin calls so it reads as one policy.
func _decide() -> Dictionary:
	if not GameManager.reminder_enabled:
		return {}
	# PROTECT: one nudge on the evening of the LAST day the streak can still be continued (the last
	# counted day plus the grace window). Anchoring on the deadline rather than on tomorrow is the
	# whole point: on any earlier evening the streak is in no danger, so a nudge would be untrue and
	# would be exactly the nightly nagging this design exists to avoid. Because every game pushes
	# the deadline a further STREAK_GRACE_DAYS out, a player who keeps playing never reaches it,
	# whatever time of day they play.
	# Deliberately NOT repeating: the message is only true on that one evening. Every later firing
	# would land after the streak had already gone and tell the player their days were still
	# counting. Once it has fired, the next launch re-decides and a free player picks the allowance
	# nudge back up.
	# Gated to 2+ days rather than 1 so the very first nudge lands on someone who has already come
	# back once of their own accord.
	if GameManager.day_streak_now() >= 2:
		var lead: int = _seconds_until(GameManager.last_streak_date,
				GameManager.STREAK_GRACE_DAYS, EVENING_HOUR)
		# Upper bound guards a future-dated save (timezone travel, a clock set forward then back):
		# day_streak_now() tolerates a negative gap, and without this the single slot would be
		# parked on an alarm months out and the allowance nudge suppressed all that time.
		var max_lead: int = (GameManager.STREAK_GRACE_DAYS + 1) * DAY_SECONDS
		if lead >= MIN_LEAD_SECONDS and lead <= max_lead:
			return {
				"title": tr("A game today?"),
				"content": tr("Play one game and your days keep counting."),
				"delay": lead,
				"repeating": false,
			}
		# The deadline is already here, gone, or nonsense: say nothing rather than nudge at a
		# moment when the message would not be true, and fall through to the allowance nudge.
	# ALLOWANCE: the original "your free games are back" nudge. Free players only (premium has no
	# limit), and gated to 2+ games so the POST_NOTIFICATIONS prompt lands on an engaged player.
	if not GameManager.is_premium and GameManager.games_played >= 2:
		return {
			"title": tr("Your free games are back!"),
			"content": tr("Come back and find the best move."),
			"delay": _seconds_until(Time.get_date_string_from_system(), 1, MORNING_HOUR),
			"repeating": true,
		}
	return {}


## Create the notification channel once. REQUIRED on Android 8+ (API 26+): a notification posted to
## a channel that was never created is silently dropped. Android's createNotificationChannel is
## idempotent, so calling this again is harmless.
func _ensure_channel() -> void:
	if _channel_ready or _scheduler == null:
		return
	var channel = _instantiate_plugin("NotificationChannel")
	if channel == null:
		return
	channel.set_id(CHANNEL_ID)
	channel.set_name(tr("Daily reminder"))
	channel.set_description(tr("A gentle nudge to come back and play."))
	channel.set_importance(CHANNEL_IMPORTANCE_DEFAULT)
	var err = _scheduler.create_notification_channel(channel)
	_channel_ready = (err == OK)  # retry next time if the channel didn't actually register


func _do_schedule(may_prompt := false) -> void:
	var plan := _decide()
	if plan.is_empty():
		_scheduler.cancel(REMINDER_ID)
		return
	_ensure_channel()  # never schedule into a channel that doesn't exist yet
	# Android 13+: schedule() is rejected (ERR_UNAUTHORIZED) unless POST_NOTIFICATIONS is already
	# granted, and the grant is async. So if we don't have it yet, request it and defer the actual
	# scheduling to _on_permission_granted. Scheduling synchronously here would silently drop the
	# very first reminder. _decide() has already returned non-empty, so the player is engaged
	# (2+ games, or a 2-day streak) and the prompt lands at a moment that makes sense to them.
	if _scheduler.has_method("has_post_notifications_permission") \
			and not _scheduler.has_post_notifications_permission():
		if not may_prompt:
			return  # not a polite moment to raise the system dialog; the next game start will
		_pending = true
		_scheduler.request_post_notifications_permission()
		return
	_post(plan)


func _on_permission_granted(_permission := "") -> void:
	if _pending:
		_pending = false
		_do_schedule(true)  # permission is granted now → falls through to _post()


func _on_permission_denied(_permission := "") -> void:
	# Can't post without permission; they can still grant it later in the OS settings, and the next
	# game start re-enters _do_schedule and asks again.
	_pending = false
	_pending_prompt = false


func _post(plan: Dictionary) -> void:
	var data = _instantiate_plugin("NotificationData")
	if data == null:
		return
	data.set_id(REMINDER_ID)
	data.set_channel_id(CHANNEL_ID)
	data.set_title(str(plan["title"]))
	data.set_content(str(plan["content"]))
	data.set_delay(int(plan["delay"]))
	# Only the allowance nudge repeats (the free games really do come back every day). The streak
	# nudge is one-shot, and having no interval also lands it on the more Doze-reliable
	# setAndAllowWhileIdle path.
	if bool(plan["repeating"]):
		data.set_interval(DAY_SECONDS)
	_scheduler.schedule(data)


## Seconds from now until `hour`:00 local, `days_ahead` days after the given "YYYY-MM-DD".
## Negative once that moment has passed. Both instants go through the same dict→unix conversion,
## so the difference is correct in local terms even though neither is really that time in UTC
## (same trick as GameManager._days_since). Returns BAD_DATE on a malformed date so callers skip it.
## The sentinel is far outside the range of any real lead, because an ordinary return value is a
## signed second count that is legitimately negative once the target has passed.
func _seconds_until(date_str: String, days_ahead: int, hour: int) -> int:
	var parts := date_str.split("-")
	if parts.size() != 3:
		return BAD_DATE
	# Advance the CALENDAR day first, from a noon anchor no DST shift can push across a midnight,
	# then place the hour on the resulting date. Adding days_ahead * DAY_SECONDS to the final
	# instant instead would drag the fire time an hour off whenever a transition falls inside the
	# window. (The returned lead is still a wall-clock difference spent as elapsed seconds, so a
	# transition inside the window can still land the alarm an hour early or late. Harmless for
	# both payloads: the morning one stays after the midnight reset, and the evening one has days
	# of margin.)
	var noon := {"year": int(parts[0]), "month": int(parts[1]), "day": int(parts[2]),
			"hour": 12, "minute": 0, "second": 0}
	var day := Time.get_datetime_dict_from_unix_time(
			Time.get_unix_time_from_datetime_dict(noon) + days_ahead * DAY_SECONDS)
	var target := {"year": day["year"], "month": day["month"], "day": day["day"],
			"hour": hour, "minute": 0, "second": 0}
	var now_unix: int = Time.get_unix_time_from_datetime_dict(Time.get_datetime_dict_from_system(false))
	return Time.get_unix_time_from_datetime_dict(target) - now_unix


## Instantiate the plugin's class_name node/resource from the global class registry, or null if the
## addon isn't installed / its class isn't registered. Avoids a parse-time reference to a maybe-absent
## class; the can_instantiate guard keeps us graceful if the script failed to compile.
func _instantiate_plugin(global_cls: String) -> Object:
	for c in ProjectSettings.get_global_class_list():
		if c.get("class", "") == global_cls:
			var scr = load(c["path"])
			if scr is Script and scr.can_instantiate():
				return scr.new()
	return null
