extends Node

## Google Play in-app review prompt (autoload "Reviews").
##
## Wraps the godot-inapp-review plugin's `InappReview` node when installed; without the plugin
## (or on desktop) it falls back to opening the Play Store listing, and is a no-op in the editor.
## We ask ONCE, after the player's 2nd non-loss game (a positive moment), gated by
## GameManager.should_ask_review(). Google throttles the native card, so it may not always show,
## which is expected and fine. The plugin's class_name nodes only exist once the addon is added,
## so we resolve + instantiate them dynamically to stay parse-safe when it isn't.

const LISTING_URL := "https://play.google.com/store/apps/details?id=game.limpidchess"

var _review = null  # InappReview node, or null when the plugin isn't installed


func _ready() -> void:
	_review = _instantiate_global("InappReview")
	if _review == null:
		return
	if _review.has_signal("review_info_generated"):
		_review.connect("review_info_generated", _on_review_info)
	if _review.has_signal("review_info_generation_failed"):
		_review.connect("review_info_generation_failed", _on_review_failed)
	add_child(_review)


## Ask for a review if eligible (gated to once, after the 2nd game). Safe to call any time.
func maybe_ask() -> void:
	if not GameManager.should_ask_review():
		return
	GameManager.mark_review_prompted()  # once only, win or lose afterward
	if _review != null:
		_review.generate_review_info()  # → review_info_generated → launch_review_flow()
	elif not OS.has_feature("editor"):
		OS.shell_open(LISTING_URL)  # no plugin → open the store listing (skip in the editor)


func _on_review_info(_a = null, _b = null) -> void:
	if _review != null:
		_review.launch_review_flow()


func _on_review_failed(_a = null, _b = null) -> void:
	if not OS.has_feature("editor"):
		OS.shell_open(LISTING_URL)  # native card unavailable → fall back to the listing


## Find a class_name script by name in the global class list and instantiate it, or null if the
## plugin isn't installed. Avoids a parse-time reference to a class that may not exist.
func _instantiate_global(cls: String) -> Object:
	for c in ProjectSettings.get_global_class_list():
		if c.get("class", "") == cls:
			var scr = load(c["path"])
			if scr != null:
				return scr.new()
	return null
