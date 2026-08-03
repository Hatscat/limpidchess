/* limpid:ios_portrait_notice — build_web.sh greps this marker to stay idempotent.
 *
 * Mitigation for the unsolved iOS portrait freeze (see README.md, "OPEN BUG"). On some
 * iPhones WebKit never presents the WebGL canvas while the device is held in portrait:
 * the engine runs at 60 fps, input works, sound plays, the correct frame is composited
 * every frame, and the screen simply never updates. Rotating to landscape displays it.
 *
 * We cannot detect the fault directly. The framebuffer is updating correctly, so nothing
 * readable from the page distinguishes an affected device from a healthy one, and only
 * some iPhones are affected — a blanket "rotate your phone" banner would be wrong for
 * everyone else.
 *
 * So trigger on the user's behaviour instead: six taps within eight seconds, CLUSTERED
 * inside 60 px, with the device in portrait. Rate alone would be a false-positive machine
 * because Puzzles rewards fast play; the clustering is what separates someone jabbing at a
 * dead screen from someone happily tapping arrows all over the board. Healthy devices
 * essentially never see this; frozen ones see it within a few seconds of trying to play.
 *
 * Delete this file, and its injection in build_web.sh, once the underlying bug is fixed.
 */
(function () {
	'use strict';

	var TAPS_NEEDED = 6;
	var WINDOW_MS = 8000;
	// Taps must also be CLUSTERED. Rate alone is not enough: Puzzles rewards fast play, so
	// a happy player on a healthy phone can easily manage six taps in eight seconds, and
	// telling them their screen is frozen would be worse than saying nothing. Someone
	// staring at a dead screen jabs the same spot; someone playing taps arrows and buttons
	// all over the board. Clustering is what separates frustration from flow.
	var CLUSTER_PX = 60;
	var STORAGE_KEY = 'limpid_rotate_hint_dismissed';

	var ua = navigator.userAgent || '';
	var isIOS = /iPad|iPhone|iPod/.test(ua)
		|| (/Mac/.test(ua) && navigator.maxTouchPoints > 1);   // iPadOS reports as Mac
	if (!isIOS) {
		return;
	}
	try {
		if (sessionStorage.getItem(STORAGE_KEY)) {
			return;
		}
	} catch (e) { /* private mode: just show it */ }

	var TEXT = {
		en: ['Screen not updating?', 'Turn your phone sideways to play. This is a bug in '
			+ 'Safari on some iPhones, sorry about that.', 'Got it'],
		fr: ['L’écran est figé ?', 'Tourne ton téléphone pour '
			+ 'jouer. C’est un bug de Safari sur certains iPhone, désolé.',
			'J’ai compris'],
		es: ['¿La pantalla no se actualiza?', 'Gira el móvil para jugar. Es un '
			+ 'fallo de Safari en algunos iPhone, lo sentimos.', 'Entendido']
	};
	var lang = (navigator.language || 'en').slice(0, 2).toLowerCase();
	var t = TEXT[lang] || TEXT.en;

	var taps = [];   // {t, x, y}
	var shown = false;
	var box = null;

	function clustered() {
		var minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
		for (var i = 0; i < taps.length; i++) {
			minX = Math.min(minX, taps[i].x);
			maxX = Math.max(maxX, taps[i].x);
			minY = Math.min(minY, taps[i].y);
			maxY = Math.max(maxY, taps[i].y);
		}
		return (maxX - minX) <= CLUSTER_PX && (maxY - minY) <= CLUSTER_PX;
	}

	function portrait() {
		return window.innerHeight > window.innerWidth;
	}

	function dismiss() {
		try {
			sessionStorage.setItem(STORAGE_KEY, '1');
		} catch (e) { /* ignore */ }
		if (box && box.parentNode) {
			box.parentNode.removeChild(box);
		}
		box = null;
	}

	function show() {
		if (shown) {
			return;
		}
		shown = true;
		box = document.createElement('div');
		box.setAttribute('style', 'position:fixed;left:12px;right:12px;bottom:16px;'
			+ 'z-index:99998;background:#171a1f;border:1px solid #66bdd9;border-radius:12px;'
			+ 'padding:16px 18px;color:#edf2f7;'
			+ 'font:15px/1.45 -apple-system,system-ui,sans-serif;'
			+ 'box-shadow:0 8px 28px rgba(0,0,0,.55)');

		var h = document.createElement('div');
		h.setAttribute('style', 'font-weight:700;color:#66bdd9;margin-bottom:6px');
		h.textContent = '↻  ' + t[0];

		var p = document.createElement('div');
		p.setAttribute('style', 'color:#b0beca');
		p.textContent = t[1];

		var btn = document.createElement('button');
		btn.textContent = t[2];
		btn.setAttribute('style', 'margin-top:14px;padding:10px 16px;font-size:15px;'
			+ 'border:0;border-radius:8px;background:#66bdd9;color:#0f1216;font-weight:700');
		btn.addEventListener('click', dismiss);

		box.appendChild(h);
		box.appendChild(p);
		box.appendChild(btn);
		document.body.appendChild(box);
	}

	// Passive, never preventDefault: this must not interfere with input reaching Godot.
	window.addEventListener('touchstart', function (e) {
		if (shown || !portrait()) {
			return;
		}
		var p = (e.touches && e.touches[0]) ? e.touches[0] : e;
		if (typeof p.clientX !== 'number') {
			return;
		}
		var now = Date.now();
		taps.push({ t: now, x: p.clientX, y: p.clientY });
		while (taps.length && now - taps[0].t > WINDOW_MS) {
			taps.shift();
		}
		if (taps.length >= TAPS_NEEDED && clustered()) {
			show();
		}
	}, { passive: true, capture: true });

	// Rotating is the fix, so once they do it the hint has served its purpose.
	window.addEventListener('orientationchange', function () {
		setTimeout(function () {
			if (box && !portrait()) {
				dismiss();
			}
		}, 300);
	});
}());
