extends SceneTree

## Dev-only headless check: every shipped locale is registered and resolves keys (a plain string, a
## %s placeholder string, and the multi-line bbcode credits block) to a NON-English translation, i.e.
## the .translation files imported cleanly and project.godot lists them all. Then, on the first
## frame (labels only show their translation inside the tree), the Premium screen's column must fit
## in every locale, with a long localized Play price on the buy button. That is the website/Android
## screen; run it again with `-- --itch` (and `-- --itch --itch-android`) for the itch.io build's.
## The other lines that once overflowed are checked too: the Bots header, the Home Puzzles card in
## both its states, and the two confirmation dialogs' titles, which must wrap.
##   godot --headless --path . -s res://scripts/dev/test_langs_loaded.gd

const NEW := ["pt", "de", "it", "ru", "tr", "pl", "id", "vi", "uk", "el"]
## Every locale we ship, for the row-completeness check below.
const ALL := ["fr", "es", "pt", "de", "it", "ru", "tr", "pl", "id", "vi", "uk", "el"]
## The day-streak strings. A missing CSV row produces NO error at all, it just falls back to raw
## English in that locale, so it has to be asserted explicitly.
const STREAK_KEYS := [
	"Day streak",
	"One game or one puzzle counts the day.",
	"Win or lose, it always counts.",
	"Days off are fine. Come back within %d days and your streak keeps going.",
	"Your best is always kept.",
	"Reminder: %s",
	"A game today?",
	"Play one game and your days keep counting.",
	"Daily reminder",
	"A gentle nudge to come back and play.",
]
## The itch.io build's Premium screen (premium.gd _refresh_itch), checked the same way.
const ITCH_KEYS := [
	"Premium is a one-time purchase in the Android app or on the website.",
	"Get it on Google Play",
	"Play on the website",
]
## The Premium screen's content column (its Content offsets) must hold every line: most phones are
## 720 logical px wide, and its labels and buttons don't wrap, so one line wider than the column
## pushes the whole screen off both edges. The Vietnamese and Indonesian "No ads" lines once did.
## Play's price is checked at its longest too ("Unlock Premium · COP 16.900,00"), since desktop
## only ever shows the default "$3.99"; premium.gd steps the button's text down to fit it.
const LONG_PRICE := "COP 16.900,00"

var _ok := true
var _frames := 0


