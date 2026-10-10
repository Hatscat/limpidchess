# limpidchess.com after the move

In 2026-10 the website and web game moved from `limpidchess.com` to
`limpidchess.lonebee.games` (one subdomain per Lone Bee game). Browser storage is bound
to its address: the web save (`user://limpid_chess.cfg`, kept by Godot in IndexedDB,
including a web Premium license key), the service worker and installed apps all live on
`https://limpidchess.com`. A plain redirect would strand every web player, so the old
domain is a small Cloudflare Worker instead ([worker.js](worker.js)):

| Request on limpidchess.com | Answer |
|---|---|
| `/play/`, `/play/index.html` (installed apps' start_url), `/play`, any query (`?ls=ok`) | **200 bridge page**: reads the save from IndexedDB, retires the old service worker and caches, then `location.replace()`s to the same path on the new address (`/play` becomes `/play/`) with the save in the fragment `#lc-move=<base64url>`. Offline, it says so and keeps the old worker. Installed apps see a one-time "has moved" notice with a Continue button first. |
| `/play/index.service.worker.js` | **200 kill switch**: replaces the old worker at its own URL, clears its caches, unregisters. No `skipWaiting`, no fetch handler. |
| other `/play/*` (old build files) | 404 |
| `/` or `/index.html` with `Sec-Fetch-Mode: navigate` and `Sec-Fetch-Dest: document` (a browser opening the page) | the bridge: a returning player goes straight to the new game with their save, anyone else to the new homepage |
| everything else, and all of `www.` | **301** to the same path and query on the new address |
| `/__move-status` | one line: waiting, live, or moved for good |

On the new address, `GameManager._adopt_moved_save()` reads the fragment at boot, strips
it from the address bar, and either adopts the save (first visit) or merges it
upgrade-only (Premium, day streak, lifetime records). Anyone can craft such a link, so:
every line must match a strict bool/int/string whitelist before `ConfigFile.parse()`, which
would otherwise build Objects and load Resources from text (godotengine/godot#80562, code
execution); every key the game saves must have its saved type; Premium crosses only
together with a license key, which Billing re-checks on that same boot (a made-up key comes
back INVALID); counters are kept in range and dates in the past.

Until the new address answers over valid HTTPS (its `/play/index.manifest.json` with
"Limpid Chess" in it), the Worker passes requests through to GitHub untouched, and serves a
503 "moving" page if GitHub no longer has the site (the certificate gap right after the
switch). A Worker's own requests verify certificates, so it cannot send anyone to a host
that still shows a certificate error. It goes live by itself within about 15 seconds of the
new certificate being issued. Once the move is verified, set `MOVED = true` in worker.js
(runbook step 10): from then on it never asks the new site or GitHub anything, so a later
hiccup or change on either side can never bring the "moving" page back.

## Why never a plain redirect on /play/

Since 2026-07-30 the game's service worker fetches navigations itself, network-first, and
hands the answer to the page. Tested against the real deployed workers:

| Old domain answers /play/ with | Chromium 153 | Firefox 155 | WebKit 26 |
|---|---|---|---|
| a plain 301 | `net::ERR_FAILED` error page | silently follows it, **without** the save | "Response served by service worker has redirections" |
| the 200 bridge | bridge, first launch | same | same |

A 301 on the worker script also makes its update check fail ("the script resource is
behind a redirect"), so a broken worker could never be replaced. Firefox adds one more:
after 3 such faults it unregisters the worker, and on a device with little free storage it
can clear the whole origin, saves included. The same applies to Cloudflare Redirect Rules,
Bulk Redirects and Page Rules: they run BEFORE Workers, so none may match `/play/`.

Workers deployed 2026-07-18..30 served navigations cache-first. Their players get the
cached old game for one more launch, then the bridge (the kill switch activates once that
tab closes; with `skipWaiting` it would delete the cache under the running game instead,
which broke its audio worklets and Stockfish in all three engines).

## Known limits

- **iPhone/iPad Home Screen apps** keep isolated storage per install. The hand-off works
  from the old icon (the new game opens in an in-app sheet), but a NEW Home Screen icon
  for limpidchess.lonebee.games starts empty, so the notice there says to keep using the
  old icon. Premium comes back with the key from the purchase email (unlimited
  activations). A copy/paste progress code (PWA_PLAN item 18) would close this gap.
  Untested on a real device.
- **Old icons and bookmarks need a connection** after their first online launch through
  the bridge: the old offline copy is removed. For offline play, open or install
  limpidchess.lonebee.games.
- **Safari tabs**: ITP deletes a site's storage after 7 days of Safari use without
  interaction, so some Safari players have no save left to hand over.
- **Safari before 16.4** sends no fetch metadata, so typing the bare old domain gets the
  plain 301 to the new homepage, without the save. Its `/play/` links and icons still get
  the bridge.
- **Browser history keeps the hand-over link**, license key included, even after the
  game cleans the address bar (and history sync uploads it). Clearing the browsing history
  removes it; re-opening it only repeats the upgrade-only merge.
- A player who starts fresh on the new address before ever opening the old one keeps
  their new save; the old one is merged in (upgrade-only) whenever they later open an old
  link or icon. Other open tabs of the new game pick the hand-over up through the save sync
  between tabs (`GameManager._join_other_tabs`).

## Cutover runbook

Before, any day (nothing visible changes):

1. **Deadline check.** GitHub's certificate for limpidchess.com cannot renew behind the
   orange cloud and expires **2026-10-16 07:26 UTC**. If Cloudflare > limpidchess.com >
   SSL/TLS shows "Full (strict)", or "Automatic SSL/TLS" (which never drops to Full when the
   origin certificate expires), the site breaks then: cut over before that, or meanwhile
   choose Configure > Custom SSL/TLS > **Full**. After the cutover the mode no longer
   matters, unless you roll back (see Rollback).
2. Cloudflare, zone **lonebee.games**: DNS record `CNAME limpidchess → hatscat.github.io`,
   **DNS only** (grey cloud), like `drawmycode`. Never proxy it: proxying blocks GitHub's
   certificate issue and renewals. No wildcard records.
3. GitHub **account** settings (github.com/settings/pages, not the repo's) > Verified
   domains > Add a domain: **limpidchess.com** (TXT `_github-pages-challenge-hatscat` in the
   limpidchess.com zone). lonebee.games is already verified there and covers its
   subdomains. This stops anyone else claiming limpidchess.com on GitHub once no repo uses
   it. Keep both TXT records (the limpidchess.com one for as long as you own that domain).
4. Cloudflare, zone **limpidchess.com**: check Rules (Redirect Rules, Bulk Redirects, Page
   Rules) for anything matching limpidchess.com; none may cover `/play/`. Optionally turn on
   SSL/TLS > Edge Certificates > Always Use HTTPS (the Worker upgrades http itself anyway).
   Keep both DNS records proxied.
5. Deploy the Worker: `npx wrangler deploy` from this folder (wrangler.toml), or in the
   dashboard Workers & Pages > Create > Hello World > Edit code > paste worker.js > Deploy,
   then Settings > Domains & Routes > add the routes `limpidchess.com/*` and
   `www.limpidchess.com/*`. Set each route's failure mode to **Fail closed**.
   Check: `curl https://limpidchess.com/__move-status` says "waiting for
   https://limpidchess.lonebee.games", and the site still works as before.
6. Optional, a few days ahead, all with the same Google account: Search Console Domain
   properties `limpidchess.com` and `lonebee.games` (DNS TXT), plus the properties the
   move needs: `https://www.limpidchess.com/` (the second move source) and
   `limpidchess.lonebee.games` (the destination). The last two verify as children of the
   Domain properties.

Cutover (a quiet hour; expect 5 to 60 minutes of "moving" page for new visitors):

7. `web/build_web.sh --deploy` (the new build carries the import), then commit everything
   together and push. **Pushing `docs/CNAME` is the switch**: GitHub stops serving
   limpidchess.com within about a minute and requests the new certificate.
8. Watch the repo's Settings > Pages until the certificate is issued (or
   `gh api repos/Hatscat/limpidchess/pages --jq '{cname, cert: .https_certificate.state}'`
   says `approved`). Give it up to an hour; GitHub documents that much. Only if the state
   reads `errored` or `bad_authz`, or nothing changes for about an hour, remove the custom
   domain and add it back: that commits docs/CNAME on main, so `git pull` before your next
   push. Meanwhile the Worker shows the "moving" page and installed players keep playing
   from their cache.
9. Tick **Enforce HTTPS**. `curl https://limpidchess.com/__move-status` should now say
   "live". Then Cloudflare > limpidchess.com > Caching > **Purge Everything**.
10. Verify: in a browser where you played on limpidchess.com, open
    `https://limpidchess.com/play/`: you land on the new address with your progress.
    `curl -sI https://limpidchess.com/privacy.html` is a 301, and
    `curl -sI https://limpidchess.com/play/index.service.worker.js` is a 200
    `text/javascript`. Then set `const MOVED = true;` in worker.js, redeploy it (wrangler
    or paste), commit, and check that `/__move-status` says "moved for good".

After:

11. Update the links that live outside the repo (as found on 2026-10-08):
    - GitHub repo About > Website is `https://limpidchess.com/`:
      `gh repo edit Hatscat/limpidchess --homepage https://limpidchess.lonebee.games/`.
    - Lemon Squeezy, live product "Limpid Chess Premium": Confirmation modal > Button link
      `https://limpidchess.lonebee.games/play/?ls=ok`, plus the Receipt button link and the
      product Links. The live modal's button text is empty, so check the link is set at all,
      then make one test purchase. Receipts already sent keep the old link; the bridge
      forwards it with `?ls=ok`.
    - YouTube, both Limpid Chess videos: the descriptions link `limpidchess.com` and
      `limpidchess.com/play` (keep the music credit, HOW_TO.md).
    - Product Hunt product page: Website and the "Other" `/play` link (the archived launch
      comment cannot change; the Worker forwards it).
    - Play Console never used limpidchess.com: Website and Privacy policy are
      `hatscat.github.io/limpidchess/...`, which GitHub forwards to whatever the custom domain
      is. Updating them is optional (each change waits for "Send for review").
    - Social bios, if any.
12. Search Console: open Settings > Change of address in the `limpidchess.com` property,
    then again in the `www.limpidchess.com` property, and pick `limpidchess.lonebee.games`
    as the new site (never `lonebee.games`). Then submit
    `https://limpidchess.lonebee.games/sitemap.xml`. A warning about `/play/` not being a
    301 is expected. Bing has no move tool: import the sites from Search Console and submit
    the sitemap.
13. limpidchess.com is paid until **2027-07-18** and auto-renew is OFF, by decision
    (2026-10-10: no web sales, so no license keys sit in the old origin's storage). Keep the
    Worker running until then. When it lapses, old links, bookmarks and installed web icons
    stop working, players who never came back keep their old save stranded, and whoever
    registers the domain next controls that address (and the old origin's leftover saves).
    Keep **lonebee.games** on auto-renew: it is the game's home now.

## Rollback

- **The new certificate never arrives** (nobody has been bridged yet, since the Worker only
  goes live on valid HTTPS): set limpidchess.com to Custom SSL/TLS > **Full** first
  (GitHub cannot renew its old certificate behind the proxy), revert docs/CNAME to
  `limpidchess.com` and push. The Worker passes through again by itself within about 10
  minutes; removing its two routes makes that immediate. Keep the lonebee.games DNS record
  for the retry.
- **The new build misbehaves after going live**: do not move the domain back (saves have
  been imported on the new address and old workers retired). Fix forward: deploy a fixed
  build to docs/play; the hand-over import is idempotent.

## Tests

```
node --test web/old_domain/worker.test.mjs        # routing, waiting / live / moved for good
T=$(mktemp -d) && HOME=$T XDG_DATA_HOME=$T/.local/share \
  godot --headless --path . -s res://scripts/dev/test_moved_save.gd   # import rules
```

End to end in real browsers, with the real Godot build (needs a fresh `web/build_web.sh`
export in build/web, and playwright outside the repo as for web/tools/webkit_check.mjs):

```
env -u LD_LIBRARY_PATH -u GTK_PATH -u GIO_MODULE_DIR PW_DIR=/tmp/pwtest \
  node web/old_domain/e2e_check.mjs chromium firefox webkit
```

It installs the game and its service worker on a local "old" origin with a real save,
switches that origin to worker.js, and checks the save arrives in the game on the "new"
origin (Premium key, stats, language, bot wins), that the fragment is stripped, the old
worker and caches are gone, and the no-save and 301 paths. Passed in Chromium, Firefox and
WebKit on 2026-10-08. The Worker also ran unchanged in workerd (`wrangler dev`, Cloudflare's
runtime) with the same answers.
