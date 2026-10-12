// End-to-end check of the itch.io build (web/build_web.sh --itch) in real browsers, served the
// way itch.io serves it: the game's folder on an origin shared by every itch.io game, inside an
// iframe of the game's page on another site. Two local origins stand in for the two:
//   http://localhost:8751   "lone-bee.itch.io/limpid-chess": the page, with itch's 2026 iframe
//   http://127.0.0.1:8752   "html-classic.itch.zone": the build under /html/12345678/, and a 404
//                           (logged as an ESCAPE) for anything outside that folder
// Different sites, so the game is a third-party frame with partitioned storage, as on itch. What
// Playwright turns off for tests is turned back on: the popup blocker, and third-party storage
// partitioning (Chromium) or Total Cookie Protection (Firefox). Nothing leaves the machine:
// requests to any other host get a stand-in page or are aborted, and a local proxy refuses
// whatever the routes cannot see.
//
// Checks: 1 boot, 2 paths, 3 engine, 4 no service worker, 5 save, 6 Premium screen,
// 7 no navigator.locks error, 8 tab re-read, 10 no GDScript error; Chromium also checks the Premium
// screen on an Android phone, and 9 the boot watchdog's "Download again". --website instead runs 8 on the website
// build, top-level, where the re-read must still open '/userfs'. Screenshots and console logs go
// to a temp folder printed at the end: look at the screenshots, the labels on the canvas are
// not checked any other way.
//
// Needs a fresh export (web/build_web.sh --itch, or plain for --website) and playwright outside
// the repo, as for e2e_check.mjs:
//   mkdir -p /tmp/pwtest && cd /tmp/pwtest && npm init -y && npm install playwright
//   npx playwright install chromium firefox webkit
//   PW_DIR=/tmp/pwtest node web/tools/itch_check.mjs [chromium] [firefox] [webkit] [--website] [--build=DIR]
// No browser named runs all three, about 6 minutes in all (check 9 sits out the 40 s watchdog).
// WebKit is Playwright's Linux build, not Safari: no popup blocker, and not Safari's storage rules.
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const PW_DIR = process.env.PW_DIR || '/tmp/pwtest';
const pw = createRequire(PW_DIR + '/package.json')('playwright');
const PW_VERSION = createRequire(PW_DIR + '/package.json')('playwright/package.json').version;
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const args = process.argv.slice(2);
const WEBSITE = args.includes('--website');
const BUILD = path.resolve((args.find((a) => a.startsWith('--build=')) || '').slice(8)
	|| path.join(ROOT, WEBSITE ? 'build/web' : 'build/itch'));
if (!fs.existsSync(path.join(BUILD, 'index.html'))) {
	console.error(`no export in ${BUILD}: run web/build_web.sh${WEBSITE ? '' : ' --itch'} first`);
	process.exit(2);
}
const OUT = fs.mkdtempSync(path.join(os.tmpdir(), 'limpid-itch-check-'));

const PAGE_PORT = 8751;
const GAME_PORT = 8752;
const PAGE = `http://localhost:${PAGE_PORT}`;   // "lone-bee.itch.io"
const GAME = `http://127.0.0.1:${GAME_PORT}`;   // "html-classic.itch.zone"
const FOLDER = '/html/12345678/';               // this build's folder there
const OTHER = '/html/99999999/';                // another itch.io game's folder (check 9)
// The itch build's own database: the user folder build_web.sh mounts (from config/name).
const SAVE_DB = '/userfs/godot/app_userdata/'
	+ /^config\/name="([^"]*)"$/m.exec(fs.readFileSync(path.join(ROOT, 'project.godot'), 'utf8'))[1];
const SAVE_KEY = SAVE_DB + '/limpid_chess.cfg';   // the same key in '/userfs' on the website
// The browser Stockfish, named from web/engine/ as build_web.sh does: an engine bump must not
// leave stale names behind.
const ENGINE = fs.readdirSync(path.join(ROOT, 'web/engine')).filter((f) => /\.(js|wasm)$/.test(f));
const ENGINE_JS = ENGINE.find((f) => f.endsWith('.js'));
const WEBSITE_URL = 'https://limpidchess.lonebee.games/play/';
const PLAY_URL = 'https://play.google.com/store/apps/details?id=game.limpidchess&utm_source=itch.io&utm_campaign=premium';
const ALLOW = 'autoplay; fullscreen *; geolocation; microphone; camera; midi; monetization; '
	+ 'xr-spatial-tracking; gamepad; gyroscope; accelerometer; xr; cross-origin-isolated; web-share';
