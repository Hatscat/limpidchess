/* limpid:boot_diagnostics — build_web.sh greps this marker to stay idempotent.
 *
 * Boot diagnostics + self-heal for the web build. build_web.sh inlines this into <head>
 * of the exported index.html, BEFORE index.js, so it is already listening when the engine
 * boots. It only ever adds passive listeners and never calls preventDefault or
 * stopPropagation, so it cannot change how input reaches the canvas.
 *
 * Godot's stock shell only surfaces *thrown* errors. A tab killed mid-wasm-compile, or one
 * served a truncated download, sits at a full progress bar forever with nothing in the DOM
 * to report. This turns that into a visible message plus one-tap recovery, and gives a
 * phone-only tester something to screenshot.
 *
 *   <page>          watchdog only: panel appears if boot stalls past BOOT_TIMEOUT_MS
 *   <page>?debug=1  live pass-through panel + the GL instrumentation below
 *   <page>?reset=1  wipe service worker + caches, then boot clean
 *   <page>?log=1    POST the panel text to /__log every 2 s (web/tools/lan_server.py)
 *
 * COST: everything expensive is gated behind ?debug=1. The pixel sampler forces a GPU sync
 * and the draw counters wrap every WebGL draw call, so neither may run for real players.
 * Keep it that way.
 *
 * The `?d=...` experiment flags used while chasing the iOS portrait freeze are gone; every
 * one of them failed. README.md, "Ruled out by measurement", records what each tested so
 * nobody rebuilds them.
 */
