class_name StockfishEngine
extends Node

## Drives Stockfish over UCI. Two transports, picked automatically by start():
##   • "ext"  — the embedded native engine (the StockfishGD GDExtension). Used on
##              Android (and anywhere the extension is present). Stockfish runs on
##              its own thread inside the .so; we poll its output each frame.
##   • "pipe" — a Stockfish child process (desktop). All pipe I/O on a worker
##              thread so a search never blocks the UI.
## If neither is available, start() returns false and the game uses the built-in
## GDScript engine ([ChessBot]).
##
## ChessRules stays the source of truth for legality / SAN / draws / highlights.
## Public API (analyse / best_move) is identical for both transports.

signal _job_done(result: Dictionary)

## Mate scores fold into this centipawn magnitude so they sort above any real eval.
const MATE_BASE := 1000000

## Where to look for a desktop Stockfish binary. Override with LIMPID_STOCKFISH.
const CANDIDATES := [
	"user://stockfish",
	"/usr/games/stockfish",
	"/usr/bin/stockfish",
	"/usr/local/bin/stockfish",
]

## Safety timeout (wall-clock ms) on the extension poll loop, so a stuck engine
## can't hang us — and so it's independent of frame rate.
const EXT_TIMEOUT_MS := 15000

var available := false
var _mode := ""  # "ext" | "pipe" | ""

# --- ext transport ---
var _sf: Object = null

# --- pipe transport ---
var _io: FileAccess
var _pid := -1
var _thread: Thread
var _sem: Semaphore
var _mutex: Mutex
var _jobs: Array = []
var _alive := false


## Launch an engine. Prefers the embedded native one; falls back to a subprocess.
func start() -> bool:
	# 1. Embedded native engine (Android / wherever the extension is loaded).
	if ClassDB.class_exists("StockfishGD"):
		_sf = ClassDB.instantiate("StockfishGD")
		if _sf != null and bool(_sf.call("start")):
			_mode = "ext"
			available = true
			_sf.call("send", "uci")
			_sf.call("send", "isready")
			_sf.call("send", "setoption name Threads value 1")
			return true
		_sf = null

	# 2. Desktop subprocess over a pipe.
	var path := _resolve_binary()
	if path != "":
		var sf := OS.execute_with_pipe(path, [])
		if not sf.is_empty():
			_io = sf["stdio"]
			_pid = sf.get("pid", -1)
			_io.store_line("uci")
			_drain_until("uciok")
			_io.store_line("isready")
			_drain_until("readyok")
			_alive = true
			available = true
			_mode = "pipe"
			_sem = Semaphore.new()
			_mutex = Mutex.new()
			_thread = Thread.new()
			_thread.start(_worker)
			return true

	push_warning("StockfishEngine: no engine available; using built-in fallback.")
	return false


func stop() -> void:
	if _mode == "ext":
		if _sf != null:
			_sf.call("stop")
			_sf = null
	elif _mode == "pipe" and _alive:
		_alive = false
		if _sem:
			_sem.post()
		if _thread and _thread.is_started():
			_thread.wait_to_finish()
		if _io and _io.is_open():
			_io.store_line("quit")
			_io.close()
	available = false
	_mode = ""


# --- Public async API (await the result on the main thread) ---

func analyse(fen: String, multipv: int, depth: int) -> Array:
	if not available:
		return []
	var cmds := [
		"setoption name UCI_LimitStrength value false",
		"setoption name Skill Level value 20",
		"setoption name MultiPV value %d" % maxi(1, multipv),
		"position fen %s" % fen,
		"go depth %d" % depth,
	]
	var res: Dictionary = await _run(cmds)
	return res.get("lines", [])


func best_move(fen: String, opts: Dictionary) -> String:
	if not available:
		return ""
	var skill: int = clampi(opts.get("skill", 20), 0, 20)
	var movetime: int = opts.get("movetime", 200)
	var cmds := [
		"setoption name UCI_LimitStrength value false",
		"setoption name MultiPV value 1",
		"setoption name Skill Level value %d" % skill,
		"position fen %s" % fen,
		"go movetime %d" % maxi(10, movetime),
	]
	var res: Dictionary = await _run(cmds)
	return res.get("best", "")


