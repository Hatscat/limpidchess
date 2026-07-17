class_name StockfishEngine
extends Node

## Drives Stockfish over UCI. Three transports, picked automatically by start():
##   • "ext"  — the embedded native engine (the StockfishGD GDExtension). Used on
##              Android (and anywhere the extension is present). Stockfish runs on
##              its own thread inside the .so; we poll its output each frame.
##   • "js"   — web builds: stockfish.js (single-threaded wasm) in a Web Worker on
##              the host page, bridged over JavaScriptBridge. The Worker keeps the
##              search off the main thread; we poll buffered lines each frame.
##   • "pipe" — a Stockfish child process (desktop). All pipe I/O on a worker
##              thread so a search never blocks the UI.
## If none is available, start() returns false and the game uses the built-in
## GDScript engine ([ChessBot]).
##
## ChessRules stays the source of truth for legality / SAN / draws / highlights.
## Public API (analyse / best_move / best_line) is identical across transports.

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

## Web engine file, served beside index.html (source of truth: web/engine/, copied on
## export by the limpid_export plugin). Its .wasm is resolved by the same basename.
const JS_ENGINE := "stockfish-18-lite-single.js"

## How long the first web search may wait on engine readiness: the boot handshake
## includes fetching + compiling the ~7 MB wasm, which can take a while on a phone.
const JS_READY_TIMEOUT_MS := 20000

## How long to wait for an abandoned (timed-out) web search to acknowledge "stop"
## with its bestmove before declaring the Worker wedged.
const JS_DRAIN_TIMEOUT_MS := 5000

var available := false
var _mode := ""  # "ext" | "js" | "pipe" | ""

# --- ext transport ---
var _sf: Object = null

# --- js transport ---
var _js_worker: JavaScriptObject = null
# Callbacks must stay referenced for the whole app: if they were dropped, the bridge
# would silently stop delivering worker messages (and a re-start() would re-wire them).
var _js_on_line: JavaScriptObject = null
var _js_on_error: JavaScriptObject = null
var _js_lines := PackedStringArray()  # UCI lines from the Worker, drained by _run_js
var _js_ready := false   # readyok seen after the boot handshake (wasm is compiled)
var _js_dirty := false   # a timed-out search may still be streaming; flush before the next one
# Session latch: the Worker errored or never became ready (bad deploy, wasm OOM).
# start() won't retry the js transport once this is set — a broken worker would just
# fail again, and re-paying the readiness timeout every game is worse than falling back.
var _js_failed := false

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


func _ready() -> void:
	# On web, spawn the Worker at app boot so the ~7 MB wasm fetch+compile overlaps
	# the menu screens instead of landing on the first turn. The engine is an
	# app-lifetime singleton anyway; this only moves its start forward.
	if OS.has_feature("web"):
		start()


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

	# 2. Web build: stockfish.js in a Web Worker (no subprocess, no GDExtension there).
	# _js_failed latches for the session — see its declaration.
	if OS.has_feature("web") and not _js_failed and _js_start():
		return true

	# 3. Desktop subprocess over a pipe.
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
	elif _mode == "js":
		if _js_worker != null:
			_js_worker.call("terminate")
			JavaScriptBridge.eval("window._limpidSf = null", true)  # drop the page's ref too
		_js_worker = null
		_js_ready = false
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
	if _mode == "js":
		return _js_worker != null  # any death path (error, wedge, stop) nulls it
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
	var line: Dictionary = await best_line(fen, opts)
	return String(line.get("move", ""))


## Like best_move(), but also returns the engine's principal variation (the expected best
## line for both sides) and the score, all from the one search. Used by the post-game review
## to show "here's the better continuation". Returns {move:String, pv:PackedStringArray, score:int};
## pv[0] is the best move, and falls back to [move] if the engine reported no line.
func best_line(fen: String, opts: Dictionary) -> Dictionary:
	if not available:
		return {"move": "", "pv": PackedStringArray(), "score": 0}
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
	var best: String = String(res.get("best", ""))
	var pv := PackedStringArray()
	var score := 0
	for L in res.get("lines", []):
		if String(L.get("uci", "")) == best:
			pv = L.get("pv", PackedStringArray())
			score = int(L.get("score", 0))
			break
	# A skill-limited search can return a bestmove that isn't the top MultiPV line's first move;
	# fall back to that line's PV (still the engine's principal variation) before the bare [best].
	if pv.is_empty():
		var ls: Array = res.get("lines", [])
		if not ls.is_empty():
			pv = ls[0].get("pv", PackedStringArray())
			score = int(ls[0].get("score", 0))
	if pv.is_empty() and best != "":
		pv = PackedStringArray([best])
	return {"move": best, "pv": pv, "score": score}


