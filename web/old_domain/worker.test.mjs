// Routing tests for worker.js, no dependencies (Node 18+ has fetch, Request and Response):
//   node --test web/old_domain/worker.test.mjs
// A tiny local server stands in for the new address, so the readiness probe is real.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';

let up = true;
let server;
let NEW;
let worker;

before(async () => {
	server = http.createServer((req, res) => {
		if (up && req.url.startsWith('/play/index.manifest.json')) {
			res.writeHead(200, { 'content-type': 'application/json' });
			return res.end('{"name":"Limpid Chess"}');
		}
		res.writeHead(404);
		res.end();
	});
	await new Promise((r) => server.listen(0, '127.0.0.1', r));
	NEW = `http://127.0.0.1:${server.address().port}`;
	worker = (await import('./worker.js')).default;
});

after(() => server.close());

const PAGE_VISIT = { 'sec-fetch-mode': 'navigate', 'sec-fetch-dest': 'document' };

function call(url, headers = {}) {
	return worker.fetch(new Request(url, { headers }), { NEW_ORIGIN: NEW });
}

test('the old worker script gets the 200 kill switch, never a redirect', async () => {
	const res = await call('https://limpidchess.com/play/index.service.worker.js');
	assert.equal(res.status, 200);
	assert.match(res.headers.get('content-type'), /^text\/javascript/);
	assert.equal(res.headers.get('cache-control'), 'no-store');
	const js = await res.text();
	assert.match(js, /registration\.unregister\(\)/);
	assert.doesNotMatch(js, /skipWaiting/, 'must wait like any update: an open game keeps its cache');
	assert.doesNotMatch(js, /addEventListener\('fetch'/, 'no fetch handler: launches must reach the network');
});

for (const path of ['/play/', '/play/index.html', '/play', '/play/?ls=ok', '/play/index.html?ls=ok']) {
	test(`${path} gets the 200 bridge (old service workers cannot follow a redirect)`, async () => {
		for (const headers of [{}, PAGE_VISIT, { 'sec-fetch-mode': 'cors', 'sec-fetch-dest': 'empty' }]) {
			const res = await call('https://limpidchess.com' + path, headers);
			assert.equal(res.status, 200);
			assert.match(res.headers.get('content-type'), /^text\/html/);
			assert.equal(res.headers.get('cache-control'), 'no-store');
			const html = await res.text();
			assert.match(html, /indexedDB\.open\('\/userfs'\)/);
			assert.ok(html.includes(`<link rel="canonical" href="${NEW}/play/">`));
			assert.ok(html.includes(JSON.stringify(NEW)), 'the new origin is injected into the script');
		}
	});
}

test('files of the retired build are 404, not redirected', async () => {
	for (const f of ['index.js', 'index.wasm', 'index.pck', 'index.manifest.json', 'stockfish-18-lite-single.js']) {
		const res = await call('https://limpidchess.com/play/' + f);
		assert.equal(res.status, 404, f);
	}
});

test('the homepage: the bridge for a browser page visit, a 301 for anything else', async () => {
	const visit = await call('https://limpidchess.com/', PAGE_VISIT);
	assert.equal(visit.status, 200);
	assert.ok((await visit.text()).includes(`<link rel="canonical" href="${NEW}/">`));
	const bot = await call('https://limpidchess.com/');
	assert.equal(bot.status, 301);
	assert.equal(bot.headers.get('location'), NEW + '/');
	const iframe = await call('https://limpidchess.com/', { 'sec-fetch-mode': 'navigate', 'sec-fetch-dest': 'iframe' });
	assert.equal(iframe.status, 301, 'an iframe has partitioned storage: no save to read there');
	const index = await call('https://limpidchess.com/index.html', PAGE_VISIT);
	assert.equal(index.status, 200);
});

test('every other path is a 301 to the same path and query, with a bounded cache life', async () => {
	for (const [from, to] of [
		['/privacy.html', '/privacy.html'],
		['/terms.html?x=1&y=2', '/terms.html?x=1&y=2'],
		['/img/icon.png', '/img/icon.png'],
		['/robots.txt', '/robots.txt'],
	]) {
		const res = await call('https://limpidchess.com' + from, PAGE_VISIT);
		assert.equal(res.status, 301, from);
		assert.equal(res.headers.get('location'), NEW + to);
		assert.equal(res.headers.get('cache-control'), 'max-age=3600');
	}
});

test('www never held a save: everything 301s, /play/ included', async () => {
	for (const path of ['/', '/play/', '/play/index.service.worker.js', '/privacy.html']) {
		const res = await call('https://www.limpidchess.com' + path, PAGE_VISIT);
		assert.equal(res.status, 301, path);
		assert.equal(res.headers.get('location'), NEW + path);
	}
});

test('plain http is upgraded on the same host first (the save lives on https)', async () => {
	const res = await call('http://limpidchess.com/play/?ls=ok', PAGE_VISIT);
	assert.equal(res.status, 301);
	assert.equal(res.headers.get('location'), 'https://limpidchess.com/play/?ls=ok');
});

test('a path that looks like another host stays a path (no open redirect)', async () => {
	const res = await call('https://limpidchess.com//evil.example/x');
	assert.equal(res.status, 301);
	assert.ok(res.headers.get('location').startsWith(NEW + '/'), res.headers.get('location'));
});

// Before the new address works: a fresh module instance (its readiness memo starts empty), and a
// stubbed fetch standing in for both the new address and GitHub behind the old one.
test('until the new address serves valid HTTPS: pass through, or a 503 "moving" page', async (t) => {
	const fresh = (await import('./worker.js?before-the-move')).default;
	let probes = 0;
	let origin = { status: 200, body: 'the old site, served by GitHub' };
	const realFetch = globalThis.fetch;
	globalThis.fetch = async (input) => {
		const url = typeof input === 'string' ? input : input.url;
		if (url.startsWith('https://limpidchess.lonebee.games/')) {
			probes++;
			throw new TypeError('certificate not valid for this name yet');
		}
		return new Response(origin.body, { status: origin.status });
	};
	t.after(() => { globalThis.fetch = realFetch; });
	const go = (path, headers = {}) => fresh.fetch(new Request('https://limpidchess.com' + path, { headers }), {});

	let res = await go('/play/', PAGE_VISIT);
	assert.equal(res.status, 200, 'before the switch: untouched pass-through');
	assert.equal(await res.text(), 'the old site, served by GitHub');
	res = await go('/play/index.service.worker.js');
	assert.equal(await res.text(), 'the old site, served by GitHub', 'no kill switch yet');
	assert.equal(probes, 1, 'a failed probe is remembered for a while, not repeated per request');

	origin = { status: 526, body: 'Invalid SSL certificate' };
	res = await go('/play/');
	assert.equal(res.status, 503, 'during the gap: an old service worker falls back to its cached game');
	assert.equal(res.headers.get('retry-after'), '300');
	const html = await res.text();
	assert.match(html, /Limpid Chess is moving/);
	assert.match(html, /"waiting"/);

	origin = { status: 404, body: "<h1>There isn't a GitHub Pages site here.</h1>" };
	res = await go('/');
	assert.equal(res.status, 503, "GitHub's no-site 404 also means the gap");

	origin = { status: 404, body: 'File not found' };
	res = await go('/nope.html');
	assert.equal(res.status, 404, 'an ordinary 404 of the live old site passes through');

	res = await go('/__move-status');
	assert.equal(await res.text(), 'limpidchess.com worker: waiting for https://limpidchess.lonebee.games\n');
});

test('the status URL says whether the Worker is live', async () => {
	const res = await call('https://limpidchess.com/__move-status');
	assert.equal(res.status, 200);
	assert.equal(await res.text(), `limpidchess.com worker: live, sending players to ${NEW}\n`);
});

test('once MOVED is set, nothing is ever fetched and every route stays live', async (t) => {
	const fresh = (await import('./worker.js?moved-for-good')).default;
	const realFetch = globalThis.fetch;
	let fetched = 0;
	globalThis.fetch = async () => { fetched++; throw new TypeError('the new site is down today'); };
	t.after(() => { globalThis.fetch = realFetch; });
	const go = (path, headers = {}) => fresh.fetch(new Request('https://limpidchess.com' + path, { headers }), { MOVED: '1' });

	assert.equal((await go('/play/index.html')).status, 200, 'the bridge, not the moving page');
	const sw = await go('/play/index.service.worker.js');
	assert.equal(sw.status, 200);
	assert.match(sw.headers.get('content-type'), /^text\/javascript/);
	const privacy = await go('/privacy.html');
	assert.equal(privacy.status, 301);
	assert.equal(privacy.headers.get('location'), 'https://limpidchess.lonebee.games/privacy.html');
	assert.equal(await (await go('/__move-status')).text(),
		'limpidchess.com worker: moved for good, sending players to https://limpidchess.lonebee.games\n');
	assert.equal(fetched, 0, 'no probe and no pass-through once moved');
});

test('HEAD during the certificate gap gets the 503 too, like GET', async (t) => {
	const fresh = (await import('./worker.js?head-in-the-gap')).default;
	const realFetch = globalThis.fetch;
	globalThis.fetch = async (input) => {
		const url = typeof input === 'string' ? input : input.url;
		if (url.startsWith('https://limpidchess.lonebee.games/')) {
			throw new TypeError('certificate not valid for this name yet');
		}
		// GitHub's no-site page: only a GET answer carries the body that identifies it.
		const method = typeof input === 'string' ? 'GET' : input.method;
		return new Response(method === 'HEAD' ? null : "<h1>There isn't a GitHub Pages site here.</h1>", { status: 404 });
	};
	t.after(() => { globalThis.fetch = realFetch; });
	const res = await fresh.fetch(new Request('https://limpidchess.com/play/', { method: 'HEAD' }), {});
	assert.equal(res.status, 503);
});
