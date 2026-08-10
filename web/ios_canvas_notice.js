/* limpid:ios_canvas_notice — build_web.sh greps this marker to stay idempotent.
 *
 * Honest message for the unsolved iOS canvas bug (see README.md, "OPEN BUG"). On some
 * iPhones WebKit never presents canvas content until the viewport itself changes. The
 * engine runs at 60 fps, input works, sound plays, the correct frame is composited every
 * frame, and the screen simply never updates. Safari and Chrome alike, both orientations.
 *
 * This file replaces an earlier "turn your phone sideways" hint, which was wrong: rotating
 * presents exactly ONE frame, so a player following that advice gets a slideshow, not a
 * game. On an affected device the web build is unusable, and saying so is more respectful
 * than sending someone round in circles.
 *
 * We cannot detect the fault directly. The framebuffer updates correctly, so nothing
 * readable from the page distinguishes an affected iPhone from a healthy one, and only
 * some are affected. So trigger on behaviour: six taps within eight seconds, CLUSTERED
 * inside 60 px. Rate alone would be a false-positive machine because Puzzles rewards fast
 * play; the clustering is what separates someone jabbing at a dead screen from someone
 * happily tapping arrows all over the board.
 *
 * Delete this file, and its injection in build_web.sh, once the underlying bug is fixed.
 */
(function () {
	'use strict';

	var TAPS_NEEDED = 6;
	var WINDOW_MS = 8000;
	var CLUSTER_PX = 60;
	var STORAGE_KEY = 'limpid_ios_notice_dismissed';

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
		en: ['Screen not updating?',
			'Some iPhones hit a bug in Safari that stops the game screen refreshing. '
				+ 'It is the browser, not your phone, and I am still chasing it. '
				+ 'For now it works on a computer, or on Android.',
			'OK'],
		fr: ['L’écran ne se rafraîchit pas ?',
			'Certains iPhone rencontrent un bug de Safari qui bloque l’affichage du jeu. '
				+ 'Cela vient du navigateur, pas de ton téléphone, et je cherche encore. '
				+ 'En attendant, ça marche sur ordinateur ou sur Android.',
			'OK'],
		es: ['¿La pantalla no se actualiza?',
			'Algunos iPhone sufren un fallo de Safari que impide refrescar la pantalla '
				+ 'del juego. Es el navegador, no tu teléfono, y sigo investigándolo. '
				+ 'Por ahora funciona en un ordenador o en Android.',
			'OK']
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
		h.textContent = t[0];

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
	// No orientation check: the bug affects portrait AND landscape, which is exactly what
	// the earlier version got wrong.
	window.addEventListener('touchstart', function (e) {
		if (shown) {
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
}());
