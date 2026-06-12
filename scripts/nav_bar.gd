extends Control

## Reusable bottom navigation bar.
## Hosting scenes set `current_tab` to one of: "play" | "bots" | "premium" | "about".
## The active tab gets a bright icon + underline; other tabs are dimmed.
## Tapping the active tab is a no-op; other taps navigate via GameManager.

const ACTIVE_COLOR := Color(1, 1, 1, 1)
const INACTIVE_COLOR := Color(1, 1, 1, 0.45)

# Tab name → GameManager navigation method
const TAB_ROUTES := {
	"play": "go_to_home",
	"bots": "go_to_bots",
	"premium": "go_to_premium",
	"about": "go_to_about",
}

@export var current_tab: String = "play"


func _ready() -> void:
	_configure_tab($Background/Tabs/PlayTab, "play")
	_configure_tab($Background/Tabs/BotsTab, "bots")
	_configure_tab($Background/Tabs/PremiumTab, "premium")
	_configure_tab($Background/Tabs/AboutTab, "about")


func _configure_tab(tab: Button, tab_name: String) -> void:
	var is_active := tab_name == current_tab
	var underline: ColorRect = tab.get_node("Underline")
	var icon: TextureRect = tab.get_node("VBox/Icon")
	var label: Label = tab.get_node("VBox/Label")

	underline.visible = is_active
	icon.modulate = ACTIVE_COLOR if is_active else INACTIVE_COLOR
	label.modulate = ACTIVE_COLOR if is_active else INACTIVE_COLOR

	if is_active:
		tab.focus_mode = Control.FOCUS_NONE
		tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	else:
		tab.pressed.connect(_on_tab_pressed.bind(tab_name))


func _on_tab_pressed(tab_name: String) -> void:
	var method: String = TAB_ROUTES.get(tab_name, "")
	if method != "" and GameManager.has_method(method):
		GameManager.call(method)
