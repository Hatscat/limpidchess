extends Node

## Google Play Billing for the one-time Premium unlock (autoload "Billing").
##
## Talks to the GodotGooglePlayBilling Android plugin (singleton "GodotGooglePlayBilling")
## when it is present. Everywhere else (desktop/dev, or an Android build before the plugin is
## installed) it degrades gracefully: `available` stays false, the price falls back to
## DEFAULT_PRICE, and ONLY in a debug build the buy/restore stubs grant Premium locally so the
## flow can be exercised without Play. See HOW_TO.md for the plugin + Play Console setup.
##
## Entitlement is GRANT-ONLY: we upgrade to Premium when Play reports the purchase (a fresh buy,
## a restore, or a redeemed promo code) and NEVER auto-revoke, so an offline launch can't lock
## out a paying player. GameManager.is_premium is the persisted local cache; Play is the truth.

signal price_updated(formatted: String)   ## the localized price string changed
signal purchase_succeeded                  ## Premium granted (buy or restore)
signal purchase_failed(message: String)    ## a buy attempt failed / was cancelled
signal restore_finished(found: bool)       ## a user-initiated "Restore" completed

## Plugin singleton + product identifiers. If you adopt a billing plugin that exposes a
## different singleton name, change SINGLETON; PRODUCT_ID must match the Play Console product.
const SINGLETON := "GodotGooglePlayBilling"
const PRODUCT_ID := "premium_unlock"   ## Play Console managed product id (non-consumable)
const PRODUCT_TYPE := "inapp"          ## one-time product (not "subs")
const DEFAULT_PRICE := "$3.99"         ## shown until Play returns the localized price
## Google Play promo-code redemption page (friends/family codes are redeemed in the Play Store,
## then flow back to us via queryPurchases on resume / Restore).
const REDEEM_URL := "https://play.google.com/redeem"

## Reconnect backoff: Play can drop the billing connection; we retry on a delay (not a tight
## loop) and give up after a few tries so a Play-less device can't drain the battery retrying.
const RECONNECT_DELAY := 5.0
const MAX_RECONNECTS := 8

var available := false          ## the billing plugin is present on this build
var store_ready := false        ## connected to Play AND product details are known
var price_text := DEFAULT_PRICE
var _billing: Object = null
var _restoring := false         ## a user-tapped Restore is in flight (vs silent reconcile)
var _connecting := false        ## a connection attempt is in flight (guards reconnect storms)
var _reconnect_attempts := 0


func _ready() -> void:
	if not Engine.has_singleton(SINGLETON):
		return  # desktop / dev / plugin not installed → graceful no-op
	_billing = Engine.get_singleton(SINGLETON)
	available = true
	_bind("connected", _on_connected)
	_bind("disconnected", _on_disconnected)
	_bind("connect_error", _on_connect_error)
	_bind("billing_resume", _on_billing_resume)
	_bind("product_details_query_completed", _on_product_details)
	_bind("product_details_query_error", _on_product_details_error)
	_bind("purchases_updated", _on_purchases_updated)
	_bind("purchase_error", _on_purchase_error)
	_bind("query_purchases_response", _on_query_purchases)
	_bind("purchase_acknowledged", _on_purchase_acknowledged)
	_bind("purchase_acknowledgement_error", _on_ack_error)
	_start_connection()


## Connect a plugin signal only if it exists, so a plugin whose API differs slightly doesn't
## spam startup errors (the rest of the flow still works with whatever signals are present).
func _bind(sig: String, fn: Callable) -> void:
	if _billing.has_signal(sig):
		_billing.connect(sig, fn)
	else:
		push_warning("Billing: plugin singleton has no signal '%s'" % sig)


## Start a connection unless one is already in flight (avoids reconnect storms).
func _start_connection() -> void:
	if _connecting or _billing == null:
		return
	_connecting = true
	_billing.startConnection()


## Reconnect after a delay (Play dropped us / a connect attempt failed), bounded by MAX_RECONNECTS.
func _reconnect_later() -> void:
	if _connecting or not available or _reconnect_attempts >= MAX_RECONNECTS:
		return
	_reconnect_attempts += 1
	_connecting = true
	var tree := get_tree()
	if tree == null:
		_connecting = false
		return
	await tree.create_timer(RECONNECT_DELAY).timeout
	if available and _billing != null:
		_billing.startConnection()  # stays "connecting" until connected / connect_error resolves it
	else:
		_connecting = false


# --- Public API (used by the Premium screen) ---

## Can a purchase be initiated right now? (Or a dev grant in a debug build.)
func can_purchase() -> bool:
	return (available and store_ready) or OS.is_debug_build()


## Launch the Google Play purchase flow for Premium.
func buy() -> void:
	if available and store_ready:
		_billing.purchase(PRODUCT_ID)
		return
	if OS.is_debug_build():
		_grant()  # no Play on desktop → grant locally so the UI can be tested
		return
	purchase_failed.emit(tr("Purchases aren't available right now."))


