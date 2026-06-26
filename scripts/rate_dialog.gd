extends CanvasLayer

## Friendly "do you enjoy the game?" pre-prompt, shown before the Play in-app review flow so the
## review overlay never appears unannounced. Emits `rated` when the player opts in; frees itself on
## either choice. Instanced on demand by the Reviews autoload (and never persists across scenes).

signal rated
signal never_ask  ## "Don't ask again": stop the automatic pre-prompt for good

@onready var _rate_btn: Button = %RateBtn
@onready var _later_btn: Button = %LaterBtn
@onready var _never_btn: Button = %NeverBtn


func _ready() -> void:
	_rate_btn.pressed.connect(_on_rate)
	_later_btn.pressed.connect(_on_later)
	_never_btn.pressed.connect(_on_never)


func _on_rate() -> void:
	rated.emit()
	queue_free()


func _on_later() -> void:
	queue_free()


func _on_never() -> void:
	never_ask.emit()
	queue_free()
