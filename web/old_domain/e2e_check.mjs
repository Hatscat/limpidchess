// End-to-end check of the move, in real browsers, with the real Godot build and worker.js:
//   1. a player has a save at the OLD address, written by the game itself, and the game's
//      service worker installed there;
//   2. the old address switches to worker.js;
//   3. opening the old address hands the save over, and the game at the NEW address takes it.
// Two local origins stand in for the two addresses. Needs a fresh export in build/web
// (web/build_web.sh, no --deploy) and playwright outside the repo, as for webkit_check.mjs:
//   mkdir -p /tmp/pwtest && cd /tmp/pwtest && npm init -y && npm install playwright
//   npx playwright install chromium firefox webkit
//   env -u LD_LIBRARY_PATH -u GTK_PATH -u GIO_MODULE_DIR PW_DIR=/tmp/pwtest \
//     node web/old_domain/e2e_check.mjs [chromium] [firefox] [webkit]
// (The env -u is the VS Code snap leak described in web/tools/webkit_check.mjs.)
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const PW_DIR = process.env.PW_DIR || '/tmp/pwtest';
const pw = createRequire(PW_DIR + '/package.json')('playwright');
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const BUILD = path.join(ROOT, 'build/web');
const DOCS = path.join(ROOT, 'docs');
const worker = (await import('./worker.js')).default;

const OLD_PORT = 8741;
const NEW_PORT = 8742;
const OLD = `http://localhost:${OLD_PORT}`;   // "limpidchess.com"
const NEW = `http://127.0.0.1:${NEW_PORT}`;   // "limpidchess.lonebee.games"
const SAVE_KEY = '/userfs/godot/app_userdata/Limpid Chess/limpid_chess.cfg';

const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm',
	'.pck': 'application/octet-stream', '.json': 'application/json', '.png': 'image/png',
	'.css': 'text/css', '.txt': 'text/plain', '.jpg': 'image/jpeg', '.mp4': 'video/mp4' };

// Both sites as GitHub Pages serves them: the landing page from docs/, the game at /play/.
function serveSite(req, res) {
	let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
	if (p === '/play') {
		res.writeHead(301, { location: '/play/' });
		return res.end();
	}
	if (p.endsWith('/')) {
		p += 'index.html';
	}
	const file = p.startsWith('/play/') ? path.join(BUILD, p.slice(6)) : path.join(DOCS, p);
	if (!(file.startsWith(BUILD) || file.startsWith(DOCS)) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
		res.writeHead(404, { 'content-type': 'text/html' });
		return res.end('<h1>404</h1>');
	}
	res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream',
		'access-control-allow-origin': '*', 'cache-control': 'no-cache' });
	fs.createReadStream(file).pipe(res);
}

// The old address after the switch: every request goes through worker.js, as on Cloudflare.
async function serveWorker(req, res) {
	const headers = new Headers();
	for (const [k, v] of Object.entries(req.headers)) {
		if (typeof v === 'string' && !['host', 'connection'].includes(k)) {
			headers.set(k, v);
		}
	}
	// The real old site is https; say so, or the worker would first upgrade the scheme.
	const request = new Request(`https://localhost:${OLD_PORT}${req.url}`, { method: req.method, headers });
	const response = await worker.fetch(request, { NEW_ORIGIN: NEW });
	const out = {};
	response.headers.forEach((v, k) => { out[k] = v; });
	res.writeHead(response.status, out);
	res.end(Buffer.from(await response.arrayBuffer()));
}

let oldMode = 'site';
const oldLog = [];
const oldServer = http.createServer((req, res) => {
	if (oldMode === 'worker') {
		oldLog.push(`${req.method} ${req.url} (${req.headers['sec-fetch-mode'] || '-'}/${req.headers['sec-fetch-dest'] || '-'})`);
		serveWorker(req, res).catch((e) => { res.writeHead(500); res.end(String(e)); });
	} else {
		serveSite(req, res);
	}
});
const newServer = http.createServer(serveSite);