## Re-check Play for an existing entitlement (manual "Restore" + redeemed promo codes).
func restore() -> void:
	if available and store_ready:
		_restoring = true
		_billing.queryPurchases(PRODUCT_TYPE)
		return
	if OS.is_debug_build():
		restore_finished.emit(GameManager.is_premium)
		return
	restore_finished.emit(false)


## Open the Play Store promo-code redemption page (friends/family codes).
func open_redeem_page() -> void:
	OS.shell_open(REDEEM_URL)


# --- Plugin callbacks ---

func _on_connected() -> void:
	_connecting = false
	_reconnect_attempts = 0
	_billing.queryProductDetails(PackedStringArray([PRODUCT_ID]), PRODUCT_TYPE)
	_billing.queryPurchases(PRODUCT_TYPE)  # silently reconcile a prior purchase on launch


func _on_disconnected() -> void:
	store_ready = false
	_reconnect_later()


func _on_connect_error(_code: int, _msg: String) -> void:
	store_ready = false
	_connecting = false
	_reconnect_later()


func _on_billing_resume() -> void:
	if available:
		_billing.queryPurchases(PRODUCT_TYPE)  # app resumed → re-check (catches redemptions)


func _on_product_details(details) -> void:
	for d in details:
		if typeof(d) != TYPE_DICTIONARY:
			continue
		if not _matches_product(d):
			continue
		var price := _extract_price(d)
		if price != "":
			price_text = price
			price_updated.emit(price_text)
	store_ready = true


func _on_product_details_error(_code: int, _msg: String, _ids = null) -> void:
	pass  # keep DEFAULT_PRICE; without details buy() reports "unavailable"


func _on_purchases_updated(purchases) -> void:
	_handle_purchases(purchases)


func _on_purchase_error(_code: int, msg := "") -> void:
	purchase_failed.emit(_friendly(msg))


func _on_query_purchases(result) -> void:
	var purchases = result.get("purchases", []) if typeof(result) == TYPE_DICTIONARY else result
	var found := _handle_purchases(purchases)
	if _restoring:
		_restoring = false
		restore_finished.emit(found or GameManager.is_premium)


func _on_purchase_acknowledged(_token := "") -> void:
	pass  # entitlement was already granted in _handle_purchases


func _on_ack_error(_code: int, _msg := "", _token := "") -> void:
	pass  # harmless: an unacknowledged purchase is re-acknowledged on the next launch


# --- Purchase handling ---

## Grant Premium for any owned, valid Premium purchase, and acknowledge it if needed.
## Returns true if a Premium purchase was found. Grant-only: never revokes.
func _handle_purchases(purchases) -> bool:
	if purchases == null:
		return false
	var found := false
	for p in purchases:
		if typeof(p) != TYPE_DICTIONARY or not _matches_product(p):
			continue
		found = true
		# purchase_state: 1 = PURCHASED, 2 = PENDING (don't grant a pending purchase yet).
		var state := int(p.get("purchase_state", p.get("purchaseState", 1)))
		if state != 1:
			continue
		_grant()
		var acked := bool(p.get("is_acknowledged", p.get("isAcknowledged", false)))
		if not acked:
			var token := str(p.get("purchase_token", p.get("purchaseToken", "")))
			if token != "" and available:
				_billing.acknowledgePurchase(token)
	return found


## True if a product-detail / purchase dict refers to our Premium product. Billing Library 5+
## reports a "products" array; older shapes use a "product_id" / "productId" string.
func _matches_product(d: Dictionary) -> bool:
	if d.has("products"):
		var prods = d["products"]
		if typeof(prods) == TYPE_ARRAY or typeof(prods) == TYPE_PACKED_STRING_ARRAY:
			for pid in prods:
				if str(pid) == PRODUCT_ID:
					return true
		return false
	return str(d.get("product_id", d.get("productId", ""))) == PRODUCT_ID


func _grant() -> void:
	if not GameManager.is_premium:
		GameManager.set_premium(true)
	if not _restoring:
		purchase_succeeded.emit()  # during a Restore, restore_finished carries the UI update


## Pull the localized formatted price from a one-time product's offer details.
func _extract_price(d: Dictionary) -> String:
	var offer = d.get("one_time_purchase_offer_details", d.get("oneTimePurchaseOfferDetails", null))
	if typeof(offer) == TYPE_DICTIONARY:
		var fp := str(offer.get("formatted_price", offer.get("formattedPrice", "")))
		if fp != "":
			return fp
	return str(d.get("formatted_price", d.get("price", "")))  # some plugin builds flatten it


func _friendly(msg: String) -> String:
	return msg if msg != "" else tr("The purchase could not be completed.")