func _initialize() -> void:
	var ok := true
	# the exact multi-line credits key (English source) lives in the About scene text
	var about_scene: Node = load("res://scenes/about.tscn").instantiate()
	var about: String = about_scene.get_node("Scroll/VBox/Credits").text
	about_scene.free()

	var loaded := TranslationServer.get_loaded_locales()
	for code in NEW:
		if not loaded.has(code):
			print("  FAIL: locale not loaded: ", code)
			ok = false
			continue
		TranslationServer.set_locale(code)
		var win := TranslationServer.translate("You win!")
		var wins := TranslationServer.translate("%s wins!")
		var cred := TranslationServer.translate(about)
		var plain_ok := win != "" and win != "You win!"
		var ph_ok := String(wins).contains("%s") and wins != "%s wins!"
		var cred_ok := cred != about and String(cred).contains("[b]") and String(cred).contains("[url=")
		if not (plain_ok and ph_ok and cred_ok):
			ok = false
		print("  %s: 'You win!'->'%s'  ph_ok=%s  credits_translated=%s" % [code, win, ph_ok, cred_ok])

	# Day-streak and itch rows: present in every locale, and their format placeholders survived
	# translation (a %d that came back as %s would crash the format operator at runtime).
	for code in ALL:
		TranslationServer.set_locale(code)
		var missing: Array = []
		for k: String in STREAK_KEYS + ITCH_KEYS:
			var t := TranslationServer.translate(k)
			if t == k:
				missing.append(k)
			elif k.contains("%d") and not String(t).contains("%d"):
				missing.append(k + " (lost %d)")
			elif k.contains("%s") and not String(t).contains("%s"):
				missing.append(k + " (lost %s)")
		if not missing.is_empty():
			ok = false
			print("  FAIL keys in ", code, ": ", missing)
	print("  streak + itch keys: checked %d in %d locales" % [STREAK_KEYS.size() + ITCH_KEYS.size(), ALL.size()])
	_ok = ok


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames > 1:
		# Frame 1 always ends in quit(): getting here means the check below died on an error.
		print("LANGS LOADED TEST: FAIL (the Premium check stopped on an error, see above)")
		quit(1)
		return false
	# Autoloads are not identifiers in a -s script, hence the lookups. Not Premium, so the buy
	# button shows, with the longest price; both put back afterwards.
	var billing: Node = root.get_node("Billing")
	var gm: Node = root.get_node("GameManager")
	var price: String = billing.get("price_text")
	var was_premium: bool = gm.get("is_premium")
	billing.set("price_text", LONG_PRICE)
	gm.set("is_premium", false)
	var wide: Array[String] = []
	for code: String in ["en"] + ALL:
		TranslationServer.set_locale(code)
		var premium: Node = load("res://scenes/premium.tscn").instantiate()
		root.add_child(premium)
		var content := premium.get_node("Content") as Control
		var column := int(content.offset_right - content.offset_left)
		var width := int(content.get_combined_minimum_size().x)
		if width > column:
			wide.append("%s %d px > %d" % [code, width, column])
		root.remove_child(premium)
		premium.free()
	billing.set("price_text", price)
	gm.set("is_premium", was_premium)
	if not wide.is_empty():
		_ok = false
		print("  FAIL Premium screen wider than its column: %s" % [wide])
	print("  premium column (%s, price %s): checked %d locales"
			% ["itch" if Itch.on else "website/Android", LONG_PRICE, ALL.size() + 1])

	# The other non-wrapping lines that once overflowed. The Bots header (back button + title) must
	# fit its own width, or the back arrow leaves the screen (es, fr did); the Home Puzzles card's
	# two-line title ("New"/"Resume" + "puzzle streak") must fit its fixed-size card, in both
	# states, or it spills out of the card (pt did).
	var spill: Array[String] = []
	var puzzle_index: int = gm.get("puzzle_index")
	for code: String in ["en"] + ALL:
		TranslationServer.set_locale(code)
		var bots: Node = load("res://scenes/bots.tscn").instantiate()
		root.add_child(bots)
		var header := bots.get_node("Header") as Control
		var header_room := int(header.offset_right - header.offset_left)
		var header_width := int(header.get_combined_minimum_size().x)
		if header_width > header_room:
			spill.append("%s Bots header %d px > %d" % [code, header_width, header_room])
		root.remove_child(bots)
		bots.free()
		var home: Node = load("res://scenes/home.tscn").instantiate()
		root.add_child(home)
		var card := home.get_node("Center/VBox/PuzzleRush") as Control
		for parked: int in [-1, 0]:   # no run parked ("New"), then one parked ("Resume")
			gm.set("puzzle_index", parked)
			home.call("_refresh_puzzle_button")
			var row_width := int((card.get_node("Row") as Control).get_combined_minimum_size().x)
			if row_width > int(card.custom_minimum_size.x):
				spill.append("%s Home Puzzles card%s %d px > %d"
						% [code, " (resume)" if parked >= 0 else "", row_width, int(card.custom_minimum_size.x)])
		root.remove_child(home)
		home.free()
	gm.set("puzzle_index", puzzle_index)
	# The confirmation dialogs' titles wrap inside their fixed cards rather than widen them (el did),
	# and the two dialogs stay identical. Not in the tree: puzzle_rush's _ready() would save.
	for path: String in ["res://scenes/game.tscn", "res://scenes/puzzle_rush.tscn"]:
		var scene: Node = load(path).instantiate()
		if (scene.get_node("ConfirmOverlay/Card/VBox/ConfirmTitle") as Label).autowrap_mode == TextServer.AUTOWRAP_OFF:
			spill.append("%s ConfirmTitle does not wrap" % path.get_file())
		scene.free()
	if not spill.is_empty():
		_ok = false
		print("  FAIL wider than their space: %s" % [spill])
	print("  Bots header, Home Puzzles card, confirm titles: checked %d locales" % [ALL.size() + 1])

	TranslationServer.set_locale("en")
	print("LANGS LOADED TEST: ", "PASS" if _ok else "FAIL")
	quit(0 if _ok else 1)
	return false
