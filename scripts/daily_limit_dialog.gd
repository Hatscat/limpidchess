class_name DailyLimitDialog
extends Control

## Reusable "out of free games today" dialog. Instance it in a scene and call open() when a free
## player has used the day's free games. It explains the free games come back tomorrow (some
## players think 3 games = the end / that they must pay) and offers Premium. "Get Premium" leads to
## the store; "Got it" just dismisses it. Hosting scenes should let their Android-back handler close
## this first (check `visible`, then call close()).

@onready var _title: Label = %DailyTitle
@onready var _message: Label = %DailyMessage


func _ready() -> void:
	visible = false


## Open the dialog, explaining which daily free limit was hit. reason: "games" (default),
## "review" (the moves-review cap), or "puzzle" (the Puzzle Rush cap). Texts are set in English;
## auto-translate localises them.
func open(reason := "games") -> void:
	if reason == "review":
		_title.text = "Out of free reviews today"
		_message.text = "Free players get 1 game review a day. It comes back tomorrow!"
	elif reason == "puzzle":
		_title.text = "Out of free puzzles today"
		_message.text = "Free players get 1 puzzle run a day. It comes back tomorrow!"
	else:
		_title.text = "Out of free games today"
		_message.text = "Your free games come back tomorrow and every day."
	visible = true


func close() -> void:
	visible = false


func _on_premium_pressed() -> void:
	GameManager.go_to_premium()


func _on_close_pressed() -> void:
	visible = false
