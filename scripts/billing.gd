extends Node

## Google Play Billing for the one-time Premium unlock (autoload "Billing").
##
## Wraps the GodotGooglePlayBilling addon's `BillingClient` node (installed under
## addons/GodotGooglePlayBilling/). On desktop/dev, where the Android plugin singleton is
## absent, it degrades gracefully: `available` stays false, the price falls back to
## DEFAULT_PRICE, and ONLY in a debug build the buy/restore stubs grant Premium locally so the
## screen can be exercised without Play. See HOW_TO.md for the Play Console setup.
##
## Entitlement is GRANT-ONLY: we upgrade to Premium when Play reports the purchase (a fresh buy,
## a restore, or a redeemed promo code) and NEVER auto-revoke, so an offline launch can't lock
## out a paying player. GameManager.is_premium is the persisted local cache; Play is the truth.

signal price_updated(formatted: String)   ## the localized price string changed
signal purchase_succeeded                  ## Premium granted (buy or restore)
signal purchase_failed(message: String)    ## a buy attempt failed (empty message = user cancelled)
signal restore_finished(found: bool)       ## a user-initiated "Restore" completed

const PRODUCT_ID := "premium_unlock"   ## Play Console managed product id (non-consumable)
const DEFAULT_PRICE := "$3.99"         ## shown until Play returns the localized price
## Reconnect backoff: Play can drop the billing connection; retry on a delay (not a tight loop)
## and give up after a few tries so a Play-less device can't drain the battery retrying.
const RECONNECT_DELAY := 5.0
const MAX_RECONNECTS := 8
## A user-tapped Restore re-queries once after this delay before reporting "nothing to restore",
## so a promo code redeemed outside the app that hasn't yet reached Play's on-device cache isn't
## reported as a definitive failure.
const RESTORE_RETRY_DELAY := 2.0

var available := false          ## the billing plugin singleton is present on this build
var connected := false          ## the billing service connection is up (the catalog may not be loaded)
var store_ready := false        ## connected AND product details (the localized price) are known
var price_text := DEFAULT_PRICE
var _client: BillingClient = null
var _restoring := false         ## a user-tapped Restore is in flight (vs silent reconcile)
var _restore_pending := false   ## a Restore tapped before the connection was up; run it on connect
var _restore_retried := false   ## the one delayed re-query for the in-flight Restore has been spent
var _connecting := false
var _reconnect_attempts := 0


func _ready() -> void:
	if not Engine.has_singleton("GodotGooglePlayBilling"):
		return  # desktop / dev / plugin not installed → graceful no-op
	available = true
	_client = BillingClient.new()
	add_child(_client)  # BillingClient is a Node; keep it under the autoload
	_client.connected.connect(_on_connected)
	_client.disconnected.connect(_on_disconnected)
	_client.connect_error.connect(_on_connect_error)
	_client.query_product_details_response.connect(_on_product_details)
	_client.query_purchases_response.connect(_on_query_purchases)
	_client.on_purchase_updated.connect(_on_purchase_updated)
	_start_connection()


## App came back to the foreground: re-check entitlement (catches promo-code redemptions and
## purchases finished outside the app). The addon has no billing_resume signal, so we poll here.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED and available and _client != null and connected:
		_client.query_purchases(BillingClient.ProductType.INAPP)


# --- Public API (used by the Premium screen) ---

func can_purchase() -> bool:
	return (available and store_ready) or OS.is_debug_build()


## Launch the Google Play purchase flow for Premium. The outcome arrives via on_purchase_updated.
func buy() -> void:
	if available and store_ready:
		var result: Dictionary = _client.purchase(PRODUCT_ID)
		var code := int(result.get("response_code", BillingClient.BillingResponseCode.OK))
		if code == BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED:
			_client.query_purchases(BillingClient.ProductType.INAPP)  # reconcile + grant
		elif code != BillingClient.BillingResponseCode.OK:
			purchase_failed.emit(tr("The purchase could not be completed."))
		return  # OK: wait for on_purchase_updated
	if OS.is_debug_build():
		_grant()  # no Play on desktop → grant locally so the UI can be tested
		return
	purchase_failed.emit(tr("Purchases aren't available right now."))


## Re-check Play for an existing entitlement (manual "Restore" + redeemed promo codes).
func restore() -> void:
	if available and connected:
		_restoring = true
		_restore_retried = false
		_client.query_purchases(BillingClient.ProductType.INAPP)
		return
	if available and _client != null:
		# Connection isn't up yet (dropped, or product details never loaded): kick a connection
		# and run the purchase query the moment we connect, rather than reporting a false "not
		# found". Restoring must never hinge on the catalog/price being readable.
		_restore_pending = true
		_start_connection()
		return
	if OS.is_debug_build():
		restore_finished.emit(GameManager.is_premium)
		return
	restore_finished.emit(false)


# --- Connection ---

func _start_connection() -> void:
	if _connecting or _client == null:
		return
	_connecting = true
	_client.start_connection()


