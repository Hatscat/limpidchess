extends CanvasLayer

## Friendly "do you enjoy the game?" pre-prompt, shown before the Play in-app review flow so the
## review overlay never appears unannounced. Emits `rated` when the player opts in; frees itself on
## either choice. Instanced on demand by the Reviews autoload (and never persists across scenes).

signal rated

@onready var _rate_btn: Button = %RateBtn
@onready var _later_btn: Button = %LaterBtn


func _ready() -> void:
	_rate_btn.pressed.connect(_on_rate)
	_later_btn.pressed.connect(_on_later)


func _on_rate() -> void:
	rated.emit()
	queue_free()


func _on_later() -> void:
	queue_free()