// A save in the exact text format ConfigFile.save() writes.
function saveText(values) {
	let out = '';
	for (const [section, keys] of Object.entries(values)) {
		out += (out ? '\n' : '') + `[${section}]\n\n`;
		for (const [k, v] of Object.entries(keys)) {
			out += `${k}=${typeof v === 'string' ? JSON.stringify(v) : v}\n`;
		}
	}
	return out;
}

const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
const OLD_SAVE = saveText({
	player: { is_premium: true, language: 'fr', sound_enabled: false, reminder_enabled: true,
		last_review_prompt_date: '', review_done: true },
	daily: { games_today: 0, reviews_today: 0, puzzles_today: 0, last_play_date: yesterday,
		bonus_games: 0, bonus_puzzles: 0 },
	premium: { license_key: 'E2E-KEY-0001', license_instance: 'E2E-INSTANCE', license_checked_date: '2026-09-01' },
	stats: { games_played: 42, puzzle_highscore: 7, day_streak: 5, day_streak_best: 9,
		last_streak_date: yesterday, puzzle_streak: 0, puzzle_index: -1 },
	bot_wins: { pip: 3 },
});

// Read user://limpid_chess.cfg straight from the game's IndexedDB, like the bridge does.
function readSaveIn(page) {
	return page.evaluate((key) => new Promise((resolve) => {
		let req;
		try { req = indexedDB.open('/userfs'); } catch (e) { resolve(null); return; }
		req.onupgradeneeded = () => req.transaction.abort();
		req.onerror = (e) => { e.preventDefault(); resolve(null); };
		req.onsuccess = () => {
			const db = req.result;
			if (!db.objectStoreNames.contains('FILE_DATA')) { db.close(); resolve(null); return; }
			const g = db.transaction('FILE_DATA', 'readonly').objectStore('FILE_DATA').get(key);
			g.onsuccess = () => {
				db.close();
				const c = g.result && g.result.contents;
				resolve(c ? new TextDecoder().decode(new Uint8Array(c.buffer, c.byteOffset, c.byteLength)) : null);
			};
			g.onerror = () => { db.close(); resolve(null); };
		};
	}), SAVE_KEY).catch(() => null);
}

async function waitForSave(page, mustContain, seconds = 120) {
	for (let i = 0; i < seconds; i++) {
		const text = await readSaveIn(page);
		if (text && mustContain.every((s) => text.includes(s))) {
			return text;
		}
		await page.waitForTimeout(1000);
	}
	return null;
}

async function workerState(page) {
	return page.evaluate(async () => ({
		registrations: (await navigator.serviceWorker.getRegistrations()).length,
		caches: (await caches.keys()).length,
	})).catch((e) => ({ error: String(e).split('\n')[0] }));
}

const results = [];
function check(name, ok, detail = '') {
	results.push({ name, ok });
	console.log(`  ${ok ? 'ok  ' : 'FAIL'}  ${name}${detail ? '  (' + detail + ')' : ''}`);
}

