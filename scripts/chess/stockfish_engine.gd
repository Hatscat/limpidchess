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
signal _run_free  ## fired when an in-flight search finishes, so a queued caller can start

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

# Serializes searches: the engine handles only one at a time (see _run).
var _run_busy := false

# --- pipe transport ---
var _io: FileAccess
var _pid := -1
var _thread: Thread
var _sem: Semaphore
var _mutex: Mutex
var _jobs: Array = []
var _alive := false


## Launch an engine. Prefers the embedded native one; falls back to a subprocess.
## Idempotent: this is an autoload reused across games, and the embedded native
## engine is a process-singleton that can't be re-created, so we start ONCE and
## keep it alive for the whole app (never stop() on a scene change).
func start() -> bool:
	if available:
		if _engine_alive():
			return true
		stop()  # the engine died under us (rare) → tear it down, then re-init below

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
	# Release the serialization gate defensively: if a search coroutine aborted mid-flight
	# (e.g. the node left the tree on app teardown), _run_busy could be latched true with no
	# one left to clear it, spinning every future _run() forever. Clearing it here keeps a
	# re-init (start → stop → start) clean.
	_run_busy = false
	_run_free.emit()


## Is the currently-selected transport actually still usable? Guards start() from
## reusing a dead engine (e.g. a crashed subprocess) across games.
func _engine_alive() -> bool:
	if _mode == "ext":
		return _sf != null
	if _mode == "pipe":
		return _pid > 0 and OS.is_process_running(_pid) and _io != null and _io.is_open()
	return false


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
	if _mode != "ext" and _mode != "pipe":
		return {}
	# Both transports handle exactly ONE search at a time: the pipe's _job_done would
	# fan a single result to two awaiters, and two ext pollers would steal each other's
	# output lines. Serialize here so a second caller queues behind the first instead of
	# corrupting it — this is what makes the reveal-time bot-reply prefetch safe.
	while _run_busy:
		await _run_free
	_run_busy = true
	var res: Dictionary
	if _mode == "ext":
		res = await _run_ext(cmds)
	else:
		res = await _run_pipe(cmds)
	_run_busy = false
	_run_free.emit()
	return res


# --- ext transport: poll the native engine each frame (no GDScript thread) ---

func _run_ext(cmds: Array) -> Dictionary:
	if _sf == null:
		return {}
	for c in cmds:
		_sf.call("send", c)
	var by_index := {}
	var deadline := Time.get_ticks_msec() + EXT_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		if _sf == null:
			break  # stopped under us (e.g. app quit mid-analyse)
		var lines: PackedStringArray = _sf.call("poll_lines")
		for line in lines:
			if line.begins_with("bestmove"):
				var bp := line.split(" ")
				return _build_result(by_index, bp[1] if bp.size() >= 2 else "")
			elif line.begins_with("info ") and line.find(" pv ") != -1 and line.find(" multipv ") != -1:
				var info := _parse_info(line)
				if not info.is_empty():
					by_index[info["k"]] = {"uci": info["uci"], "score": info["score"], "pv": info["pv"]}
		# Guard the frame await: if we've left the tree mid-search (app teardown / scene
		# change), get_tree() is null and awaiting it would abort this coroutine before the
		# gate is released in _run(). Bail cleanly instead so _run_busy always resets.
		var tree := get_tree()
		if tree == null:
			break
		await tree.process_frame
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
	if _io == null or not _io.is_open():
		return _build_result({}, "")  # pipe closed under us → caller falls back
	for cmd in cmds:
		_io.store_line(cmd)
	var by_index := {}
	var best := ""
	# _alive lets a shutdown (stop()) break the read loop instead of waiting on
	# the engine's final "bestmove" (searches are bounded, so this just trims it).
	while _alive and _io.is_open() and not _io.eof_reached():
		var line := _io.get_line()
		if line.begins_with("bestmove"):
			var bp := line.split(" ")
			if bp.size() >= 2:
				best = bp[1]
			break
		elif line.begins_with("info ") and line.find(" pv ") != -1 and line.find(" multipv ") != -1:
			var info := _parse_info(line)
			if not info.is_empty():
				by_index[info["k"]] = {"uci": info["uci"], "score": info["score"], "pv": info["pv"]}
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
	var pv := PackedStringArray()
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
				# "pv" is always the last token group on a UCI info line, so the whole
				# remainder is the principal variation (UCI moves), best move first.
				pv = p.slice(i + 1)
				uci = pv[0] if pv.size() > 0 else ""
				i = p.size()
			_:
				i += 1
	if k == -1 or uci == "":
		return {}
	return {"k": k, "uci": uci, "score": score, "pv": pv}


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
