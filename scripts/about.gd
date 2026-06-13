extends Control

## About screen: player stats, credits, and asset attributions.
## OpenMoji's CC BY-SA 4.0 licence REQUIRES the attribution shown here — keep it.

@onready var scroll: ScrollContainer = %Scroll
@onready var stats: Label = %Stats


func _ready() -> void:
	var safe := DisplayServer.get_display_safe_area()
	scroll.offset_top = max(safe.position.y, 16)
	_fill_stats()
	# Wire every credit link: tapping a [url] opens it in the system browser.
	for label in _find_rich_labels(self):
		label.meta_clicked.connect(_on_link_clicked)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		GameManager.go_to_home()


func _fill_stats() -> void:
	stats.text = "Games played: %d\nWins %d · Draws %d · Losses %d\nBest moves found: %d\nCoins: best %d · blunder %d" % [
		GameManager.games_played, GameManager.wins, GameManager.draws, GameManager.losses,
		GameManager.best_moves_found, GameManager.coins_best, GameManager.coins_blunder,
	]


func _find_rich_labels(node: Node) -> Array[RichTextLabel]:
	var found: Array[RichTextLabel] = []
	for child in node.get_children():
		if child is RichTextLabel:
			found.append(child)
		found.append_array(_find_rich_labels(child))
	return found


func _on_link_clicked(meta: Variant) -> void:
	OS.shell_open(str(meta))
