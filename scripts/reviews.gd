extends Node

## Google Play in-app review prompt (autoload "Reviews").
##
## Wraps the godot-inapp-review plugin's `InappReview` node when installed; without the plugin
## (or on desktop) it falls back to opening the Play Store listing, and is a no-op in the editor.
## We auto-ask at most once per day, after a non-loss game (a positive moment), gated by
## GameManager.should_ask_review(). Google throttles the native card, so it may not always show,
## which is expected and fine. The plugin's class_name nodes only exist once the addon is added,
## so we resolve + instantiate them dynamically to stay parse-safe when it isn't.

const LISTING_URL := "https://play.google.com/store/apps/details?id=game.limpidchess"

var _review = null  # InappReview node, or null when the plugin isn't installed


func _ready() -> void:
	# Only touch the plugin when its Android singleton actually exists; on desktop/dev the
	# InappReview node would push "singleton not found" errors, so we stay a clean no-op there.
	if not Engine.has_singleton("InappReviewPlugin"):
		return
	_review = _instantiate_plugin("InappReview")
	if _review == null:
		return
	if _review.has_signal("review_info_generated"):
		_review.connect("review_info_generated", _on_review_info)
	if _review.has_signal("review_info_generation_failed"):
		_review.connect("review_info_generation_failed", _on_review_failed)
	add_child(_review)


## Auto-prompt for a review if eligible (at most once per day, after the 2nd game). We never drop
## the native review card on the player unannounced: first show our own gentle "do you enjoy it?"
## dialog, and only launch the real flow if they tap "Rate it". Safe to call any time.
func maybe_ask() -> void:
	if not GameManager.should_ask_review():
		return
	# Spend today's single slot only if the dialog actually appeared (so a failed show can retry).
	if _show_pre_dialog():
		GameManager.mark_review_prompted()  # at most once per day; "Not now" just waits for a later day


## Show the friendly pre-prompt over the current scene; returns false if it couldn't be shown.
## On "Rate it" it calls ask(); "Not now" just dismisses (the About "Review game" button stays
## available, and we may gently ask again on a later day, never twice the same day).
func _show_pre_dialog() -> bool:
	var scene := get_tree().current_scene
	if scene == null:
		return false
	var ps := load("res://scenes/rate_dialog.tscn") as PackedScene
	if ps == null:
		return false
	var dlg := ps.instantiate()
	dlg.rated.connect(ask)
	scene.add_child(dlg)
	return true


## Launch the in-app review card (the auto pre-prompt's "Rate it"). The native card is quota-limited
## and may silently not show, which is fine for this one-shot positive moment; falls back to the
## store listing without the plugin.
func ask() -> void:
	GameManager.mark_review_done()  # they engaged with rating → stop the automatic pre-prompt
	if _review != null:
		_review.generate_review_info()  # → review_info_generated → launch_review_flow()
	elif not OS.has_feature("editor"):
		OS.shell_open(LISTING_URL)  # no plugin → open the store listing (skip in the editor)


## Open the Play Store listing so the player can rate or CHANGE their review at any time. Used by the
## always-available About "Review game" button: unlike the in-app card it's reliable and repeatable
## (the review API never reports whether they rated, so the button can't be hidden on "done").
func open_store_listing() -> void:
	GameManager.mark_review_done()  # they went to rate → quiet the automatic pre-prompt
	if not OS.has_feature("editor"):
		OS.shell_open(LISTING_URL)


func _on_review_info(_a = null, _b = null) -> void:
	if _review != null:
		_review.launch_review_flow()


func _on_review_failed(_a = null, _b = null) -> void:
	if not OS.has_feature("editor"):
		OS.shell_open(LISTING_URL)  # native card unavailable → fall back to the listing


## Instantiate the plugin's class_name node from the global class registry, or null if the addon
## isn't installed / its class isn't registered. Avoids a parse-time reference to a maybe-absent
## class; the can_instantiate guard keeps us graceful if the script failed to compile.
func _instantiate_plugin(global_cls: String) -> Object:
	for c in ProjectSettings.get_global_class_list():
		if c.get("class", "") == global_cls:
			var scr = load(c["path"])
			if scr is Script and scr.can_instantiate():
				return scr.new()
	return null