func _reconnect_later() -> void:
	if _connecting or not available:
		return
	if _reconnect_attempts >= MAX_RECONNECTS:
		if _restore_pending:  # gave up reconnecting with a Restore still queued: stop the spinner
			_restore_pending = false
			restore_finished.emit(GameManager.is_premium)
		return
	_reconnect_attempts += 1
	_connecting = true
	var tree := get_tree()
	if tree == null:
		_connecting = false
		return
	await tree.create_timer(RECONNECT_DELAY).timeout
	if available and _client != null:
		_client.start_connection()
	else:
		_connecting = false


func _on_connected() -> void:
	_connecting = false
	_reconnect_attempts = 0
	connected = true
	_client.query_product_details(PackedStringArray([PRODUCT_ID]), BillingClient.ProductType.INAPP)
	if _restore_pending:
		_restore_pending = false  # a Restore was tapped before we connected: resolve it from this query
		_restoring = true
		_restore_retried = false
	_client.query_purchases(BillingClient.ProductType.INAPP)  # reconcile on launch / pending restore


func _on_disconnected() -> void:
	connected = false
	store_ready = false
	_reconnect_later()


func _on_connect_error(_code: int, _msg := "") -> void:
	connected = false
	store_ready = false
	_connecting = false
	_reconnect_later()


# --- Plugin responses ---

func _on_product_details(response: Dictionary) -> void:
	for p in response.get("product_details", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var pid := str(p.get("product_id", PRODUCT_ID))
		if pid != PRODUCT_ID:
			continue
		var price := _extract_price(p)
		if price != "":
			price_text = price
			price_updated.emit(price_text)
	store_ready = true


## Result of a buy: success carries the purchase(s); USER_CANCELED is a silent no-op.
func _on_purchase_updated(response: Dictionary) -> void:
	var code := int(response.get("response_code", BillingClient.BillingResponseCode.OK))
	if code == BillingClient.BillingResponseCode.OK or response.has("purchases"):
		_handle_purchases(response)
	elif code == BillingClient.BillingResponseCode.USER_CANCELED:
		purchase_failed.emit("")  # cancelled: just re-enable the button, no error shown
	else:
		purchase_failed.emit(tr("The purchase could not be completed."))


func _on_query_purchases(response: Dictionary) -> void:
	var found := _handle_purchases(response)
	if not _restoring:
		return  # silent launch / resume reconcile: _handle_purchases already granted if owned
	if found or GameManager.is_premium:
		_restoring = false
		_restore_retried = false
		restore_finished.emit(true)
		return
	# Nothing found yet. A promo code redeemed outside the app can lag Play's on-device cache, so
	# re-query once after a short delay before telling the player there is nothing to restore.
	if not _restore_retried and connected and _client != null:
		_restore_retried = true
		_retry_restore_query()
		return
	_restoring = false
	_restore_retried = false
	restore_finished.emit(false)


## One delayed re-query for an in-flight Restore (see RESTORE_RETRY_DELAY). The response lands
## back in _on_query_purchases, where _restore_retried is now set so a second miss reports failure.
func _retry_restore_query() -> void:
	var tree := get_tree()
	if tree == null:
		_restoring = false
		_restore_retried = false
		restore_finished.emit(GameManager.is_premium)
		return
	await tree.create_timer(RESTORE_RETRY_DELAY).timeout
	if _restoring and connected and _client != null:
		_client.query_purchases(BillingClient.ProductType.INAPP)
	elif _restoring:
		_restoring = false
		_restore_retried = false
		restore_finished.emit(GameManager.is_premium)


# --- Purchase handling ---

## Grant Premium for any owned, valid Premium purchase, and acknowledge it if needed.
## Returns true if a Premium purchase was found. Grant-only: never revokes.
func _handle_purchases(response: Dictionary) -> bool:
	var found := false
	for pu in response.get("purchases", []):
		if typeof(pu) != TYPE_DICTIONARY or not _is_premium_purchase(pu):
			continue
		found = true
		# PurchaseState: PURCHASED=1, PENDING=2. Don't grant a pending purchase yet.
		var state := int(pu.get("purchase_state", BillingClient.PurchaseState.PURCHASED))
		if state != BillingClient.PurchaseState.PURCHASED:
			continue
		_grant()
		if not bool(pu.get("is_acknowledged", false)):
			var token := str(pu.get("purchase_token", ""))
			if token != "" and _client != null:
				_client.acknowledge_purchase(token)
	return found


func _is_premium_purchase(pu: Dictionary) -> bool:
	for pid in pu.get("product_ids", []):
		if str(pid) == PRODUCT_ID:
			return true
	return false


func _grant() -> void:
	if not GameManager.is_premium:
		GameManager.set_premium(true)
	if not _restoring:
		purchase_succeeded.emit()  # during a Restore, restore_finished carries the UI update


## Pull the localized formatted price from a one-time product's offer details.
func _extract_price(p: Dictionary) -> String:
	for o in p.get("one_time_purchase_offer_details_list", []):
		if typeof(o) == TYPE_DICTIONARY:
			var fp := str(o.get("formatted_price", ""))
			if fp != "":
				return fp
	return ""