func _run(cmds: Array) -> Dictionary:
	if _mode == "ext":
		return await _run_ext(cmds)
	elif _mode == "pipe":
		return await _run_pipe(cmds)
	return {}


# --- ext transport: poll the native engine each frame (no GDScript thread) ---

func _run_ext(cmds: Array) -> Dictionary:
	for c in cmds:
		_sf.call("send", c)
	var by_index := {}
	var deadline := Time.get_ticks_msec() + EXT_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		var lines: PackedStringArray = _sf.call("poll_lines")
		for line in lines:
			if line.begins_with("bestmove"):
				var bp := line.split(" ")
				return _build_result(by_index, bp[1] if bp.size() >= 2 else "")
			elif line.begins_with("info ") and line.find(" pv ") != -1 and line.find(" multipv ") != -1:
				var info := _parse_info(line)
				if not info.is_empty():
					by_index[info["k"]] = {"uci": info["uci"], "score": info["score"]}
		await get_tree().process_frame
	return _build_result(by_index, "")


# --- pipe transport: worker thread does blocking reads ---

func _run_pipe(cmds: Array) -> Dictionary:
	_mutex.lock()
	_jobs.append(cmds)
	_mutex.unlock()
	_sem.post()
	var result: Dictionary = await _job_done
	return result


func _worker() -> void:
	while true:
		_sem.wait()
		if not _alive:
			break
		_mutex.lock()
		var cmds: Array = _jobs.pop_front() if not _jobs.is_empty() else []
		_mutex.unlock()
		if cmds.is_empty():
			continue
		var result := _execute(cmds)
		call_deferred("emit_signal", "_job_done", result)


func _execute(cmds: Array) -> Dictionary:
	for cmd in cmds:
		_io.store_line(cmd)
	var by_index := {}
	var best := ""
	while _io.is_open() and not _io.eof_reached():
		var line := _io.get_line()
		if line.begins_with("bestmove"):
			var bp := line.split(" ")
			if bp.size() >= 2:
				best = bp[1]
			break
		elif line.begins_with("info ") and line.find(" pv ") != -1 and line.find(" multipv ") != -1:
			var info := _parse_info(line)
			if not info.is_empty():
				by_index[info["k"]] = {"uci": info["uci"], "score": info["score"]}
	return _build_result(by_index, best)


# --- Shared parsing ---

func _build_result(by_index: Dictionary, best: String) -> Dictionary:
	var lines: Array = by_index.values()
	lines.sort_custom(func(a, b): return a["score"] > b["score"])
	return {"best": best, "lines": lines}


func _parse_info(line: String) -> Dictionary:
	var p := line.split(" ", false)
	var k := -1
	var uci := ""
	var score := 0
	var i := 0
	while i < p.size():
		match p[i]:
			"multipv":
				k = int(p[i + 1]); i += 2
			"score":
				if p[i + 1] == "cp":
					score = int(p[i + 2])
				elif p[i + 1] == "mate":
					var m := int(p[i + 2])
					score = (MATE_BASE - absi(m)) * (1 if m > 0 else -1)
				i += 3
			"pv":
				uci = p[i + 1]
				i = p.size()
			_:
				i += 1
	if k == -1 or uci == "":
		return {}
	return {"k": k, "uci": uci, "score": score}


func _resolve_binary() -> String:
	var override := OS.get_environment("LIMPID_STOCKFISH")
	if override != "" and FileAccess.file_exists(override):
		return override
	for p in CANDIDATES:
		if FileAccess.file_exists(p):
			return ProjectSettings.globalize_path(p) if p.begins_with("user://") else p
	return ""


func _drain_until(token: String) -> void:
	while _io.is_open() and not _io.eof_reached():
		if _io.get_line() == token:
			return


func _exit_tree() -> void:
	stop()
