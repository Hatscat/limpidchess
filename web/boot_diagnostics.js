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

	var errors = [];
	var touches = 0;
	var lastTouch = '';
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

	// Passive capture probe: did the tap reach the page at all, and at what coords?
	// Compare against the canvas rect below to spot a hit-test offset.
	['touchstart', 'pointerdown'].forEach(function (type) {
		window.addEventListener(type, function (e) {
			touches++;
			var p = (e.touches && e.touches[0]) ? e.touches[0] : e;
			if (typeof p.clientX === 'number') {
				lastTouch = ' last ' + Math.round(p.clientX) + ',' + Math.round(p.clientY);
			}
			render();
		}, { passive: true, capture: true });
	});

	function diagnostics() {
		var c = document.getElementById('canvas');
		var r = c ? c.getBoundingClientRect() : null;
		var vv = window.visualViewport;
		var lines = [
			'ua       ' + navigator.userAgent,
			'window   ' + window.innerWidth + 'x' + window.innerHeight
				+ ' dpr' + (window.devicePixelRatio || 1),
			'visual   ' + (vv ? Math.round(vv.width) + 'x' + Math.round(vv.height)
				+ ' off' + Math.round(vv.offsetTop) : 'n/a'),
			'canvas   ' + (c ? c.width + 'x' + c.height
				+ ' css ' + Math.round(r.width) + 'x' + Math.round(r.height)
				+ ' @' + Math.round(r.left) + ',' + Math.round(r.top) : 'MISSING'),
			'touches  ' + touches + lastTouch,
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
