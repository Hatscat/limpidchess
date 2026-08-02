// Run the exported web build in Playwright's WebKit and report what the engine does.
//
// WebKit is the same engine family as Safari, so this is the closest thing to an iPhone
// that runs on this box. It does NOT reproduce the iOS portrait freeze (see the OPEN BUG
// section of web/README.md), but it does surface WebGL errors the engine emits, which are
// invisible on a real phone: browsers log those internally, not through console.error, so
// the on-page diagnostics panel never sees them.
//
// Setup (once), kept out of the repo so no node_modules lands in the Godot project:
//   mkdir -p /tmp/pwtest && cd /tmp/pwtest && npm init -y && npm install playwright
//   npx playwright install webkit
//
// Run:
//   cd /home/lucien/limpid-chess/build/web && python3 -m http.server 8099 &
//   env -u LD_LIBRARY_PATH -u GTK_PATH -u GIO_MODULE_DIR PW_DIR=/tmp/pwtest \
//     node web/tools/webkit_check.mjs
//
// The `env -u` is not optional. VS Code's snap leaks GIO_MODULE_DIR and friends into
// child processes, which drags a 2020-era glibc into WebKit's network process and makes
// every navigation fail with "WebKit encountered an internal error". Same class of snap
// leak that build_web.sh already works around for XDG_DATA_HOME.
import { createRequire } from 'node:module';
import crypto from 'node:crypto';

// playwright lives outside the repo on purpose (no node_modules in a Godot project), so
// resolve it from PW_DIR rather than relative to this file.
const PW_DIR = process.env.PW_DIR || '/tmp/pwtest';
const { webkit } = createRequire(PW_DIR + '/package.json')('playwright');

const URL_BASE = process.env.URL_BASE || 'http://localhost:8099/index.html';
const WATCH_MS = Number(process.env.WATCH_MS || 10000);

const CASES = [
  { name: 'PORTRAIT ', width: 390, height: 658, tap: [195, 330] },
  { name: 'LANDSCAPE', width: 844, height: 390, tap: [422, 200] },
];

const sha = (b) => crypto.createHash('sha1').update(b).digest('hex').slice(0, 10);

async function run(browser, c) {
  const ctx = await browser.newContext({
    viewport: { width: c.width, height: c.height },
    deviceScaleFactor: 3,
    isMobile: true,
    hasTouch: true,
  });
  const page = await ctx.newPage();

  // Bucket console output by message rather than dumping it: a per-frame GL error and a
  // one-off startup warning look identical in a raw log, and the difference is the point.
  const counts = new Map();
  const bump = (t) => counts.set(t, (counts.get(t) || 0) + 1);
  page.on('console', (m) => {
    if (m.type() === 'error' || m.type() === 'warning') bump(m.text().slice(0, 110));
  });
  page.on('pageerror', (e) => bump('PAGEERROR ' + String(e).slice(0, 110)));

  await page.goto(URL_BASE, { waitUntil: 'domcontentloaded' });
  let booted = true;
  try {
    await page.waitForFunction(() => !document.getElementById('status'), null, { timeout: 120000 });
  } catch { booted = false; }
  await page.waitForTimeout(2000);

  const info = await page.evaluate(() => {
    const cv = document.getElementById('canvas');
    let renderer = 'n/a';
    try {
      const gl = cv.getContext('webgl2') || cv.getContext('webgl');
      const dbg = gl && gl.getExtension('WEBGL_debug_renderer_info');
      renderer = gl ? (dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : 'webgl ok') : 'NO GL';
    } catch (e) { renderer = 'err ' + e.message; }
    return { win: window.innerWidth + 'x' + window.innerHeight,
             canvas: cv ? cv.width + 'x' + cv.height : 'missing', renderer };
  });

  // Frame-freeze check: tap somewhere that should change the screen, then compare.
  const before = await page.screenshot();
  await page.touchscreen.tap(c.tap[0], c.tap[1]);
  await page.waitForTimeout(2500);
  const after = await page.screenshot();

  // Now measure error RATE over a quiet window, with no interaction.
  counts.clear();
  const t0 = Date.now();
  await page.waitForTimeout(WATCH_MS);
  const secs = (Date.now() - t0) / 1000;

  console.log(`\n=== ${c.name} ${c.width}x${c.height} ===`);
  console.log(`  booted ${booted}  win ${info.win}  canvas ${info.canvas}  gl ${info.renderer}`);
  console.log(`  canvas ${sha(before) !== sha(after) ? 'REPAINTED after tap' : 'FROZEN after tap'}`);
  if (counts.size === 0) {
    console.log(`  console  clean over ${secs}s`);
  } else {
    for (const [msg, n] of [...counts].sort((a, b) => b[1] - a[1])) {
      console.log(`  console  ${String(n).padStart(5)}x (${(n / secs).toFixed(1)}/s)  ${msg}`);
    }
  }
  await ctx.close();
}

const browser = await webkit.launch();
console.log('webkit', browser.version(), '|', URL_BASE);
for (const c of CASES) await run(browser, c);
await browser.close();
console.log('\nA per-frame rate (~60/s) means the message is on the render path.');
console.log('A handful total means it is a startup artifact and probably not the bug.');
