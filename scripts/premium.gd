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
	var top: int = max(safe.position.y, 16)
	$Content.offset_top = top
	$Back.offset_top = top
	$Back.offset_bottom = top + 80
	Billing.price_updated.connect(_on_price_updated)
	Billing.purchase_succeeded.connect(_on_purchase_succeeded)
	Billing.purchase_failed.connect(_on_purchase_failed)
	Billing.restore_finished.connect(_on_restore_finished)
	Billing.redeem_started.connect(_on_redeem_started)
	GameManager.premium_changed.connect(_refresh)  # e.g. a revoke landing while we're open
	_refresh()
	if GameManager.returned_from_checkout:
		# Landed back from the checkout: the key is in their inbox, not in the app.
		GameManager.returned_from_checkout = false
		if not GameManager.is_premium:
			_set_status(tr("Your key is in your purchase email."))


## Web: the license check is a network round trip, so say something during it.
func _on_redeem_started() -> void:
	_set_status(tr("Checking your key…"))


## Back arrow (top-left) returns to Home, same as the Android back gesture.
func _on_back_pressed() -> void:
	GameManager.go_to_home()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		GameManager.go_to_home()


## Reflect the current entitlement + latest price. Buy/restore/redeem hide once Premium.
## On web there is no Play Billing: the same buttons drive the Lemon Squeezy checkout and
## the license-key redeem instead (see Billing), so only their labels differ.
func _refresh() -> void:
	var web := OS.has_feature("web")
	var premium := GameManager.is_premium
	price_label.text = tr("%s · one-time, forever") % Billing.price_text
	get_button.visible = not premium
	restore_button.visible = not premium
	status_label.visible = premium
	# On web the key IS the purchase record, so "Restore purchase" becomes "I have a key":
	# the same button, the same redeem flow, whether they just bought or are returning on
	# a new browser.
	restore_button.text = tr("I have a key") if web else tr("Restore purchase")
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
	if OS.has_feature("web"):
		# Opens the hosted checkout in a new tab; the key then arrives by email, so the
		# button must NOT go into a "Processing…" state we can never resolve. No status
		# either: nothing has been bought yet, and a green "your key is in your email"
		# before paying would be a lie. The line appears on the way BACK (?ls=ok).
		Billing.buy()
		return
	get_button.disabled = true
	get_button.text = tr("Processing…")
	Billing.buy()


func _on_restore_pressed() -> void:
	if OS.has_feature("web"):
		Billing.restore()  # opens the key prompt; status comes from its signals
		return
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
