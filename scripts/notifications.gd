extends Node

## "Your free games are back" local notification (autoload "Notifications").
##
## Wraps the godot-notification-scheduler plugin's `NotificationScheduler` + `NotificationData`
## nodes when installed; a harmless no-op on desktop/dev or without the plugin. Scheduled when a
## free player runs out of daily games (GameManager._count_game), cancelled when they have games
## again or go Premium. We schedule via set_delay and never request SCHEDULE_EXACT_ALARM, so the
## plugin falls back to an inexact while-idle alarm: it still fires while the app is closed and
## survives a reboot, but may land up to ~1h late (fine for a daily "games are back" nudge). The
## plugin's class_name nodes only exist once the addon is added, so we resolve + instantiate them
## dynamically to stay parse-safe when it isn't.

const REMINDER_ID := 1001
const CHANNEL_ID := "limpid_daily"
const CHANNEL_IMPORTANCE_DEFAULT := 3  # NotificationChannel.Importance.DEFAULT (literal = parse-safe)

var _scheduler = null
var _initialized := false
var _channel_ready := false
var _pending := false  # a schedule is waiting on a precondition (init, or the async permission grant)


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
	_ensure_channel()
	if _pending:
		_pending = false
		_do_schedule()


## Schedule the "free games are back" reminder for tomorrow morning. No-op without the plugin.
func schedule_reset_reminder() -> void:
	if _scheduler == null:
		return
	if not _initialized:
		_pending = true  # flushed on initialization_completed
		return
	_do_schedule()


func cancel_reset_reminder() -> void:
	_pending = false
	if _scheduler != null:
		_scheduler.cancel(REMINDER_ID)


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
	channel.set_name(tr("Free games reminder"))
	channel.set_description(tr("Reminds you when your free daily games reset."))
	channel.set_importance(CHANNEL_IMPORTANCE_DEFAULT)
	var err = _scheduler.create_notification_channel(channel)
	_channel_ready = (err == OK)  # retry next time if the channel didn't actually register


func _do_schedule() -> void:
	_ensure_channel()  # never schedule into a channel that doesn't exist yet
	# Android 13+: schedule() is rejected (ERR_UNAUTHORIZED) unless POST_NOTIFICATIONS is already
	# granted, and the grant is async. So if we don't have it yet, request it (the contextual moment:
	# the player just ran out of free games) and defer the actual scheduling to _on_permission_granted.
	# Scheduling synchronously here would silently drop the very first reminder.
	if _scheduler.has_method("has_post_notifications_permission") \
			and not _scheduler.has_post_notifications_permission():
		_pending = true
		_scheduler.request_post_notifications_permission()
		return
	_post_reminder()


func _on_permission_granted(_permission := "") -> void:
	if _pending:
		_pending = false
		_do_schedule()  # permission is granted now → falls through to _post_reminder()


func _on_permission_denied(_permission := "") -> void:
	_pending = false  # can't post without permission; they can still enable it later in settings


func _post_reminder() -> void:
	var data = _instantiate_plugin("NotificationData")
	if data == null:
		return
	data.set_id(REMINDER_ID)
	data.set_channel_id(CHANNEL_ID)
	data.set_title(tr("Your free games are back!"))
	data.set_content(tr("Come back and find the best move."))
	data.set_delay(_delay_to_tomorrow_morning())
	_scheduler.schedule(data)


## Seconds from now until tomorrow ~10:00 local. Always lands AFTER the midnight free-games
## reset, so the notification never claims the games are back before they actually are.
func _delay_to_tomorrow_morning() -> int:
	var d := Time.get_datetime_dict_from_system(false)  # local time
	var into_day: int = int(d["hour"]) * 3600 + int(d["minute"]) * 60 + int(d["second"])
	return (86400 - into_day) + 10 * 3600  # next midnight + 10h


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
