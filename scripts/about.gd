extends Control

## About screen: credits, asset attributions, and the store-review link.
## OpenMoji's CC BY-SA 4.0 licence REQUIRES the attribution shown here — keep it.

@onready var scroll: ScrollContainer = %Scroll
@onready var version: Label = %Version
@onready var review_button: Button = %ReviewButton


func _ready() -> void:
	var safe := DisplayServer.get_display_safe_area()
	var top: int = max(safe.position.y, 16)
	$Header.offset_top = top
	$Header.offset_bottom = top + 80  # room for the font-40 title (min ~73px), matching the bots header
	scroll.offset_top = top + 96      # clear gap below the fixed back/title header
	# Single source of truth for the version: the project setting (baked into the export and
	# readable at runtime; export_presets.cfg is editor-only and not shipped).
	version.text = "Limpid Chess · v%s" % ProjectSettings.get_setting("application/config/version", "")
	# Always available on Android: the Play review API never tells us whether the player actually
	# rated, so we can't (and don't) hide this. It opens the store listing, where they can rate or
	# change their review whenever (the in-app review card is quota-limited and can't be reliably
	# re-shown). Hidden on web: rating an app the browser player doesn't have makes no sense.
	review_button.visible = not OS.has_feature("web")
	review_button.pressed.connect(_on_review_pressed)
	# Wire every credit link: tapping a [url] opens it in the system browser.
	for label in _find_rich_labels(self):
		label.meta_clicked.connect(_on_link_clicked)


func _on_review_pressed() -> void:
	Reviews.open_store_listing()


## Back arrow (top-left) returns to Home, same as the Android back gesture.
func _on_back_pressed() -> void:
	GameManager.go_to_home()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		GameManager.go_to_home()


func _find_rich_labels(node: Node) -> Array[RichTextLabel]:
	var found: Array[RichTextLabel] = []
	for child in node.get_children():
		if child is RichTextLabel:
			found.append(child)
		found.append_array(_find_rich_labels(child))
	return found


func _on_link_clicked(meta: Variant) -> void:
	OS.shell_open(str(meta))