// Tap targets in CSS px inside the frame, read off this build's screenshots.
const DESKTOP = { newGame: [250, 450], coco: [250, 144], gamesPill: [367, 46], premiumButton: [250, 703] };
const PHONE = { gamesPill: [300, 40], premiumButton: [206, 627] };   // Pixel 7: 412x839, frame covering it
const BOARD_DARK = [117, 145, 168];   // UI.BOARD_DARK: ~70k pixels of the game's board in the desktop frame
const ACCENT = [102, 189, 217];       // UI.ACCENT: the option arrows before the reveal, hundreds of pixels each
// What the boot watchdog's reset downloads again (build_web.sh stamps the same list into OWN_FILES).
const OWN_FILES = fs.readdirSync(BUILD).filter((f) => /\.(js|wasm|pck)$/.test(f));
// Playwright 1.63's --disable-features list, less ThirdPartyStoragePartitioning (and Edge's own):
// the last --disable-features wins, so passing it again turns partitioning back on, as in Chrome.
const PW_DISABLED_FEATURES = ['AvoidUnnecessaryBeforeUnloadCheckSync', 'DestroyProfileOnBrowserClose',
	'DialMediaRouteProvider', 'GlobalMediaControls', 'HttpsUpgrades', 'LensOverlay', 'MediaRouter',
	'PaintHolding', 'BlockOriginHeaderModificationOnRedirect', 'Translate', 'AutoDeElevate', 'OptimizationHints'];
if (PW_VERSION !== '1.63.0') {
	console.log(`WARNING: PW_DISABLED_FEATURES copies Playwright 1.63's list; check chromiumSwitches in ${PW_VERSION}`);
}

const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm',
	'.pck': 'application/octet-stream', '.json': 'application/json', '.png': 'image/png', '.txt': 'text/plain' };

// itch's page for the game: the frame at the embed size, or covering the screen, as a phone
// shows it once the player taps "Run game".
function itchPage(folder, phone) {
	const size = phone ? 'style="position:fixed;top:0;left:0;width:100vw;height:100vh;border:0"' : 'width="500" height="900"';
	return `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="icon" href="data:,"><title>Limpid Chess by Lone Bee</title>
<body style="margin:0;padding:${phone ? 0 : 20}px;background:#2b2b2b">
<iframe id="game_drop" frameborder="0" scrolling="no" allowtransparency="true" allow="${ALLOW}"
 allowfullscreen="true" webkitallowfullscreen="true" mozallowfullscreen="true" msallowfullscreen="true"
 ${size} src="${GAME}${folder}index.html"></iframe>`;
}

const pageServer = http.createServer((req, res) => {
	const url = new URL(req.url, PAGE);
	const folder = { '/limpid-chess': FOLDER, '/other-game': OTHER }[url.pathname];
	res.writeHead(folder ? 200 : 404, { 'content-type': 'text/html' });
	res.end(folder ? itchPage(folder, url.searchParams.has('phone')) : '<h1>404</h1>');
});

// Another itch.io game played earlier on the same origin, with a service worker and a cache of
// its own: check 9's reset must leave both alone.
const OTHER_FILES = {
	'index.html': `<!doctype html><script>
caches.open('other-game').then((c) => c.put('saved', new Response('theirs')))
	.then(() => navigator.serviceWorker.register('sw.js')).then(() => navigator.serviceWorker.ready)
	.then(() => { document.title = 'ready'; }, (e) => { document.title = 'failed: ' + e; });
</script>`,
	'sw.js': '// another game\'s service worker\n',
};

