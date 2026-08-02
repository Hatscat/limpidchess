/* limpid:boot_diagnostics — build_web.sh greps this marker to stay idempotent.
 *
 * Boot diagnostics + self-heal for the web build. build_web.sh inlines this into <head>
 * of the exported index.html, BEFORE index.js, so it is already listening when the
 * engine boots. It only ever adds passive listeners and never calls preventDefault or
 * stopPropagation, so it cannot change how input reaches the canvas.
 *
 * Godot's stock shell only surfaces *thrown* errors. A tab killed mid-wasm-compile, or
 * one served a bad cached response, sits at a full progress bar forever with nothing in
 * the DOM to report. This turns that into a visible message plus one-tap recovery, and
 * gives a phone-only tester something to screenshot.
 *
 *   <page>          watchdog only: panel appears if boot stalls past BOOT_TIMEOUT_MS
 *   <page>?debug=1  live pass-through panel (frame rate, sizes, taps, errors)
 *   <page>?reset=1  wipe service worker + caches, then boot clean
 *
 * Probes that answered their question have been removed; see README.md, "Ruled out by
 * measurement". Don't re-add one without reading that list first.
 */
(function () {
	'use strict';

	var BOOT_TIMEOUT_MS = 40000;
	var ACCENT = '#66bdd9';
	var DIM = '#b0beca';
	var BG = '#171a1f';

	var errors = [];
	var taps = 0;
	var ups = 0;
	var glInfo = '?';
	var glLost = 0;
	var frames = 0;
	var fps = 0;
	var fpsAt = 0;
	var engFrames = 0;   // rAF callbacks from anyone else, i.e. Godot's main loop
	var engFps = 0;
	var started = false;
	var overlay = null;
	var pre = null;
	var passThrough = false;

	function note(kind, msg) {
		errors.push(kind + ': ' + msg);
		if (errors.length > 4) {
			errors.shift();
		}
		render();
	}

	window.addEventListener('error', function (e) {
		note('error', (e && e.message) || 'unknown');
	}, true);
	window.addEventListener('unhandledrejection', function (e) {
		var r = e && e.reason;
		note('rejection', (r && (r.message || String(r))) || 'unknown');
	});

	// Godot prints its own failures to a console nobody can open on a phone.
	['error', 'warn'].forEach(function (level) {
		var orig = console[level];
		console[level] = function () {
			try {
				note(level, Array.prototype.join.call(arguments, ' ').slice(0, 160));
			} catch (e) { /* never let logging break the page */ }
			return orig.apply(console, arguments);
		};
	});

	// Two frame counters. `raf` is ours and only says the browser is painting; `engine`
	// counts rAF callbacks registered by anyone else, which here is emscripten's main
	// loop. A healthy browser with a dead engine is a different bug entirely, and no
	// other probe separates them. We run before index.js so the patched function is the
	// one emscripten picks up; the handle passes through so cancelAnimationFrame works.
	var rafOrig = window.requestAnimationFrame.bind(window);
	window.requestAnimationFrame = function (cb) {
		return rafOrig(function (t) {
			engFrames++;
			return cb(t);
		});
	};

	function tick(t) {
		frames++;
		if (t - fpsAt >= 1000) {
			fps = Math.round((frames * 1000) / (t - fpsAt));
			engFps = Math.round((engFrames * 1000) / (t - fpsAt));
			frames = 0;
			engFrames = 0;
			fpsAt = t;
		}
		rafOrig(tick);
	}
	rafOrig(tick);

	// Safari silently clamps a drawing buffer it cannot allocate. Read once, lazily: a
	// mismatch against the canvas would be a real finding and it costs nothing.
	function checkGL(c) {
		try {
			var gl = c.getContext('webgl2') || c.getContext('webgl');
			if (!gl) {
				glInfo = 'no context';
				return;
			}
			glInfo = gl.drawingBufferWidth + 'x' + gl.drawingBufferHeight
				+ ((gl.drawingBufferWidth !== c.width || gl.drawingBufferHeight !== c.height)
					? '  CLAMPED!' : ' ok');
		} catch (e) {
			glInfo = 'read failed';
		}
	}

	function probeCanvas(c) {
		c.addEventListener('touchstart', function () {
			taps++;
			render();
		}, { passive: true });
		c.addEventListener('touchend', function () {
			ups++;
			render();
		}, { passive: true });
		c.addEventListener('webglcontextlost', function () {
			glLost++;
			note('webgl', 'context lost');
		}, false);
		c.addEventListener('webglcontextrestored', function () {
			note('webgl', 'context restored');
		}, false);
	}

	function diagnostics() {
		var c = document.getElementById('canvas');
		if (c && glInfo === '?' && c.width > 1) {
			checkGL(c);
		}
		var out = [
			'raf ' + fps + ' / engine ' + engFps + 'fps' + (glLost ? '  GL LOST' : ''),
			'win ' + window.innerWidth + 'x' + window.innerHeight
				+ '  canvas ' + (c ? c.width + 'x' + c.height : '?'),
			'gl  ' + glInfo,
			'taps ' + taps + ' down, ' + ups + ' up',
			'started ' + started
		];
		if (errors.length) {
			out.push('err ' + errors[errors.length - 1].slice(0, 70));
		}
		return out.join('\n');
	}

	function render() {
		if (pre) {
			pre.textContent = diagnostics();
		}
	}

	/** Drop the service worker and every cache, then reload clean. */
	function hardReset() {
		var jobs = [];
		if (navigator.serviceWorker && navigator.serviceWorker.getRegistrations) {
			jobs.push(navigator.serviceWorker.getRegistrations().then(function (rs) {
				return Promise.all(rs.map(function (r) { return r.unregister(); }));
			}).catch(function () {}));
		}
		if (window.caches && caches.keys) {
			jobs.push(caches.keys().then(function (ks) {
				return Promise.all(ks.map(function (k) { return caches.delete(k); }));
			}).catch(function () {}));
		}
		Promise.all(jobs).then(function () {
			location.replace(location.pathname + '?fresh=' + Date.now());
		});
	}

	// Promote a service worker held in `waiting`. 'claim' makes it skipWaiting + claim
	// WITHOUT navigating clients, unlike 'update', so it cannot interrupt a game in
	// another tab: this page keeps what it loaded, the next launch gets the new cache.
	// GameManager._check_web_update() only promotes when it is the sole tab and online,
	// which strands a worker indefinitely for anyone browsing with other tabs open.
	// Unrelated to the iOS bug (the service worker is ruled out) — this is deploy
	// hygiene, so that a bad build is always fixable by shipping a good one. Keep it.
	function promoteServiceWorker() {
		if (!navigator.serviceWorker || !navigator.serviceWorker.getRegistration) {
			return;
		}
		navigator.serviceWorker.getRegistration().then(function (reg) {
			if (!reg) {
				return;
			}
			function promote() {
				if (reg.waiting && navigator.serviceWorker.controller) {
					reg.waiting.postMessage('claim');
				}
			}
			reg.addEventListener('updatefound', function () {
				var inst = reg.installing;
				if (inst) {
					inst.addEventListener('statechange', function () {
						if (inst.state === 'installed') {
							promote();
						}
					});
				}
			});
			try {
				reg.update();
			} catch (e) { /* offline */ }
			promote();
		}, function () { /* lookup failed */ });
	}

	function build(title, blurb) {
		var box = 'position:fixed;left:0;right:0;top:0;z-index:99999;background:' + BG + ';'
			+ 'color:#edf2f7;font:13px/1.4 -apple-system,system-ui,sans-serif;'
			+ (passThrough ? 'padding:8px 10px;' : 'padding:18px;')
			+ 'overflow:auto;-webkit-overflow-scrolling:touch;';
		// Pass-through sits over the top of the page but lets taps fall through to the
		// canvas, so the panel never interferes with what it is measuring.
		box += passThrough
			? 'max-height:33%;background:rgba(23,26,31,.92);pointer-events:none;'
			: 'bottom:0;';

		overlay = document.createElement('div');
		overlay.setAttribute('style', box);

		var h = document.createElement('div');
		h.setAttribute('style', 'font-weight:700;margin-bottom:2px;color:' + ACCENT
			+ (passThrough ? ';font-size:12px' : ';font-size:19px'));
		h.textContent = title;

		var p = document.createElement('div');
		p.setAttribute('style', 'color:' + DIM
			+ (passThrough ? ';display:none' : ';margin-bottom:12px'));
		p.textContent = blurb;

		pre = document.createElement('pre');
		pre.setAttribute('style', 'white-space:pre-wrap;word-break:break-word;font-size:11px;'
			+ 'background:#0f1216;padding:8px;border-radius:6px;color:' + DIM + ';margin:0');

		overlay.appendChild(h);
		overlay.appendChild(p);
		overlay.appendChild(pre);

		if (!passThrough) {
			var btn = document.createElement('button');
			btn.textContent = 'Reset and reload';
			btn.setAttribute('style', 'margin-top:14px;padding:12px 18px;font-size:15px;'
				+ 'border:0;border-radius:8px;background:' + ACCENT + ';color:#0f1216;'
				+ 'font-weight:700');
			btn.addEventListener('click', hardReset);
			overlay.appendChild(btn);
		}

		document.body.appendChild(overlay);
		render();
	}

	function watch() {
		var t0 = Date.now();
		var iv = setInterval(function () {
			// Godot's shell removes #status once startGame() resolves.
			if (!document.getElementById('status')) {
				started = true;
				clearInterval(iv);
				render();
				return;
			}
			if (Date.now() - t0 > BOOT_TIMEOUT_MS) {
				clearInterval(iv);
				if (!overlay) {
					build('Limpid Chess could not start',
						'Loading stalled. That is usually a bad cached copy, or the device '
						+ 'running out of memory. Tap below to clear it and try again.');
				}
			}
		}, 500);
	}

	function boot() {
		var q = location.search;
		if (q.indexOf('reset=1') !== -1) {
			hardReset();
			return;
		}
		var c = document.getElementById('canvas');
		if (c) {
			probeCanvas(c);
		}
		promoteServiceWorker();
		if (q.indexOf('debug=1') !== -1) {
			passThrough = true;
			build('Limpid Chess diagnostics', 'Tap a few times, then screenshot.');
			setInterval(render, 1000);
		}
		watch();
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', boot);
	} else {
		boot();
	}
}());
