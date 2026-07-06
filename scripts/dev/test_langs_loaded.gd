extends SceneTree

## Dev-only headless check: every shipped locale is registered and resolves keys (a plain string, a
## %s placeholder string, and the multi-line bbcode credits block) to a NON-English translation, i.e.
## the .translation files imported cleanly and project.godot lists them all.
##   godot --headless --path . -s res://scripts/dev/test_langs_loaded.gd

const NEW := ["pt", "de", "it", "ru", "tr", "pl", "id", "vi", "uk", "el"]


func _initialize() -> void:
	var ok := true
	# the exact multi-line credits key (English source) lives in the About scene text
	var about: String = load("res://scenes/about.tscn").instantiate().get_node("Scroll/VBox/Credits").text

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

	TranslationServer.set_locale("en")
	print("LANGS LOADED TEST: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
