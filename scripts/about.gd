extends Control

## About screen: player stats, credits, and asset attributions.
## OpenMoji's CC BY-SA 4.0 licence REQUIRES the attribution shown here — keep it.

@onready var scroll: ScrollContainer = %Scroll
@onready var stats: Label = %Stats
@onready var version: Label = %Version
@onready var review_button: Button = %ReviewButton


func _ready() -> void:
	var safe := DisplayServer.get_display_safe_area()
	scroll.offset_top = max(safe.position.y, 16)
	# Single source of truth for the version: the project setting (baked into the export and
	# readable at runtime; export_presets.cfg is editor-only and not shipped).
	version.text = "Limpid Chess · v%s" % ProjectSettings.get_setting("application/config/version", "")
	_fill_stats()
	# Always available: the Play review API never tells us whether the player actually rated, so we
	# can't (and don't) hide this. It opens the store listing, where they can rate or change their
	# review whenever (the in-app review card is quota-limited and can't be reliably re-shown).
	review_button.pressed.connect(_on_review_pressed)
	# Wire every credit link: tapping a [url] opens it in the system browser.
	for label in _find_rich_labels(self):
		label.meta_clicked.connect(_on_link_clicked)


func _on_review_pressed() -> void:
	Reviews.open_store_listing()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		GameManager.go_to_home()


func _fill_stats() -> void:
	stats.text = tr("Games played: %d\nWins %d · Draws %d · Losses %d\nBest moves found: %d\nBlunders: %d") % [
		GameManager.games_played, GameManager.wins, GameManager.draws, GameManager.losses,
		GameManager.best_moves_found, GameManager.blunders_made,
	]
	stats.text += "\n" + tr("Best puzzle streak: %d") % GameManager.puzzle_highscore


func _find_rich_labels(node: Node) -> Array[RichTextLabel]:
	var found: Array[RichTextLabel] = []
	for child in node.get_children():
		if child is RichTextLabel:
			found.append(child)
		found.append_array(_find_rich_labels(child))
	return found


func _on_link_clicked(meta: Variant) -> void:
	OS.shell_open(str(meta))
