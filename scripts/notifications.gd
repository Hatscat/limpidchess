extends Node

## "Your free games are back" local notification (autoload "Notifications").
##
## Wraps the godot-notification-scheduler plugin's `NotificationScheduler` + `NotificationData`
## nodes when installed; a harmless no-op on desktop/dev or without the plugin. Scheduled when a
## free player runs out of daily games (GameManager._count_game), cancelled when they have games
## again or go Premium. Uses set_delay (the plugin's inexact alarm), so it needs no
## SCHEDULE_EXACT_ALARM Play declaration. The plugin's class_name nodes only exist once the addon
## is added, so we resolve + instantiate them dynamically to stay parse-safe when it isn't.

const REMINDER_ID := 1001
const CHANNEL_ID := "limpid_daily"

var _scheduler = null
var _initialized := false
var _pending := false  # a schedule was requested before the plugin finished initializing


func _ready() -> void:
	_scheduler = _instantiate_global("NotificationScheduler")
	if _scheduler == null:
		return
	if _scheduler.has_signal("initialization_completed"):
		_scheduler.connect("initialization_completed", _on_initialized)
	else:
		_initialized = true  # no init signal on this version → assume ready
	add_child(_scheduler)


func _on_initialized() -> void:
	_initialized = true
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


func _do_schedule() -> void:
	# Ask for notification permission the first time (Android 13+); harmless if already granted.
	if _scheduler.has_method("has_post_notifications_permission") \
			and not _scheduler.has_post_notifications_permission():
		_scheduler.request_post_notifications_permission()
	var data = _instantiate_global("NotificationData")
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


## Find a class_name script by name in the global class list and instantiate it, or null if the
## plugin isn't installed. Avoids a parse-time reference to a class that may not exist.
func _instantiate_global(cls: String) -> Object:
	for c in ProjectSettings.get_global_class_list():
		if c.get("class", "") == cls:
			var scr = load(c["path"])
			if scr != null:
				return scr.new()
	return null