const requests = [];    // everything the game origin was asked for
const stalled = [];     // check 9's index.wasm responses, held open
let stallWasm = false;  // check 9: the next index.wasm stops after its first megabyte
const gameServer = http.createServer((req, res) => {
	const p = decodeURIComponent(new URL(req.url, GAME).pathname);
	const r = { path: p, dest: req.headers['sec-fetch-dest'] || '-', status: 200 };
	requests.push(r);
	if (p === '/probe') {   // a top-level page of this origin (check 5) and a harmless popup (check 6)
		res.writeHead(200, { 'content-type': 'text/html' });
		return res.end('<!doctype html><link rel="icon" href="data:,"><title>probe</title>');
	}
	if (p.startsWith(OTHER) && OTHER_FILES[p.slice(OTHER.length)]) {
		res.writeHead(200, { 'content-type': TYPES[path.extname(p)] });
		return res.end(OTHER_FILES[p.slice(OTHER.length)]);
	}
	r.escape = !p.startsWith(FOLDER);
	const file = path.join(BUILD, p.slice(FOLDER.length) || 'index.html');
	if (r.escape || !file.startsWith(BUILD + path.sep) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
		r.status = 404;
		res.writeHead(404, { 'content-type': 'text/plain' });
		return res.end('not found');
	}
	// itch keeps every file in caches for a month (see boot_diagnostics.js, refetchOwnFiles).
	res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream',
		'content-length': fs.statSync(file).size, 'cache-control': 'max-age=2592000' });
	if (stallWasm && p === FOLDER + 'index.wasm') {
		stallWasm = false;
		stalled.push(res);
		return fs.createReadStream(file, { end: (1 << 20) - 1 }).pipe(res, { end: false });
	}
	fs.createReadStream(file).pipe(res);
});

// Whatever the routes cannot see comes here instead of going out, and is refused: in practice the
// browser's own traffic (Chrome for Testing calls Google on its own) and its preconnect to a popup's
// host, which it opens before the route has answered.
const refused = [];
const proxy = http.createServer((req, res) => {
	refused.push(req.url);
	res.writeHead(403);
	res.end();
});
proxy.on('connect', (req, socket) => {
	refused.push('CONNECT ' + req.url);
	socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
});

function launchOptions(name, extraArgs = []) {
	const o = { proxy: { server: `http://127.0.0.1:${proxy.address().port}`, bypass: 'localhost,127.0.0.1' } };
	if (name === 'chromium') {
		o.channel = 'chromium';   // the full browser in new headless mode, not the headless shell
		o.ignoreDefaultArgs = ['--disable-popup-blocking'];
		o.args = ['--use-angle=swiftshader', '--ignore-gpu-blocklist',
			'--disable-features=' + PW_DISABLED_FEATURES.join(','), ...extraArgs];
	} else if (name === 'firefox') {
		o.firefoxUserPrefs = { 'dom.disable_open_during_load': true, 'network.cookie.cookieBehavior': 5 };
	} else {
		// The VS Code snap leaks these, and WebKit's network process then fails every navigation.
		const leaks = ['LD_LIBRARY_PATH', 'GTK_PATH', 'GIO_MODULE_DIR'];
		o.env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !leaks.includes(k)));
	}
	return o;
}

// Runs in every frame before its own scripts: records what the game frame does with Workers and
// service workers.
function watchGameFrame(folder) {
	if (!location.pathname.startsWith(folder)) {
		return;
	}
	const seen = (window.__itchCheck = { workers: [], registers: [] });
	const RealWorker = window.Worker;
	window.Worker = function (url, options) {
		const worker = new RealWorker(url, options);
		const rec = { url: String(url), bestmoves: 0 };
		seen.workers.push(rec);
		worker.addEventListener('message', (e) => { rec.bestmoves += String(e.data).startsWith('bestmove') ? 1 : 0; });
		return worker;
	};
	if (navigator.serviceWorker) {
		const register = navigator.serviceWorker.register.bind(navigator.serviceWorker);
		navigator.serviceWorker.register = (url, options) => {
			seen.registers.push(String(url));
			return register(url, options);
		};
	}
	// Every label the boot watchdog's button takes (check 9), logged as it changes: the console
	// keeps them even once the frame has navigated away.
	let label = null;
	new MutationObserver(() => {
		const button = document.querySelector('button');
		if (button && button.textContent !== label) {
			label = button.textContent;
			console.log('itch_check button: ' + label);
		}
	}).observe(document, { subtree: true, childList: true, characterData: true });
}

const external = [];   // requests to other hosts, answered here
const logs = [];       // console lines and page errors of the current browser
async function newContext(browser, options) {
	const ctx = await browser.newContext({ locale: 'en-US', ...options });
	await ctx.route((url) => !['localhost', '127.0.0.1'].includes(url.hostname), (route) => {
		const r = route.request();
		external.push({ url: r.url(), type: r.resourceType() });
		return r.resourceType() === 'document'
			? route.fulfill({ contentType: 'text/html', body: '<!doctype html><link rel="icon" href="data:,"><title>stand-in</title>' })
			: route.abort('blockedbyclient');
	});
	await ctx.addInitScript(watchGameFrame, FOLDER);
	ctx.on('console', (m) => logs.push(`${m.type()}: ${m.text()}`));
	ctx.on('weberror', (e) => logs.push(`pageerror: ${e.error().message}`));
	ctx.on('dialog', (d) => {
		logs.push(`dialog ${d.type()}: ${d.message()}`);
		return d.type() === 'beforeunload' ? d.accept() : d.dismiss();   // the game guards a game in progress
	});
	return ctx;
}