(function () {
	'use strict';

	var BOOT_TIMEOUT_MS = 40000;
	var ACCENT = '#66bdd9';
	var DIM = '#b0beca';
	var BG = '#171a1f';
	var DEBUG = /[?&]debug=1\b/.test(location.search);

	// --- live experiments for the "presents only on resize" bug --------------------------
	//
	// Confirmed in person on an iPhone 13 (Safari AND Chrome, which is WebKit too): the
	// canvas is frozen in BOTH orientations and each rotation presents exactly one frame.
	// So orientation is irrelevant; what presents a frame is a RESIZE. WebKit is not being
	// told the canvas content changed, and only a layer-geometry change makes it re-read
	// the drawing buffer.
	//
	// These three attack that directly. Test with the phone held still, no rotating.
	//
	//   ?d=anim        a 2px element running an infinite CSS transform animation. Forces
	//                  the compositor to run every frame for something else on the page.
	//                  If the canvas then presents, the fix is a hidden CSS animation.
	//   ?d=canvasanim  the same animation applied to the canvas layer itself.
	//   ?d=stepsize    alternate the canvas CSS height by 1px EVERY frame. Godot's
	//                  updateSize() snaps it back on the next frame, so it oscillates,
	//                  which is a real per-frame resize. (?d=nudge earlier used 0.5px at
	//                  2 Hz, far too little and far too rare.)
	var expMode = (/[?&]d=([a-z]+)/.exec(location.search) || [])[1] || '';

	if (expMode === 'anim' || expMode === 'canvasanim') {
		var st = document.createElement('style');
		// Sub-pixel scale: invisible, but the compositor must service the layer every
		// frame. A rotate() on a separate element (?d=anim) can be run entirely on its
		// own layer without touching the canvas, which is probably why that one failed.
		st.textContent = '@keyframes limpidspin{from{transform:rotate(0)}'
			+ 'to{transform:rotate(360deg)}}'
			+ '@keyframes limpidnudge{0%{transform:scale(1)}'
			+ '50%{transform:scale(1.0004)}100%{transform:scale(1)}}';
		document.head.appendChild(st);
	}
	var expCanvas = null;
	var expApplied = 0;
	var stepOn = false;

	// Timestamped event ring, appended to the ?log=1 POST. The panel shows current state;
	// this shows the SEQUENCE, which is what matters for "what does a rotation actually do
	// that we cannot reproduce?".
	var events = [];
	var t0 = Date.now();
	function logLine(msg) {
		events.push(((Date.now() - t0) / 1000).toFixed(2) + 's  ' + msg);
		if (events.length > 60) {
			events.shift();
		}
	}

	var errors = [];
	var taps = 0;
	var ups = 0;
	var glInfo = '?';
	var glGranted = '?';
	var glCheckedFor = '';
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

	// --- debug-only GL instrumentation -------------------------------------------------
	//
	// The DRAW counters produced the decisive result of the iOS investigation: on a frozen
	// portrait screen `to-screen` equalled the frame rate, proving Godot composites to the
	// default framebuffer every frame and WebKit simply never presents it. Kept so that can
	// be re-verified in a single page load, but debug-gated, because wrapping every draw
	// call is not something to ship to players.
	var GL_ERRS = {
		1280: 'INVALID_ENUM', 1281: 'INVALID_VALUE', 1282: 'INVALID_OPERATION',
		1285: 'OUT_OF_MEMORY', 1286: 'INVALID_FRAMEBUFFER_OPERATION', 37442: 'CONTEXT_LOST'
	};
	var glErrs = {};
	var glPoll = null;
	var drawCalls = 0;
	var drawScreen = 0;
	var blits = 0;
	var drawRate = 0;
	var screenRate = 0;
	var blitRate = 0;
	var pxSamples = 0;
	var pxChanges = 0;
	var pxLast = -1;

	function instrumentGL(proto) {
		if (!proto || proto.__limpidPatched) {
			return;
		}
		proto.__limpidPatched = true;
		var bindOrig = proto.bindFramebuffer;
		proto.bindFramebuffer = function (target) {
			// FRAMEBUFFER (0x8D40) and DRAW_FRAMEBUFFER (0x8CA9) both retarget draws.
			if (target === 0x8D40 || target === 0x8CA9) {
				this.__limpidDrawFB = arguments[1];
			}
			return bindOrig.apply(this, arguments);
		};
		['drawArrays', 'drawElements', 'drawArraysInstanced',
			'drawElementsInstanced'].forEach(function (name) {
			var orig = proto[name];
			if (!orig) {
				return;
			}
			proto[name] = function () {
				drawCalls++;
				if (!this.__limpidDrawFB) {   // unset or null == the default framebuffer
					drawScreen++;
				}
				return orig.apply(this, arguments);
			};
		});
		if (proto.blitFramebuffer) {
			var blitOrig = proto.blitFramebuffer;
			proto.blitFramebuffer = function () {
				blits++;
				return blitOrig.apply(this, arguments);
			};
		}
	}

	// Browsers emit WebGL errors through internal logging, not console.error, so nothing
	// the page hooks can see them and a phone has no console. getContext() with no
	// attributes returns the context Godot created, and getError() reports and clears one
	// flag per call, so draining it surfaces engine GL errors on a real device.
	// Note this consumes errors Godot might otherwise check; fine for a diagnostic build.
	function pollGL() {
		try {
			if (!glPoll) {
				var cv = document.getElementById('canvas');
				if (!cv || cv.width < 2) {
					return;
				}
				glPoll = cv.getContext('webgl2') || cv.getContext('webgl');
				if (!glPoll) {
					return;
				}
			}
			for (var i = 0; i < 8; i++) {          // bounded: never spin on a stuck queue
				var e = glPoll.getError();
				if (!e) {
					break;
				}
				glErrs[e] = (glErrs[e] || 0) + 1;
			}
		} catch (e) { /* context lost mid-poll */ }
	}

	// Read the default framebuffer straight after the engine's callback, before it is
	// composited. Distinguishes "the engine draws nothing useful" from "the engine draws
	// correctly and the frame never reaches the screen"; counting draws alone cannot.
	function samplePixels() {
		try {
			if (!glPoll) {
				return;
			}
			var cv = document.getElementById('canvas');
			var buf = new Uint8Array(64);
			var hash = 0;
			var pts = [[0.3, 0.35], [0.7, 0.35], [0.3, 0.7], [0.7, 0.7]];
			for (var q = 0; q < pts.length; q++) {
				glPoll.readPixels(Math.floor(cv.width * pts[q][0]),
					Math.floor(cv.height * pts[q][1]),
					4, 4, glPoll.RGBA, glPoll.UNSIGNED_BYTE, buf);
				for (var i = 0; i < 64; i++) {
					hash = (hash * 31 + buf[i]) & 0x7fffffff;
				}
			}
			pxSamples++;
			if (pxLast !== -1 && hash !== pxLast) {
				pxChanges++;
			}
			pxLast = hash;
		} catch (e) { /* buffer already discarded, or context lost */ }
	}

	if (DEBUG) {
		instrumentGL(window.WebGL2RenderingContext && window.WebGL2RenderingContext.prototype);
		instrumentGL(window.WebGLRenderingContext && window.WebGLRenderingContext.prototype);
	}

	// Two frame counters, and the gap between them is the point. `raf` is ours and only
	// says the browser is painting; `engine` counts rAF callbacks registered by anyone
	// else, i.e. emscripten's main loop. A healthy browser with a dead engine is a
	// different bug, and no other probe separates them. We run before index.js so the
	// patched function is the one emscripten picks up, and the handle passes straight
	// through so cancelAnimationFrame still works.
	var rafOrig = window.requestAnimationFrame.bind(window);
	window.requestAnimationFrame = function (cb) {
		return rafOrig(function (t) {
			engFrames++;
			var r = cb(t);
			// After the engine's frame, so our change is what survives to the end of it.
			if (expCanvas) {
				var h = parseFloat(expCanvas.style.height);
				if (h) {
					stepOn = !stepOn;
					expCanvas.style.height = (stepOn ? h - 1 : h + 1) + 'px';
					expApplied++;
				}
			}
			watchGeometry();
			if (DEBUG) {
				pollGL();
				if (engFrames % 12 === 0) {   // ~5/s: readPixels forces a GPU sync
					samplePixels();
				}
			}
			return r;
		});
	};

	// Log every change to the canvas's geometry. A rotation presents exactly one frame, so
	// whatever this records around a rotation IS the thing to reproduce.
	var lastGeom = '';
	function watchGeometry() {
		var c = document.getElementById('canvas');
		if (!c) {
			return;
		}
		var g = c.width + 'x' + c.height + ' css ' + c.style.width + ',' + c.style.height
			+ ' win ' + window.innerWidth + 'x' + window.innerHeight;
		if (g !== lastGeom) {
			lastGeom = g;
			logLine('geom ' + g);
		}
	}

	function tick(t) {
		frames++;
		if (t - fpsAt >= 1000) {
			var per = 1000 / (t - fpsAt);
			fps = Math.round(frames * per);
			engFps = Math.round(engFrames * per);
			drawRate = Math.round(drawCalls * per);
			screenRate = Math.round(drawScreen * per);
			blitRate = Math.round(blits * per);
			frames = 0;
			engFrames = 0;
			drawCalls = 0;
			drawScreen = 0;
			blits = 0;
			fpsAt = t;
		}
		rafOrig(tick);
	}
	rafOrig(tick);

	// Safari silently clamps a drawing buffer it cannot allocate. Re-read whenever the
	// canvas resizes rather than once: a single early read captures the untouched 300x150
	// default and caches it forever, and keying on size also re-checks after a rotation,
	// which is exactly when a clamp would show up.
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
			// Godot requests no attributes, so these are browser defaults. Recorded
			// because `aa=true` means the default framebuffer is multisampled.
			var got = gl.getContextAttributes ? gl.getContextAttributes() : null;
			if (got) {
				glGranted = 'aa=' + got.antialias + ' preserve=' + got.preserveDrawingBuffer
					+ ' alpha=' + got.alpha;
			}
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
		// Only once Godot has booted. checkGL() calls getContext(), and an untouched
		// canvas is 300x150, which passes any `width > 1` test: running earlier would
		// CREATE the context with our attributes and Godot would silently inherit it.
		if (c && started && c.width > 1) {
			var key = c.width + 'x' + c.height;
			if (key !== glCheckedFor) {
				glCheckedFor = key;
				checkGL(c);
			}
		}
		var out = [
			'raf ' + fps + ' / engine ' + engFps + 'fps' + (glLost ? '  GL LOST' : ''),
			'win ' + window.innerWidth + 'x' + window.innerHeight
				+ '  canvas ' + (c ? c.width + 'x' + c.height : '?'),
			'gl  ' + glInfo,
			'granted ' + glGranted,
			'taps ' + taps + ' down, ' + ups + ' up',
			'started ' + started
		];
		if (DEBUG) {
			var ge = Object.keys(glErrs);
			out.splice(1, 0,
				'DRAW ' + drawRate + '/s  to-screen ' + screenRate + '/s  blit '
					+ blitRate + '/s',
				'PIXELS ' + pxSamples + ' read, ' + pxChanges + ' changed',
				'glerr ' + (ge.length
					? ge.map(function (k) {
						return (GL_ERRS[k] || k) + ' x' + glErrs[k];
					}).join(', ')
					: 'none'));
		}
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
	// Deploy hygiene, so a bad build is always fixable by shipping a good one. Keep it.
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

	function applyExperiment(c) {
		if (expMode === 'anim') {
			var dot = document.createElement('div');
			dot.setAttribute('style', 'position:fixed;left:0;top:0;width:2px;height:2px;'
				+ 'background:#66bdd9;z-index:99997;pointer-events:none;'
				+ 'animation:limpidspin 1s linear infinite');
			document.body.appendChild(dot);
		} else if (expMode === 'canvasanim') {
			c.style.transformOrigin = '50% 50%';
			c.style.animation = 'limpidnudge 0.5s linear infinite';
			logLine('exp canvasanim: animation=' + c.style.animation);
		} else if (expMode === 'stepsize') {
			// Applied in the rAF wrapper AFTER Godot's callback, not before. Registering
			// our own rAF at DOMContentLoaded put us ahead of emscripten's, so Godot's
			// updateSize() reverted the change inside the same frame and the compositor
			// never saw a single one of them.
			expCanvas = c;
			logLine('exp stepsize armed (applied after each engine frame)');
		}
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

	['resize', 'orientationchange', 'pageshow', 'visibilitychange',
		'focus', 'blur'].forEach(function (ev) {
		window.addEventListener(ev, function () {
			logLine(ev + '  win ' + window.innerWidth + 'x' + window.innerHeight
				+ ' dpr' + window.devicePixelRatio
				+ (document.hidden ? ' HIDDEN' : ''));
		});
	});

	function boot() {
		if (location.search.indexOf('reset=1') !== -1) {
			hardReset();
			return;
		}
		var c = document.getElementById('canvas');
		if (c) {
			probeCanvas(c);
			applyExperiment(c);
		}
		promoteServiceWorker();
		if (location.search.indexOf('log=1') !== -1) {
			// Same-origin POST, so no CORS and nothing to configure: whoever serves the
			// page collects the log. Only useful behind web/tools/lan_server.py, which
			// prints it to a terminal instead of a phone screenshot.
			setInterval(function () {
				try {
					fetch('/__log', {
						method: 'POST',
						body: diagnostics()
							+ '\nexp ' + (expMode || 'none') + ' applied ' + expApplied
							+ '\n--- events ---\n' + events.join('\n')
					});
				} catch (e) { /* offline or blocked */ }
			}, 2000);
		}
		if (DEBUG) {
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
