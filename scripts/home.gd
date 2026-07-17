extends Control

## Home screen: today's remaining games and the three entry cards. "New game" opens the opponent
## picker (Bots), so choosing who to play is the first, obvious step. About lives in the Settings dialog.

@onready var games_label: Label = %GamesLabel
@onready var puzzle_title: Label = %PuzzleTitle
@onready var puzzle_best: Label = %PuzzleBest
@onready var settings_overlay: Control = %SettingsOverlay
@onready var language_btn: Button = %LanguageBtn      ## Settings row: shows the current language, opens the picker
@onready var lang_picker: Control = %LanguagePicker   ## the scrollable language chooser (scales to ~15 languages)
@onready var lang_picker_list: VBoxContainer = %List  ## rows built per language in _build_lang_picker
@onready var sound_toggle: Button = %SoundToggle
@onready var reset_btn: Button = %ResetBtn
@onready var daily_limit: DailyLimitDialog = %DailyLimit


func _ready() -> void:
	var safe := DisplayServer.get_display_safe_area()
	$TopBar.offset_top = max(safe.position.y, 16)

	settings_overlay.visible = false
	lang_picker.visible = false

	_refresh_games()
	_refresh_puzzle_button()
	_refresh_language_btn()
	# Calm moment after a positive game: ask for a Play rating (gated to once, 2nd+ game).
	if GameManager.pending_review_check:
		GameManager.pending_review_check = false
		Reviews.maybe_ask()


func _refresh_games() -> void:
	if GameManager.is_premium:
		games_label.text = "Premium · ∞"
	else:
		games_label.text = tr("%d / %d today") % [GameManager.games_remaining_today(), GameManager.FREE_GAMES_PER_DAY]


## The Puzzles button has two states: resume a parked run (a streak left in progress) or start a new
## one. Subtitle shows the parked streak length when resuming, else the best streak ever.
func _refresh_puzzle_button() -> void:
	# Composed from separate keys ("New"/"Resume" + "puzzle streak") so each word translates cleanly,
	# with the verb on line 1 and the noun on line 2. This is set in code (not a scene auto-translate),
	# so it must be rebuilt on a language change too, see the call in _on_language_chosen.
	var verb: String = tr("Resume") if GameManager.has_puzzle_run() else tr("New")
	puzzle_title.text = verb + "\n" + tr("puzzle streak")
	if GameManager.has_puzzle_run():
		puzzle_best.text = "%s: %d" % [tr("Streak"), GameManager.puzzle_streak]
	else:
		puzzle_best.text = tr("Best: %d") % GameManager.puzzle_highscore


## The daily-games pill is tappable: it routes to Premium (which explains the daily limit and
## offers unlimited play), so a player puzzled by the counter learns what it means.
func _on_games_input(event: InputEvent) -> void:
	# Touch only: emulate_touch_from_mouse guarantees mouse clicks arrive here as an
	# emulated touch too, so a separate mouse branch would fire this twice per click.
	var touch := event as InputEventScreenTouch
	if touch != null and touch.pressed:
		GameManager.go_to_premium()


## "New game" opens the opponent picker (Bots). The daily-games gate is enforced there, when a bot is
## actually chosen, so browsing opponents is always free.
func _on_play_pressed() -> void:
	GameManager.go_to_bots()


## Android back closes the top-most open overlay (language picker → settings → daily-limit), so the
## gesture dismisses dialogs just like their close buttons. With nothing open, Home is the root: back
## leaves the app (default), so we don't consume it.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	if lang_picker.visible:
		_on_lang_picker_close()
	elif settings_overlay.visible:
		_on_settings_close()
	elif daily_limit.visible:
		daily_limit.close()


## Puzzle Rush: free players get one run a day (premium unlimited). Out of runs routes to the same
## daily-limit dialog (with the puzzle wording), which offers Premium.
func _on_puzzle_pressed() -> void:
	if GameManager.has_puzzle_run():
		GameManager.start_puzzle_rush(true)  # resume a parked run: no daily gate, it was already paid
		return
	if GameManager.can_puzzle_today():
		GameManager.start_puzzle_rush(false)
	else:
		daily_limit.open("puzzle")


func _on_pass_play_pressed() -> void:
	if GameManager.is_premium:
		GameManager.start_pass_and_play()
	else:
		GameManager.go_to_premium()


# --- Settings (language; sound toggle later) ---

func _on_settings_pressed() -> void:
	_refresh_language_btn()
	_refresh_sound_btn()
	reset_btn.visible = OS.is_debug_build()  # dev-only convenience
	settings_overlay.visible = true


func _on_settings_close() -> void:
	settings_overlay.visible = false


## About (credits, licenses, source) now lives in the Settings dialog, its own screen a tap away.
func _on_about_pressed() -> void:
	GameManager.go_to_about()