async function gameFrame(page) {
	const iframe = await page.$('#game_drop');
	return iframe ? iframe.contentFrame() : page.mainFrame();
}

// Godot's shell removes #status once the engine has started.
async function booted(page, seconds = 180) {
	for (let i = 0; i < seconds; i++) {
		const frame = await gameFrame(page);
		if (frame && await frame.evaluate(() => !document.getElementById('status')).catch(() => false)) {
			return frame;
		}
		await page.waitForTimeout(1000);
	}
	return null;
}

async function waitFor(fn, seconds) {
	for (let i = 0; i < seconds; i++) {
		const value = await fn();
		if (value) {
			return value;
		}
		await new Promise((r) => setTimeout(r, 1000));
	}
	return null;
}

async function tap(page, [x, y], touch = false) {
	const box = await page.locator('#game_drop').boundingBox();
	return touch ? page.touchscreen.tap(box.x + x, box.y + y) : page.mouse.click(box.x + x, box.y + y);
}

function shot(page, name) {
	return page.locator('#game_drop').screenshot({ path: path.join(OUT, name + '.png') });
}

// Decodes a screenshot and returns a counter of the pixels close to a colour. Playwright writes
// 8-bit, non-interlaced RGB(A) PNGs, so undoing the row filters is all the decoding there is.
function pixelCounter(png) {
	if (png[24] !== 8 || png[28] !== 0 || ![2, 6].includes(png[25])) {
		throw new Error('unexpected PNG format: the decoder below only handles 8-bit RGB(A)');
	}
	const width = png.readUInt32BE(16);
	const height = png.readUInt32BE(20);
	const bpp = png[25] === 6 ? 4 : 3;
	const chunks = [];
	for (let at = 8; at < png.length; at += png.readUInt32BE(at) + 12) {
		if (png.toString('latin1', at + 4, at + 8) === 'IDAT') {
			chunks.push(png.subarray(at + 8, at + 8 + png.readUInt32BE(at)));
		}
	}
	const raw = zlib.inflateSync(Buffer.concat(chunks));
	const stride = width * bpp;
	const px = Buffer.alloc(height * stride);
	for (let y = 0; y < height; y++) {
		const filter = raw[y * (stride + 1)];
		for (let x = 0; x < stride; x++) {
			const at = y * stride + x;
			const left = x >= bpp ? px[at - bpp] : 0;
			const up = y ? px[at - stride] : 0;
			const corner = x >= bpp && y ? px[at - stride - bpp] : 0;
			const p = left + up - corner;
			const paeth = Math.abs(p - left) <= Math.abs(p - up) && Math.abs(p - left) <= Math.abs(p - corner)
				? left : Math.abs(p - up) <= Math.abs(p - corner) ? up : corner;
			px[at] = raw[y * (stride + 1) + 1 + x] + [0, left, up, (left + up) >> 1, paeth][filter];
		}
	}
	return ([r, g, b], tolerance = 10) => {
		let n = 0;
		for (let i = 0; i < px.length; i += bpp) {
			n += Math.abs(px[i] - r) <= tolerance && Math.abs(px[i + 1] - g) <= tolerance
				&& Math.abs(px[i + 2] - b) <= tolerance ? 1 : 0;
		}
		return n;
	};
}

// The option arrows: once the board is up, the only UI.ACCENT on the game screen (the Bots screen
// before it has accent pips, hence the board first). 1 to 3 of them, by design.
async function arrowsShown(page, name) {
	for (let i = 0; i < 40; i++) {
		await page.waitForTimeout(1500);
		const count = pixelCounter(await shot(page, name));
		if (count(BOARD_DARK) > 40000 && count(ACCENT) > 300) {
			await page.waitForTimeout(1000);   // let them finish drawing for the screenshot
			return pixelCounter(await shot(page, name))(ACCENT);
		}
	}
	return 0;
}

