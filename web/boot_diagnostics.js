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

	// ?d=lowdpi — must run here, at <head> parse time, before the engine reads it.
	// Godot sizes its canvas as window * devicePixelRatio, so dpr 3 gives a 1170x1974
	// backing store in portrait against 2250x912 in landscape: near-identical pixel
	// counts, but more than twice the height. Height is the one measured asymmetry
	// between the frozen and working orientations, and forcing dpr to 1 collapses
	// portrait to 390x658. If that unfreezes it, the fix is the `allow_hidpi` project
	// setting (or a capped backing store), not anything to do with compositing.
	if (location.search.indexOf('d=lowdpi') !== -1) {
		try {
			Object.defineProperty(window, 'devicePixelRatio', {
				get: function () { return 1; },
				configurable: true
			});
		} catch (e) { /* not overridable here; the test is simply inconclusive */ }
	}

	// The DRAW probe below proved Godot composites to the default framebuffer every
	// frame on a frozen portrait screen (to-screen == fps), so the engine is innocent and
	// WebKit is simply not presenting the buffer. That makes the context attributes the
	// most promising lever, and they can only be set at creation time — hence patching
	// getContext here, in <head>, before Godot ever calls it.
	//
	//   ?d=preserve  preserveDrawingBuffer: true   (stops WebKit discarding the buffer
	//                                               after compositing; the classic fix
	//                                               for a canvas that will not update)
	//   ?d=noaa      antialias: false              (no multisample resolve on the
	//                                               default framebuffer)
	//   ?d=aa        antialias: true
	//   ?d=noalpha   alpha: false
	//   ?d=desync    desynchronized: true          (low-latency canvas path; on some
	//                                               Safari builds this bypasses the
	//                                               normal compositor pipeline entirely)
	var GL_OVERRIDES = {
		preserve: { preserveDrawingBuffer: true },
		noaa: { antialias: false },
		aa: { antialias: true },
		noalpha: { alpha: false },
		desync: { desynchronized: true }
	};
	var activeMode = (/[?&]d=([a-z]+)/.exec(location.search) || [])[1] || '';
	var glAttrs = null;
	var glResize = /[?&]d=resize\b/.test(location.search);
	var glForce = (/[?&]d=(finish|flush)\b/.exec(location.search) || [])[1] || '';
	(function patchGetContext() {
		var q = location.search;
		var m = /[?&]d=([a-z]+)/.exec(q);
		var override = m && GL_OVERRIDES[m[1]];
		var orig = HTMLCanvasElement.prototype.getContext;
		HTMLCanvasElement.prototype.getContext = function (type, attrs) {
			// Only the real game canvas. Godot's shell feature-detects WebGL2 on a
			// throwaway <canvas> first, and recording that one reports "(defaults)"
			// no matter what the engine actually asks for.
			if (/webgl/i.test(String(type)) && this && this.id === 'canvas') {
				var merged = {};
				var k;
				for (k in (attrs || {})) {
					merged[k] = attrs[k];
				}
				if (!glAttrs) {
					glAttrs = merged;
				}
				if (override) {
					for (k in override) {
						merged[k] = override[k];
					}
				}
				return orig.call(this, type, merged);
			}
			return orig.apply(this, arguments);
		};
	}());

	// ?d=wide — isolates canvas ASPECT, which no test so far has varied independently.
	// `lowdpi` changed the canvas size (1170x1974 -> 390x658) and it still froze, so size
	// is out. But every frozen canvas has been taller than wide, and every working one
	// (landscape) wider than tall. Godot derives its canvas from window.innerWidth/Height,
	// so shrinking innerHeight gives a portrait phone a landscape-shaped canvas. The game
	// will look squashed into a letterbox at the top; that does not matter. The only
	// question is whether tapping visibly changes anything.
	//
	// If this presents, the trigger is aspect, and a real workaround becomes possible:
	// render into a wide canvas and rotate it back with a CSS transform.
	if (/[?&]d=wide\b/.test(location.search)) {
		try {
			var realW = window.innerWidth;
			Object.defineProperty(window, 'innerHeight', {
				get: function () { return Math.floor(realW * 0.6); },
				configurable: true
			});
		} catch (e) { /* not overridable; test is inconclusive */ }
	}

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

	// Drain Godot's GL error queue right after the engine's own frame callback.
	//
	// This is the blind spot that stalled the whole iOS investigation: browsers emit
	// WebGL errors through internal logging, NOT through console.error, so nothing the
	// page can hook will ever see them and a phone has no console. But getContext() with
	// no attributes hands back the very context Godot created, and getError() reports and
	// clears one flag per call, so polling it surfaces the engine's GL errors on a real
	// device with no inspector attached.
	//
	// Caveat for anyone reading this later: this *consumes* errors Godot might otherwise
	// have checked itself. Fine for a diagnostic build, and the Compatibility renderer
	// does not check them in release.
	var GL_ERRS = {
		1280: 'INVALID_ENUM', 1281: 'INVALID_VALUE', 1282: 'INVALID_OPERATION',
		1285: 'OUT_OF_MEMORY', 1286: 'INVALID_FRAMEBUFFER_OPERATION', 37442: 'CONTEXT_LOST'
	};
	var glErrs = {};
	var glPoll = null;
	var glCheckedFor = '';
	var glGranted = '?';

	// THE decisive probe for the iOS portrait freeze. Everything else established that
	// the engine loop runs, input arrives, the GL context is healthy and error-free, and
	// the screen still does not update. That leaves exactly two possibilities, needing
	// opposite fixes:
	//
	//   Godot draws but Safari never presents  ->  compositor bug, nothing engine-side
	//   Godot never draws                      ->  engine bug, Safari is innocent
	//
	// Counting draw calls separates them. `screen` counts only draws issued while the
	// DRAW framebuffer binding is null, i.e. straight to the default framebuffer, which
	// is what actually reaches the display. Patch the prototypes rather than one context
	// instance: we run in <head>, well before Godot calls getContext, so every call it
	// makes goes through these.
	var drawCalls = 0;
	var drawScreen = 0;
	var blits = 0;
	var drawRate = 0;
	var screenRate = 0;
	var blitRate = 0;

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
	instrumentGL(window.WebGL2RenderingContext && window.WebGL2RenderingContext.prototype);
	instrumentGL(window.WebGLRenderingContext && window.WebGLRenderingContext.prototype);

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

	// Closes the last ambiguity in the DRAW result. Counting draw calls proves Godot
	// *issues* a composite every frame, but not that the composite is CORRECT: a broken
	// viewport would produce an identical blank frame each time and look the same to that
	// probe. So sample the default framebuffer right after the engine's callback, before
	// the buffer is composited and discarded. If these pixels change when the game state
	// changes while the display stays stale, rendering is correct and only presentation
	// is broken. If they never change, the engine is drawing nothing useful.
	var pxSamples = 0;
	var pxChanges = 0;
	var pxLast = -1;

	function samplePixels() {
		try {
			if (!glPoll) {
				return;
			}
			var cv = document.getElementById('canvas');
			var buf = new Uint8Array(64 * 4);
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

	var rafOrig = window.requestAnimationFrame.bind(window);
	window.requestAnimationFrame = function (cb) {
		return rafOrig(function (t) {
			engFrames++;
			var r = cb(t);
			// ?d=finish / ?d=flush — force the GL commands to complete before the
			// compositor can sample the buffer. A missing flush is a classic cause of a
			// canvas showing stale content: the compositor grabs the previous buffer
			// because this frame's commands have not landed yet. WebGL flushes
			// implicitly at the end of a rAF task, but Safari has not always honoured it.
			if (glForce && glPoll) {
				try {
					if (glForce === 'finish') {
						glPoll.finish();
					} else {
						glPoll.flush();
					}
				} catch (e) { /* context lost */ }
			}
			// ?d=resize — last resort, and the only mechanism with proven effect: a real
			// backing-store change is what rotating the device does. Shrink the canvas and
			// let Godot's updateSize() snap it back next frame, which reallocates the GL
			// buffer exactly as a rotation would. Expensive, so 10x/s rather than every
			// frame. Earlier attempts only dirtied canvas.style, which was not enough.
			if (glResize && engFrames % 6 === 0) {
				try {
					var rc = document.getElementById('canvas');
					if (rc && rc.width > 4) {
						rc.width = rc.width - 2;
					}
				} catch (e) { /* ignore */ }
			}
			pollGL();
			if (engFrames % 12 === 0) {   // ~5 reads/s: readPixels forces a GPU sync
				samplePixels();
			}
			return r;
		});
	};

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
			// What the browser actually GRANTED, which is what matters. Godot requests
			// nothing, so defaults apply, and `samples > 1` means the default framebuffer
			// really is multisampled and needs a resolve to present.
			var got = gl.getContextAttributes ? gl.getContextAttributes() : null;
			if (got) {
				glGranted = 'aa=' + got.antialias + ' preserve=' + got.preserveDrawingBuffer
					+ ' alpha=' + got.alpha;
			}
			try {
				glGranted += ' samples=' + gl.getParameter(gl.SAMPLES);
			} catch (e) { /* WebGL1 without the constant */ }
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
		// Re-read whenever the canvas is resized, not just once: a single early read
		// captures the untouched 300x150 default before Godot sizes it, and caches that
		// forever. Keying on the size also re-checks after every rotation, which is
		// precisely when a clamp would appear.
		if (c && c.width > 1) {
			var key = c.width + 'x' + c.height;
			if (key !== glCheckedFor) {
				glCheckedFor = key;
				checkGL(c);
			}
		}
		var ge = Object.keys(glErrs);
		var out = [
			'raf ' + fps + ' / engine ' + engFps + 'fps' + (glLost ? '  GL LOST' : ''),
			'DRAW ' + drawRate + '/s  to-screen ' + screenRate + '/s  blit ' + blitRate + '/s'
				+ (drawRate > 0 && screenRate === 0 ? '   <-- NOTHING TO SCREEN' : ''),
			'PIXELS ' + pxSamples + ' read, ' + pxChanges + ' changed',
			'glerr ' + (ge.length
				? ge.map(function (k) {
					return (GL_ERRS[k] || k) + ' x' + glErrs[k];
				}).join(', ')
				: 'none'),
			'win ' + window.innerWidth + 'x' + window.innerHeight
				+ '  canvas ' + (c ? c.width + 'x' + c.height : '?'),
			'gl  ' + glInfo,
			'MODE ' + (activeMode || 'none'),
			'granted ' + glGranted,
			'attrs ' + (glAttrs
				? (Object.keys(glAttrs).length
					? Object.keys(glAttrs).map(function (k) {
						return k + '=' + glAttrs[k];
					}).join(' ')
					: '(defaults)')
				: 'n/a'),
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
		if (q.indexOf('log=1') !== -1) {
			// Same-origin POST, so no CORS and no config: whoever serves the page
			// collects the log. See web/tools/lan_server.py.
			setInterval(function () {
				try {
					fetch('/__log', { method: 'POST', body: diagnostics() });
				} catch (e) { /* offline or blocked */ }
			}, 2000);
		}
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