## Tap outside the Settings card (on the dim) to dismiss it. We close on RELEASE, not press: the
## dim is a full-screen STOP control above the home content, so it swallows the whole tap while the
## overlay is still visible. Closing on press would hide the overlay mid-tap and let the release
## (or, on touch, the emulated mouse press that follows) fall through to the Play / Face to Face
## buttons and start a game.
func _on_dim_input(event: InputEvent) -> void:
	# Touch only, same convention as _on_games_input: with emulate_touch_from_mouse,
	# mouse releases arrive as emulated touch releases too, so one branch covers all.
	var touch := event as InputEventScreenTouch
	if touch != null and not touch.pressed:
		_on_settings_close()


## The sound toggle is a full-width button (big tap target, matches the language
## rows): accent border + "On" when enabled, subtle border + "Off" when muted.
func _refresh_sound_btn() -> void:
	var on := GameManager.sound_enabled
	sound_toggle.text = tr("Sound: %s") % (tr("On") if on else tr("Off"))
	# Speaker glyph reflects the state: waves when on, muted (slashed) when off.
	sound_toggle.icon = load("res://assets/icons/sound_on.png" if on else "res://assets/icons/sound_off.png")
	sound_toggle.add_theme_constant_override("icon_max_width", 30)
	sound_toggle.add_theme_constant_override("h_separation", 12)
	var sb := StyleBoxFlat.new()
	sb.bg_color = UI.SURFACE
	sb.content_margin_left = 16
	sb.content_margin_right = 16
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


## Country flag per language code (a quick visual cue alongside the native name). Extend as languages
## are added; a code with no flag just shows its name.
const LANG_FLAGS := {
	"en": "flag_en.png", "fr": "flag_fr.png", "es": "flag_es.png",
	"pt": "flag_pt.png", "de": "flag_de.png", "it": "flag_it.png", "ru": "flag_ru.png",
	"tr": "flag_tr.png", "pl": "flag_pl.png", "id": "flag_id.png", "vi": "flag_vi.png",
	"uk": "flag_uk.png", "el": "flag_el.png",
}


func _lang_name(code: String) -> String:
	for lang in GameManager.LANGUAGES:
		if lang["code"] == code:
			return lang["name"]
	return code


## The Settings "Language" row: shows the current language's flag + native name; tapping opens the picker.
func _refresh_language_btn() -> void:
	var code := GameManager.current_language()
	language_btn.text = tr("Language: %s") % _lang_name(code)
	language_btn.auto_translate_mode = Control.AUTO_TRANSLATE_MODE_DISABLED  # the native name is not translated
	var flag: String = LANG_FLAGS.get(code, "")
	language_btn.icon = load("res://assets/icons/" + flag) if flag != "" else null


func _on_language_btn_pressed() -> void:
	_build_lang_picker()
	lang_picker.visible = true


## Open the language picker: one row per language (native name + flag), the current one accent-bordered.
## Scrollable, so it scales to the full planned language set (~15+).
func _build_lang_picker() -> void:
	for c in lang_picker_list.get_children():
		c.queue_free()
	var current := GameManager.current_language()
	# Alphabetical by each language's own (native) name, so no language is privileged by list position.
	var langs := GameManager.LANGUAGES.duplicate()
	langs.sort_custom(func(a, b): return String(a["name"]) < String(b["name"]))
	for lang in langs:
		var b := Button.new()
		b.text = lang["name"]  # shown in its OWN language, never translated
		b.auto_translate_mode = Control.AUTO_TRANSLATE_MODE_DISABLED
		b.custom_minimum_size = Vector2(0, 60)
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 22)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var flag: String = LANG_FLAGS.get(lang["code"], "")
		if flag != "":
			b.icon = load("res://assets/icons/" + flag)
			b.add_theme_constant_override("icon_max_width", 34)
			b.add_theme_constant_override("h_separation", 14)
		var selected: bool = lang["code"] == current
		var sb := StyleBoxFlat.new()
		sb.bg_color = UI.SURFACE
		sb.content_margin_left = 16
		sb.content_margin_right = 16
		sb.set_corner_radius_all(16)
		sb.set_border_width_all(2 if selected else 1)
		sb.border_color = UI.ACCENT if selected else UI.BORDER_SUBTLE
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
		b.add_theme_stylebox_override("pressed", sb)
		b.pressed.connect(_on_language_chosen.bind(lang["code"]))
		lang_picker_list.add_child(b)


func _on_lang_picker_close() -> void:
	lang_picker.visible = false


## Tap the dim outside the picker card to dismiss it (close on RELEASE, like the Settings dim).
func _on_lang_picker_dim_input(event: InputEvent) -> void:
	# Touch only — see _on_dim_input.
	var touch := event as InputEventScreenTouch
	if touch != null and not touch.pressed:
		_on_lang_picker_close()


func _on_language_chosen(code: String) -> void:
	lang_picker.visible = false  # a pick always closes the picker, back to Settings
	if code == GameManager.current_language():
		return
	GameManager.set_language(code)
	# The locale switches live: auto-translated labels update themselves, but the strings we build in
	# code must be refreshed. Settings stays open, now showing the new language on its Language row.
	_refresh_games()
	_refresh_puzzle_button()
	_refresh_sound_btn()
	_refresh_language_btn()