func _run(cmds: Array) -> Dictionary:
	if _mode != "ext" and _mode != "js" and _mode != "pipe":
		return {}
	# Every transport handles exactly ONE search at a time: the pipe's _job_done would
	# fan a single result to two awaiters, and two ext/js pollers would steal each
	# other's output lines. Serialize here so a second caller queues behind the first
	# instead of corrupting it — this is what makes the reveal-time bot-reply prefetch safe.
	while _run_busy:
		await _run_free
	_run_busy = true
	# Re-check after the gate: stop() (worker death, app teardown) can tear the
	# transport down while we waited — releasing this very gate is part of dying —
	# and dispatching on a dead mode would run a transport whose state is gone.
	var res: Dictionary
	if _mode == "ext":
		res = await _run_ext(cmds)
	elif _mode == "js":
		res = await _run_js(cmds)
	elif _mode == "pipe":
		res = await _run_pipe(cmds)
	else:
		res = {}
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
	var out := {}
	var deadline := Time.get_ticks_msec() + EXT_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		if _sf == null:
			break  # stopped under us (e.g. app quit mid-analyse)
		var lines: PackedStringArray = _sf.call("poll_lines")
		for line in lines:
			if _consume_line(line, by_index, out):
				return _build_result(by_index, String(out.get("best", "")))
		# Guard the frame await: on app teardown the loop can be gone, and awaiting it
		# would abort this coroutine before the gate is released in _run(). Bail cleanly
		# instead so _run_busy always resets. Engine.get_main_loop() (not get_tree()) so
		# the wait also works when the node is outside the tree (headless -s test scripts).
		var loop := Engine.get_main_loop() as SceneTree
		if loop == null:
			break
		await loop.process_frame
	return _build_result(by_index, "")


# --- js transport: stockfish.js in a Web Worker, bridged via JavaScriptBridge ---

## Spawn the Worker and kick off the UCI handshake. Returns false when the bridge is
## unusable (never on a real web export). The Worker fetches + compiles its wasm in
## the background and queues commands until then, so this returns immediately; the
## first _run_js awaits _js_ready (set by the handshake's readyok) before searching.
func _js_start() -> bool:
	_js_on_line = JavaScriptBridge.create_callback(_on_js_line)
	_js_on_error = JavaScriptBridge.create_callback(_on_js_error)
	var window: JavaScriptObject = JavaScriptBridge.get_interface("window")
	if window == null or _js_on_line == null or _js_on_error == null:
		return false
	# JS members are dynamic — go through set()/call() (the analyzer rejects dotted
	# access to undeclared members on a typed native class).
	window.set("_limpidSfOnLine", _js_on_line)
	window.set("_limpidSfOnError", _js_on_error)
	JavaScriptBridge.eval("""
		window._limpidSf = new Worker("%s");
		window._limpidSf.onmessage = (e) => window._limpidSfOnLine(String(e.data));
		window._limpidSf.onerror = () => window._limpidSfOnError();
	""" % JS_ENGINE, true)
	_js_worker = JavaScriptBridge.get_interface("_limpidSf")
	if _js_worker == null:
		return false
	_js_lines.clear()
	_js_ready = false
	_js_dirty = false
	_mode = "js"
	available = true
	_js_worker.call("postMessage", "uci")
	_js_worker.call("postMessage", "setoption name Hash value 16")
	_js_worker.call("postMessage", "isready")
	return true


func _on_js_line(args: Array) -> void:
	if args.is_empty():
		return
	# One postMessage per UCI line normally; split defensively anyway.
	for line in String(args[0]).split("\n", false):
		if line == "readyok":
			_js_ready = true
		_js_lines.append(line)


## Worker "error" event: the engine .js is missing/broken (bad deploy) or the Worker
## crashed. Latch the failure so in-flight and future searches bail to the GDScript
## fallback instead of stalling until their timeout.
func _on_js_error(_args: Array) -> void:
	_js_failed = true
	push_warning("StockfishEngine: web Worker failed; using built-in fallback.")
	stop()


