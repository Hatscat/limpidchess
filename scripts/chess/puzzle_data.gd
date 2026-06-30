class_name PuzzleData
extends Resource

## The bundled Lichess puzzle set (CC0) embedded as a Godot RESOURCE so it ships reliably in every
## export. `raw` is the same `FEN,Moves,Rating` text as assets/puzzles.txt, one puzzle per line.
##
## Why a resource and not the plain .txt: a non-resource .txt depends on the export `include_filter`,
## which did NOT bundle the file on device (the puzzle run started then immediately ended / bounced
## home). Resources are always exported, so this loads reliably. assets/puzzles.txt stays as the
## human-editable source; regenerate the resource after editing it with:
##   godot --headless --path . -s res://scripts/dev/build_puzzles.gd

@export var raw := ""