// The save as Emscripten's IDBFS keeps it: database `db`, store FILE_DATA, key = the file's path.
// Versionless open, aborted if the database is missing, so reading never creates one.
function readSave(target, db) {
	return target.evaluate(([db, key]) => new Promise((resolve) => {
		const req = indexedDB.open(db);
		req.onupgradeneeded = () => req.transaction.abort();
		req.onerror = (e) => { e.preventDefault(); resolve(null); };
		req.onsuccess = () => {
			const d = req.result;
			if (!d.objectStoreNames.contains('FILE_DATA')) {
				d.close();
				resolve(null);
				return;
			}
			const get = d.transaction('FILE_DATA', 'readonly').objectStore('FILE_DATA').get(key);
			get.onsuccess = () => {
				d.close();
				resolve(get.result && get.result.contents ? new TextDecoder().decode(get.result.contents) : null);
			};
			get.onerror = () => { d.close(); resolve(null); };
		};
	}), [db, SAVE_KEY]).catch(() => null);
}

// GameManager's tab re-read: a tab coming back into view reads the save from IndexedDB and hands
// it to the game. Records which databases it opens and what it hands over.
function reread(target) {
	return target.evaluate(() => new Promise((resolve) => {
		const opened = [];
		const open = indexedDB.open;
		const handOver = window._limpidOtherTabSaved;
		let done = false;
		const finish = (json) => {
			if (!done) {
				done = true;
				delete indexedDB.open;
				window._limpidOtherTabSaved = handOver;
				resolve({ opened, cfg: json ? JSON.parse(json).cfg : null });
			}
		};
		indexedDB.open = function (name) {
			opened.push(String(name));
			return open.apply(this, arguments);
		};
		window._limpidOtherTabSaved = function (json) {
			handOver.apply(this, arguments);
			finish(json);
		};
		setTimeout(() => finish(null), 5000);
		document.dispatchEvent(new Event('visibilitychange'));
	})).catch((e) => ({ opened: [], cfg: null, error: String(e).split('\n')[0] }));
}

// Requests to Lemon Squeezy (the website's store) since `from`, seen by the routes or the proxy.
function lemonSqueezy(from) {
	return [...external.slice(from).map((e) => e.url), ...refused].filter((u) => /lemonsqueezy/.test(u));
}

async function popupFrom(ctx, action, timeout = 10000) {
	const next = ctx.waitForEvent('page', { timeout }).catch(() => null);
	await action();
	const popup = await next;
	if (!popup) {
		return null;
	}
	await popup.waitForLoadState('domcontentloaded').catch(() => {});
	const url = popup.url();
	await popup.close();
	return url;
}

const results = [];
function check(name, ok, detail = '') {
	results.push({ name, ok });
	console.log(`  ${ok === null ? 'SKIP' : ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  (' + detail + ')' : ''}`);
}

