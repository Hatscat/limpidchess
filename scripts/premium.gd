extends Control

## Premium screen. One-time purchase → unlimited games, all bots, and Face to Face.
##
## The actual store flow lives in the [Billing] autoload (Google Play). This screen just
## drives it and mirrors its signals: the price comes from Play (localized) and the buy/restore
## buttons call Billing. Promo codes are redeemed outside the app via a prefilled Play redeem
## link, then picked up by Billing's launch/resume reconcile (no in-app redeem button). On
## desktop/dev (no Play) Billing degrades gracefully and a debug build grants locally.

@onready var get_button: Button = %GetButton
@onready var restore_button: Button = %RestoreButton
@onready var status_label: Label = %StatusLabel
@onready var price_label: Label = %PriceLabel


func _ready() -> void:
	var safe := DisplayServer.get_display_safe_area()
	$Content.offset_top = max(safe.position.y, 16)
	Billing.price_updated.connect(_on_price_updated)
	Billing.purchase_succeeded.connect(_on_purchase_succeeded)
	Billing.purchase_failed.connect(_on_purchase_failed)
	Billing.restore_finished.connect(_on_restore_finished)
	_refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		GameManager.go_to_home()


## Reflect the current entitlement + latest price. Buy/restore/redeem hide once Premium.
func _refresh() -> void:
	price_label.text = tr("%s · one-time, forever") % Billing.price_text
	var premium := GameManager.is_premium
	get_button.visible = not premium
	restore_button.visible = not premium
	status_label.visible = premium
	if premium:
		_set_status(tr("✓ You're Premium. Thank you!"))
	else:
		get_button.disabled = false
		get_button.text = tr("Unlock Premium  ·  %s") % Billing.price_text


## Show a one-line status message (green for good news, soft red for a problem).
func _set_status(msg: String, ok := true) -> void:
	status_label.text = msg
	status_label.modulate = Color(0.4, 0.78, 0.52) if ok else Color(0.85, 0.5, 0.45)
	status_label.visible = true


func _on_get_pressed() -> void:
	get_button.disabled = true
	get_button.text = tr("Processing…")
	Billing.buy()


func _on_restore_pressed() -> void:
	_set_status(tr("Checking your purchases…"))
	Billing.restore()


func _on_price_updated(_formatted: String) -> void:
	if not GameManager.is_premium:
		_refresh()


func _on_purchase_succeeded() -> void:
	_refresh()
	_set_status(tr("✓ You're Premium. Thank you!"))


func _on_purchase_failed(message: String) -> void:
	get_button.disabled = false
	get_button.text = tr("Unlock Premium  ·  %s") % Billing.price_text
	if message != "":  # empty = user cancelled; just re-enable, no error shown
		_set_status(message, false)


func _on_restore_finished(found: bool) -> void:
	if found:
		_refresh()
		_set_status(tr("✓ Purchase restored. Thank you!"))
	else:
		_set_status(tr("No purchase found to restore."), false)
