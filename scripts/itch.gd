class_name Itch
extends RefCounted

## The itch.io build: `web/build_web.sh --itch` exports the "Web (itch)" preset, whose custom
## feature tag "itch" turns this on. itch.io plays the game in an iframe of its page, served from
## a folder of html-classic.itch.zone: ONE origin shared by every itch.io game, so that origin's
## storage, service workers and caches are every game's, not ours.
##
## Everything that build changes is here, behind Itch.on, or in build_web.sh's itch mode:
## - no PWA: the "Web (itch)" preset exports no service worker, no manifest and no page icons, and
##   GameManager._check_web_update() stays off (its navigator.locks.query() also throws in
##   Firefox's third-party frame);
## - nothing sold: an itch.io HTML5 page can only take donations, so Billing never starts the
##   Lemon Squeezy client, and the Premium screen sends the player where Premium is sold instead
##   (premium_url): the Google Play listing on Android, the website everywhere else. The itch
##   page is a funnel to the Android app;
## - its own save database: every Godot game on itch shares the IndexedDB database "/userfs", and
##   Emscripten's sync deletes or rewinds the files a game does not hold in memory, so
##   build_web.sh mounts our user folder as its own database (GODOT_CONFIG.persistentPaths);
##   GameManager's tab re-read takes the database name from there;
## - an itch-safe boot watchdog: its reset downloads our own files again and never touches the
##   origin's service workers or caches (web/boot_diagnostics.js, ITCH).
##
## Saves stay in the frame's storage, apart from the website's and the Android app's. Chrome and
## Firefox keep it; WebKit (Safari, every iPhone and iPad browser) drops it when the browser quits.

## True in the itch.io export. Custom feature tags are off when running from the editor or a
## script, so `-- --itch` turns it on there (validate.gd, screenshot.gd, desktop previews).
static var on: bool = OS.has_feature("itch") or "--itch" in OS.get_cmdline_user_args()
## An Android browser, where the Premium screen offers the Google Play listing. `-- --itch-android`
## previews that variant on desktop.
static var android: bool = OS.has_feature("web_android") or "--itch-android" in OS.get_cmdline_user_args()

## utm_source/utm_campaign let Play Console's store-listing report count the installs that came
## from itch.io (it only counts people who did not have the app yet).
const PLAY_URL := "https://play.google.com/store/apps/details?id=game.limpidchess&utm_source=itch.io&utm_campaign=premium"
const WEBSITE_URL := "https://limpidchess.lonebee.games/play/"


## Where the Premium screen sends the player: the Android app's listing on Android, the website
## (where Premium is sold and saves last) everywhere else, iPhones and desktops included.
static func premium_url() -> String:
	return PLAY_URL if android else WEBSITE_URL
