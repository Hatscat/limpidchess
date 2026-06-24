@tool
extends EditorExportPlugin

## Android manifest tweaks: strip policy-sensitive permissions the notification-scheduler .aar
## pulls in but Limpid Chess never uses.
##
## The godot-notification-scheduler .aar declares SCHEDULE_EXACT_ALARM and
## REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, but Limpid Chess only schedules INEXACT alarms
## (Notifications uses set_delay and never requests the exact-alarm or battery-exemption APIs).
## Both are needless surface on an otherwise minimal, no-tracking app, and
## REQUEST_IGNORE_BATTERY_OPTIMIZATIONS is actively risky: Google Play's Device and Network Abuse
## policy only allows narrow app types (messaging/calling, safety, task-automation, companion) to
## request a battery-optimization exemption, and merely declaring it can draw a rejection. A
## once-a-day reminder fires fine without it. The Android manifest merger honours tools:node="remove"
## from the app manifest, and Godot's generated manifest declares the xmlns:tools namespace.


func _get_name() -> String:
	return "LimpidManifestTweaks"


func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform is EditorExportPlatformAndroid


func _get_android_manifest_element_contents(_platform: EditorExportPlatform, _debug: bool) -> String:
	return """<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM" tools:node="remove" />
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" tools:node="remove" />"""
