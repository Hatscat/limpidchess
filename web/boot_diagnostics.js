/* limpid:boot_diagnostics — build_web.sh greps this marker to stay idempotent.
 *
 * Boot diagnostics + self-heal for the web build.
 *
 * build_web.sh inlines this into <head> of the exported index.html, BEFORE index.js,
 * so it is already listening when the engine boots. It never calls preventDefault or
 * stopPropagation and only ever adds passive capture listeners, so it cannot change
 * how input reaches the canvas.
 *
 * Why it exists: iOS Safari failures on this project are unreproducible on the dev box
 * (no Apple device), and Godot's stock shell only surfaces *thrown* errors. A tab that
 * is OOM-killed mid-wasm-compile, or one served a poisoned service-worker cache entry,
 * just sits at a full progress bar forever with nothing in the DOM to report. This
 * turns both into a visible message plus a one-tap recovery.
 *
 *   <page>            watchdog only: a panel appears if boot stalls past BOOT_TIMEOUT_MS
 *   <page>?debug=1    live pass-through overlay (touch probe, canvas rect, storage)
 *   <page>?reset=1    wipe service worker + caches, then boot clean
 */
(function () {
	'use strict';

	var BOOT_TIMEOUT_MS = 40000;
	var ACCENT = '#66bdd9';
	var DIM = '#b0beca';
	var BG = '#171a1f';

	// Patched first, before anything else registers, so we capture exactly which input
	// events the engine subscribes to and on which element. Everything else says the
	// event reaches the canvas; this says whether Godot ever asked to hear about it.
	// `selfProbe` excludes our own listeners from the tally.
	var bound = { canvas: {}, document: {}, window: {} };
	var engCalls = {};   // times the ENGINE's own handler actually ran
	var selfProbe = false;
	var aelOrig = EventTarget.prototype.addEventListener;
	EventTarget.prototype.addEventListener = function (type, fn, opts) {
		var wrapped = fn;
		try {
			if (!selfProbe && /^(touch|pointer|mouse|click|key)/.test(type)) {
				var tag = this === window ? 'window'
					: this === document ? 'document'
						: (this && this.id === 'canvas' ? 'canvas' : null);
				if (tag) {
					bound[tag][type] = true;
				}
				// Wrap the engine's touch handlers so we can count invocations, not
				// just registrations. Everything else here proves the event reaches
				// the element; only this proves Godot's code runs on it. Functions
				// only (never an EventListener object), and the return value is passed
				// through untouched.
				if (tag === 'canvas' && typeof fn === 'function'
						&& (type === 'touchstart' || type === 'touchend')) {
					wrapped = function (e) {
						engCalls[type] = (engCalls[type] || 0) + 1;
						return fn.apply(this, arguments);
					};
				}
			}
		} catch (e) { /* never let the probe break registration */ }
		return aelOrig.call(this, type, wrapped, opts);
	};

	// Counts attempted removals of the canvas's input listeners. Purely observational:
	// the wrapper above already registers a different function object than the engine
	// holds, so these removals silently fail to match either way. If this reads
	// nonzero, something tears Godot's touch handlers down after registration, and
	// that accidental non-removal is what made iOS start working.
	var removed = {};
	var relOrig = EventTarget.prototype.removeEventListener;
	EventTarget.prototype.removeEventListener = function (type, fn, opts) {
		try {
			if (this && this.id === 'canvas' && /^(touch|pointer|mouse)/.test(type)) {
				removed[type] = (removed[type] || 0) + 1;
			}
		} catch (e) { /* never let the probe break removal */ }
		return relOrig.call(this, type, fn, opts);
	};

	var errors = [];
	var touches = 0;          // seen at window, capture phase
	var canvasTouches = 0;    // actually delivered to the canvas element
	var cUp = 0;              // completed releases
	var cCancel = 0;          // iOS pulled the sequence away (gesture recognition)
	var cMove = 0;            // movement between down and up reads as a drag, not a tap
	var lastX = -1;
	var lastY = -1;
	var glLost = 0;
	var frames = 0;      // our own rAF: is the browser painting at all
	var fps = 0;
	var fpsAt = 0;
	var engFrames = 0;   // rAF callbacks from anyone else, i.e. Godot's main loop
	var engFps = 0;
	var audioCtx = null;
	var started = false;
	var overlay = null;
	var pre = null;
	var passThrough = false;

	function note(kind, msg) {
		errors.push(kind + ': ' + msg);
		if (errors.length > 6) {
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

	// Godot prints its own failures (shader/context/script) to the console, which is
	// invisible on a phone. Mirror them into the panel.
	['error', 'warn'].forEach(function (level) {
		var orig = console[level];
		console[level] = function () {
			try {
				note(level, Array.prototype.join.call(arguments, ' ').slice(0, 200));
			} catch (e) { /* never let logging break the page */ }
			return orig.apply(console, arguments);
		};
	});

	// Passive capture probe: did the tap reach the page at all, and at what coords?
	// Compare against the canvas rect below to spot a hit-test offset.
	selfProbe = true;
	['touchstart', 'pointerdown'].forEach(function (type) {
		window.addEventListener(type, function (e) {
			touches++;
			var p = (e.touches && e.touches[0]) ? e.touches[0] : e;
			if (typeof p.clientX === 'number') {
				lastX = Math.round(p.clientX);
				lastY = Math.round(p.clientY);
			}
			render();
		}, { passive: true, capture: true });
	});
	selfProbe = false;

	// Same probe, but bound to the canvas itself. window sees the capture phase, so a
	// nonzero `touches` with a zero `canvas` count means the event never reached
	// Godot's own listeners: something is swallowing it in between.
	function probeCanvas(c) {
		selfProbe = true;
		['touchstart', 'pointerdown'].forEach(function (type) {
			c.addEventListener(type, function () {
				canvasTouches++;
				render();
			}, { passive: true });
		});
		// A Godot button needs press AND release on the same control. Counting only
		// the press hides the two ways a tap dies on iOS: Safari stealing the sequence
		// for gesture recognition (touchcancel), or enough drift that it reads as a
		// drag. Both leave the press counter looking perfectly healthy.
		[['touchend', 'up'], ['pointerup', 'up'],
			['touchcancel', 'cancel'], ['pointercancel', 'cancel'],
			['touchmove', 'move'], ['pointermove', 'move']].forEach(function (pair) {
			c.addEventListener(pair[0], function () {
				if (pair[1] === 'up') {
					cUp++;
				} else if (pair[1] === 'cancel') {
					cCancel++;
				} else {
					cMove++;
				}
				render();
			}, { passive: true });
		});
		c.addEventListener('webglcontextlost', function () {
			glLost++;
			note('webgl', 'context lost');
		}, false);
		c.addEventListener('webglcontextrestored', function () {
			note('webgl', 'context restored');
		}, false);
		selfProbe = false;
	}

	function boundList(tag) {
		var keys = Object.keys(bound[tag]);
		return keys.length ? keys.join(',') : 'NONE';
	}

	// Two separate frame counters, and the difference between them is the whole point.
	// `raf` is ours and only says the browser is still painting. `engine` counts rAF
	// callbacks registered by anyone else — in this page, emscripten's main loop. A
	// healthy browser (raf 60) with a dead engine (engine 0) means Godot stopped
	// ticking, which no other probe here can distinguish. We run before index.js, so
	// the patched function is the one emscripten picks up, and the handle is passed
	// straight through so cancelAnimationFrame still works.
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

	// iOS Safari is strict about AudioContext resuming only inside a user gesture, and
	// Godot resumes on first input. If that path throws, input dies with it.
	['AudioContext', 'webkitAudioContext'].forEach(function (name) {
		var Orig = window[name];
		if (typeof Orig !== 'function') {
			return;
		}
		function Patched() {
			var bound = Function.prototype.bind.apply(
				Orig, [null].concat(Array.prototype.slice.call(arguments)));
			audioCtx = new bound();
			return audioCtx;
		}
		Patched.prototype = Orig.prototype;
		window[name] = Patched;
	});

	function describe(el) {
		if (!el) {
			return 'none';
		}
		return el.tagName + (el.id ? '#' + el.id : '')
			+ (el.className && el.className.baseVal === undefined && el.className
				? '.' + String(el.className).split(' ')[0] : '');
	}

	function diagnostics() {
		var c = document.getElementById('canvas');
		var r = c ? c.getBoundingClientRect() : null;
		var vv = window.visualViewport;
		var lines = [
			'ua       ' + navigator.userAgent.slice(0, 78),
			'bound    canvas ' + (bound.canvas.touchstart ? 'touch+' : 'touch-')
				+ (bound.canvas.mousedown ? 'mouse' : 'NOMOUSE')
				+ '   win ' + boundList('window'),
			'ENGINE handler ran: touchstart ' + (engCalls.touchstart || 0)
				+ '  touchend ' + (engCalls.touchend || 0),
			'removeEL ' + (Object.keys(removed).length
				? Object.keys(removed).map(function (k) {
					return k + ' x' + removed[k];
				}).join(', ')
				: 'none'),
			'window   ' + window.innerWidth + 'x' + window.innerHeight
				+ ' dpr' + (window.devicePixelRatio || 1),
			'visual   ' + (vv ? Math.round(vv.width) + 'x' + Math.round(vv.height)
				+ ' off' + Math.round(vv.offsetTop) : 'n/a'),
			'canvas   ' + (c ? c.width + 'x' + c.height
				+ ' css ' + Math.round(r.width) + 'x' + Math.round(r.height)
				+ ' @' + Math.round(r.left) + ',' + Math.round(r.top) : 'MISSING'),
			'touches  win ' + touches + '  canvas down ' + canvasTouches
				+ ' up ' + cUp + ' CANCEL ' + cCancel + ' move ' + cMove
				+ (lastX < 0 ? '' : '  last ' + lastX + ',' + lastY),
			// What the browser thinks is on top at the tap point. Anything other than
			// CANVAS#canvas means an element is intercepting taps.
			'hitTest  ' + (lastX < 0 ? 'no tap yet' : describe(
				document.elementFromPoint(lastX, lastY))),
			'raf      browser ' + fps + 'fps  ENGINE ' + engFps + 'fps'
				+ (glLost ? '  GL CONTEXT LOST x' + glLost : ''),
			'audio    ' + (audioCtx ? audioCtx.state : 'none created'),
			'focus    ' + describe(document.activeElement),
			'sw       ' + (navigator.serviceWorker
				? (navigator.serviceWorker.controller ? 'controlled' : 'not controlling')
				: 'unsupported'),
			'mem      ' + (navigator.deviceMemory ? navigator.deviceMemory + 'GB' : 'n/a'),
			'started  ' + started
		];
		if (errors.length) {
			lines.push('', 'last errors:', errors.join('\n'));
		}
		return lines.join('\n');
	}

	function render() {
		if (!pre) {
			return;
		}
		var base = diagnostics();
		pre.textContent = base;
		if (navigator.storage && navigator.storage.estimate) {
			navigator.storage.estimate().then(function (e) {
				var mb = function (n) { return Math.round((n || 0) / 1048576) + 'MB'; };
				pre.textContent = base + '\nstorage  ' + mb(e.usage) + ' used / '
					+ mb(e.quota) + ' quota';
			}, function () { /* Safari private mode rejects; the rest still reads fine */ });
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

	function build(title, blurb) {
		var box = 'position:fixed;left:0;right:0;top:0;z-index:99999;background:' + BG + ';'
			+ 'color:#edf2f7;font:13px/1.45 -apple-system,system-ui,sans-serif;padding:18px;'
			+ 'overflow:auto;-webkit-overflow-scrolling:touch;';
		box += passThrough
			// Sit over the top of the page but let taps fall through to the canvas,
			// so the touch probe measures real input instead of hits on this panel.
			? 'max-height:52%;background:rgba(23,26,31,.94);pointer-events:none;'
			: 'bottom:0;';

		overlay = document.createElement('div');
		overlay.setAttribute('style', box);

		var h = document.createElement('div');
		h.setAttribute('style', 'font-size:19px;font-weight:700;margin-bottom:6px;color:' + ACCENT);
		h.textContent = title;

		var p = document.createElement('div');
		p.setAttribute('style', 'margin-bottom:12px;color:' + DIM);
		p.textContent = blurb;

		pre = document.createElement('pre');
		pre.setAttribute('style', 'white-space:pre-wrap;word-break:break-all;font-size:11px;'
			+ 'background:#0f1216;padding:10px;border-radius:6px;color:' + DIM + ';margin:0');

		overlay.appendChild(h);
		overlay.appendChild(p);
		overlay.appendChild(pre);

		if (!passThrough) {
			var btn = document.createElement('button');
			btn.textContent = 'Reset and reload';
			btn.setAttribute('style', 'margin-top:14px;padding:12px 18px;font-size:15px;border:0;'
				+ 'border-radius:8px;background:' + ACCENT + ';color:#0f1216;font-weight:700');
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
		if (q.indexOf('debug=1') !== -1) {
			passThrough = true;
			build('Limpid Chess diagnostics',
				'Tap the screen a few times, then screenshot this panel.');
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
