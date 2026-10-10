// What is left of limpidchess.com after the move to limpidchess.lonebee.games (2026-10).
//
// A Cloudflare Worker on the routes limpidchess.com/* and www.limpidchess.com/* (see
// wrangler.toml and README.md). Browser saves are bound to their address, so the old one is
// kept useful instead of becoming a plain redirect:
//   - /play/, /play/index.html (the start_url of installed apps) and /play: a 200 BRIDGE page.
//     It reads the save the game kept here (Godot's IndexedDB) and opens the new address with it
//     in the URL fragment, where GameManager._adopt_moved_save takes it over.
//   - /play/index.service.worker.js: a 200 kill switch that retires the old service worker.
//   - A browser opening the bare domain gets the bridge too, so a returning player who types
//     limpidchess.com keeps their progress. Crawlers and link previews get a 301 there.
//   - Everything else: a 301 to the same path and query on the new address.
// Until the new address answers over valid HTTPS (GitHub takes a few minutes to issue its
// certificate after the switch), requests pass through to GitHub as before, and a 503 "moving"
// page covers the gap. An old service worker falls back to its cached game on any non-OK
// answer, so players keep playing meanwhile.
//
// NEVER answer /play/ or the worker script with a redirect, here or with a Cloudflare
// Redirect Rule or Page Rule (those run before this Worker). The old service worker fetches
// /play/ itself and hands the answer to the page: browsers refuse a redirected answer for a
// page load (an error page in Chrome and Safari), and a worker script may not redirect either,
// so the stuck worker could never be replaced. Verified against the real deployed workers in
// Chromium, Firefox and WebKit, see README.md.

const NEW_ORIGIN = 'https://limpidchess.lonebee.games';
// Set to true once the new address is verified (README, cutover step 10), then redeploy. From
// then on the Worker never asks the new site or GitHub anything: no probe, no pass-through, no
// "moving" page, whatever later happens to either of them.
const MOVED = false;
const SW_PATH = '/play/index.service.worker.js';
const BRIDGE_PATHS = ['/play', '/play/', '/play/index.html'];
const HOME_PATHS = ['/', '/index.html'];
const STATUS_PATH = '/__move-status';