async function itchRun(name) {
	const browser = await pw[name].launch(launchOptions(name));
	const ctx = await newContext(browser, { viewport: { width: 540, height: 940 } });
	const page = await ctx.newPage();
	const fromRequest = requests.length;
	const fromExternal = external.length;
	const popups = name === 'chromium' ? [WEBSITE_URL, PLAY_URL] : [WEBSITE_URL];   // what check 6 opens
	try {
		await page.goto(`${PAGE}/limpid-chess`);
		let frame = await booted(page);
		check('1 boot: the engine starts in the frame', !!frame, `Home: see ${name}-1-home.png`);
		if (!frame) {
			return;
		}
		await page.waitForTimeout(3000);
		await shot(page, `${name}-1-home`);

		const lockErrors = logs.filter((l) => /LockManager|navigator\.locks/.test(l));
		const lockProbe = await frame.evaluate(() => (navigator.locks
			? navigator.locks.query().then(() => 'allowed', (e) => 'refused: ' + e.message) : 'absent'));
		check('7 no navigator.locks error at boot', !lockErrors.length,
			`${lockErrors[0] || 'none'}; this frame's LockManager.query(): ${lockProbe}`);

		const sw = await frame.evaluate(async () => ({ registered: window.__itchCheck.registers,
			registrations: navigator.serviceWorker ? (await navigator.serviceWorker.getRegistrations()).length : 0 }));
		check('4 no service worker: none registered, no register() call', !sw.registrations && !sw.registered.length,
			JSON.stringify(sw));

		await tap(page, DESKTOP.newGame);
		await page.waitForTimeout(2500);
		await shot(page, `${name}-2-bots`);
		await tap(page, DESKTOP.coco);
		const arrows = await arrowsShown(page, `${name}-3-game`);
		const sf = (await frame.evaluate(() => window.__itchCheck.workers)).find((w) => w.url.includes('stockfish')) || {};
		const fetched = (f) => requests.slice(fromRequest).some((r) => r.path === FOLDER + f && r.status === 200);
		const fallback = logs.filter((l) => /StockfishEngine:.*fallback/.test(l));
		check('3 engine: Stockfish runs from the folder, a game shows its option arrows',
			sf.url === ENGINE_JS && ENGINE.every(fetched) && sf.bestmoves > 0 && !fallback.length && arrows > 0,
			`new Worker('${sf.url}'), ${sf.bestmoves} bestmove(s), ${arrows} arrow pixels in ${name}-3-game.png, `
				+ `fallback: ${fallback[0] || 'none'}`);

		const saved = await waitFor(async () => {
			const text = await readSave(frame, SAVE_DB);
			return text && text.includes('games_today=1') ? text : null;
		}, 30);
		const inShared = await readSave(frame, '/userfs');
		const databases = await frame.evaluate(async () => (indexedDB.databases
			? (await indexedDB.databases()).map((d) => d.name) : 'not listed')).catch((e) => String(e));
		const probe = await ctx.newPage();
		await probe.goto(`${GAME}/probe`);
		const topLevel = await readSave(probe, SAVE_DB);
		await probe.close();
		await page.reload();
		frame = await booted(page);
		const reloaded = frame && await waitFor(() => readSave(frame, SAVE_DB), 10);
		await page.waitForTimeout(3000);
		await shot(page, `${name}-4-home-after-reload`);
		check('5 save: in its own database, kept on reload, unseen by a top-level visit',
			!!saved && saved.includes('games_today=1') && !inShared && !topLevel && reloaded === saved,
			`databases ${JSON.stringify(databases)}; ${saved ? 'games_today=1 ' + saved.includes('games_today=1') : 'NO save'}; `
				+ `in '/userfs': ${inShared ? 'YES' : 'no'}; top-level visit sees it: ${topLevel ? 'YES' : 'no'}; `
				+ `after reload: ${!reloaded ? 'GONE' : reloaded === saved ? 'same' : 'CHANGED'}`);
		if (!frame) {
			return;
		}

		const rr = await reread(frame);
		check('8 tab re-read: reads the save from its own database', !!rr.cfg && rr.cfg === reloaded
			&& rr.opened.includes(SAVE_DB) && !rr.opened.includes('/userfs'),
			`opened ${JSON.stringify(rr.opened)}, handed the game ${rr.cfg ? (rr.cfg === reloaded ? 'the save' : 'ANOTHER text') : 'nothing'}`
				+ (rr.error ? `; ${rr.error}` : ''));

		// Chromium gives every evaluate() a user gesture that lasts 5 s: let it expire, so the
		// popup below can only come from the tap.
		await page.waitForTimeout(6000);
		await tap(page, DESKTOP.gamesPill);
		await page.waitForTimeout(2500);
		await shot(page, `${name}-5-premium`);
		const opened = await popupFrom(ctx, () => tap(page, DESKTOP.premiumButton));
		const sold = lemonSqueezy(fromExternal);
		// No price and no key button are drawn on the canvas: the screenshot is the only check of those.
		check('6 Premium screen: its one button opens the website in a popup', opened === WEBSITE_URL,
			`popup ${opened || 'NONE'}; Lemon Squeezy requests: ${sold.length}; price and key button: see ${name}-5-premium.png`);
		// Control: a window.open() with no gesture behind it must be blocked, or the above proves nothing.
		const control = await popupFrom(ctx, () => frame.evaluate((url) => {
			setTimeout(() => window.open(url), 6000);
		}, `${GAME}/probe`), 9000);
		check('6 control: the popup blocker stops a window.open() with no gesture', name === 'webkit' ? null : !control,
			name === 'webkit' ? "Playwright's WebKit has no popup blocker" : control ? 'it OPENED' : 'blocked');

		if (name === 'chromium') {
			await phoneRun();
			await stallRun(browser);
		}
	} finally {
		const mine = requests.slice(fromRequest);
		const escapes = mine.filter((r) => r.escape).map((r) => r.path);
		const missing = mine.filter((r) => r.status === 404 && !r.escape).map((r) => r.path);
		const files = [...new Set(mine.filter((r) => r.path.startsWith(FOLDER)).map((r) => r.path.slice(FOLDER.length)))];
		const others = external.slice(fromExternal).filter((e) => !(e.type === 'document' && popups.includes(e.url)));
		const proxied = {};
		refused.forEach((r) => {
			const host = r.replace(/^(CONNECT |https?:\/\/)/, '').replace(/[:/].*$/, '');
			proxied[host] = (proxied[host] || 0) + 1;
		});
		check('2 paths: every request stays in the folder, none to another host',
			!escapes.length && !missing.length && !others.length,
			`${files.length} files (${files.join(', ')}); escapes: ${escapes.join(', ') || 'none'}; 404: ${missing.join(', ') || 'none'}; `
				+ `other hosts: ${others.map((e) => `${e.type} ${e.url}`).join(', ') || 'only the expected popups'}; `
				+ `refused by the proxy: ${Object.entries(proxied).map(([h, n]) => `${h} x${n}`).join(', ') || 'nothing'}`);
		await browser.close();
	}
}