async function run(name) {
	console.log(`=== ${name} ===`);
	const browser = await pw[name].launch();
	const ctx = await browser.newContext();
	const page = await ctx.newPage();
	const gdErrors = [];
	page.on('console', (m) => {
		if (/SCRIPT ERROR|Parse Error|USER ERROR/.test(m.text())) {
			gdErrors.push(m.text().slice(0, 200));
		}
	});
	try {
		// 1. Before the move: a returning player. The game writes the save on the old origin (fed
		//    through the same hand-over door, which is the one way to script a real save), and its
		//    service worker gets installed there.
		oldMode = 'site';
		const payload = Buffer.from(OLD_SAVE).toString('base64url');
		await page.goto(`${OLD}/play/#lc-move=${payload}`, { waitUntil: 'load', timeout: 60000 });
		const oldSave = await waitForSave(page, ['games_played=42', 'E2E-KEY-0001']);
		check('the game wrote its save at the expected IndexedDB key on the old origin', !!oldSave);
		check('the hand-over fragment was stripped from the address bar', (await page.evaluate(() => location.hash)) === '');
		await page.evaluate(() => navigator.serviceWorker.ready.then(() => true)).catch(() => false);
		const before = await workerState(page);
		check('the old origin has a service worker and its cache', before.registrations === 1 && before.caches >= 1,
			JSON.stringify(before));

		// 2. The switch: the old origin is now worker.js. 3. The player opens the installed app.
		oldMode = 'worker';
		oldLog.length = 0;
		await page.goto(`${OLD}/play/index.html`, { waitUntil: 'commit', timeout: 30000 }).catch(() => {});
		await page.waitForURL((u) => u.href.startsWith(NEW), { timeout: 30000 }).catch(() => {});
		check('the old address sent the player to the new one', page.url().startsWith(`${NEW}/play/index.html`), page.url().replace(/#.*/, '#…'));
		check('the old service worker fetched the bridge page itself (no redirect)',
			oldLog.some((l) => l.startsWith('GET /play/index.html') && l.includes('cors/empty')), oldLog.slice(0, 3).join('; '));
		const newSave = await waitForSave(page, ['games_played=42', 'E2E-KEY-0001', 'language="fr"', 'pip=3']);
		check('the new game took the save over (premium key, stats, language, bot wins)', !!newSave);
		check('...and stripped the fragment', (await page.evaluate(() => location.hash)) === '');

		// The old origin's leftovers: worker and caches retired, the save itself kept.
		const probe = await ctx.newPage();
		await probe.goto(`${OLD}/play/index.wasm`).catch(() => {});
		const after = await workerState(probe);
		check('the old service worker and caches are gone', after.registrations === 0 && after.caches === 0, JSON.stringify(after));
		check('the old save is still there, so a later visit can hand it over again', !!(await readSaveIn(probe)));
		await probe.close();

		// 4. Later, the player types the bare old domain: the bridge on / sends them to the game.
		await page.goto(`${OLD}/`, { waitUntil: 'commit', timeout: 30000 }).catch(() => {});
		await page.waitForURL((u) => u.href.startsWith(NEW), { timeout: 30000 }).catch(() => {});
		check('a returning player on the bare old domain lands in the new game', page.url().startsWith(`${NEW}/play/`), page.url().replace(/#.*/, '#…'));
		const merged = await waitForSave(page, ['games_played=42']);
		check('a second hand-over merges without losing anything', !!merged && merged.includes('E2E-KEY-0001'));
		check('no GDScript errors in the console', gdErrors.length === 0, gdErrors[0] || '');

		// 5. Someone with no save: the old homepage goes to the new homepage, other pages 1:1.
		const ctx2 = await browser.newContext();
		const p2 = await ctx2.newPage();
		await p2.goto(`${OLD}/`, { waitUntil: 'commit' }).catch(() => {});
		await p2.waitForURL((u) => u.href.startsWith(NEW), { timeout: 30000 }).catch(() => {});
		check('no save: the old homepage leads to the new homepage', p2.url() === `${NEW}/`, p2.url());
		await p2.goto(`${OLD}/privacy.html`).catch(() => {});
		check('other pages: a 301 to the same page', p2.url() === `${NEW}/privacy.html`, p2.url());
		await ctx2.close();
	} catch (e) {
		check('no unexpected exception', false, String(e).split('\n')[0]);
	}
	await browser.close();
}

await new Promise((r) => oldServer.listen(OLD_PORT, r));
await new Promise((r) => newServer.listen(NEW_PORT, r));
const which = process.argv.slice(2).filter((a) => pw[a]);
for (const name of which.length ? which : ['chromium']) {
	await run(name);
}
oldServer.close();
newServer.close();
const failed = results.filter((r) => !r.ok).length;
console.log(failed ? `${failed} check(s) FAILED` : 'all checks passed');
process.exit(failed ? 1 : 0);