export default {
	async fetch(request, env) {
		// env.NEW_ORIGIN and env.MOVED exist for local tests only (worker.test.mjs, e2e_check.mjs).
		const newOrigin = (env && env.NEW_ORIGIN) || NEW_ORIGIN;
		const moved = MOVED || (env && env.MOVED === '1');
		const url = new URL(request.url);
		// The save lives in the https origin, so upgrade on this host before anything else.
		if (url.protocol === 'http:') {
			return redirect('https://' + url.host + url.pathname + url.search);
		}
		const up = moved || await newSiteIsUp(newOrigin);
		if (url.pathname === STATUS_PATH) {
			// curl https://limpidchess.com/__move-status : proves the Worker is in front, before and after.
			const state = moved ? 'moved for good, sending players to' : up ? 'live, sending players to' : 'waiting for';
			return new Response(`limpidchess.com worker: ${state} ${newOrigin}\n`,
				{ headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' } });
		}
		if (!up) {
			return beforeTheMove(request, newOrigin);
		}
		// www never held a save: GitHub always redirected it to the apex.
		const apex = !url.hostname.startsWith('www.');
		const path = url.pathname;
		if (apex && path === SW_PATH) {
			return script(KILL_SWITCH);
		}
		if (apex && BRIDGE_PATHS.includes(path)) {
			return page(htmlPage('bridge', newOrigin, newOrigin + '/play/'));
		}
		if (apex && path.startsWith('/play/')) {
			// Files of the retired build. Never redirect them: an old cached game would mix in the
			// new build's files, and an old worker cannot use a redirected answer anyway.
			return new Response('Not found', { status: 404, headers: {
				'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' } });
		}
		if (apex && HOME_PATHS.includes(path) && isPageVisit(request)) {
			return page(htmlPage('bridge', newOrigin, newOrigin + '/'));
		}
		// Concatenation, not new URL(path, base): a path like //evil.example must stay a path.
		return redirect(newOrigin + path + url.search);
	},
};

// A person's browser opening a page. Browsers send this fetch metadata (Safari only since 16.4,
// so older Safari gets the 301 here; its /play/ links still get the bridge). Crawlers and
// link-preview bots normally don't, so they keep the plain 301 for the homepage, and one that
// does send it gets the bridge, which still lands it on the new homepage.
function isPageVisit(request) {
	return request.headers.get('sec-fetch-mode') === 'navigate'
		&& request.headers.get('sec-fetch-dest') === 'document';
}

// Until MOVED is set: is the new address serving the game over valid HTTPS (its
// /play/index.manifest.json answering 200 with "Limpid Chess")? A Worker's own requests to another
// host always verify its certificate, so during GitHub's certificate gap this fails and nobody
// is sent there yet. The answer is remembered for a while per Worker instance, and the probe is
// kept short: an old service worker waits 2.5 s for /play/ before it falls back to its cache.
let upUntil = 0;
let downUntil = 0;

async function newSiteIsUp(origin) {
	const now = Date.now();
	if (now < upUntil) {
		return true;
	}
	if (now < downUntil) {
		return false;
	}
	let up = false;
	try {
		const res = await fetch(origin + '/play/index.manifest.json?up=' + now,
			{ redirect: 'manual', signal: AbortSignal.timeout(2000) });
		up = res.status === 200 && (await res.text()).includes('Limpid Chess');
	} catch (e) {
		up = false;
	}
	if (up) {
		upUntil = now + 10 * 60 * 1000;
	} else {
		downUntil = now + 15 * 1000;
	}
	return up;
}

// Before the switch GitHub still serves this domain: pass through untouched. During the gap it
// no longer does (a 5xx such as Cloudflare's 526, or GitHub's "Site not found" 404): answer with
// a short "moving" page instead.
async function beforeTheMove(request, newOrigin) {
	try {
		// A HEAD answer has no body to recognise GitHub's no-site page by: ask with GET (the runtime
		// drops the body again for HEAD).
		const res = await fetch(request.method === 'HEAD' ? new Request(request, { method: 'GET' }) : request);
		if (res.status < 500 && !(res.status === 404 && await isGitHubNoSite(res.clone()))) {
			return res;
		}
	} catch (e) {
		// fall through to the moving page
	}
	return page(htmlPage('waiting', newOrigin, newOrigin + '/'), 503, { 'retry-after': '300' });
}

async function isGitHubNoSite(res) {
	try {
		return (await res.text()).includes("There isn't a GitHub Pages site here");
	} catch (e) {
		return false;
	}
}

function redirect(location) {
	// An hour, not forever: a mistake must be fixable. Search engines only look at the status.
	return new Response(null, { status: 301, headers: { location, 'cache-control': 'max-age=3600' } });
}

function page(html, status = 200, extra = {}) {
	return new Response(html, { status, headers: {
		'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', ...extra } });
}

function script(js) {
	return new Response(js, { headers: {
		'content-type': 'text/javascript; charset=utf-8', 'cache-control': 'no-store' } });
}

// Served at the old worker's own URL, so the browser's routine update check installs it. It
// waits like any update (no skipWaiting): a game that is already open keeps its cached files
// until it closes, instead of losing them mid-session. Once active it clears the old caches
// and unregisters; with no fetch handler, the next launch goes to the network and the bridge.
const KILL_SWITCH = `// Retires the limpidchess.com/play/ service worker: Limpid Chess moved to ${NEW_ORIGIN}.
self.addEventListener('activate', function (event) {
	event.waitUntil(caches.keys().then(function (keys) {
		return Promise.all(keys.map(function (key) { return caches.delete(key); }));
	}).then(function () {
		return self.registration.unregister();
	}));
});
`;

// Player-facing copy, same languages and register as assets/i18n/ui.csv. US English, and no
// em dashes in any language (house style).
const STRINGS = {
	en: {
		title: 'Limpid Chess has moved',
		moved: 'Its new address is limpidchess.lonebee.games.',
		progress: 'Your progress comes with you.',
		keep_icon: 'Keep using this icon: it opens the game at its new address, with your progress.',
		install: 'Installed it as an app? Tap Continue, then install it again from the new address and remove this old icon.',
		continue: 'Continue',
		offline: "You're offline. Connect to the internet to continue.",
		retry: 'Retry',
		waiting_title: 'Limpid Chess is moving',
		waiting: "It's settling into its new address. Please try again in a few minutes.",
	},
	fr: {
		title: 'Limpid Chess a déménagé',
		moved: 'Sa nouvelle adresse est limpidchess.lonebee.games.',
		progress: 'Votre progression vous suit.',
		keep_icon: "Continuez d'utiliser cette icône : elle ouvre le jeu à sa nouvelle adresse, avec votre progression.",
		install: "Vous l'aviez installé comme une application ? Touchez Continuer, puis installez-le à nouveau depuis la nouvelle adresse et supprimez cette ancienne icône.",
		continue: 'Continuer',
		offline: 'Vous êtes hors ligne. Connectez-vous à Internet pour continuer.',
		retry: 'Réessayer',
		waiting_title: 'Limpid Chess déménage',
		waiting: "Il s'installe à sa nouvelle adresse. Réessayez dans quelques minutes.",
	},
	es: {
		title: 'Limpid Chess se ha mudado',
		moved: 'La nueva dirección es limpidchess.lonebee.games.',
		progress: 'Tu progreso viene contigo.',
		keep_icon: 'Sigue usando este icono: abre el juego en su nueva dirección, con tu progreso.',
		install: '¿Lo instalaste como app? Toca Continuar, vuelve a instalarlo desde la nueva dirección y elimina este icono antiguo.',
		continue: 'Continuar',
		offline: 'No tienes conexión. Conéctate a internet para continuar.',
		retry: 'Reintentar',
		waiting_title: 'Limpid Chess se está mudando',
		waiting: 'Se está instalando en su nueva dirección. Vuelve a intentarlo en unos minutos.',
	},
	pt: {
		title: 'O Limpid Chess mudou de endereço',
		moved: 'O novo endereço é limpidchess.lonebee.games.',
		progress: 'Seu progresso vai junto.',
		keep_icon: 'Continue usando este ícone: ele abre o jogo no novo endereço, com seu progresso.',
		install: 'Instalou como app? Toque em Continuar, instale de novo pelo novo endereço e depois remova este ícone antigo.',
		continue: 'Continuar',
		offline: 'Você está offline. Conecte-se à internet para continuar.',
		retry: 'Tentar de novo',
		waiting_title: 'O Limpid Chess está de mudança',
		waiting: 'Ele está se instalando no novo endereço. Tente de novo em alguns minutos.',
	},
	de: {
		title: 'Limpid Chess ist umgezogen',
		moved: 'Die neue Adresse ist limpidchess.lonebee.games.',
		progress: 'Dein Fortschritt kommt mit.',
		keep_icon: 'Nutze weiter dieses Symbol: Es öffnet das Spiel unter der neuen Adresse, mit deinem Fortschritt.',
		install: 'Als App installiert? Tippe auf Weiter, installiere es dann von der neuen Adresse aus erneut und entferne dieses alte Symbol.',
		continue: 'Weiter',
		offline: 'Du bist offline. Verbinde dich mit dem Internet, um weiterzumachen.',
		retry: 'Nochmal',
		waiting_title: 'Limpid Chess zieht um',
		waiting: 'Es richtet sich gerade unter der neuen Adresse ein. Versuche es in ein paar Minuten noch einmal.',
	},
	it: {
		title: 'Limpid Chess si è trasferito',
		moved: 'Il nuovo indirizzo è limpidchess.lonebee.games.',
		progress: 'I tuoi progressi ti seguono.',
		keep_icon: 'Continua a usare questa icona: apre il gioco al nuovo indirizzo, con i tuoi progressi.',
		install: "L'avevi installato come app? Tocca Continua, poi installalo di nuovo dal nuovo indirizzo e rimuovi questa vecchia icona.",
		continue: 'Continua',
		offline: 'Sei offline. Connettiti a internet per continuare.',
		retry: 'Riprova',
		waiting_title: 'Limpid Chess sta traslocando',
		waiting: 'Si sta sistemando al nuovo indirizzo. Riprova tra qualche minuto.',
	},
	ru: {
		title: 'Limpid Chess переехал',
		moved: 'Новый адрес: limpidchess.lonebee.games.',
		progress: 'Ваш прогресс сохранится.',
		keep_icon: 'Продолжайте открывать игру этим значком: он ведёт на новый адрес, с вашим прогрессом.',
		install: 'Установили игру как приложение? Нажмите «Продолжить», установите её заново с нового адреса и удалите старый значок.',
		continue: 'Продолжить',
		offline: 'Нет подключения к интернету. Подключитесь, чтобы продолжить.',
		retry: 'Повторить',
		waiting_title: 'Limpid Chess переезжает',
		waiting: 'Игра обустраивается по новому адресу. Попробуйте ещё раз через несколько минут.',
	},
	tr: {
		title: 'Limpid Chess taşındı',
		moved: 'Yeni adresi limpidchess.lonebee.games.',
		progress: 'İlerlemeniz de sizinle geliyor.',
		keep_icon: 'Bu simgeyi kullanmaya devam edin: oyunu yeni adresinde, ilerlemenizle birlikte açar.',
		install: "Uygulama olarak mı yüklemiştiniz? Devam et'e dokunun, ardından yeni adresten tekrar yükleyin ve bu eski simgeyi kaldırın.",
		continue: 'Devam et',
		offline: 'Çevrimdışısınız. Devam etmek için internete bağlanın.',
		retry: 'Tekrar dene',
		waiting_title: 'Limpid Chess taşınıyor',
		waiting: 'Yeni adresine yerleşiyor. Lütfen birkaç dakika sonra tekrar deneyin.',
	},
	pl: {
		title: 'Limpid Chess ma nowy adres',
		moved: 'Nowy adres to limpidchess.lonebee.games.',
		progress: 'Twoje postępy przenoszą się razem z grą.',
		keep_icon: 'Dalej używaj tej ikony: otwiera grę pod nowym adresem, razem z Twoimi postępami.',
		install: 'Gra jest zainstalowana jako aplikacja? Dotknij Kontynuuj, zainstaluj ją ponownie z nowego adresu i usuń tę starą ikonę.',
		continue: 'Kontynuuj',
		offline: 'Brak połączenia z internetem. Połącz się, aby kontynuować.',
		retry: 'Spróbuj ponownie',
		waiting_title: 'Limpid Chess zmienia adres',
		waiting: 'Gra urządza się pod nowym adresem. Spróbuj ponownie za kilka minut.',
	},
	id: {
		title: 'Limpid Chess sudah pindah',
		moved: 'Alamat barunya limpidchess.lonebee.games.',
		progress: 'Progres Anda ikut pindah.',
		keep_icon: 'Tetap gunakan ikon ini: ikon ini membuka game di alamat barunya, beserta progres Anda.',
		install: 'Memasangnya sebagai aplikasi? Ketuk Lanjutkan, lalu pasang lagi dari alamat baru dan hapus ikon lama ini.',
		continue: 'Lanjutkan',
		offline: 'Anda sedang offline. Sambungkan ke internet untuk melanjutkan.',
		retry: 'Coba lagi',
		waiting_title: 'Limpid Chess sedang pindah',
		waiting: 'Sedang menyiapkan alamat barunya. Coba lagi dalam beberapa menit.',
	},
	vi: {
		title: 'Limpid Chess đã chuyển nhà',
		moved: 'Địa chỉ mới là limpidchess.lonebee.games.',
		progress: 'Tiến trình của bạn vẫn được giữ nguyên.',
		keep_icon: 'Hãy tiếp tục dùng biểu tượng này: nó mở trò chơi ở địa chỉ mới, cùng tiến trình của bạn.',
		install: 'Bạn đã cài đặt như một ứng dụng? Hãy chạm Tiếp tục, rồi cài lại từ địa chỉ mới và xóa biểu tượng cũ này.',
		continue: 'Tiếp tục',
		offline: 'Bạn đang ngoại tuyến. Hãy kết nối internet để tiếp tục.',
		retry: 'Thử lại',
		waiting_title: 'Limpid Chess đang chuyển nhà',
		waiting: 'Trò chơi đang ổn định ở địa chỉ mới. Vui lòng thử lại sau vài phút.',
	},
	uk: {
		title: 'Limpid Chess переїхав',
		moved: 'Нова адреса: limpidchess.lonebee.games.',
		progress: 'Ваш прогрес збережеться.',
		keep_icon: 'Далі відкривайте гру цим значком: він веде на нову адресу, з вашим прогресом.',
		install: 'Встановили гру як застосунок? Натисніть «Продовжити», встановіть її знову з нової адреси й видаліть старий значок.',
		continue: 'Продовжити',
		offline: "Немає з'єднання з інтернетом. Підключіться, щоб продовжити.",
		retry: 'Ще раз',
		waiting_title: 'Limpid Chess переїжджає',
		waiting: 'Гра облаштовується за новою адресою. Спробуйте ще раз за кілька хвилин.',
	},
	el: {
		title: 'Το Limpid Chess μετακόμισε',
		moved: 'Η νέα διεύθυνση είναι limpidchess.lonebee.games.',
		progress: 'Η πρόοδός σας έρχεται μαζί σας.',
		keep_icon: 'Συνεχίστε να χρησιμοποιείτε αυτό το εικονίδιο: ανοίγει το παιχνίδι στη νέα του διεύθυνση, με την πρόοδό σας.',
		install: 'Το είχατε εγκαταστήσει ως εφαρμογή; Πατήστε Συνέχεια, εγκαταστήστε το ξανά από τη νέα διεύθυνση και αφαιρέστε αυτό το παλιό εικονίδιο.',
		continue: 'Συνέχεια',
		offline: 'Είστε εκτός σύνδεσης. Συνδεθείτε στο διαδίκτυο για να συνεχίσετε.',
		retry: 'Ξανά',
		waiting_title: 'Το Limpid Chess μετακομίζει',
		waiting: 'Εγκαθίσταται στη νέα του διεύθυνση. Δοκιμάστε ξανά σε λίγα λεπτά.',
	},
};

// Palette and type from docs/style.css, so the page reads as the same site.
const CSS = `
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #16191e;
	color: #eef1f4; line-height: 1.6; -webkit-font-smoothing: antialiased;
	font-family: system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
main { max-width: 28rem; padding: 24px 16px; text-align: center; }
h1 { font-size: 1.5rem; margin: 0 0 .75rem; }
p { margin: 0 0 1rem; color: rgba(238, 241, 244, .75); }
.go { display: inline-block; margin-top: .5rem; padding: .75rem 1.5rem; border: 0; border-radius: 12px;
	background: #6cc3de; color: #0c1116; font: inherit; font-weight: 700; text-decoration: none; cursor: pointer; }
[hidden] { display: none !important; }
.js main { visibility: hidden; }
.js main.show { visibility: visible; }
`;

// The page script runs in old browsers too, so it stays ES2017 with no build step. `mode` is
// "bridge" (hand the save over, then leave) or "waiting" (the 503 during the certificate gap).
const PAGE_SCRIPT = `(function () {
	'use strict';
	var MODE = __MODE__;
	var NEW_ORIGIN = __ORIGIN__;
	var T = __STRINGS__;
	// Where Godot keeps user://limpid_chess.cfg on the web: IndexedDB "/userfs", store
	// "FILE_DATA", keyed by absolute path (the same in every build ever deployed here).
	var SAVE_KEY = '/userfs/godot/app_userdata/Limpid Chess/limpid_chess.cfg';
	var MAX_SAVE_BYTES = 8192;
	var NOTICE_KEY = 'limpid_moved_notice';
	var main = document.getElementById('main');
	var go = document.getElementById('go');

	function wait(ms) {
		return new Promise(function (resolve) { setTimeout(resolve, ms); });
	}

	// Opened without a version, so it can never upgrade or block the game's own database, and
	// a missing database is not created (the abort): that simply means "no save".
	function readSave() {
		return new Promise(function (resolve) {
			var req;
			try {
				req = indexedDB.open('/userfs');
			} catch (e) {
				resolve(null);
				return;
			}
			req.onupgradeneeded = function () { req.transaction.abort(); };
			req.onerror = function (e) { e.preventDefault(); resolve(null); };
			req.onblocked = function () { resolve(null); };
			req.onsuccess = function () {
				var db = req.result;
				db.onversionchange = function () { db.close(); };
				if (!db.objectStoreNames.contains('FILE_DATA')) {
					db.close();
					resolve(null);
					return;
				}
				try {
					var get = db.transaction('FILE_DATA', 'readonly').objectStore('FILE_DATA').get(SAVE_KEY);
					get.onsuccess = function () {
						db.close();
						// An Int8Array or a view on a larger buffer: read exactly its own bytes.
						var c = get.result && get.result.contents;
						resolve(c && ArrayBuffer.isView(c) ? new Uint8Array(c.buffer, c.byteOffset, c.byteLength) : null);
					};
					get.onerror = function () { db.close(); resolve(null); };
				} catch (e) {
					db.close();
					resolve(null);
				}
			};
		});
	}

	function toBase64Url(bytes) {
		var bin = '';
		for (var i = 0; i < bytes.length; i++) {
			bin += String.fromCharCode(bytes[i]);
		}
		return btoa(bin).replace(/[+]/g, '-').replace(/[/]/g, '_').replace(/=+$/, '');
	}

	// Same clean-up as the game's own hardReset (web/boot_diagnostics.js): the old service worker
	// and its cached files have nothing left to do here. IndexedDB is left alone on purpose, so a
	// later visit can hand the save over again.
	function retireOldApp() {
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
		return Promise.race([Promise.all(jobs), wait(1500)]);
	}

	// The game's own language first, then the website's, then the browser's.
	function pickLang(saveText) {
		var m = /^language="([a-z]{2})"$/m.exec(saveText || '');
		if (m && T[m[1]]) {
			return m[1];
		}
		try {
			var saved = localStorage.getItem('limpid_lang');
			if (saved && T[saved]) {
				return saved;
			}
		} catch (e) {}
		var prefs = navigator.languages || [navigator.language || 'en'];
		for (var i = 0; i < prefs.length; i++) {
			var code = String(prefs[i]).toLowerCase().split('-')[0];
			if (T[code]) {
				return code;
			}
		}
		return 'en';
	}

	function render(lang) {
		var dict = T[lang] || T.en;
		document.documentElement.lang = lang;
		document.title = MODE === 'waiting' ? dict.waiting_title : dict.title;
		var nodes = document.querySelectorAll('[data-t]');
		for (var i = 0; i < nodes.length; i++) {
			nodes[i].textContent = dict[nodes[i].getAttribute('data-t')];
		}
	}

	function show(ids) {
		var nodes = document.querySelectorAll('[data-t], .go');
		for (var i = 0; i < nodes.length; i++) {
			nodes[i].hidden = ids.indexOf(nodes[i].id) < 0;
		}
		main.className = 'show';
	}

	if (MODE === 'waiting') {
		render(pickLang(''));
		show(['waiting_title', 'waiting', 'retry']);
		// Moves on by itself once the new address is ready, but never under a reader's eyes.
		setInterval(function () {
			if (document.visibilityState === 'visible') {
				location.reload();
			}
		}, 60000);
		return;
	}

	// Same path on the new address (a returning player who typed the bare domain goes straight to
	// the game, save and all), the query kept (?ls=ok), and the save in the fragment. Without a
	// save, an ordinary #anchor rides along as a 301 would have kept it.
	function targetFor(bytes) {
		var path = location.pathname;
		if (path === '/play' || (bytes && path.indexOf('/play/') !== 0)) {
			path = '/play/';
		}
		var hash = bytes ? '#lc-move=' + toBase64Url(bytes)
			: (location.hash.indexOf('#lc-move=') === 0 ? '' : location.hash);
		return NEW_ORIGIN + path + location.search + hash;
	}

	(async function () {
		var reading = readSave();
		var slow = {};
		var bytes = await Promise.race([reading, wait(2500).then(function () { return slow; })]);
		if (bytes === slow) {
			// A slow device: show the way out now, without the save, but keep waiting for it rather
			// than leaving it behind (capped, for an old Safari whose IndexedDB never answers).
			render(pickLang(''));
			go.href = targetFor(null);
			show(['title', 'moved', 'go']);
			bytes = await Promise.race([reading, wait(7500).then(function () { return null; })]);
		}
		if (bytes && (bytes.length === 0 || bytes.length > MAX_SAVE_BYTES)) {
			bytes = null;
		}
		var target = targetFor(bytes);
		render(pickLang(bytes ? new TextDecoder().decode(bytes) : ''));
		go.href = target;
		if (navigator.onLine === false) {
			// Keep the old worker for now: it is what shows this page again on an offline launch.
			show(['title', 'offline', 'retry']);
			return;
		}
		await retireOldApp();
		var ios = navigator.standalone === true;
		var standalone = ios || (window.matchMedia && matchMedia('(display-mode: standalone)').matches);
		var seen = true;
		try {
			seen = localStorage.getItem(NOTICE_KEY) === '1';
		} catch (e) {}
		if (standalone && !seen) {
			// Once, for installed apps: they need to know where their game went. On iPhone and iPad a
			// new Home Screen icon starts with empty storage, so there the old icon is the one to keep.
			var ids = ['title', 'moved', 'go'];
			if (bytes) {
				ids.push(ios ? 'keep_icon' : 'progress');
			}
			if (!ios) {
				ids.push('install');
			}
			show(ids);
			go.onclick = function (e) {
				try {
					localStorage.setItem(NOTICE_KEY, '1');
				} catch (x) {}
				e.preventDefault();
				location.replace(target);  // no Back into this page
			};
			return;
		}
		location.replace(target);
	})();

	// Still here after a few seconds (a very slow device): show the way out.
	setTimeout(function () {
		if (main.className !== 'show') {
			show(['title', 'moved', 'go']);
		}
	}, 4000);
})();
`;

// The bridge and the waiting page share one template. Without JavaScript the page still shows
// the English text and a link (search engines get a canonical to the same place).
function htmlPage(mode, origin, canonical) {
	const en = STRINGS.en;
	const js = PAGE_SCRIPT
		.replace('__MODE__', () => JSON.stringify(mode))
		.replace('__ORIGIN__', () => JSON.stringify(origin))
		.replace('__STRINGS__', () => JSON.stringify(STRINGS));
	const waiting = mode === 'waiting';
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${waiting ? en.waiting_title : en.title}</title>
<link rel="canonical" href="${canonical}">
<style>${CSS}</style>
<script>document.documentElement.className = 'js';</script>
</head>
<body>
<main id="main">
<h1 id="title" data-t="title"${waiting ? ' hidden' : ''}>${en.title}</h1>
<h1 id="waiting_title" data-t="waiting_title"${waiting ? '' : ' hidden'}>${en.waiting_title}</h1>
<p id="moved" data-t="moved"${waiting ? ' hidden' : ''}>${en.moved}</p>
<p id="progress" data-t="progress" hidden>${en.progress}</p>
<p id="keep_icon" data-t="keep_icon" hidden>${en.keep_icon}</p>
<p id="waiting" data-t="waiting"${waiting ? '' : ' hidden'}>${en.waiting}</p>
<p id="install" data-t="install" hidden>${en.install}</p>
<p id="offline" data-t="offline" hidden>${en.offline}</p>
<a id="go" class="go" href="${canonical}" data-t="continue"${waiting ? ' hidden' : ''}>${en.continue}</a>
<a id="retry" class="go" href="" data-t="retry"${waiting ? '' : ' hidden'}>${en.retry}</a>
</main>
<script>${js}</script>
</body>
</html>
`;
}
