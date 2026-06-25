extends Control

## Bots screen: pick your opponent. Rows are built from BotRoster.ALL.
## Tapping a bot selects it and starts a game (or routes to Premium if the
## player is out of free games).

@onready var scroll: ScrollContainer = %Scroll
@onready var list: VBoxContainer = %List
@onready var daily_limit: DailyLimitDialog = %DailyLimit


func _ready() -> void:
	var safe := DisplayServer.get_display_safe_area()
	var top: int = max(safe.position.y, 16)
	$Header.offset_top = top
	$Header.offset_bottom = top + 80
	scroll.offset_top = top + 108
	for bot in BotRoster.ALL:
		list.add_child(_make_row(bot))
	# Rows are a fixed-min Button, so a tagline that wraps (longer in fr/es) would
	# overflow the card. Grow each row to fit its content once it has a real width.
	_fit_rows.call_deferred()
	list.resized.connect(_fit_rows)
	# Calm moment after a positive game (e.g. arriving here via "Change opponent"): ask for a rating.
	if GameManager.pending_review_check:
		GameManager.pending_review_check = false
		Reviews.maybe_ask()


## Set each row's height to fit its (possibly wrapped) content; 96px floor. Runs on
## first layout + any width change; same-value sets are no-ops so it can't loop.
func _fit_rows() -> void:
	if list.size.x < 50.0:
		return  # width not established yet; resized will call us again
	for row in list.get_children():
		if row.get_child_count() == 0:
			continue
		var hb := row.get_child(0) as Control
		row.custom_minimum_size.y = maxf(96.0, hb.get_combined_minimum_size().y + 28.0)


func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	if daily_limit.visible:
		daily_limit.close()   # close the daily-limit dialog first
	else:
		GameManager.go_to_home()


func _make_row(bot: Dictionary) -> Button:
	var selected: bool = GameManager.current_bot.get("id", "") == bot["id"]
	var locked: bool = BotRoster.is_premium_bot(bot) and not GameManager.is_premium

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(0, 96)
	btn.focus_mode = Control.FOCUS_NONE
	# PASS (not the default STOP) so a touch-drag that starts on a row bubbles up
	# Button -> List(VBox) -> Scroll and scrolls the list. With STOP the button ate
	# the drag and you could only scroll in the thin gaps between rows. A clean tap
	# still fires (dragging out of the button cancels its press), and the Scroll's
	# scroll_deadzone keeps small jitters from hijacking a tap. NOTE: this relies on
	# the List VBox staying PASS (Containers default to PASS; bots.tscn sets it
	# explicitly) so the event keeps bubbling up to the ScrollContainer.
	btn.mouse_filter = Control.MOUSE_FILTER_PASS

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
	# Name row: name on the left, an optional gold "wins" badge pinned to the right edge.
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	name_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_label := Label.new()
	name_label.text = bot["name"]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(name_label)
	var wins: int = GameManager.wins_against(bot["id"])
	if wins > 0:  # hidden for bots the player hasn't beaten yet, to avoid clutter
		var win_badge := HBoxContainer.new()
		win_badge.add_theme_constant_override("separation", 3)
		win_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		win_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var trophy := TextureRect.new()
		trophy.custom_minimum_size = Vector2(20, 20)
		trophy.texture = load("res://assets/icons/trophy.png")
		trophy.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		trophy.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		trophy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		trophy.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var count := Label.new()
		count.text = str(wins)
		count.add_theme_font_size_override("font_size", UI.FONT_CAPTION)
		count.modulate = UI.COIN_BEST
		count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		win_badge.add_child(trophy)
		win_badge.add_child(count)
		name_row.add_child(win_badge)
	var tagline := Label.new()
	tagline.text = bot["tagline"]
	tagline.modulate = UI.TEXT_DIM
	tagline.add_theme_font_size_override("font_size", UI.FONT_CAPTION)
	tagline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_box.add_child(name_row)
	text_box.add_child(tagline)
	hb.add_child(text_box)

	var meta := VBoxContainer.new()
	meta.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	meta.alignment = BoxContainer.ALIGNMENT_CENTER
	meta.add_theme_constant_override("separation", 8)
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tier := Label.new()
	tier.text = bot["tier"]
	tier.add_theme_font_size_override("font_size", UI.FONT_CAPTION)
	tier.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# Relative difficulty pips (not an Elo: the strengths aren't calibrated).
	var pips := preload("res://scripts/ui/difficulty_pips.gd").new()
	pips.set_level(int(bot.get("difficulty", 1)))
	pips.size_flags_horizontal = Control.SIZE_SHRINK_END
	pips.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	meta.add_child(tier)
	meta.add_child(pips)
	hb.add_child(meta)

	# Premium bots are dimmed and carry a lock until the player unlocks Premium.
	if locked:
		avatar.modulate = UI.TEXT_FADED
		text_box.modulate = UI.TEXT_FADED
		meta.modulate = UI.TEXT_FADED
		var lock := TextureRect.new()
		lock.custom_minimum_size = Vector2(36, 36)
		lock.texture = load("res://assets/icons/lock.png")
		lock.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		lock.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		lock.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		lock.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hb.add_child(lock)

	btn.add_child(hb)
	btn.pressed.connect(_on_bot_pressed.bind(bot))
	return btn


func _on_bot_pressed(bot: Dictionary) -> void:
	# Strongest bots are premium-only: route to the Premium page instead of playing.
	if BotRoster.is_premium_bot(bot) and not GameManager.is_premium:
		GameManager.go_to_premium()
		return
	GameManager.current_bot = bot
	if GameManager.can_play_game():
		GameManager.start_bot_game(bot, true)
	else:
		daily_limit.open()  # out of free games: explain the daily reload (not a silent jump to the store)
