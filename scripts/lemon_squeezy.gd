class_name LemonSqueezy
extends Node

## Lemon Squeezy license keys: the WEB build's Premium unlock ([Billing] owns the
## Play flow and instantiates this only on web).
##
## No backend and no API key: the /licenses/ endpoints authenticate with the license
## key itself and answer `Access-Control-Allow-Origin: *`, so the browser calls them
## directly. That is the whole reason this fits the project's no-backend rule.
##
## Everything here FAILS OPEN. A network error, a timeout or an unparseable answer is
## reported as "unknown", never as "invalid", so an offline launch can never cost a
## paying player their Premium (see Billing._revalidate).

## --- Store wiring ---
## Test and live are separate Lemon Squeezy environments: a product copied to live mode
## gets a NEW id and a NEW checkout url. GO-LIVE IS ONE EDIT: fill the LIVE_* values and
## set TEST_STORE := false. Nothing else changes.
##
## Shipping with TEST_STORE = true would hand out Premium for free (test cards work and
## test keys are accepted), so `web/build_web.sh --deploy` REFUSES to publish while it
## is set. That guard is the real protection; this comment is not.
const TEST_STORE := false

const TEST_CHECKOUT_URL := "https://lonebee.lemonsqueezy.com/checkout/buy/7c13932f-f04b-4075-ad2c-c02d3d2a8e0e"
const TEST_PRODUCT_IDS: Array[int] = [1267657]
const LIVE_CHECKOUT_URL := "https://lonebee.lemonsqueezy.com/checkout/buy/c53c3897-df1c-484b-918f-d693d4fec7e2"
const LIVE_PRODUCT_IDS: Array[int] = [1278251]

## Keys are accepted only for these products, so a license bought from any other store
## on the platform (they all share one API) can't unlock this game.
static var PRODUCT_IDS: Array[int] = TEST_PRODUCT_IDS if TEST_STORE else LIVE_PRODUCT_IDS
static var CHECKOUT_URL: String = TEST_CHECKOUT_URL if TEST_STORE else LIVE_CHECKOUT_URL
## Test-mode keys only ever unlock a test-mode build.
const ACCEPT_TEST_KEYS := TEST_STORE

const API_BASE := "https://api.lemonsqueezy.com/v1/licenses/"
## The name shown beside the activation in the Lemon Squeezy dashboard.
const INSTANCE_NAME := "Limpid Chess (web)"
const TIMEOUT_SEC := 15.0

## Outcomes. OK = entitled; INVALID = the store positively denied this key (refunded,
## disabled, wrong product); UNKNOWN = we could not tell (offline, timeout, bad JSON).
enum { OK, INVALID, UNKNOWN }


## Activate a key for this browser. Returns {result: int, instance_id: String}.
##
## A fresh key is "inactive" until its first activation, so activation must come first:
## validating an unused key would judge it on a status it hasn't earned yet.
func activate(key: String) -> Dictionary:
	var body := "license_key=%s&instance_name=%s" % [key.uri_encode(), INSTANCE_NAME.uri_encode()]
	var res := await _post("activate", body)
	if res.is_empty():
		return {"result": UNKNOWN, "instance_id": ""}
	if bool(res.get("activated", false)):
		var inst: Dictionary = res.get("instance", {})
		return {"result": _judge(res), "instance_id": str(inst.get("id", ""))}
	# Refused. That covers a dead key AND a perfectly good key that simply can't take
	# another activation (limit reached after storage evictions forced re-pastes), so
	# ask validate — which consumes nothing — before calling a paying player a fraud.
	return {"result": await validate(key, ""), "instance_id": ""}


## Re-check a stored key. `instance_id` may be "" (validates the key alone).
func validate(key: String, instance_id: String) -> int:
	var body := "license_key=" + key.uri_encode()
	if instance_id != "":
		body += "&instance_id=" + instance_id.uri_encode()
	var res := await _post("validate", body)
	if res.is_empty():
		return UNKNOWN
	if bool(res.get("valid", false)):
		return _judge(res)
	# NOT valid. Only a denial that names the KEY is a verdict; a rate limit (429), a
	# proxy's error page, or an instance we no longer recognise must stay UNKNOWN, or
	# a bad afternoon at the API would revoke every paying player at once.
	var err := str(res.get("error", "")).to_lower()
	if err.find("not found") != -1 or err.find("disabled") != -1 or err.find("expired") != -1:
		return INVALID
	var lk: Dictionary = res.get("license_key", {})
	var status := str(lk.get("status", ""))
	if status == "disabled" or status == "expired":
		return INVALID
	return UNKNOWN


## Judge a response the store considered successful: is this a live key for one of OUR
## products? UNKNOWN (not INVALID) when the payload isn't the shape we know, so an API
## change can't mass-revoke.
func _judge(res: Dictionary) -> int:
	var lk: Dictionary = res.get("license_key", {})
	var meta: Dictionary = res.get("meta", {})
	if lk.is_empty() or meta.is_empty():
		return UNKNOWN
	if str(lk.get("status", "")) != "active":
		return INVALID
	if bool(lk.get("test_mode", false)) and not ACCEPT_TEST_KEYS:
		return INVALID
	if not (int(meta.get("product_id", 0)) in PRODUCT_IDS):
		return INVALID  # a key for some other product on the platform
	return OK


## POST a form-encoded body. Returns the parsed object, or {} for ANY transport-level
## failure (which the callers must treat as "unknown", never as "invalid").
func _post(endpoint: String, body: String) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_SEC
	add_child(http)
	var headers := [
		"Content-Type: application/x-www-form-urlencoded",
		"Accept: application/json",
	]
	var err := http.request(API_BASE + endpoint, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		return {}
	var res: Array = await http.request_completed
	http.queue_free()
	# res = [result, response_code, headers, body]
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		return {}
	var code := int(res[1])
	# 4xx from the license endpoints still carries a JSON verdict we want to read; only
	# a server-side failure (5xx) is unreadable.
	if code >= 500:
		return {}
	var parsed: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed
