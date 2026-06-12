extends Control

## Premium screen. Premium is a one-time purchase that unlocks unlimited games
## and Pass & Play. Per the design, the entitlement is stored LOCALLY (and could
## later be backed by Play Games / StoreKit) — we don't fight clock-cheaters.
##
## NOTE: the purchase here is a local stub. Real billing (Google Play Billing /
## StoreKit) is wired in later; _on_get_pressed() is where that call goes.

const PRICE := "$3.99"

@onready var get_button: Button = %GetButton
@onready var restore_button: Button = %RestoreButton
@onready var status_label: Label = %StatusLabel


func _ready() -> void:
	var safe := DisplayServer.get_display_safe_area()
	$Content.offset_top = max(safe.position.y, 16)
	%PriceLabel.text = "%s · one-time, forever" % PRICE
	_refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		GameManager.go_to_home()


func _refresh() -> void:
	if GameManager.is_premium:
		status_label.text = "✓ You're Premium. Thank you!"
		status_label.visible = true
		get_button.disabled = true
		get_button.text = "Unlocked"
	else:
		status_label.visible = false
		get_button.disabled = false
		get_button.text = "Unlock Premium  ·  %s" % PRICE


func _on_get_pressed() -> void:
	# TODO: replace with a real Google Play Billing / StoreKit purchase flow.
	# On a successful purchase callback, call GameManager.set_premium(true).
	GameManager.set_premium(true)
	_refresh()


func _on_restore_pressed() -> void:
	# TODO: query the store for an existing entitlement and restore it.
	_refresh()
