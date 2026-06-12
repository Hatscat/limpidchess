class_name StockfishEngine
extends Node

## Drives the Stockfish chess engine over the UCI protocol via a child process.
##
## ChessRules stays the source of truth for legality / SAN / draws / highlights.
## This service only provides the BRAIN: a full-strength MultiPV analysis (for
## the best/decent/blunder options + grading) and a weakened reply move (for the
## bot). All pipe I/O happens on a dedicated worker thread so a search never
## blocks the UI; results come back on the main thread via an awaited signal.
##
## Desktop uses the system / bundled Stockfish binary. On Android the subprocess
## route doesn't work — a native build is needed (see HOW_TO.md / CLAUDE.md). If
## no binary is found, `start()` returns false and the game falls back to the
## built-in GDScript engine.

signal _job_done(result: Dictionary)

## Mate scores are folded into this centipawn magnitude so they sort above any
## real eval while still ordering faster mates first.
const MATE_BASE := 1000000

## Where to look for a Stockfish binary, in order. Override with the
## LIMPID_STOCKFISH environment variable, or a bundled binary extracted to user://.
const CANDIDATES := [
	"user://stockfish",
	"/usr/games/stockfish",
	"/usr/bin/stockfish",
	"/usr/local/bin/stockfish",
]

var available := false

var _io: FileAccess
var _pid := -1
var _thread: Thread
var _sem: Semaphore
var _mutex: Mutex
var _jobs: Array = []
var _alive := false


## Launch Stockfish and complete the UCI handshake. Returns false if unavailable.
func start() -> bool:
	var path := _resolve_binary()
	if path == "":
		push_warning("StockfishEngine: no binary found; falling back to built-in engine.")
		return false
	var sf := OS.execute_with_pipe(path, [])
	if sf.is_empty():
		push_warning("StockfishEngine: failed to launch %s" % path)
		return false
	_io = sf["stdio"]
	_pid = sf.get("pid", -1)
	# Handshake on the calling thread — fast, and no worker is reading yet.
	_io.store_line("uci")
	_drain_until("uciok")
	_io.store_line("isready")
	_drain_until("readyok")

	_alive = true
	available = true
	_sem = Semaphore.new()
	_mutex = Mutex.new()
	_thread = Thread.new()
	_thread.start(_worker)
	return true


func stop() -> void:
	if not _alive:
		return
	_alive = false
	if _sem:
		_sem.post()  # wake the worker so it can notice _alive and exit
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	if _io and _io.is_open():
		_io.store_line("quit")
		_io.close()
	available = false


# --- Public async API: call on the main thread, `await` the result ---

## Full-strength MultiPV analysis of `fen`. Returns an Array of
## { uci:String, score:int } in centipawns from the side-to-move's POV (mate
## folded to ±MATE_BASE), sorted best-first. Empty if unavailable.
func analyse(fen: String, multipv: int, depth: int) -> Array:
	if not _alive:
		return []
	var cmds := [
		"setoption name UCI_LimitStrength value false",
		"setoption name Skill Level value 20",
		"setoption name MultiPV value %d" % maxi(1, multipv),
		"position fen %s" % fen,
		"go depth %d" % depth,
	]
	var res: Dictionary = await _run({"cmds": cmds})
	return res.get("lines", [])


## A weakened reply move for `fen`. opts: { skill:int 0-20, movetime:int ms }.
## Returns a UCI move ("e2e4"), or "" if unavailable.
func best_move(fen: String, opts: Dictionary) -> String:
	if not _alive:
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
	var res: Dictionary = await _run({"cmds": cmds})
	return res.get("best", "")


# --- Internals ---

func _run(job: Dictionary) -> Dictionary:
	_mutex.lock()
	_jobs.append(job)
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
		var job: Dictionary = _jobs.pop_front() if not _jobs.is_empty() else {}
		_mutex.unlock()
		if job.is_empty():
			continue
		var result := _execute(job)
		call_deferred("emit_signal", "_job_done", result)


## Runs on the worker thread: write the commands, read until `bestmove`,
## collecting the latest MultiPV line per index.
func _execute(job: Dictionary) -> Dictionary:
	for cmd in job["cmds"]:
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
				i = p.size()  # pv is the last field
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
