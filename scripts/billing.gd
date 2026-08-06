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
##
## On WEB there is no Play: the same public API (can_purchase / buy / restore + the four signals)
## is served by Lemon Squeezy license keys instead — buy() opens the hosted checkout, the key
## arrives by email, and redeem() activates it (see [LemonSqueezy]). The one place web differs
## from the grant-only rule is a key the store POSITIVELY rejects (refund / chargeback), and even
## then only when we could actually reach the store; anything ambiguous keeps Premium.

signal price_updated(formatted: String)   ## the localized price string changed
signal purchase_succeeded                  ## Premium granted (buy or restore)
signal purchase_failed(message: String)    ## a buy attempt failed (empty message = user cancelled)
signal restore_finished(found: bool)       ## a user-initiated "Restore" completed
signal redeem_started                      ## web: a license key is being checked

const PRODUCT_ID := "premium_unlock"   ## Play Console managed product id (non-consumable)
const DEFAULT_PRICE := "$3.99"         ## shown until Play returns the localized price
## Web price. Lemon Squeezy has no price API we can call without a secret key, so this
## mirrors the product's price in the dashboard — keep the two in sync by hand.
const WEB_PRICE := "€4.99"
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
var _ls: LemonSqueezy = null   ## web only: the license-key client
var _redeeming := false        ## a key activation is in flight (guards double taps)


func _ready() -> void:
	if OS.has_feature("web"):
		_ls = LemonSqueezy.new()
		add_child(_ls)
		price_text = WEB_PRICE
		_revalidate()
		return  # no Play in a browser; the rest of this file is the Play path
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
		if not store_ready:
			# Catalog never loaded (a transient product-details miss, e.g. Play propagation lag just
			# after publishing): re-fetch it so a configured build self-heals to purchasable without an
			# app restart, instead of "Purchases aren't available" lingering.
			_client.query_product_details(PackedStringArray([PRODUCT_ID]), BillingClient.ProductType.INAPP)


# --- Public API (used by the Premium screen) ---

func can_purchase() -> bool:
	if _ls != null:
		return true  # web: the hosted checkout is always reachable
	return (available and store_ready) or OS.is_debug_build()


## Launch the Google Play purchase flow for Premium. The outcome arrives via on_purchase_updated.
## On web, open the Lemon Squeezy checkout instead; the player returns with a key by email.
func buy() -> void:
	if _ls != null:
		_open_checkout()
		return
	if available and store_ready:
		var result: Dictionary = _client.purchase(PRODUCT_ID)
		var code := int(result.get("response_code", BillingClient.BillingResponseCode.OK))
		if code == BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED:
			_client.query_purchases(BillingClient.ProductType.INAPP)  # reconcile + grant
		elif code != BillingClient.BillingResponseCode.OK:
			if OS.is_debug_build():
				_grant()  # dev build: Play declined (e.g. unconfigured product) → unlock locally to test
			else:
				purchase_failed.emit(tr("The purchase could not be completed."))
		return  # OK: wait for on_purchase_updated
	if OS.is_debug_build():
		_grant()  # no Play on desktop → grant locally so the UI can be tested
		return
	purchase_failed.emit(tr("Purchases aren't available right now."))


## Re-check Play for an existing entitlement (manual "Restore" + redeemed promo codes).
## On web "restore" is the same act as buying-then-redeeming: paste the key again.
func restore() -> void:
	if _ls != null:
		redeem()
		return
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


# --- Web: Lemon Squeezy license keys ---

## Open the hosted checkout. window.open can be swallowed by a strict popup blocker
## (Safari), so fall back to navigating this tab rather than leaving a dead button.
func _open_checkout() -> void:
	var url := LemonSqueezy.CHECKOUT_URL
	JavaScriptBridge.eval(
		"if (!window.open(%s, '_blank')) location.assign(%s);" % [JSON.stringify(url), JSON.stringify(url)],
		true)