func _run_js(cmds: Array) -> Dictionary:
	# First search of the session may wait on the wasm fetch+compile (see _js_start).
	var deadline := Time.get_ticks_msec() + JS_READY_TIMEOUT_MS
	while not _js_ready and not _js_failed and Time.get_ticks_msec() < deadline:
		var loop := Engine.get_main_loop() as SceneTree
		if loop == null:
			return _build_result({}, "")
		await loop.process_frame
	if not _js_ready and not _js_failed:
		# Never became ready and never errored: a stalled wasm fetch, or an init death
		# inside the Worker (those fire the worker-global unhandledrejection, NOT the
		# parent's Worker.onerror). Latch the failure so every later call falls back
		# immediately instead of re-paying this timeout.
		_js_failed = true
		push_warning("StockfishEngine: web engine never became ready; using built-in fallback.")
		stop()
	if _js_failed or _js_worker == null:
		return _build_result({}, "")
	# A search we abandoned on timeout may still be running in the Worker: its late
	# lines must not be parsed as ours. Stop it and swallow through its bestmove.
	if _js_dirty:
		await _js_drain_stale()
		if _js_failed or _js_worker == null:
			return _build_result({}, "")
	# Serialized by _run, so any still-buffered lines are stale (handshake echo /
	# drained-search tail). Drop them so they can't be mistaken for this search.
	_js_lines.clear()
	for c in cmds:
		_js_worker.call("postMessage", c)
	var by_index := {}
	var out := {}
	deadline = Time.get_ticks_msec() + EXT_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		if _js_failed or _js_worker == null:
			# Died mid-search: a truncated MultiPV set would mislabel "best" and skew
			# the grading reference — drop it so the caller falls back honestly.
			return _build_result({}, "")
		# No await inside the scan, so the callback can't grow the buffer under it.
		for line in _js_lines:
			if _consume_line(line, by_index, out):
				_js_lines.clear()
				return _build_result(by_index, String(out.get("best", "")))
		_js_lines.clear()
		# Same teardown guard as _run_ext: never abort the coroutine with the gate held.
		var loop := Engine.get_main_loop() as SceneTree
		if loop == null:
			break
		await loop.process_frame
	# Timed out with the Worker still searching: ask it to stop and make the next
	# search flush the stale stream before trusting anything (partial result returned,
	# mirroring _run_ext's timeout semantics).
	_js_dirty = true
	if _js_worker != null:
		_js_worker.call("postMessage", "stop")
	return _build_result(by_index, "")


## Swallow the tail of a search abandoned by a _run_js timeout: discard Worker lines
## until its terminating bestmove so they can't poison the next search's parse. The
## abandoned search was already told to stop.
func _js_drain_stale() -> void:
	var deadline := Time.get_ticks_msec() + JS_DRAIN_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		if _js_failed or _js_worker == null:
			return
		for line in _js_lines:
			if line.begins_with("bestmove"):
				_js_dirty = false
				return  # caller clears the buffer before the new search
		_js_lines.clear()
		var loop := Engine.get_main_loop() as SceneTree
		if loop == null:
			return
		await loop.process_frame
	# Still no bestmove: the Worker is wedged. Treat it as dead rather than risk
	# mixing two searches' output streams.
	_js_failed = true
	push_warning("StockfishEngine: web engine ignored stop; using built-in fallback.")
	stop()


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
	var out := {}
	# _alive lets a shutdown (stop()) break the read loop instead of waiting on
	# the engine's final "bestmove" (searches are bounded, so this just trims it).
	while _alive and _io.is_open() and not _io.eof_reached():
		if _consume_line(_io.get_line(), by_index, out):
			break
	return _build_result(by_index, String(out.get("best", "")))


# --- Shared parsing ---

## Feed one engine output line into the MultiPV accumulator. Returns true when the
## line is the search-ending "bestmove ..." — out["best"] then carries its UCI move
## ("" when malformed). Pure function: safe from the pipe worker thread too.
func _consume_line(line: String, by_index: Dictionary, out: Dictionary) -> bool:
	if line.begins_with("bestmove"):
		var bp := line.split(" ")
		out["best"] = bp[1] if bp.size() >= 2 else ""
		return true
	if line.begins_with("info ") and line.find(" pv ") != -1 and line.find(" multipv ") != -1:
		var info := _parse_info(line)
		if not info.is_empty():
			by_index[info["k"]] = {"uci": info["uci"], "score": info["score"], "pv": info["pv"]}
	return false


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
