extends Control

## Home screen: today's remaining games and the big Play button.
## Play starts a quick game vs the last-picked bot (default: Pip). Choosing a
## specific opponent happens on the Bots tab.

@onready var games_label: Label = %GamesLabel
@onready var bot_avatar: TextureRect = %BotAvatar
@onready var bot_name: Label = %BotName
@onready var settings_overlay: Control = %SettingsOverlay
@onready var lang_list: VBoxContainer = %LangList
@onready var sound_toggle: Button = %SoundToggle
@onready var reset_btn: Button = %ResetBtn


func _ready() -> void:
	var safe := DisplayServer.get_display_safe_area()
	$TopBar.offset_top = max(safe.position.y, 16)

	settings_overlay.visible = false

	var bot := _selected_bot()
	bot_avatar.texture = load(BotRoster.avatar_path(bot))
	bot_name.text = bot.get("name", "a bot")

	_refresh_games()


func _refresh_games() -> void:
	if GameManager.is_premium:
		games_label.text = "Premium · ∞"
	else:
		games_label.text = tr("%d / %d today") % [GameManager.games_remaining_today(), GameManager.FREE_GAMES_PER_DAY]


func _selected_bot() -> Dictionary:
	return GameManager.current_bot if not GameManager.current_bot.is_empty() else BotRoster.default()


func _on_play_pressed() -> void:
	var bot := _selected_bot()
	# A premium-only opponent (e.g. selected while premium, now lapsed) routes to Premium.
	if BotRoster.is_premium_bot(bot) and not GameManager.is_premium:
		GameManager.go_to_premium()
		return
	if GameManager.can_play_game():
		GameManager.start_bot_game(bot, true)
	else:
		GameManager.go_to_premium()


func _on_pass_play_pressed() -> void:
	if GameManager.is_premium:
		GameManager.start_pass_and_play()
	else:
		GameManager.go_to_premium()


# --- Settings (language; sound toggle later) ---

func _on_settings_pressed() -> void:
	_build_lang_list()
	_refresh_sound_btn()
	reset_btn.visible = OS.is_debug_build()  # dev-only convenience
	settings_overlay.visible = true


func _on_settings_close() -> void:
	settings_overlay.visible = false


## The sound toggle is a full-width button (big tap target, matches the language
## rows): accent border + "On" when enabled, subtle border + "Off" when muted.
func _refresh_sound_btn() -> void:
	var on := GameManager.sound_enabled
	sound_toggle.text = tr("Sound: %s") % (tr("On") if on else tr("Off"))
	var sb := StyleBoxFlat.new()
	sb.bg_color = UI.SURFACE
	sb.set_corner_radius_all(16)
	sb.set_border_width_all(2 if on else 1)
	sb.border_color = UI.ACCENT if on else UI.BORDER_SUBTLE
	sound_toggle.add_theme_stylebox_override("normal", sb)
	sound_toggle.add_theme_stylebox_override("hover", sb)
	sound_toggle.add_theme_stylebox_override("pressed", sb)


func _on_sound_pressed() -> void:
	GameManager.set_sound_enabled(not GameManager.sound_enabled)
	_refresh_sound_btn()
	if GameManager.sound_enabled:
		Audio.play("move")  # a little confirmation blip


func _on_reset_pressed() -> void:
	GameManager.reset_save()
	GameManager.go_to_home()  # reload fresh (non-premium, zeroed stats)


func _build_lang_list() -> void:
	for c in lang_list.get_children():
		c.queue_free()
	var current := GameManager.current_language()
	for lang in GameManager.LANGUAGES:
		var b := Button.new()
		b.text = lang["name"]  # shown in its OWN language, never translated
		b.auto_translate_mode = Control.AUTO_TRANSLATE_MODE_DISABLED
		b.custom_minimum_size = Vector2(0, 60)
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 22)
		var selected: bool = lang["code"] == current
		var sb := StyleBoxFlat.new()
		sb.bg_color = UI.SURFACE
		sb.set_corner_radius_all(16)
		sb.set_border_width_all(2 if selected else 1)
		sb.border_color = UI.ACCENT if selected else UI.BORDER_SUBTLE
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
		b.add_theme_stylebox_override("pressed", sb)
		b.pressed.connect(_on_language_chosen.bind(lang["code"]))
		lang_list.add_child(b)


func _on_language_chosen(code: String) -> void:
	if code == GameManager.current_language():
		settings_overlay.visible = false
		return
	GameManager.set_language(code)
	GameManager.go_to_home()  # reload so every string (incl. code-built) re-renders