## Ask for a license key and activate it. The browser's own prompt is deliberate: it
## has paste on every platform including iOS Safari, and it keeps the game free of
## text fields (Godot's web virtual-keyboard handling is the thing we're avoiding).
func redeem() -> void:
	if _redeeming or _ls == null:
		return
	# A browser that suppresses dialogs ("prevent this page from creating more dialogs")
	# returns undefined from prompt(); the sentinel tells that apart from a real cancel,
	# so the button explains itself instead of doing nothing forever.
	var entered: Variant = JavaScriptBridge.eval("""
		(function () {
			try { var r = window.prompt(%s, ''); return (r === undefined) ? '\\u0001blocked' : r; }
			catch (e) { return '\\u0001blocked'; }
		})()
	""" % JSON.stringify(tr("Paste your license key")), true)
	if typeof(entered) == TYPE_STRING and String(entered) == "blocked":
		purchase_failed.emit(tr("Couldn't reach the store. Try again."))
		return
	# Cancelling the prompt is a silent no-op: no signal, so the screen says nothing
	# (emitting restore_finished(false) here would scold them with "no purchase found").
	if typeof(entered) != TYPE_STRING:
		return
	var key := String(entered).strip_edges()
	if key == "":
		return
	_redeeming = true
	redeem_started.emit()  # the round trip can take seconds; the screen says so
	var res: Dictionary = await _ls.activate(key)
	_redeeming = false
	# Exactly one outcome signal, so the screen shows one message: _grant() emits
	# purchase_succeeded ("You're Premium"), which reads right for both a first redeem
	# and a re-redeem on a new browser.
	match int(res.get("result", LemonSqueezy.UNKNOWN)):
		LemonSqueezy.OK:
			GameManager.set_license(key, str(res.get("instance_id", "")))
			_grant()
		LemonSqueezy.INVALID:
			purchase_failed.emit(tr("That key wasn't recognized."))
		_:
			purchase_failed.emit(tr("Couldn't reach the store. Try again."))


## Once a day, re-check a stored key so a refunded purchase eventually stops unlocking
## Premium. Fail-open by construction: only a positive INVALID from the store revokes,
## so offline launches, timeouts and outages leave a paying player alone.
##
## The stored key is NEVER deleted here. It is the player's proof of purchase and the
## only thing that can undo a mistaken revoke: if a later check says OK, Premium comes
## back by itself on the next launch, with nothing for them to do.
func _revalidate() -> void:
	var key := GameManager.license_key
	if _ls == null or key == "":
		return
	var today := Time.get_date_string_from_system()
	if GameManager.license_checked_date == today and GameManager.is_premium:
		return
	var state: int = await _ls.validate(key, GameManager.license_instance)
	if state == LemonSqueezy.OK:
		GameManager.set_license_checked(today)
		if not GameManager.is_premium:
			_grant()  # self-heal: a wrongly-revoked player is restored silently
	elif state == LemonSqueezy.INVALID and GameManager.is_premium:
		GameManager.set_premium(false)


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
	var found_product := false
	for p in response.get("product_details", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var pid := str(p.get("product_id", PRODUCT_ID))
		if pid != PRODUCT_ID:
			continue
		found_product = true
		var price := _extract_price(p)
		if price != "":
			price_text = price
			price_updated.emit(price_text)
	# "Ready to buy" ONLY if Play actually returned our product. Otherwise launching the purchase flow
	# would hit an unknown product and Play shows an error dialog; instead buy() falls through to the
	# debug-build local grant (a sideloaded dev build has no live Play product).
	store_ready = found_product


## Result of a buy: success carries the purchase(s); USER_CANCELED is a silent no-op.
func _on_purchase_updated(response: Dictionary) -> void:
	var code := int(response.get("response_code", BillingClient.BillingResponseCode.OK))
	if code == BillingClient.BillingResponseCode.OK or response.has("purchases"):
		_handle_purchases(response)
	elif code == BillingClient.BillingResponseCode.USER_CANCELED:
		purchase_failed.emit("")  # cancelled: just re-enable the button, no error shown
	elif OS.is_debug_build():
		_grant()  # dev build: any Play error unlocks locally so Premium stays testable without a live product
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
