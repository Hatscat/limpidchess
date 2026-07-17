@tool
extends EditorExportPlugin

## Web export: copy the browser Stockfish (web/engine/*) beside the exported
## index.html. Those files are page assets the js transport loads as a Web Worker
## (see stockfish_engine.gd); web/ is .gdignore'd so they can never ride in the pck,
## and a plain post-export copy keeps `godot --export-release "Web" ...` one command.

const SRC_DIR := "res://web/engine"

var _dest_dir := ""


func _get_name() -> String:
	return "LimpidWebFiles"


func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform is EditorExportPlatformWeb


func _export_begin(features: PackedStringArray, _is_debug: bool, path: String, _flags: int) -> void:
	# Godot invokes _export_begin/_export_end on every registered plugin regardless of
	# _supports_platform (that only gates the platform-specific hooks), so gate on the
	# feature tag or this would copy the engine beside Android .aab exports too.
	if not features.has("web"):
		_dest_dir = ""
		return
	# `path` is the preset's export_path and may be project-relative (CLI exports).
	_dest_dir = path.get_base_dir()
	if _dest_dir.is_relative_path():
		_dest_dir = ProjectSettings.globalize_path("res://").path_join(_dest_dir)


func _export_end() -> void:
	if _dest_dir == "":
		return
	var src := ProjectSettings.globalize_path(SRC_DIR)
	var dir := DirAccess.open(src)
	if dir == null:
		push_error("LimpidWebFiles: %s is missing — the web build ships without Stockfish" % src)
		return
	for f in dir.get_files():
		if dir.copy(src.path_join(f), _dest_dir.path_join(f)) != OK:
			push_error("LimpidWebFiles: failed to copy %s to %s" % [f, _dest_dir])
	_dest_dir = ""
