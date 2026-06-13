extends Control

## Home screen: the quote, today's remaining games, and the big Play button.
## Play starts a quick game vs the last-picked bot (default: Biscuit). Choosing a
## specific opponent happens on the Bots tab.

@onready var games_label: Label = %GamesLabel
@onready var play_subtitle: Label = %PlaySubtitle
@onready var quote_label: Label = %Quote


func _ready() -> void:
	var safe := DisplayServer.get_display_safe_area()
	$TopBar.offset_top = max(safe.position.y, 16)

	var q := Quotes.random()
	quote_label.text = "“%s”\n%s" % [q["text"], q["author"]]

	var bot := _selected_bot()
	play_subtitle.text = "vs %s" % bot.get("name", "a bot")

	_refresh_games()


func _refresh_games() -> void:
	if GameManager.is_premium:
		games_label.text = "Premium · ∞"
	else:
		games_label.text = "%d / %d today" % [GameManager.games_remaining_today(), GameManager.FREE_GAMES_PER_DAY]


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
