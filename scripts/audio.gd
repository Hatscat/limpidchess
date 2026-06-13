extends Node

## Tiny one-shot sound-effect player (autoload "Audio"). Plays short feedback cues
## by name and respects GameManager.sound_enabled. The cues are self-made CC0 tones
## (assets/sfx) tuned to the calm "limpid" feel; swap for recorded SFX any time.
##
## A small round-robin pool of players lets brief cues overlap (e.g. a reward chime
## landing while a move click is still ringing) without cutting each other off.

const FILES := {
	"move": "res://assets/sfx/move.wav",
	"capture": "res://assets/sfx/capture.wav",
	"best": "res://assets/sfx/best.wav",
	"decent": "res://assets/sfx/decent.wav",
	"blunder": "res://assets/sfx/blunder.wav",
	"win": "res://assets/sfx/win.wav",
	"end": "res://assets/sfx/end.wav",
}
const POOL_SIZE := 4

var _streams := {}
var _players: Array[AudioStreamPlayer] = []
var _next := 0


func _ready() -> void:
	for key in FILES:
		var s: AudioStream = load(FILES[key])
		if s != null:
			_streams[key] = s
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)


## Play a named cue (no-op if sounds are off or the cue is unknown).
func play(sound: String) -> void:
	if not GameManager.sound_enabled:
		return
	var s: AudioStream = _streams.get(sound)
	if s == null:
		return
	var p := _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = s
	p.play()
