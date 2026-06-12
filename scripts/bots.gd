extends Control

## Bots screen: pick your opponent. Rows are built from BotRoster.ALL.
## Tapping a bot selects it and starts a game (or routes to Premium if the
## player is out of free games).

@onready var scroll: ScrollContainer = %Scroll
@onready var list: VBoxContainer = %List


func _ready() -> void:
	var safe := DisplayServer.get_display_safe_area()
	var top: int = max(safe.position.y, 16)
	$Header.offset_top = top
	$Header.offset_bottom = top + 80
	scroll.offset_top = top + 108
	for bot in BotRoster.ALL:
		list.add_child(_make_row(bot))


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		GameManager.go_to_home()


func _make_row(bot: Dictionary) -> Button:
	var selected: bool = GameManager.current_bot.get("id", "") == bot["id"]

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(0, 96)
	btn.focus_mode = Control.FOCUS_NONE

	var sb := StyleBoxFlat.new()
	sb.bg_color = UI.SURFACE
	sb.set_corner_radius_all(20)
	sb.set_border_width_all(1)
	sb.border_color = UI.ACCENT if selected else UI.BORDER_SUBTLE
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", sb)
	var sb_pressed := sb.duplicate()
	sb_pressed.bg_color = UI.SURFACE_PRESSED
	btn.add_theme_stylebox_override("pressed", sb_pressed)

	var hb := HBoxContainer.new()
	hb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hb.offset_left = 16
	hb.offset_top = 12
	hb.offset_right = -16
	hb.offset_bottom = -12
	hb.add_theme_constant_override("separation", 14)
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var avatar := TextureRect.new()
	avatar.custom_minimum_size = Vector2(64, 64)
	avatar.texture = load(BotRoster.avatar_path(bot))
	avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(avatar)

	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text_box.add_theme_constant_override("separation", 2)
	text_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_label := Label.new()
	name_label.text = bot["name"]
	var tagline := Label.new()
	tagline.text = bot["tagline"]
	tagline.modulate = UI.TEXT_DIM
	tagline.add_theme_font_size_override("font_size", UI.FONT_CAPTION)
	tagline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_box.add_child(name_label)
	text_box.add_child(tagline)
	hb.add_child(text_box)

	var meta := VBoxContainer.new()
	meta.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	meta.alignment = BoxContainer.ALIGNMENT_CENTER
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tier := Label.new()
	tier.text = bot["tier"]
	tier.add_theme_font_size_override("font_size", UI.FONT_CAPTION)
	tier.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var elo := Label.new()
	elo.text = "~%d" % bot["elo"]
	elo.modulate = UI.TEXT_FADED
	elo.add_theme_font_size_override("font_size", UI.FONT_CAPTION)
	elo.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	meta.add_child(tier)
	meta.add_child(elo)
	hb.add_child(meta)

	btn.add_child(hb)
	btn.pressed.connect(_on_bot_pressed.bind(bot))
	return btn


func _on_bot_pressed(bot: Dictionary) -> void:
	GameManager.current_bot = bot
	if GameManager.can_play_game():
		GameManager.start_bot_game(bot, true)
	else:
		GameManager.go_to_premium()