// Chromium as an Android phone, the frame covering the screen. An out-of-process frame gets the
// phone's user agent and touch but devicePixelRatio 1, so the frame stays in-process (as on most
// Android Chrome sites) for faithful screenshots. Itch.android reads the user agent either way.
async function phoneRun() {
	const browser = await pw.chromium.launch(launchOptions('chromium', ['--disable-site-isolation-trials']));
	const ctx = await newContext(browser, pw.devices['Pixel 7']);
	const page = await ctx.newPage();
	const fromExternal = external.length;
	try {
		await page.goto(`${PAGE}/limpid-chess?phone`);
		const frame = await booted(page);
		if (!frame) {
			check('6 Premium screen on an Android phone', false, 'did not boot');
			return;
		}
		const [ua, dpr] = await frame.evaluate(() => [navigator.userAgent, devicePixelRatio]);
		await page.waitForTimeout(6000);   // as on the desktop: no evaluate() gesture left for the taps
		await shot(page, 'chromium-phone-1-home');
		await tap(page, PHONE.gamesPill, true);
		await page.waitForTimeout(2500);
		await shot(page, 'chromium-phone-2-premium');
		const opened = await popupFrom(ctx, () => tap(page, PHONE.premiumButton, true));
		const sold = lemonSqueezy(fromExternal);
		check('6 Premium screen on an Android phone: its button opens the Play listing', opened === PLAY_URL,
			`popup ${opened || 'NONE'}; Lemon Squeezy requests: ${sold.length}; frame: ${/Android/.test(ua) ? 'Android' : 'NOT Android'} `
				+ `user agent, devicePixelRatio ${dpr}; label: see chromium-phone-2-premium.png`);
	} finally {
		await browser.close();
	}
}

