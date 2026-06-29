class_name Puzzles

## Bundled Lichess puzzle set (CC0), used by Puzzle Rush. The CSV is `FEN,Moves,Rating` per line,
## sampled across rating bands 400-2699, ~240 per band (see assets/puzzles.txt). Lichess convention:
## Moves[0] is the setup move to apply to the FEN, then the side to move plays Moves[1], the opponent
## replies Moves[2], the player plays Moves[3], and so on (the player solves the odd indices; the last
## move is always the player's). Loaded once, lazily, and indexed by 100-point rating band so we can
## pick a puzzle near a target difficulty for the rising streak.

const PATH := "res://assets/puzzles.txt"  # plain text (not .csv: avoids Godot's CSV-translation import)

static var _all: Array = []            ## each: { fen:String, moves:PackedStringArray, rating:int }
static var _by_band: Dictionary = {}   ## band (rating/100) -> Array[int] of indices into _all


static func _ensure_loaded() -> void:
	if not _all.is_empty():
		return
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		push_warning("Puzzles: could not open %s" % PATH)
		return
	while not f.eof_reached():
		var line := f.get_line()
		if line.is_empty():
			continue
		var parts := line.split(",")
		if parts.size() < 3:
			continue
		var moves := parts[1].split(" ", false)
		if moves.size() < 2:
			continue  # need a setup move + at least one solution move
		var rating := int(parts[2])
		var idx := _all.size()
		_all.append({"fen": parts[0], "moves": moves, "rating": rating})
		var band := int(rating / 100)
		if not _by_band.has(band):
			_by_band[band] = []
		(_by_band[band] as Array).append(idx)


## Pick a puzzle whose rating is closest to `target_rating`, skipping any index already in `used`
## (so a streak never repeats one). Marks the chosen index in `used`. Returns
## { index:int, fen:String, moves:PackedStringArray, rating:int }, or {} if the set is empty.
static func pick(target_rating: int, used: Dictionary) -> Dictionary:
	_ensure_loaded()
	if _all.is_empty():
		return {}
	var target := clampi(target_rating, 400, 2600)
	var tb := int(target / 100)
	for d in range(0, 25):  # widen the band search outward until a band has an unused puzzle
		for band: int in ([tb] if d == 0 else [tb - d, tb + d]):
			if not _by_band.has(band):
				continue
			# A RANDOM unused puzzle from this band, so a streak isn't the exact same list every run.
			var pool: Array = []
			for idx: int in _by_band[band]:
				if not used.has(idx):
					pool.append(idx)
			if not pool.is_empty():
				var idx: int = pool[randi() % pool.size()]
				used[idx] = true
				var p: Dictionary = _all[idx]
				return {"index": idx, "fen": p["fen"], "moves": p["moves"], "rating": p["rating"]}
	return {}  # exhausted (only on absurdly long streaks); caller can reset `used`


static func count() -> int:
	_ensure_loaded()
	return _all.size()