// 9. A boot that stalls: another itch game has left a service worker and a cache on the shared
// origin, then index.wasm stops arriving. The watchdog's panel must offer "Download again", which
// downloads each of our own files once more (a second tap must not start a second download) and
// then reloads the frame, touching neither. That those downloads skip the HTTP cache cannot be
// seen here: while a route is set, Playwright turns the browser's HTTP cache off altogether.
async function stallRun(browser) {
	const ctx = await newContext(browser, { viewport: { width: 540, height: 940 } });
	const page = await ctx.newPage();
	await page.goto(`${PAGE}/other-game`);
	const other = await gameFrame(page);
	await other.waitForFunction(() => document.title !== '', null, { timeout: 30000 }).catch(() => {});
	const otherState = await other.evaluate(() => document.title);
	stallWasm = true;
	await page.goto(`${PAGE}/limpid-chess`);
	const button = (await gameFrame(page)).getByRole('button', { name: 'Download again' });
	const t0 = Date.now();
	const panel = await button.waitFor({ timeout: 90000 }).then(() => true, () => false);
	const seconds = Math.round((Date.now() - t0) / 1000);
	await shot(page, 'chromium-9-stalled');
	const mark = requests.length;
	if (panel) {
		const box = await button.boundingBox();
		await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
		await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);   // an impatient second tap
	}
	const frame = panel ? await booted(page) : null;
	const label = logs.some((l) => l.endsWith('itch_check button: Downloading…')) ? 'Downloading…' : 'unchanged';
	// The reset's own downloads: fetch()es after the tap and before the frame navigated (the reboot
	// then loads everything again by itself).
	const again = requests.slice(mark);
	const nav = again.findIndex((r) => r.path === FOLDER + 'index.html' && r.dest === 'iframe');
	const reset = (nav >= 0 ? again.slice(0, nav) : again).filter((r) => r.dest === 'empty');
	const times = (f) => reset.filter((r) => r.path === FOLDER + f).length;
	const missed = OWN_FILES.filter((f) => !times(f));
	const twice = OWN_FILES.filter((f) => times(f) > 1);
	const left = frame ? await frame.evaluate(async () => ({
		workers: (await navigator.serviceWorker.getRegistrations()).map((r) => new URL(r.scope).pathname),
		caches: await caches.keys() })) : { workers: [], caches: [] };
	check('9 stalled boot: "Download again" fetches our files once more and reloads, other games untouched',
		otherState === 'ready' && panel && label === 'Downloading…' && !missed.length && !twice.length
			&& nav >= 0 && !!frame && left.workers.includes(OTHER) && left.caches.includes('other-game'),
		`other game: ${otherState}; panel ${panel ? `after ${seconds} s` : 'NEVER'}; button after the tap: '${label}'; `
			+ `downloaded again: ${OWN_FILES.length - missed.length}/${OWN_FILES.length}`
			+ `${missed.length ? ' (missing ' + missed.join(', ') + ')' : ''}${twice.length ? ', TWICE: ' + twice.join(', ') : ''}; `
			+ `frame reloaded: ${nav >= 0}, booted: ${!!frame}; left on the origin: ${JSON.stringify(left)}`);
	await ctx.close();
}

// The website build, top-level: the shared re-read code must still open '/userfs' there.
async function websiteRun(name) {
	const browser = await pw[name].launch(launchOptions(name));
	try {
		const ctx = await newContext(browser, { viewport: { width: 500, height: 900 } });
		const page = await ctx.newPage();
		// A save handed over the way the old domain does it (web/old_domain/): the game writes it at boot.
		const save = '[player]\n\nreview_done=true\n\n[stats]\n\ngames_played=42\n';
		await page.goto(`${GAME}${FOLDER}index.html#lc-move=${Buffer.from(save).toString('base64url')}`);
		const frame = await booted(page);
		const saved = frame && await waitFor(async () => {
			const text = await readSave(frame, '/userfs');
			return text && text.includes('games_played=42') ? text : null;
		}, 30);
		const rr = saved ? await reread(frame) : { opened: [], cfg: null };
		check("8 tab re-read on the website build: reads the save from '/userfs'",
			!!saved && rr.cfg === saved && rr.opened.includes('/userfs'),
			`booted: ${!!frame}; save in '/userfs': ${!!saved}; opened ${JSON.stringify(rr.opened)}, `
				+ `handed the game ${rr.cfg ? (rr.cfg === saved ? 'the save' : 'ANOTHER text') : 'nothing'}`);
	} finally {
		await browser.close();
	}
}

await new Promise((r) => pageServer.listen(PAGE_PORT, 'localhost', r));
await new Promise((r) => gameServer.listen(GAME_PORT, '127.0.0.1', r));
await new Promise((r) => proxy.listen(0, '127.0.0.1', r));
console.log(`build: ${BUILD}`);
const which = args.filter((a) => ['chromium', 'firefox', 'webkit'].includes(a));
for (const name of which.length ? which : ['chromium', 'firefox', 'webkit']) {
	console.log(`=== ${name}${WEBSITE ? ' (website build)' : ''} ===`);
	logs.length = 0;
	refused.length = 0;
	try {
		await (WEBSITE ? websiteRun(name) : itchRun(name));
	} catch (e) {
		check('no unexpected exception', false, String(e).split('\n')[0]);
	}
	const gdErrors = logs.filter((l) => /SCRIPT ERROR|Parse Error|USER ERROR/.test(l));
	check('10 no GDScript error in the console', !gdErrors.length, gdErrors[0] || '');
	fs.writeFileSync(path.join(OUT, `${name}-console.log`), logs.join('\n') + '\n');
}
stalled.forEach((res) => res.destroy());
pageServer.close();
gameServer.close();
proxy.close();
const failed = results.filter((r) => r.ok === false).length;
console.log(`screenshots and console logs: ${OUT}`);
console.log(failed ? `${failed} check(s) FAILED` : 'all checks passed');
process.exit(failed ? 1 : 0);
