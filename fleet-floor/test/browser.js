/* fleet-floor/test/browser.js — drive the real page and assert what it renders.
 *
 *   node browser.js <url> <outdir> [user] [pass]
 *   node browser.js file:///.../index.html shots        # DEMO mode
 *
 * playwright-core against the cached chromium; no browser download. Basic auth
 * goes through httpCredentials, NOT credentials in the URL — Chrome refuses to
 * build a Request from a document URL that carries them, which silently
 * strands the page in DEMO.
 *
 * Everything asserted here is something a screenshot cannot tell you: that a
 * control targeted the box the operator was looking at, that hostile log text
 * stayed text, that a disabled control is disabled. The screenshots are for
 * humans; the assertions are the test.
 */
const { chromium } = require('playwright-core');
const fs = require('fs');
const path = require('path');

const CHROME = process.env.PW_CHROME
  || process.env.HOME + '/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome';
const [, , URL_ARG, OUT_ARG, USER, PASS] = process.argv;
/* FLOOR_TEST_READONLY=1 — render and navigate, but never touch a control.
   This walk is written for the stub fleet, where clicking Pause costs nothing.
   Against a REAL fleet (drill/rehearsal-app.sh) the same clicks pause a live
   box and start stopped ones, so the drill runs us in this mode unless the
   operator explicitly opted into control. */
const READONLY = process.env.FLOOR_TEST_READONLY === '1';
/* Re-run the frame-sensitive byline check without redoing the whole collector
   suite. The default remains one assertion per browser-walk width; #489's
   loaded-machine verification sets this to 20. */
const BYLINE_REPEATS = Math.max(1,
  Number.parseInt(process.env.FLOOR_TEST_BYLINE_REPEATS || '1', 10) || 1);
/* Whether the fleet under the page is the STUB fixture or a real one.
   test/run.sh drives fixtures/roster.txt, whose contents are guaranteed: there
   IS a box with hostile log text, one inside its first session, and several
   offline. Those are the states the page's worst bugs lived in, so "that box
   was not reachable" must be a loud failure there -- otherwise the checks that
   depend on it silently do not run and the suite stays green.

   The drill points the same walk at a REAL fleet, which has no box named
   hostile or firstrun, and when healthy has nothing offline at all. Asserting
   the fixture's contents there fails on every host, forever -- for the good
   reason that the fleet is fine. kimi-bot caught this: the guard is right for
   the suite and wrong unconditionally, so it is gated rather than removed. */
const FIXTURE = process.env.FLOOR_TEST_FIXTURE === '1';
const FIXTURE_ENGINE_VERSION = process.env.FLOOR_TEST_ENGINE_VERSION || '0.4.1';
const FIXTURE_ENGINE_PATTERN = FIXTURE_ENGINE_VERSION.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const url = URL_ARG || 'http://127.0.0.1:8791/';
const out = OUT_ARG || 'shots';

let pass = 0;
let skipped = 0;
const fails = [];
const ok = (name, cond, detail = '') => {
  if (cond) { pass++; console.log(`  ok   ${name}`); }
  else { fails.push(name); console.log(`  FAIL ${name}${detail ? '  — ' + String(detail).slice(0, 150) : ''}`); }
};
const skip = (name, detail = '') => {
  skipped++;
  console.log(`  skip ${name}${detail ? '  — ' + detail : ''}`);
};
const eq = (name, want, got) => ok(name, String(want) === String(got), `expected [${want}] got [${got}]`);

(async () => {
  /* Actionable, because the old message ("no chromium at <playwright cache>")
     named a path that playwright-core NEVER populates — it ships without
     browsers on purpose — and said nothing about the variable that fixes it.
     A system Chrome is invisible here unless PW_CHROME points at it. */
  if (!fs.existsSync(CHROME)) {
    console.error('no browser at ' + CHROME);
    console.error('playwright-core ships without browsers; point PW_CHROME at an installed one, e.g.');
    console.error('  PW_CHROME=/usr/bin/google-chrome-stable   (or /opt/google/chrome/chrome, /usr/bin/chromium)');
    process.exit(2);
  }
  fs.mkdirSync(out, { recursive: true });

  /* FLOOR_TEST_HEADED=1 shows the browser, FLOOR_TEST_SLOWMO=<ms> paces it.
     Both exist so a human can WATCH the walk drive the page — there was no way
     to, and the screenshots are a poor substitute for seeing a control land.
     Headed mode needs a display, so it stays opt-in and CI never sets it. */
  const HEADED = process.env.FLOOR_TEST_HEADED === '1';
  const SLOWMO = Number(process.env.FLOOR_TEST_SLOWMO || 0) || 0;
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: !HEADED,
    slowMo: SLOWMO,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  const ctx = await browser.newContext({
    viewport: { width: 1600, height: 1000 },
    httpCredentials: USER ? { username: USER, password: PASS } : undefined,
  });
  const page = await ctx.newPage();

  /* Observe the shipped canvas call, not the label-producing helper. This is
     installed before the page loads so removing drawFloorHeader() from the
     frame path makes the browser assertion red even though FLOORDEV.header()
     can still describe what the disconnected painter would have drawn. */
  await page.addInitScript(() => {
    window.__floorHeaderPaint = [];
    window.__camHeadroomPaint = [];
    const fillText = CanvasRenderingContext2D.prototype.fillText;
    CanvasRenderingContext2D.prototype.fillText = function (text, x, y) {
      if (this.canvas && this.canvas.id === 'scene' && y <= 130) {
        const metrics = this.measureText(String(text));
        window.__floorHeaderPaint.push({
          text: String(text), x, y, align: this.textAlign,
          viewportWidth: window.innerWidth,
          width: metrics.width,
          ascent: metrics.actualBoundingBoxAscent || 0,
          descent: metrics.actualBoundingBoxDescent || 0,
        });
        if (window.__floorHeaderPaint.length > 200) window.__floorHeaderPaint.shift();
      }
      if (this.canvas && this.canvas.id === 'scene' &&
          (/^(MEM|DISK)$/.test(String(text)) || /^\d+(?:\.\d+)?\/\d+(?:\.\d+)?G$/.test(String(text)))) {
        window.__camHeadroomPaint.push(String(text));
        if (window.__camHeadroomPaint.length > 400) window.__camHeadroomPaint.shift();
      }
      return fillText.apply(this, arguments);
    };
  });

  const consoleErrors = [];
  page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()); });
  page.on('pageerror', (e) => consoleErrors.push('pageerror: ' + e.message));
  page.on('dialog', (d) => d.accept());          // confirm() guards

  const shot = (n) => page.screenshot({ path: path.join(out, n + '.png') });

  await page.goto(url, { waitUntil: 'load' });
  // Poll for the LIVE flip rather than guessing how long the first poll takes:
  // a fixed wait that expires early mislabels the MODE, and every branch below
  // is then testing the wrong thing. DEMO legitimately never flips, so the
  // timeout is the answer there, not a failure.
  for (let w = 0; w < 12000; w += 250) {
    if ((await page.locator('.demo-badge.live').count()) > 0) break;
    await page.waitForTimeout(250);
  }
  // There are two badges (floor bar + room HUD); goLive() marks both.
  const LIVE = (await page.locator('.demo-badge.live').count()) > 0;
  console.log(`  mode: ${LIVE ? 'LIVE' : 'DEMO'}${READONLY ? ' (read-only: controls not exercised)' : ''}`);

  // Record every command the page posts, so an assertion can name the box a
  // control actually addressed.
  await page.evaluate(() => {
    window.__sent = [];
    window.__opened = [];
    window.__fetched = [];
    const _open = window.open;
    window.open = function (u) { window.__opened.push(u); return null; };
    const f = window.fetch;
    window.fetch = function (u, o) {
      window.__fetched.push(String(u));
      if (o && o.method === 'POST') { try { window.__sent.push(JSON.parse(o.body)); } catch (e) {} }
      return f.apply(this, arguments);
    };
  });
  const sent = () => page.evaluate(() => window.__sent);
  const fetched = () => page.evaluate(() => window.__fetched);
  const lastSent = async () => (await sent()).slice(-1)[0] || {};

  // ---- floor --------------------------------------------------------------
  /* The expected cell order comes from the collector, not from a test hook in
     the app: /api/fleet is the same list, in the same order, that the page
     laid the floor out from. In DEMO there is no collector, so there is
     nothing to compare against and the identity check is skipped. */
  const snapshot = LIVE
    ? await page.evaluate(async () => {
        const r = await fetch(location.origin + '/api/fleet');
        return await r.json();
      })
    : null;
  const roster = LIVE
    ? snapshot.units.map((u) => ({ box: u.box, agent: u.agent, room: u.room, state: u.state,
        hired: u.hired }))
    : Array.from({ length: 7 }, (_, i) => ({ box: null, agent: null, room: null, state: null }));
  /* DECLARED vs DEPLOYED (#204). `roster` is what /api/fleet carries — every
     member, hired or not — and `shown` is the subset that gets a console. The
     two used to be the same list, and every assertion below that means "the
     grid" said `roster`. They are now different, and which one an assertion
     names is the difference between testing the filter and asserting it away:
     the coverage checks want `shown`, and the payload checks want `roster`.

     `hired === 'no'` and nothing else. Reading the engine string here would
     re-implement the very inference the collector's verdict exists to stop, so
     a page that started filtering on silence would still pass. */
  const shown = LIVE ? roster.filter((u) => u.hired !== 'no') : roster;
  const hiddenBoxes = LIVE ? roster.filter((u) => u.hired === 'no').map((u) => u.box) : [];
  /* A fleet with nothing hired now draws NO console, deliberately, and the
     drill reaches that state for real: rehearsal-app.sh skips its engine-version
     block with "no box on this host is hired", so a host part-way through
     provisioning has a legitimately empty floor. Before #204 that fleet still
     rendered cells and every check below had something to stand on; now it does
     not, and a walk that read the empty floor as a broken renderer would fail
     the drill for doing the right thing.

     So the emptiness is checked rather than assumed: an empty floor passes only
     if the page SAYS it is empty and names the way out. Same assertion count
     either way, because the floor in run.sh is exact. The stub fleet always has
     boxes hired, so this run always takes the second branch. */
  const emptyFloor = LIVE && !shown.length;
  const emptyState = emptyFloor
    ? await page.evaluate(() => {
        const el = document.querySelector('#emptyfloor');
        if (!el) return null;
        const r = el.getBoundingClientRect();
        return { on: el.classList.contains('on'), visible: r.width > 0 && r.height > 0,
                 text: el.textContent.replace(/\s+/g, ' ').trim() };
      })
    : null;
  ok(emptyFloor ? 'floor: a fleet with nothing hired draws the empty state'
                : 'floor: roster rendered',
     emptyFloor
       ? !!emptyState && emptyState.on && emptyState.visible && /crew hire/.test(emptyState.text)
       : shown.length > 0,
     emptyFloor ? JSON.stringify(emptyState) : shown.length + ' units');
  if (LIVE) {
    const header = await page.evaluate(() => window.FLOORDEV.header());
    const paintedVersion = header.find((h) => /^crew /.test(h.text));
    const actualPaint = await page.evaluate((label) =>
      window.__floorHeaderPaint.some((p) => p.text === label.text
        && p.x === label.x && p.y === label.y), paintedVersion);
    ok('floor: the canvas header paints the serving host version',
       !!paintedVersion && paintedVersion.text === snapshot.version && actualPaint,
       `header=${paintedVersion && paintedVersion.text}, painted=${actualPaint}, api=${snapshot.version}`);
    ok('floor: the serving version is not dropped or hardcoded',
       snapshot.version === process.env.FLOOR_TEST_VERSION,
       `expected ${process.env.FLOOR_TEST_VERSION}, got ${snapshot.version}`);
    const headroom = await page.evaluate(() => ({
      measured: window.FLOORDEV.camHeadroom({fields:{
        mem_total_mb:'8090', mem_avail_mb:'1844',
        disk_total_mb:'61440', disk_used_mb:'48128',
      }}),
      absent: window.FLOORDEV.camHeadroom(null),
      noMemory: window.FLOORDEV.camHeadroom({fields:{
        disk_total_mb:'61440', disk_used_mb:'48128',
      }}),
      noDisk: window.FLOORDEV.camHeadroom({fields:{
        mem_total_mb:'8090', mem_avail_mb:'1844',
      }}),
      painted: window.__camHeadroomPaint.slice(),
    }));
    eq('god view: memory is current/max', '6.1/7.9G', headroom.measured[0][1]);
    eq('god view: disk is current/max', '47/60G', headroom.measured[1][1]);
    eq('god view: an old engine gives MEM an em dash', '—', headroom.absent[0][1]);
    eq('god view: an old engine gives DISK an em dash', '—', headroom.absent[1][1]);
    eq('god view: an unreadable free gives MEM an em dash', '—', headroom.noMemory[0][1]);
    eq('god view: an unreadable df gives DISK an em dash', '—', headroom.noDisk[1][1]);
    ok('god view: the shipped canvas paints both headroom rows',
       headroom.painted.includes('MEM') && headroom.painted.includes('DISK') &&
         headroom.painted.some((x) => /^\d+(?:\.\d+)?\/\d+(?:\.\d+)?G$/.test(x)),
       headroom.painted.join(', '));
    for (let repeat = 1; repeat <= BYLINE_REPEATS; repeat++) {
      for (const width of [1400, 1600]) {
        await page.setViewportSize({ width, height: 1000 });
        /* Plant a paint from the other width after the resize request. This is
         the mutation that makes the ordering below bite: clearing before the
         resize, or not clearing at all, mixes it into the measured frame and
         fails the viewport-width check instead of depending on scheduler luck. */
        await page.evaluate(({ text, staleWidth }) => {
          const label = window.FLOORDEV.header().find((h) => h.text === text);
          window.__floorHeaderPaint.push({
            text: label.text, x: label.x, y: label.y, align: label.align,
            viewportWidth: staleWidth, width: label.width, ascent: 8, descent: 2,
          });
        }, { text: snapshot.version, staleWidth: width === 1400 ? 1600 : 1400 });
        const composition = await page.evaluate(({ version, width: targetWidth }) =>
          new Promise((resolve) => requestAnimationFrame(() => {
          // The first resized frame settles layout. Clear only after it has
          // painted, then read both canvas observations and DOM rectangles in
          // the following frame so two viewport geometries cannot mix.
          window.__floorHeaderPaint = [];
          requestAnimationFrame(() => {
            const labels = window.FLOORDEV.header();
            // This set is intentionally exact: the DOM fleetbar owns all other
            // chrome, so reviving a legacy canvas brand or counter must fail.
            const expected = [version, 'scroll · click a unit to zoom in'];
            const wanted = new Set(labels.map((h) => h.text));
            const paints = window.__floorHeaderPaint
              .filter((p) => wanted.has(p.text))
              .filter((p, i, all) => all.findIndex((q) => q.text === p.text
                && q.x === p.x && q.y === p.y) === i)
              .map((p) => {
                let left = p.x;
                if (p.align === 'center') left -= p.width / 2;
                if (p.align === 'right' || p.align === 'end') left -= p.width;
                return {
                  text: p.text, viewportWidth: p.viewportWidth,
                  rect: { left, right: left + p.width,
                    top: p.y - p.ascent, bottom: p.y + p.descent },
                };
              });
            const chrome = Array.from(document.querySelectorAll('.fleetbar *'))
              .filter((el) => {
                const r = el.getBoundingClientRect();
                const s = getComputedStyle(el);
                return r.width > 0 && r.height > 0 && s.display !== 'none'
                  && s.visibility !== 'hidden';
              })
              .map((el) => {
                const r = el.getBoundingClientRect();
                return { name: el.id || el.className || el.tagName,
                  rect: { left: r.left, right: r.right, top: r.top, bottom: r.bottom } };
              });
            const overlaps = [];
            for (const paint of paints) {
              for (const el of chrome) {
                const a = paint.rect, b = el.rect;
                if (a.left < b.right && a.right > b.left
                    && a.top < b.bottom && a.bottom > b.top) {
                  overlaps.push({ paint: paint.text, element: String(el.name),
                    paintRect: a, elementRect: b });
                }
              }
            }
            const domChrome = document.querySelector('.fleetbar').textContent;
            resolve({
              targetWidth, measuredWidth: window.innerWidth,
              labels: labels.map((h) => h.text), expected,
              painted: paints.map((p) => p.text),
              paintWidths: paints.map((p) => p.viewportWidth), overlaps,
              domOwnsChrome: domChrome.includes('FLEET FLOOR')
                && document.querySelectorAll('.fleetbar #tiles .tile').length > 0,
            });
          });
          })), { version: snapshot.version, width });
        const repetition = BYLINE_REPEATS > 1 ? ` (run ${repeat}/${BYLINE_REPEATS})` : '';
        ok(`floor: canvas byline does not duplicate DOM fleetbar chrome at ${width}px${repetition}`,
           composition.measuredWidth === width
             && composition.paintWidths.every((paintWidth) => paintWidth === width)
             && JSON.stringify(composition.labels) === JSON.stringify(composition.expected)
             && composition.expected.every((text) => composition.painted.includes(text))
             && composition.overlaps.length === 0
             && composition.domOwnsChrome,
           JSON.stringify(composition));
      }
    }
    await page.setViewportSize({ width: 1600, height: 1000 });
  }
  /* Not just "the word units appears": that is true of an empty fleet too,
     because the tiles always render. Assert the count matches the roster.
     DECLARED, deliberately: #204 filters the grid and must not shrink this
     number, or the page and `crew status` stop agreeing about how big the
     fleet is. So this assertion is now also the one that catches a filter
     applied one layer too high. */
  const tilesText = (await page.locator('#tiles').textContent()).replace(/\s+/g, '');
  const tileUnits = (tilesText.match(/(\d+)units/) || [])[1];
  ok('floor: the unit tile matches the DECLARED fleet size',
     LIVE ? String(roster.length) === tileUnits : /^[1-9]/.test(tileUnits || ''),
     `tile says ${tileUnits}, roster has ${roster.length}`);

  /* The state chips filter the CANVAS by painting a scrim, so an active DOM
     class says only which button was clicked. FLOORDEV.matched() reports the
     set left undimmed by the shipped predicate. The adjacent tiles consume
     that same predicate, and comparing their totals makes a second copy on
     either side fail this walk as soon as the split changes. */
  const stateMatches = async (state) => {
    await page.locator(`.fchip[data-f="state"][data-v="${state}"]`).click();
    return await page.evaluate(() => window.FLOORDEV.matched().slice().sort());
  };
  const stateChipWords = await page.locator('.fchip[data-f="state"]').evaluateAll((chips) =>
    chips.map((c) => c.textContent.trim()));
  eq('filter: state chips mirror the tile vocabulary',
     JSON.stringify(['All', 'Working', 'Idle', 'Suppressed', 'Limited', 'Disarmed', 'Silent']),
     JSON.stringify(stateChipWords));
  const stateChipBounds = await page.locator('.fchip[data-f="state"]').evaluateAll((chips) =>
    chips.map((chip) => {
      const rect = chip.getBoundingClientRect();
      return { word: chip.textContent.trim(), left: rect.left, right: rect.right,
        top: rect.top, bottom: rect.bottom, width: window.innerWidth, height: window.innerHeight };
    }));
  ok('filter: every state chip stays inside the CI viewport',
     stateChipBounds.every((rect) => rect.left >= 0 && rect.top >= 0
       && rect.right <= rect.width && rect.bottom <= rect.height),
     JSON.stringify(stateChipBounds));
  for (const state of ['all', 'working', 'idle', 'suppressed', 'limited', 'disarmed', 'silent']) {
    await stateMatches(state);
  }
  await stateMatches('all');
  ok('filter: every state chip is operable at the CI viewport', true);

  if (LIVE && FIXTURE) {
    /* floor/actions.sh proves wake-silent resumes ff-paused. Put that fixture back in
       its deliberately-stopped state so the three named boxes exercise both
       sides of this page split together, then pull the refreshed snapshot
       into the page rather than waiting for the ordinary 15-second poll. */
    await page.evaluate(async () => {
      await fetch(location.origin + '/api/command', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'pause', box: 'ff-paused' }),
      });
    });
    let disarmedMatches = [];
    for (let i = 0; i < 80; i++) {
      await page.waitForTimeout(250);
      disarmedMatches = await stateMatches('disarmed');
      if (disarmedMatches.includes('ff-paused')) break;
    }
    const silentMatches = await stateMatches('silent');
    const suppressedMatches = await stateMatches('suppressed');
    const limitedMatches = await stateMatches('limited');
    const allMatches = await stateMatches('all');
    const trio = ['ff-disarmed', 'ff-paused', 'ff-silent'];
    const amongTrio = (set) => set.filter((box) => trio.includes(box));
    eq('filter: Disarmed selects the two deliberately-stopped fixtures',
       JSON.stringify(['ff-disarmed', 'ff-paused']),
       JSON.stringify(amongTrio(disarmedMatches)));
    eq('filter: Silent reserves the alarm for the silent fixture',
       JSON.stringify(['ff-silent']), JSON.stringify(amongTrio(silentMatches)));
    eq('filter: Suppressed selects the breaker-stopped fixture',
       JSON.stringify(['ff-suppressed']), JSON.stringify(suppressedMatches));
    // The recovered fixtures are absent by name, not by omission: ff-lim-failed
    // (a failed retry), ff-lim-restarted (a newer admitted START) and
    // ff-lim-recovered (a clean session) all carry limit evidence the engine
    // has since let go of, and the filter must not offer any of them as a
    // lane to go and unstick (#611 round 3).
    eq('filter: Limited selects every current limit fixture',
       JSON.stringify(['ff-lim-breaker', 'ff-lim-budget', 'ff-lim-event',
                       'ff-lim-terminal']),
       JSON.stringify(limitedMatches));
    eq('filter: All keeps all three offline fixtures reachable',
       JSON.stringify(trio.slice().sort()), JSON.stringify(amongTrio(allMatches)));
    const stateTiles = await page.locator('#tiles .tile').evaluateAll((tiles) =>
      tiles.map((t) => ({
        label: t.querySelector('.l').textContent.trim(),
        n: Number(t.querySelector('.n').textContent.trim()),
      })));
    const tileNumber = (label) => (stateTiles.find((t) => t.label === label) || {}).n;
    eq('filter: Disarmed chip and tile count the same boxes',
       disarmedMatches.length, tileNumber('disarmed'));
    eq('filter: Silent chip and tile count the same boxes',
       silentMatches.length, tileNumber('silent'));
    eq('filter: Suppressed chip and tile count the same boxes',
       suppressedMatches.length, tileNumber('suppressed'));
    eq('filter: Limited chip and tile count the same boxes',
       limitedMatches.length, tileNumber('limited'));
    eq('limited: terminal evidence is shouted from the god-view', 'LIMITED',
       await page.evaluate(() => window.FLOORDEV.alert('ff-lim-terminal')));
    eq('limited: AUTH outranks LIMITED', 'AUTH', await page.evaluate(() =>
      window.FLOORDEV.alertData({ping:null,lock:null,authfail:['vendor: rejected'],limited:{}})));
    eq('limited: STUCK outranks AUTH and LIMITED', 'STUCK', await page.evaluate(() =>
      window.FLOORDEV.alertData({ping:null,lock:{stuck:true},authfail:['vendor: rejected'],limited:{}})));
    eq('limited: UNREACHABLE outranks every lower alert', 'UNREACHABLE', await page.evaluate(() =>
      window.FLOORDEV.alertData({ping:{wedged:true},lock:{stuck:true},authfail:['x'],limited:{}})));
    eq('limited: SILENT outranks LIMITED in fleet counters and filters', 'silent',
       await page.evaluate(() => window.FLOORDEV.fleetStateData(
         {state:'offline'}, {paused:false,disarmed:false,limited:{}})));
    eq('limited: PAUSED and DISARMED outrank LIMITED in fleet counters and filters', 'disarmed',
       await page.evaluate(() => window.FLOORDEV.fleetStateData(
         {state:'offline'}, {paused:true,disarmed:true,limited:{}})));
    eq('limited: STUCK outranks LIMITED after grid-state normalisation', 'working',
       await page.evaluate(() => window.FLOORDEV.fleetStateData(
         {state:'idle'}, {lock:{stuck:true},limited:{}})));
    /* The badge says AUTH for this box (asserted three lines up), the console
       refuses to draw LIMITED over it, and now the counter and the filter
       agree with both instead of calling it limited (#611 round 4). */
    eq('limited: AUTH outranks LIMITED after grid-state normalisation', 'idle',
       await page.evaluate(() => window.FLOORDEV.fleetStateData(
         {state:'idle'}, {authfail:['vendor: rejected'],limited:{}})));
    /* THE ROWS THE TWO ABOVE CANNOT SEE, because both pass `state:'idle'`
       (#611 round 5). `lock.stuck` and `authfail` are published for every
       unit, and the collector ranks paused/disarmed/SILENT above both — so an
       `offline` box carrying either is the ordinary output of its ladder, not
       a corner. These four pin that neither fact outranks the offline split:
       a box that went silent while its credential died is still SILENT, and a
       box that stopped ticking BECAUSE its duty run is wedged is still SILENT,
       which is the one the alarm exists for. */
    eq('silent: a dead credential does not spend the SILENT tile', 'silent',
       await page.evaluate(() => window.FLOORDEV.fleetStateData(
         {state:'offline'}, {paused:false,disarmed:false,
                             authfail:['vendor: rejected'],limited:{}})));
    eq('silent: a wedged duty run does not spend the SILENT tile', 'silent',
       await page.evaluate(() => window.FLOORDEV.fleetStateData(
         {state:'offline'}, {paused:false,disarmed:false,
                             lock:{stuck:true},limited:{}})));
    eq('disarmed: a dead credential does not move a stopped box', 'disarmed',
       await page.evaluate(() => window.FLOORDEV.fleetStateData(
         {state:'offline'}, {paused:true,disarmed:true,
                             authfail:['vendor: rejected'],limited:{}})));
    eq('disarmed: a wedged duty run does not move a stopped box', 'disarmed',
       await page.evaluate(() => window.FLOORDEV.fleetStateData(
         {state:'offline'}, {paused:true,disarmed:true,
                             lock:{stuck:true},limited:{}})));
    /* The setup command is not part of the later control-target assertion,
       which expects the next recorded command to come from the open room. */
    await page.evaluate(() => { window.__sent = []; });
  } else if (!LIVE) {
    const disarmedMatches = await stateMatches('disarmed');
    const silentMatches = await stateMatches('silent');
    const suppressedMatches = await stateMatches('suppressed');
    const limitedMatches = await stateMatches('limited');
    const allMatches = await stateMatches('all');
    eq('demo: Disarmed selects no preview unit', JSON.stringify([]),
       JSON.stringify(disarmedMatches));
    eq('demo: Silent selects every offline preview unit',
       JSON.stringify(['kimi-reviewer']), JSON.stringify(silentMatches));
    eq('demo: Suppressed selects no preview unit', JSON.stringify([]),
       JSON.stringify(suppressedMatches));
    eq('demo: Limited selects no preview unit', JSON.stringify([]),
       JSON.stringify(limitedMatches));
    ok('demo: no zero LIMITED tile is rendered', !/limited/i.test(tilesText), tilesText);
    eq('demo: All restores every preview unit', 7, allMatches.length);
  }
  /* ...and the hired tile is the "visible count rather than a silent omission"
     half of #204: a box without a console is omitted from the grid and never
     from the page. It appears only when the two numbers differ — a permanent
     "26 hired" beside "26 units" is furniture — so the assertion is a
     conditional with BOTH sides pinned, not a check that only runs when it
     happens to be there. */
  if (LIVE) {
    const tileHired = (tilesText.match(/(\d+)hired/) || [])[1];
    ok(hiddenBoxes.length ? 'floor: the hired tile counts the consoles drawn'
                          : 'floor: no hired tile when every box is hired',
       hiddenBoxes.length ? String(shown.length) === tileHired
                          : tileHired === undefined,
       `hired tile ${tileHired}, ${shown.length} of ${roster.length} deployed`);
    const hiredTitle = hiddenBoxes.length
      ? await page.evaluate(() => {
          const t = Array.from(document.querySelectorAll('#tiles .tile'))
            .find((e) => /hired/i.test(e.textContent));
          return t ? t.getAttribute('title') || '' : null;
        })
      : 'crew hire';
    ok('floor: the hired tile names the command that fills the gap',
       /crew hire/.test(hiredTitle || ''), String(hiredTitle));
  }
  await shot('01-floor');

  /* Cell geometry comes from the layout itself: FLOORDEV.grid() reports where
     every roster cell IS under the camera as it stands, plus the camera range.
     The test used to mirror drawFloor()'s constants and re-derive positions,
     and every layout change broke the mirror silently — the conference-grid
     rework (vertical scroll, window-sized tiles) is exactly the kind of change
     that would have clicked thin air for a whole walk. */
  const gridAt = () => page.evaluate(() => window.FLOORDEV.grid());
  const g0 = await gridAt();
  const vh = await page.evaluate(() => window.innerHeight);
  const camMax = g0.camMax;
  /* A slot is clickable when its centre is clear of the fixed chrome: the
     fleet bar (top) and the ops bar (bottom 152px) both overlay the canvas. */
  const CHROME_TOP = 80, CHROME_BOT = 170;
  const slotsOnScreen = async () => {
    const g = await gridAt();
    return g.cell
      .map((c) => ({ i: c.i, x: c.x + g.tw / 2, y: c.y + g.th / 2 }))
      .filter((c) => c.y >= CHROME_TOP && c.y <= vh - CHROME_BOT);
  };
  // The floor scrolls VERTICALLY; a viewport-sized walk steps the camera down.
  const stepPx = Math.max(150, vh - g0.th - CHROME_TOP - CHROME_BOT);
  // The camera eases toward its target, so scrolling needs a settle wait.
  // Absolute positioning: rewind to 0 first, then wheel forward by `cam`, so
  // the camera lands somewhere known rather than "as far as it got".
  /* #195 landed an independent fix for the same race while this PR was in
     review, from the other end: FLOORDEV.cam() is a real hook, and settleCam
     takes the target to converge ON rather than inferring convergence from a
     window global. That is the better mechanism and it wins the merge — this
     branch's version, which polled `window.floorCam` because app.js is inlined
     as a classic script, is dropped. Both were chasing the same symptom; #195's
     comment records "15/17 boxes reached, twice, on an idle box". */
  /* The camera IS readable now: FLOORDEV.cam() (the whiteboard hook postdates
     the "reading the real camera would need a test hook" decision below, and
     the hook exists regardless). The fixed waits this replaced covered ~4
     easing frames on a slow machine — the camera lands half-scrolled and a
     cell-centre click falls in a gap: that was "15/17 boxes reached", twice,
     on an idle box. (When this was written, a console dwell also expired
     every visible portrait still, making post-Escape frames build-heavy;
     stills are deterministic and permanent since #226, but the easing-vs-
     fixed-wait race is real on its own.) Poll convergence; on timeout click
     anyway — every caller still verifies by outcome. */
  const camAt = () => page.evaluate(() => window.FLOORDEV.cam());
  const settleCam = async (want) => {
    for (let w = 0; w < 8000; w += 60) {
      if (Math.abs((await camAt()) - want) < 0.75) return true;
      await page.waitForTimeout(60);
    }
    return false;
  };
  const scrollTo = async (cam) => {
    await page.mouse.move(700, Math.min(vh - CHROME_BOT, 400));
    await page.mouse.wheel(0, -(g0.totalH + 2000));
    await settleCam(0);
    if (cam > 0) {
      await page.mouse.wheel(0, cam);
      await settleCam(Math.min(cam, camMax));
    }
  };
  /* POLL, never sleep-and-hope. A fixed 700 ms for the room to open and 1200 ms
     for the easing camera to settle is a margin, not a guarantee: on a loaded
     CI runner a slow frame silently skipped a cell and the reachability count
     failed. That produced two intermittent red heads on this PR (the paused-box
     walk, then this one), which is how a suite teaches people to ignore it.
     One retry per cell, because a miss is nearly always a frame, not a bug. */
  const settle = async (pred, ms = 6000, every = 100) => {
    for (let w = 0; w < ms; w += every) {
      if (await pred()) return true;
      await page.waitForTimeout(every);
    }
    return false;
  };
  // Back out of a console to the floor. Every open/close pair goes through
  // this, including the ones inside the search below: leaving a console open
  // makes the next click land inside it instead of on a cell.
  const leave = async () => {
    await page.keyboard.press('Escape');
    await settle(async () => (await page.locator('body.floor').count()) === 1, 4000);
  };
  /* NEVER click while a console is open.
     `leave()` ran only after a SUCCESSFUL read, so a click whose room opened
     just after its settle window closed left the console up. The next click
     then landed INSIDE that console, where `body.room` is present and
     `#c-target` still names the PREVIOUS box — so the settle reported success
     and the walk recorded a read of a box it had already seen, while the cell
     it was aiming at was never visited. That is `16 reads -> 16 distinct,
     roster 17` with a DIFFERENT box missing each run (ff-noauth, ff-disarmed
     and two others across four), and it gets likelier with every cell added,
     because every cell is another chance for one settle to lose its race.
     Escape is idempotent on the floor, so this costs one DOM read per click
     and removes the class: whatever room appears after a click can only have
     come from that click. */
  const ensureFloor = async () => {
    if ((await page.locator('body.floor').count()) === 1) return;
    await leave();
  };
  // Re-open a unit recorded by the scan, by the position it was found at.
  /* Re-entry SEARCHES for the box; it does not replay a position.
     Saved (x, y, cam) cannot reliably reproduce a unit: scrollTo eases and
     clamps, so the same coordinates under a slightly different camera open a
     neighbour. Verifying that (the previous fix) correctly turned a silent
     mis-assertion into an honest failure — `expected ff-firstrun, got null` —
     but the replay itself is the unsound part. Try the saved spot first as a
     fast path, then fall back to scanning slots until the wanted box opens. */
  const openHere = async (x, y) => {
    // Same guard as the scan (grok, round 1): re-entry can inherit a late-open
    // room just as the walk could, and then reports the PREVIOUS box as this
    // click's result. Closing the class on one half only leaves it live on the
    // other, and enterAt()'s fast path is exactly where a stale console is
    // most likely — it clicks a remembered position straight after a scroll.
    await ensureFloor();
    await page.mouse.click(x, y);
    const opened = await settle(async () =>
      (await page.locator('body.room').count()) === 1
      && ((await page.locator('#c-target').textContent()) || '').includes('MESSAGE'), 4000);
    if (!opened) return null;
    return (await page.locator('#c-target').textContent()).replace('▸ MESSAGE ', '').trim();
  };
  const enterAt = async (v) => {
    // fast path: where we found it last time
    await scrollTo(v.cam);
    let got = await openHere(v.x, v.y);
    if (got === v.got) return got;
    if (got !== null) await leave();
    // search: every on-screen slot at every camera step until the box appears
    for (let cam = 0; ; cam = Math.min(cam + stepPx, camMax)) {
      await scrollTo(cam);
      for (const sl of await slotsOnScreen()) {
        got = await openHere(sl.x, sl.y);
        if (got === v.got) { v.x = sl.x; v.y = sl.y; v.cam = cam; return got; }
        if (got !== null) await leave();
      }
      if (cam >= camMax) break;
    }
    return null;
  };

  // ---- identity: cell i must open box i, and its controls must target it ---
  // Two boxes can share an agent+role (nothing forbids it), so a console keyed
  // by anything but the box name silently shows — and CONTROLS — the wrong box.
  /* Scan the floor in steps rather than assuming every cell is visible from
     one end or the other. Two fixed passes (cam 0 and cam max) left a middle
     cell unreachable once the fleet grew to 15 — and only on a slower runner,
     where the camera lerp had not fully settled, so it passed locally and went
     red in CI. Step until every index has been opened or progress stops. */
  /* Walk by RESULT, not by assumed camera position.
     The previous version computed each cell's x from the `cam` it had just
     requested — but scrollTo() eases and clamps, so the camera is not exactly
     where it was asked to be, and the click landed on a neighbour ("cell 8 is
     ff-nothired but opened ff-stopped", "15 cells resolved to 14 distinct
     boxes"). Reading the real camera would need a test hook in production
     code, so instead: click each on-screen SLOT, record whichever box actually
     opens, and assert the two properties that do not require knowing the
     camera —
       coverage: every DEPLOYED box is reachable, and
       ordering: boxes read in layout order are consecutive in that same list,
     which is what catches a cell rendering another unit's identity.
     Deployed, not declared, since #204: the grid no longer draws a console for
     a box that was never hired, so `shown` — not `roster` — is what these two
     properties are about. */
  const visible = [];
  const seenBox = new Map();          // box -> first {i-ish slot} we saw it at
  const orderViolations = [];


  for (let cam = 0; ; cam = Math.min(cam + stepPx, camMax)) {
    await scrollTo(cam);
    const readHere = [];              // boxes read at this scroll position, in layout order
    /* Every slot the grid reports is a real roster cell — the layout hook
       enumerates cells, not grid positions, so there is no "half-empty last
       column" case to special-case around. A slot that will not open is a
       lost race, not an absence — retry it once with a longer budget instead
       of silently recording the box as unreachable. */
    for (const sl of await slotsOnScreen()) {
      let opened = false;
      for (const budget of [4000, 8000]) {
        await ensureFloor();
        await page.mouse.click(sl.x, sl.y);
        opened = await settle(async () =>
          (await page.locator('body.room').count()) === 1
          && ((await page.locator('#c-target').textContent()) || '').includes('MESSAGE'), budget);
        if (opened) break;
      }
      // A room that opened after its settle window must not be left up for
      // the next click to land in.
      if (!opened) { await ensureFloor(); continue; }
      const box = (await page.locator('#c-target').textContent()).replace('▸ MESSAGE ', '').trim();
      readHere.push({ box, i: sl.i });
      if (!seenBox.has(box)) {
        seenBox.set(box, true);
        visible.push({ x: sl.x, y: sl.y, cam, got: box, expect: box });
      }
      await leave();
    }
    // Ordering: layout order must follow roster order. A cell rendering some
    // other unit's identity breaks this without needing the camera value.
    const idx = readHere.map((r) => shown.findIndex((u) => u.box === r.box));
    for (let k = 1; k < idx.length; k++) {
      // Increasing, not consecutive: a slot that failed to open is skipped,
      // which leaves a gap and is not a rendering fault. Going BACKWARDS or
      // repeating is — that is a cell showing another unit's identity.
      if (idx[k] >= 0 && idx[k - 1] >= 0 && idx[k] <= idx[k - 1]) {
        orderViolations.push(`${readHere[k - 1].box}(#${idx[k - 1]}) then ${readHere[k].box}(#${idx[k]})`);
      }
    }
    if (seenBox.size >= shown.length) break;
    if (cam >= camMax) break;
  }
  await scrollTo(0);

  ok('nav: layout order follows roster order', orderViolations.length === 0,
     orderViolations.slice(0, 3).join('; '));

  /* On an all-unhired fleet the correct number of cells is zero, and the
     assertion that the floor said so is above. Everywhere else, a floor whose
     cells will not open is exactly the failure this line is for. */
  ok('nav: cells open', emptyFloor ? visible.length === 0 : visible.length > 0,
     visible.length + ' distinct boxes entered');
  // Scrolling is what makes this meaningful: without it the tail of the fleet
  // is never clicked, and the tail is where the odd states live.
  /* Name the boxes that were missed. "16/17" says a walk failed; it does not
     say whether the renderer dropped a cell, the cell would not open, or the
     scan never reached it — and those want three different fixes. */
  const missed = shown.map((u) => u.box).filter((b) => !seenBox.has(b));
  ok('nav: every deployed box is reachable by scrolling', seenBox.size === shown.length,
     `${seenBox.size}/${shown.length} boxes reached` +
     (missed.length ? ` — never opened: ${missed.join(', ')}` : ''));
  if (LIVE) {
    // Every deployed box appears exactly once across the scan. Combined with
    // the ordering check above, that is the identity property without needing
    // to know where the camera actually is.
    const distinct = new Set(visible.map((v) => v.got));
    ok('identity: every box appears exactly once', distinct.size === visible.length
       && distinct.size === shown.length,
       `${visible.length} reads → ${distinct.size} distinct, deployed ${shown.length}`);
    const strays = visible.filter((v) => !roster.some((u) => u.box === v.got));
    ok('identity: no box outside the roster was rendered', strays.length === 0,
       strays.map((v) => v.got).join(','));
    /* ---- the #204 filter, ON THE RENDERED PAGE ---------------------------
       The scan above opened every cell the grid drew, so `seenBox` is the
       page's own answer to "which boxes have a console" — read out of the DOM,
       not out of /api/fleet. Every collector assertion for this feature can
       stay green while the page draws the wrong grid; that is the regression
       shape #203 recorded, and these two are what red it.

       Both directions, because both are ways to get this exactly wrong. A
       filter that hides nothing has not shipped; a filter that hides a stopped
       or unreachable box has INVERTED the issue — the hired-and-gone-dark box
       is the one an operator most needs on the page. */
    const drawnButHidden = hiddenBoxes.filter((b) => seenBox.has(b));
    ok('filter: an unhired box gets no console', drawnButHidden.length === 0,
       hiddenBoxes.length
         ? `hidden: ${hiddenBoxes.join(', ')}; wrongly drawn: ${drawnButHidden.join(', ') || 'none'}`
         : 'no unhired box in this fleet');
    const keptStates = roster.filter((u) => u.hired === 'unknown');
    const droppedKeepers = keptStates.map((u) => u.box).filter((b) => !seenBox.has(b));
    ok('filter: a box whose hired state cannot be measured keeps its console',
       droppedKeepers.length === 0,
       `unmeasurable: ${keptStates.map((u) => u.box).join(', ') || 'none'}` +
       `; wrongly hidden: ${droppedKeepers.join(', ') || 'none'}`);
  }
  if (LIVE && FIXTURE) {
    /* The exact fixture boxes, by name. The two assertions above are shape
       checks that hold on any fleet — and on a fleet where nothing is unhired
       and nothing is unmeasurable they are both vacuously true. Only this run
       can name the four boxes that make each of the four table rows in #204
       bite, so only this run gets to. */
    const drew = (b) => seenBox.has(b);
    ok('filter: ff-nothired — answered, no engine — is hidden', !drew('ff-nothired'));
    ok('filter: ff-absent — no box exists yet — is hidden', !drew('ff-absent'));
    ok('filter: ff-stopped keeps its console', drew('ff-stopped'));
    ok('filter: ff-unreach keeps its console', drew('ff-unreach'));
    // ...and the payload is untouched, read from the page's own fetch. The
    // drill's agreement check fails a box outright with "not in /api/fleet",
    // so a filter that reached the API would red a drill nothing in this suite
    // can run.
    ok('filter: the hidden boxes are still served by /api/fleet',
       ['ff-nothired', 'ff-absent'].every((b) => roster.some((u) => u.box === b)),
       roster.length + ' units in the payload');
  }

  if (LIVE && visible.length && !READONLY) {
    // The control must address the box on screen, not a lookalike.
    const target = visible[0];
    const reopened = await enterAt(target);
    // Assert we are actually in the room before driving a control: a null
    // re-entry used to fall through and click a hidden #a-pause, which failed
    // as a 30s Playwright timeout rather than as a legible test failure.
    ok('identity: the target console re-opens', reopened === target.got,
       `expected ${target.got}, got ${reopened}`);
    await page.click('#a-pause');
    await settle(async () => (await sent()).length > 0, 8000);
    const s = await lastSent();
    eq('identity: pause targets the open box', target.expect, s.box);
    ok('ctl: pause posts pause/resume', /^(pause|resume)$/.test(s.action || ''), s.action);
    // Undo it: this is a real pause on a real box, and leaving it paused
    // changes the fleet the later tests in this suite walk into.
    if (s.action === 'pause') {          // never send a bare resume: on a box an
                                         // operator had parked, that un-parks it
      await page.evaluate(async (b) => {
        await fetch(location.origin + '/api/command', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ action: 'resume', box: b }),
        });
      }, target.expect);
      await page.waitForTimeout(500);
    }
    await leave();
  }

  // ---- per-state rendering ------------------------------------------------
  const byState = {};
  for (const v of visible) {
    const opened = await enterAt(v);
    // A missed click would otherwise attribute the PREVIOUS console's readings
    // to this box, and every per-state assertion below would be about the
    // wrong unit.
    if (opened !== v.got) { if (opened !== null) await leave(); continue; }
    const st = (await page.locator('#modelabel').textContent()).trim();
    (byState[st] = byState[st] || []).push({
      box: v.got,
      current: (await page.locator('#w-current').textContent()).replace(/\s+/g, ' '),
      vitals: (await page.locator('#w-vitals').textContent()).replace(/\s+/g, ' '),
      pauseLabel: (await page.locator('#a-pause').textContent()).trim(),
      cron: ((await page.locator('#w-vitals').textContent()).match(/Cron\s*(\S+)/) || [])[1] || '',
      // The headline pill and the room's status line: the two loudest words on
      // the console, and two of the four that called every stopped box SILENT
      // (#203). Read here rather than in their own walk so the four readouts
      // for one box come from ONE render — a headline captured on a later
      // entry than its big card could disagree for a reason no operator would
      // ever see.
      headline: ((await page.locator('#w-id .pill').textContent()) || '').trim(),
      fl: (await page.locator('#fl').textContent()).trim(),
      sessions: (await page.locator('#w-sessions').textContent()).replace(/\s+/g, ' '),
      terminalRows: await page.locator('#w-sessions .terminal').count(),
    });
    await leave();
  }
  // ---- the three tiers must be VISIBLE, not merely served ----------------
  // Every field below is in /api/fleet and asserted in floor/units.sh. That proves
  // the collector computed it; it says nothing about whether an operator can
  // see it. The gh column regressed exactly this way — probe.sh stopped
  // emitting "ok", the page still tested for it, and every healthy box
  // rendered "gh ✗" while every collector assertion stayed green.
  const allSeen = Object.keys(byState).reduce((a, k) => a.concat(byState[k]), []);
  if (LIVE && allSeen.length) {
    // Asserted by SHAPE, because this block is gated on LIVE alone and LIVE
    // only means "the page flipped to real data" — true on a real host as much
    // as against the stub. The previous form pinned `0.4.1` and `deadbee`,
    // which are stub-box fixture constants (test/stub-box:84,431), so on a real
    // fleet — rendering its own VERSION — it could not pass by construction. It
    // failed every real-host drill while reading as an app defect (#190, #202).
    // The exact-constant form still runs, under LIVE && FIXTURE below, which is
    // the only place those values are true.
    //
    // What survives here is the regression this exists to catch: stampVersion
    // (src/app.js) maps `crew@X.Y.Z[-suffix]` to the version alone, so a leaked
    // `crew@` prefix means the raw stamp reached the tile, and `unknown` means
    // it could not parse one. Both are anchored on the Engine label rather than
    // searched loose in the vitals string, or the check would match on a
    // neighbouring field and report the wrong tier.
    ok('render: engine shows the version without provenance',
       allSeen.some((u) => /Engine\s*\d+\.\d+\.\d+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?/.test(u.vitals)) &&
         allSeen.every((u) => !/Engine\s*(?:crew@|unknown)/.test(u.vitals)),
       allSeen.map((u) => u.box + ': ' + u.vitals).join(' | '));
    ok('render: the heartbeat is on screen',
       allSeen.every((u) => /Heartbeat/.test(u.vitals)),
       allSeen.filter((u) => !/Heartbeat/.test(u.vitals)).map((u) => u.box).join(','));
    // A live round-trip renders as "12ms · 4s ago". Asserting the ms shape
    // rather than the label proves a real value reached the DOM.
    const pinged = allSeen.filter((u) => /Heartbeat\s*\d+ms/.test(u.vitals));
    ok('render: at least one box shows a measured round-trip',
       pinged.length > 0,
       allSeen.map((u) => u.box + ': ' + (u.vitals.match(/Heartbeat\s*(\S+)/) || [])[1]).join(' | '));
    // #159's verdict, beside the version and never instead of it. The version
    // alone is what install.sh wrote once; this says whether the files still
    // hash to it, and an operator who cannot see it is reading a claim nobody
    // checked. Shape, on the same reasoning as the assertion above: the words
    // are `crew status`'s INTEGRITY vocabulary and hold on any fleet, while
    // WHICH word is true of WHICH box is a fixture fact, asserted below.
    //
    // Over the boxes that render a version, not all of them: an unreachable or
    // unhired box shows "—" and has no verdict to carry.
    const stamped = allSeen.filter((u) =>
      /Engine\s*\d+\.\d+\.\d+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?/.test(u.vitals));
    ok('render: the engine tile carries its integrity verdict',
       stamped.length > 0 &&
         // No trailing \b: the grid's textContent runs one field straight into
         // the next label ("…0.4.1✓ currentUptime25h 30m"), so a word boundary
         // after the verdict never occurs and the check would red on a page
         // that renders it perfectly.
         stamped.every((u) => /Engine\s*\d+\.\d+\.\d+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?\s*[✓⚠~]\s*(?:current|MODIFIED|unverified)/.test(u.vitals)),
       stamped.map((u) => u.box + ': ' + (u.vitals.match(/Engine\s*(\S+ ?\S*)/) || [])[1]).join(' | '));
    /* ---- the gh check, SCOPED to boxes that could be flowing (#190) -------
       `flowing` — the ✓ — is a claim the collector makes only while the last
       tick is younger than SILENT_AFTER_S: a credential the box reported as
       `nofail` ages to `stale` past that boundary (server/floor.py), and the
       page renders stale as the amber `~` on purpose. A DISARMED box has no
       cron line, so it cannot tick, so it passes that threshold BY
       CONSTRUCTION — and drill/rehearsal.sh disarms every box before the walk
       runs. Asserting `gh ✓` over that fleet failed a page that was behaving
       exactly as designed, and read as a rendering defect for four drills.
       That is #202's shape one field over: an assertion that cannot pass on a
       run the harness allows.
       So the check runs over the boxes it could ever have been about — the
       ones whose CRON vital shows a live tick age, which is armed AND ticking
       in one readout. DISARMED, PAUSED, SILENT and "no ticks yet" all render a
       word there instead, and none of them is evidence about a credential.
       Scoped, never loosened: what the check asserts about a candidate box is
       untouched, and an armed, freshly-ticking box rendering a blanket ✗ still
       reds it — the probe.sh vocabulary-mismatch regression it was written for.
       A check that would pass vacuously says so instead, in the same stream as
       the ok lines: a fleet with nothing to check is not a fleet that passed. */
    const canFlow = allSeen.filter((u) => /^\d/.test(u.cron));
    if (FIXTURE) {
      // The fixture guarantees healthy ticking boxes, so an empty candidate set
      // here is the scrape breaking, not a fleet at rest — and it would silently
      // retire the check below rather than fail it.
      ok('render: the fixture offers an armed, ticking box to check gh against',
         canFlow.length > 0,
         allSeen.map((u) => u.box + ': cron=' + u.cron).join(' | '));
    }
    if (canFlow.length) {
      // The regression guard. "gh ?" is legitimate (an unhired box), "gh ✗" is
      // legitimate (a real rejection) — but not for every box at once, which is
      // what a vocabulary mismatch produces.
      const ticked = canFlow.filter((u) => /gh ✓/.test(u.vitals));
      ok('render: healthy boxes show gh ✓, not a blanket ✗',
         ticked.length > 0,
         canFlow.map((u) => u.box + ': ' + (u.vitals.match(/Box\s*(\S+ \S+)/) || [])[1]).join(' | '));
    } else {
      console.log('  --   no armed, ticking box in this fleet: gh ✓ is not a claim the page '
                  + 'can make about a box whose credentials age to ~, so the check did not run');
    }
  }
  if (LIVE && FIXTURE) {
    const terminal = allSeen.find((u) => /ff-lim-terminal/.test(u.box));
    ok('limited: terminal session has its own rendered class',
       !!terminal && terminal.terminalRows > 0,
       terminal ? terminal.sessions : 'terminal fixture not reached');
    ok('limited: reset text renders as display-only console detail',
       !!terminal && /LIMITED/.test(terminal.headline)
         && /build lane, terminal/.test(terminal.current)
         && /resets at 18:00 UTC/.test(terminal.current),
       terminal ? terminal.headline+' | '+terminal.current : 'terminal fixture not reached');
    const eventUnit = allSeen.find((u) => /ff-idle/.test(u.box));
    ok('limited: floor events render on the unit console without an alert channel',
       !!eventUnit && /OPERATING LIMIT EVENTS/.test(eventUnit.sessions)
         && /github_connection_nodes/.test(eventUnit.sessions)
         && /fixture-payload/.test(eventUnit.sessions),
       eventUnit ? eventUnit.sessions : 'event fixture not reached');
    const breakerUnit = allSeen.find((u) => /ff-lim-breaker/.test(u.box));
    ok('limited: breaker reason and lane render on the unit console',
       !!breakerUnit && /LIMITED/.test(breakerUnit.headline)
         && /review lane, terminal-breaker/.test(breakerUnit.current),
       breakerUnit ? breakerUnit.headline+' | '+breakerUnit.current : 'breaker fixture not reached');
    const budgetUnit = allSeen.find((u) => /ff-lim-budget/.test(u.box));
    ok('limited: budget reason and lane render on the unit console',
       !!budgetUnit && /LIMITED/.test(budgetUnit.headline)
         && /triage lane, budget/.test(budgetUnit.current),
       budgetUnit ? budgetUnit.headline+' | '+budgetUnit.current : 'budget fixture not reached');
    // The exact-constant half of the engine assertion above. The stub stamps
    // `crew@${FLOOR_TEST_ENGINE_VERSION} (deadbee)` (test/run.sh), so this is
    // the one run where
    // provenance-stripping can be checked against a KNOWN input: the version
    // must render and the provenance token must not. A real fleet cannot make
    // this claim — its stamp carries whatever provenance it carries — which is
    // why the live block above asserts shape instead.
    ok(`render: the fixture engine renders ${FIXTURE_ENGINE_VERSION} with its provenance stripped`,
       allSeen.some((u) => new RegExp(`Engine\\s*${FIXTURE_ENGINE_PATTERN}`).test(u.vitals)) &&
         allSeen.every((u) => !/deadbee/.test(u.vitals)),
       allSeen.map((u) => u.box + ': ' + u.vitals).join(' | '));
    /* The three verdicts must render as three verdicts (#159, #190). A tile
       that shows every box as verified has added a word and no information,
       and the two boxes it would be wrong about are the only two the
       instrument exists for. FIXTURE-gated because a healthy real fleet has no
       hand-edited box in it and should not be asked for one — its truth is
       asserted where the hash can prove it, in boxside.sh.
       Read out of the Engine field alone: `MODIFIED` loose in the vitals would
       also match a neighbouring readout, and this check is precisely about
       which field the word is in. */
    const eng = (u) => (u.vitals.match(/Engine\s*(.*?)\s*Uptime/) || [])[1] || '';
    const mod = allSeen.find((u) => /ff-modified/.test(u.box));
    ok('integrity: the modified box was reachable', !!mod,
       `no ff-modified among ${allSeen.length} consoles`);
    if (mod) {
      ok('integrity: a diverged engine says MODIFIED on the tile',
         /MODIFIED/.test(eng(mod)) && !/current/.test(eng(mod)), `${mod.box}: Engine=[${eng(mod)}]`);
    }
    const unv = allSeen.find((u) => /ff-unverified/.test(u.box));
    ok('integrity: the unverified box was reachable', !!unv,
       `no ff-unverified among ${allSeen.length} consoles`);
    if (unv) {
      // The state every box is in the day content stamping ships. Rendering it
      // as verified would be the most expensive of the three mistakes: it
      // claims a check that never ran.
      ok('integrity: an unverified engine is not rendered as verified',
         /unverified/.test(eng(unv)) && !/current/.test(eng(unv)), `${unv.box}: Engine=[${eng(unv)}]`);
    }
    // The positive half, in one unconditional check: the negatives above prove
    // two boxes are not called verified, and prove nothing about whether any
    // box ever is.
    const clean = allSeen.find((u) => /ff-working/.test(u.box));
    ok('integrity: a clean engine is rendered as verified',
       !!clean && /current/.test(eng(clean)) && !/MODIFIED|unverified/.test(eng(clean)),
       clean ? `${clean.box}: Engine=[${eng(clean)}]` : `no ff-working among ${allSeen.length} consoles`);
    // FIXTURE-gated: a real fleet has no box wedged on purpose, and should not.
    const stuck = allSeen.find((u) => /ff-stuck/.test(u.box));
    ok('render: the stuck box was reachable', !!stuck,
       'no ff-stuck among ' + allSeen.length + ' consoles');
    if (stuck) {
      // It is STATE=working with a live session, so without this the panel
      // showed an ordinary elapsed timer and the box read as healthy.
      ok('render: a stuck lock says STUCK in the session panel',
         /STUCK/.test(stuck.current), stuck.current.slice(0, 90));
      ok('render: the stuck panel names how long the lock has been held',
         /lock held/.test(stuck.current), stuck.current.slice(0, 90));
    }
  }

  /* ---- SILENT is an alarm, and the page must spend it on nothing else -----
     #189 taught the COLLECTOR the difference and floor/units.sh pins it: `wire:
     disarmed box carries the flag`, `note: disarmed names crew hire, not
     SILENT`. The page was never taught, and every one of those green
     assertions stayed green while an operator looked at three disarmed boxes
     and read SILENT three times (#203).

     That is the gap the comment at the head of the tier block above is about,
     one field over. So these read the RENDERED page — the headline pill, the
     CRON vital, the big card and the room's status line — and the API is not
     consulted for any of them.

     FIXTURE-gated: `ff-disarmed` and `ff-silent` are states a healthy real
     fleet does not have and should not be asked for. `ff-paused` is NOT used
     here, deliberately — the collector cases run `wake-silent`, which resumes
     the fixture's paused box long before this walk starts, so the paused half
     is asserted further down where the walk pauses a box itself. */
  if (LIVE && FIXTURE) {
    const four = (u) => `${u.box}: headline=[${u.headline}] cron=[${u.cron}] ` +
      `fl=[${u.fl}] current=[${u.current.slice(0, 60)}]`;
    const dis = allSeen.find((u) => /ff-disarmed/.test(u.box));
    ok('disarmed: the disarmed box was reachable', !!dis,
       `no ff-disarmed among ${allSeen.length} consoles`);
    if (dis) {
      // The defect, at each of the four sites, in the order an eye hits them.
      ok('disarmed: the headline says DISARMED, not SILENT',
         /DISARMED/.test(dis.headline) && !/SILENT/.test(dis.headline), four(dis));
      // Anchored, not equal: `cron` is scraped out of a CSS grid's
      // textContent, so the value runs straight into the next field's label
      // ("DISARMEDRepoheavy-duty/crew…"). The neighbours are what makes the
      // negative half worth asserting rather than implying.
      ok('disarmed: the CRON vital says DISARMED, not SILENT',
         /^DISARMED/.test(dis.cron) && !/SILENT/.test(dis.cron), four(dis));
      // Case-sensitive on purpose: the note UNDER the big card has always said
      // "disarmed — no cron line", and it is the 40px word above it that said
      // SILENT. Matching case-insensitively would pass on the note alone.
      ok('disarmed: the big card says DISARMED, not SILENT',
         /DISARMED/.test(dis.current) && !/SILENT/.test(dis.current), four(dis));
      ok('disarmed: the status line does not call it silent',
         /DISARMED/.test(dis.fl) && !/SILENT/.test(dis.fl), four(dis));
    }
    /* The other half, and the one that matters more: #189 exists because an
       alarm nobody can act on is an alarm nobody reads. Suppressing it for a
       box that really has stopped ticking would be a worse bug than the one
       above, so every site is asserted in both directions. */
    const sil = allSeen.find((u) => /ff-silent/.test(u.box));
    ok('disarmed: the genuinely silent box was reachable', !!sil,
       `no ff-silent among ${allSeen.length} consoles`);
    if (sil) {
      ok('silent: an armed box that stopped still says SILENT in the headline',
         /SILENT/.test(sil.headline), four(sil));
      ok('silent: ...and in the CRON vital', /^SILENT/.test(sil.cron), four(sil));
      ok('silent: ...and on the big card', /SILENT/.test(sil.current), four(sil));
      ok('silent: ...and on the status line', /SILENT/.test(sil.fl), four(sil));
    }
  }

  const down = byState.OFFLINE || [];
  // The fixture guarantees offline boxes; a healthy real fleet guarantees the
  // opposite, and "everything is up" must not read as a test failure.
  if (FIXTURE) {
    ok('render: at least one down box in view', down.length > 0, Object.keys(byState).join(','));
  }
  if (down.length > 0) {
    ok('render: down boxes state a reason',
       down.every((u) => /unreachable|stopped|SILENT|paused|not hired|not created|cron/i.test(u.current)),
       down.map((u) => u.box + ': ' + u.current.slice(0, 50)).join(' | '));
  } else {
    console.log('  --   no offline box in this fleet; nothing to state a reason for');
  }
  if (LIVE) {
    // Self-consistency within one render: the vitals say whether the box is
    // paused, so the button must name the action that follows from it.
    const all = Object.values(byState).flat();
    const inconsistent = all.filter((u) =>
      /PAUSED/i.test(u.cron) !== /Resume/.test(u.pauseLabel));
    ok('render: the Pause label names the action the click sends',
       inconsistent.length === 0,
       inconsistent.map((u) => `${u.box} cron=${u.cron} label=${u.pauseLabel}`).join('; '));
  }

  /* Pause a box HERE rather than relying on one being paused in the fixture:
     the collector-side tests run `wake-silent`, which resumes every offline
     box — including the fixture's paused one — so "is something paused right
     now" depends on what ran before this. Make the state, assert it, undo it.

     Truth comes from the API (u.paused), not from scraping Cron text out of a
     CSS grid's textContent — that scrape was brittle and is what put CI red.
     Both are re-read together each iteration, so there is no window where a
     label captured earlier is compared against a flag fetched later. */
  if (LIVE && visible.length && !READONLY) {
    /* The victim must be a box a pause can actually MOVE. Since #188 a box with
       no armed tick.sh line answers 200 `nothing to pause` — correctly; an
       action with nothing to do is not a refusal — so landing on the fixture's
       disarmed box would sit out all fourteen polls below waiting for a
       `paused` that is never coming, and report the renderer as broken. The
       name says nothing about this: `disarmed` is the flag the collector
       derives from the box's own crontab count, so ask the API, in keeping with
       the rest of this block. Falls back to the old choice if nothing is armed,
       rather than silently skipping the assertion. */
    const armed = await page.evaluate(async () => {
      const r = await fetch(location.origin + '/api/fleet');
      return (await r.json()).units.filter((u) => !u.disarmed).map((u) => u.box);
    });
    const reachable = visible.filter((v) => !/unreach|wedged|absent|stopped/.test(v.got));
    const victim = reachable.find((v) => armed.includes(v.got)) || reachable[0] || visible[0];
    const cmd = (action, box) => page.evaluate(async ([a, b]) => {
      const r = await fetch(location.origin + '/api/command', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: a, box: b }),
      });
      return r.status;
    }, [action, box]);

    const pauseStatus = await cmd('pause', victim.got);
    ok('ctl: pause command accepted', pauseStatus === 200, `HTTP ${pauseStatus}`);

    let checked = false;
    for (let i = 0; i < 14; i++) {
      await page.waitForTimeout(2500);
      const apiPaused = await page.evaluate(async (b) => {
        const r = await fetch(location.origin + '/api/fleet');
        const u = (await r.json()).units.find((x) => x.box === b);
        return u ? !!u.paused : null;
      }, victim.got);
      if (!apiPaused) continue;               // collector has not re-polled yet
      const opened = await enterAt(victim);
      if (opened !== victim.got) {           // clicked the wrong cell — retry
        if (opened !== null) await leave();
        continue;
      }
      const label = (await page.locator('#a-pause').textContent()).trim();
      /* The paused half of #203, read from the SAME entry as the label above.
         It cannot use the fixture's `ff-paused`: the collector cases run
         `wake-silent` before this walk starts, which resumes it. So the state
         is made here — which is why this block already exists — and the four
         readouts are captured while it holds. */
      const paused = {
        box: victim.got,
        headline: ((await page.locator('#w-id .pill').textContent()) || '').trim(),
        current: (await page.locator('#w-current').textContent()).replace(/\s+/g, ' '),
        cron: ((await page.locator('#w-vitals').textContent()).match(/Cron\s*(\S+)/) || [])[1] || '',
        fl: (await page.locator('#fl').textContent()).trim(),
      };
      await leave();
      // The page can lag the collector by one poll; only assert once it agrees.
      if (/Resume/.test(label)) {
        ok('render: a paused box offers Resume', /Resume/.test(label),
           `${victim.got} label=${label}`);
        const four = `${paused.box}: headline=[${paused.headline}] ` +
          `cron=[${paused.cron}] fl=[${paused.fl}] current=[${paused.current.slice(0, 60)}]`;
        // Paused was the ONE state the page half-knew about: the CRON vital
        // named it and the other three shouted SILENT anyway. All four now.
        ok('paused: the headline says PAUSED, not SILENT',
           /PAUSED/.test(paused.headline) && !/SILENT/.test(paused.headline), four);
        ok('paused: the CRON vital says PAUSED, not SILENT',
           /^PAUSED/.test(paused.cron) && !/SILENT/.test(paused.cron), four);
        ok('paused: the big card says PAUSED, not SILENT',
           /PAUSED/.test(paused.current) && !/SILENT/.test(paused.current), four);
        ok('paused: the status line does not call it silent',
           /PAUSED/.test(paused.fl) && !/SILENT/.test(paused.fl), four);
        checked = true;
        break;
      }
    }
    if (!checked) {
      ok('render: a paused box offers Resume', false,
         `${victim.got}: page never showed Resume while the API reported paused`);
    }
    await cmd('resume', victim.got);
    await page.waitForTimeout(500);
  }

  // ---- hostile log content must stay text ---------------------------------
  const hostile = visible.find((v) => /hostile/.test(v.got));
  if (FIXTURE && LIVE && !hostile) {
    // Silent coverage loss is worse than a loud failure: without this, the XSS
    // checks below simply would not run and the suite would still be green.
    // FIXTURE-gated -- a real fleet has no such box, and should not.
    ok('xss: the hostile-log box was reachable', false,
       `no unit matching /hostile/ among ${visible.length} reached boxes`);
  }
  if (hostile) {
    if ((await enterAt(hostile)) !== hostile.got) {
      ok('xss: hostile console re-opened', false, `could not re-open ${hostile.got}`);
    } else {
    const injected = await page.evaluate(() => ({
      imgs: document.querySelectorAll('.rail-l img, .rail-r img').length,
      scripts: document.querySelectorAll('.rail-l script, .rail-r script').length,
      queueText: document.getElementById('w-queue').textContent,
      curText: document.getElementById('w-current').textContent,
    }));
    eq('xss: no injected <img>', 0, injected.imgs);
    eq('xss: no injected <script>', 0, injected.scripts);
    ok('xss: markup rendered as text',
       /<img|onerror|<script/.test(injected.queueText + injected.curText),
       (injected.queueText + ' | ' + injected.curText).slice(0, 120));
    await shot('06-hostile-escaped');
    await leave();
    }
  }

  /* A box inside its FIRST session — cur set, sessions empty — is ordinary
     live telemetry (floor.py sets working whenever cur exists). The room's
     diagnostic hologram dereferenced sessions[0] unguarded, so opening this
     room threw inside the render loop, every frame. Three reviewers found it;
     136 checks did not, because no fixture could reach the state. */
  const firstRun = visible.find((v) => /firstrun/.test(v.got));
  if (FIXTURE && LIVE && !firstRun) {
    ok('first-run: the first-session box was reachable', false,
       `no unit matching /firstrun/ among ${visible.length} reached boxes`);
  }
  if (LIVE && firstRun) {
    const before = consoleErrors.length;
    const frOpened = await enterAt(firstRun);
    ok('first-run console re-opened', frOpened === firstRun.got,
       `expected ${firstRun.got}, got ${frOpened}`);
    if (frOpened !== firstRun.got) { await leave(); }
    else {
    await page.waitForTimeout(2500);          // let the render loop run frames
    ok('first-run room renders without throwing',
       consoleErrors.length === before,
       consoleErrors.slice(before).slice(0, 2).join(' | '));
    ok('first-run room still shows its open session',
       /\d/.test(await page.locator('#w-current').textContent()),
       (await page.locator('#w-current').textContent()).replace(/\s+/g, ' ').slice(0, 60));
    await shot('07-first-run-room');
    await leave();
    }
  }

  /* Live repo strings are full owner/repo. The link used to prefix the org
     unconditionally, yielding github.com/heavy-duty/heavy-duty%2Fcrew — and
     the old assertion only checked for the "heavy-duty/" prefix, which the
     BROKEN url also satisfied. Assert the whole URL. */
  if (LIVE && visible.length) {
    const withRepo = [];
    for (const v of visible) {
      // Skip a unit we could not re-open rather than reading whichever console
      // happened to be on screen — that is exactly how the wrong repo string
      // would get asserted as correct.
      if ((await enterAt(v)) !== v.got) continue;
      // From the button's own text node: scraping the whole panel ran the
      // repo name into the next button's icon and produced "…crew◱".
      const repo = (await page.locator('#ac-repo').textContent()).match(/Open repo · (.+)$/);
      if (repo && repo[1].trim() !== '—') {
        await page.click('#ac-repo');
        await page.waitForTimeout(250);
        withRepo.push({ box: v.got, repo: repo[1].trim(), url: (await page.evaluate(() => window.__opened)).slice(-1)[0] });
        await leave();
        break;
      }
      await leave();
    }
    if (withRepo.length) {
      const { repo, url } = withRepo[0];
      ok('repo link is not double-prefixed', !/heavy-duty\/heavy-duty/.test(url || ''), url);
      ok('repo link does not escape the slash', !/%2F/i.test(url || ''), url);
      ok('repo link points at the actual repo',
         url === 'https://github.com/' + repo, `${url} for repo ${repo}`);
    } else if (FIXTURE) {
      // Fixture-gated for the same reason as the offline-box demand above: the
      // fixture guarantees a unit with a repo, a real fleet does not. A host
      // whose boxes are all idle with no history and no repos.txt would fail
      // here for a reason that says nothing about the page.
      //
      // Unlike the hostile/first-run cases this one is DEFENSIVE, not
      // demonstrated: I could not drive a stub fleet into it, because the repo
      // string comes from session and queue lines rather than from `::repos`,
      // so every box with any history still exposes one. Gated on the argument,
      // not on a reproduction -- worth stating plainly rather than implying the
      // same evidence as the other two.
      ok('repo link points at the actual repo', false, 'no unit exposed a repo');
    } else {
      console.log('  --   no unit exposed a repo; nothing to check a repo link against');
    }
  }

  // ---- transcript and raw-log overlay / demo lockout ----------------------
  if (visible.length) {
    const logTarget = LIVE && FIXTURE
      ? visible.find((v) => /ff-working/.test(v.got))
      : visible[0];
    const l0 = await enterAt(logTarget);
    ok('logs: console re-opened for the overlay check', l0 === logTarget.got,
       `expected ${logTarget.got}, got ${l0}`);
    if (LIVE && l0 === logTarget.got) {
      eq('room: the HUD shows the serving host version', snapshot.version,
         (await page.locator('#room-version').textContent()).trim());
    }
    if (LIVE && l0 === logTarget.got) {
      if (FIXTURE) {
        const row = page.locator('#dfeed .session-log').first();
        eq('transcript: the paired session is the one offered', 1, await row.count());
        ok('transcript: the row visibly names its affordance',
           /transcript/.test(await row.textContent()), await row.textContent());
        const before = (await fetched()).length;
        await row.click();
        await settle(async () => await page.locator('#logov').isVisible().catch(() => false), 8000);
        const calls = (await fetched()).slice(before).filter((u) => /\/api\/logs\?/.test(u));
        eq('transcript: one request is fired', 1, calls.length);
        ok('transcript: the request names the paired basename, not duty.log',
           calls.length === 1
             && /file=20260726T090000Z-build-heavy-duty_crew_601\.log(?:&|$)/.test(calls[0]),
           calls.join(' | '));
        const title = await page.locator('#logttl').textContent();
        ok('transcript: title identifies the session and the tail bound',
           /build heavy-duty\/crew#601/.test(title)
             && /ok/.test(title) && /4m 50s/.test(title) && /last 500 lines/.test(title),
           title);
        await page.keyboard.press('Escape');
        await settle(async () => !(await page.locator('#logov').isVisible().catch(() => false)), 4000);
        ok('transcript: Esc closes the overlay and keeps the room',
           !(await page.locator('#logov').isVisible().catch(() => false))
             && (await page.locator('body.room').count()) === 1);
      }

      const rawBefore = (await fetched()).length;
      await page.click('#ac-logs');
      await settle(async () => await page.locator('#logov').isVisible().catch(() => false), 8000);
      const shown = await page.locator('#logov').isVisible().catch(() => false);
      ok('logs: raw duty.log still opens in the overlay', shown,
         (await page.locator('#livestat').textContent()).trim());
      const rawCalls = (await fetched()).slice(rawBefore).filter((u) => /\/api\/logs\?/.test(u));
      ok('logs: raw control still sends no file parameter',
         rawCalls.length === 1 && !/[?&]file=/.test(rawCalls[0]), rawCalls.join(' | '));
      if (shown) await shot('05-log-overlay');
      await page.keyboard.press('Escape');
      await settle(async () => !(await page.locator('#logov').isVisible().catch(() => false)), 4000);
      ok('logs: Esc closes overlay and keeps the room',
         !(await page.locator('#logov').isVisible().catch(() => false))
         && (await page.locator('body.room').count()) === 1);

      if (FIXTURE) {
        await leave();
        const unavailable = visible.find((v) => /ff-idle/.test(v.got));
        const inertOpen = await enterAt(unavailable);
        ok('transcript: unavailable-session console opens', inertOpen === unavailable.got,
           `expected ${unavailable.got}, got ${inertOpen}`);
        if (inertOpen === unavailable.got) {
          const aged = page.locator('#dfeed .session-log-off').filter({hasText: 'start aged out'}).first();
          ok('transcript: an aged-out START says why the row is inert',
             (await aged.count()) === 1, await page.locator('#dfeed').textContent());
          const inertBefore = (await fetched()).length;
          await aged.click();
          await page.waitForTimeout(250);
          const inertCalls = (await fetched()).slice(inertBefore).filter((u) => /\/api\/logs\?/.test(u));
          eq('transcript: clicking an inert row fires no request', 0, inertCalls.length);
          eq('transcript: the orphan-reconciled row is inert too', 1,
             await page.locator('#dfeed .session-log-off').filter({hasText: 'ORPHANED'}).count());
        }
      }
    } else {
      const woff = await page.evaluate(() =>
        ['g-start', 'g-stop', 'g-wake', 'g-reg', 'g-roster', 'a-pause', 'a-restart', 'c-send']
          .filter((id) => document.getElementById(id).classList.contains('woff')).length);
      // Seven since #488: the registry editor writes host files, so it belongs
      // in the lockout with every other control that does something. Eight
      // with the roster editor, for the same reason.
      eq('demo: all 8 controls disabled', 8, woff);
      eq('demo: message box disabled', true, await page.locator('#c-in').isDisabled());
      await shot('05-demo-disabled');
    }
    await shot('03-console');
    await leave();
  }

  /* ---- #488: the registries are REACHABLE, from both scopes ----------------
     A collector assertion cannot answer the acceptance criterion here. "The
     per-box override is reachable from that box's own cell" is a claim about
     the page, and #203 is the standing reminder of what happens when only the
     collector is asserted: every server-side row stayed green while the page
     said the wrong thing.

     READ-ONLY ON PURPOSE. The editor is opened, rendered and closed; nothing
     is saved. A walk that wrote an override would leave the fixture fleet
     narrowed for every suite after it, and what is being asserted is that an
     operator can GET to the editor, which a save adds nothing to. */
  eq('registry: the ops bar carries the fleet-wide control', 1,
     await page.locator('#g-reg').count());
  if (LIVE && visible.length) {
    await page.click('#g-reg');
    await settle(async () => await page.locator('#regov').isVisible().catch(() => false), 8000);
    const fleetOpen = await page.locator('#regov').isVisible().catch(() => false);
    ok('registry: the fleet-wide editor opens', fleetOpen,
       (await page.locator('#livestat').textContent()).trim());
    if (fleetOpen) {
      // Both registries, not just the work one: the fleet has two and an
      // editor that silently covered one of them would read as complete.
      eq('registry: both registries are on the fleet-wide editor', 2,
         await page.locator('#regov .regblk').count());
      eq('registry: ...the work list first', 'work',
         await page.locator('#regov .regblk').first().getAttribute('data-kind'));
      // A box scope would carry the source chip; the fleet-wide one has no
      // layer above it, so it must not claim one.
      eq('registry: the fleet-wide scope claims no inheritance', 0,
         await page.locator('#regov .regsrc').count());
      // The fleet-wide scope IS the universe, so it is the one that gets a
      // free field: there is nothing above it to bound what an operator may
      // type, and adding a board is typing its name.
      eq('registry: the fleet-wide scope is a free list', 2,
         await page.locator('#regov .regta').count());
      await shot('06-registries-fleet');
      await page.keyboard.press('Escape');
      await settle(async () => !(await page.locator('#regov').isVisible().catch(() => false)), 4000);
      ok('registry: Esc closes the editor',
         !(await page.locator('#regov').isVisible().catch(() => false)));
    }
    // ...and the per-box half, from that box's own console.
    const r0 = await enterAt(visible[0]);
    ok('registry: console re-opened for the per-box editor', r0 === visible[0].got,
       `expected ${visible[0].got}, got ${r0}`);
    if (r0 === visible[0].got) {
      // The always-visible summary first: an override must be legible without
      // opening anything, or a box quietly pinned to a stale registry is
      // invisible until somebody goes looking for it.
      const vit = await page.locator('.rail-l #w-vitals').textContent();
      ok('registry: the box vitals name what it watches', /Registry/.test(vit),
         vit.replace(/\s+/g, ' ').slice(-90));
      await page.click('#ac-reg');
      await settle(async () => await page.locator('#regov').isVisible().catch(() => false), 8000);
      const boxOpen = await page.locator('#regov').isVisible().catch(() => false);
      ok('registry: the per-box editor opens from the box console', boxOpen,
         (await page.locator('#livestat').textContent()).trim());
      if (boxOpen) {
        // SCOPED TO THE OPEN BOX. One editor serves both scopes, so the thing
        // that can go wrong is it opening on the wrong one — the same identity
        // check `pause` gets above, for the same reason.
        eq('registry: ...scoped to the box on screen', visible[0].expect,
           await page.locator('#regov').getAttribute('data-box'));
        eq('registry: ...saying whether the box inherits or overrides', 2,
           await page.locator('#regov .regsrc').count());
        eq('registry: ...and offering the inherit action', 2,
           await page.locator('#regov [data-reg="inherit"]').count());
        /* THE PER-BOX SCOPE IS A SELECTION, NOT A FREE LIST (operator,
           2026-08-29). A box can never name a repository the fleet-wide
           registry does not, so the legal values are finite and already on
           screen; a textarea here would exist only for the collector to refuse
           what the page had invited. Asserted on the page because that is
           where the invitation is — the collector's refusal is already
           covered, and a build with both would still be one an operator could
           type into. */
        eq('registry: ...as switches over the fleet-wide list, not a free field', 0,
           await page.locator('#regov .regta').count());
        const wsel = '#regov .regblk[data-kind="work"] ';
        ok('registry: ...one switch per repository the fleet watches',
           (await page.locator(`${wsel}.regopt`).count()) >= 1,
           `switches: ${await page.locator(`${wsel}.regopt`).count()}`);
        // An inheriting box shows every switch ON. Inheriting IS selecting all
        // of them, and a cell that drew them off would read as a narrowed box
        // and invite an operator to "fix" one that is not.
        const wsrc = (await page.locator(`${wsel}.regsrc`).textContent()).trim();
        if (wsrc === 'inherited') {
          eq('registry: ...every one of them on for an inheriting box',
             await page.locator(`${wsel}.regopt input`).count(),
             await page.locator(`${wsel}.regopt input:checked`).count());
        }
        await shot('07-registries-box');
        await page.keyboard.press('Escape');
        await settle(async () => !(await page.locator('#regov').isVisible().catch(() => false)), 4000);
      }
    }
    await leave();
  }

  /* ---- #486: the words and the path are one decision -----------------------
     THE CROSS-LAYER CASE, and it is only meaningful at a NON-DEFAULT
     threshold: run.sh starts this collector at CREW_FLOOR_PING_FAILS=2, the
     page used to carry a 3 of its own, and in that gap the floor force-stopped
     a guest whose restart confirmation still promised a graceful stop. So this
     asserts the page's shipped sentence over the payload the collector
     actually served, not over a fixture written here.

     Both directions, because only the pair rules out a page-side threshold:
     the box the collector calls wedged must get the force wording, and a box
     it calls reachable must NOT — even with a miss count above any constant
     the page could plausibly have kept. */
  if (LIVE && FIXTURE) {
    let say = null;
    for (let i = 0; i < 20; i++) {
      say = await page.evaluate(async () => {
        const r = await fetch(location.origin + '/api/fleet');
        const u = (await r.json()).units.find((x) => x.box === 'ff-wedged');
        const served = u && u.ping ? u.ping : null;
        return {
          wedged: served ? served.wedged : null,
          fails: served ? served.fails : null,
          plan: window.FLOORDEV.restartPlan('ff-wedged', { ping: served }),
          /* Served as NOT wedged, with nine misses on the counter. Any
             threshold the page kept for itself would call this unreachable. */
          gentle: window.FLOORDEV.restartPlan('ff-other', {
            ping: { ok: false, fails: 9, stale: false, wedged: false },
          }),
        };
      });
      if (say.wedged === true) break;
      await page.waitForTimeout(1500);
    }
    ok("force: the collector's wedge verdict reaches the page",
       say && say.wedged === true, JSON.stringify(say));
    ok('force: the restart confirm names the force path from that verdict',
       !!say && /FORCE-STOPPED/.test(say.plan.ask), say && say.plan.ask);
    ok('force: a box the collector calls reachable is never told it will be killed',
       !!say && !/FORCE/.test(say.gentle.ask) && /stopped and started again/.test(say.gentle.ask),
       say && say.gentle.ask);

    /* ROUND 2 — the sentence is a promise about the path, and the mode is what
       makes it keepable. The page reads a snapshot up to POLL_MS old while the
       collector re-reads the ping map when the POST lands, so the words alone
       guarantee nothing: what has to hold is that the mode the page puts ON
       THE WIRE is the one those exact words promised. Asserted as a pair from
       one call, because they come from one evaluation — a `restartPlan` that
       returned the force sentence beside a graceful mode is precisely the bug,
       and it would be invisible to either half checked alone. */
    ok('mode: the wedged box authorises the force path it was shown',
       !!say && say.plan.mode === 'force' && /FORCE-STOPPED/.test(say.plan.ask),
       say && JSON.stringify(say.plan));
    ok('mode: the reachable box authorises only the gentle path',
       !!say && say.gentle.mode === 'graceful' && !/FORCE/.test(say.gentle.ask),
       say && JSON.stringify(say.gentle));

    /* ...and that the mode actually reaches the collector. The two above are
       about the page's own answer; this is about the request, which is the
       thing the collector adjudicates. Driven through the SHIPPED click
       handler, because "the page decides well and then posts something else"
       is a shape the hook alone cannot rule out — and the console has to be
       open for that handler to have a box.

       The POST is intercepted, not fired: the walk must not restart a fixture
       box the cases after this one read. */
    const first = visible.length ? visible[0] : null;
    const opened = first ? await enterAt(first) : null;
    ok('mode: console re-opened to drive the shipped restart click',
       !!first && opened === first.got,
       `expected ${first ? first.got : '(no visible unit)'}, got ${opened}`);
    const wire = !first || opened !== first.got ? null : await page.evaluate(async () => {
      const real = window.fetch;
      let sent = null;
      window.fetch = function (u, o) {
        if (String(u).indexOf('/api/command') >= 0) {
          sent = JSON.parse(o.body);
          return Promise.resolve(new Response('{"ok":true,"results":[]}',
            { status: 200, headers: { 'Content-Type': 'application/json' } }));
        }
        return real.apply(this, arguments);
      };
      const conf = window.confirm;
      window.confirm = () => true;
      try {
        document.getElementById('a-restart').click();
        await new Promise((r) => setTimeout(r, 200));
      } finally { window.fetch = real; window.confirm = conf; }
      return sent;
    });
    ok('mode: the shipped click puts a restart mode on the wire',
       !!wire && wire.action === 'restart'
         && (wire.mode === 'force' || wire.mode === 'graceful'),
       JSON.stringify(wire));

    /* A refusal has to arrive as words. 409 carries the operator's next step in
       its body and nothing else does — no per-box rows exist, because nothing
       ran — so a page that threw on the status code would replace the one
       sentence that says which way the box moved with "HTTP 409". */
    const refused = wire === null ? '' : await page.evaluate(async () => {
      const real = window.fetch;
      window.fetch = function (u) {
        if (String(u).indexOf('/api/command') >= 0) {
          return Promise.resolve(new Response(JSON.stringify({
            ok: false, refused: true, confirmed: 'graceful', verdict: 'force',
            error: 'ff-wedged has stopped answering since that dialog. '
                 + 'Nothing was done — confirm again.',
          }), { status: 409, headers: { 'Content-Type': 'application/json' } }));
        }
        return real.apply(this, arguments);
      };
      const conf = window.confirm;
      window.confirm = () => true;
      try {
        document.getElementById('a-restart').click();
        await new Promise((r) => setTimeout(r, 300));
      } finally { window.fetch = real; window.confirm = conf; }
      const s = document.getElementById('livestat');
      return s ? s.textContent : '';
    });
    ok('mode: a refused restart reaches the operator as words, not a status code',
       /refused/.test(refused) && /confirm again/.test(refused), refused);
    ok('mode: ...and is not reported as a failure, because nothing ran',
       !/FAILED/.test(refused) && !/HTTP 409/.test(refused), refused);
    if (wire !== null) await leave();

    /* The disclosure AFTER the click. A restart that escalated and one that
       did not both end `restart ok`, so the status line was the one place the
       operator could not tell what had happened to their box. Driven over
       replies named here rather than by firing a restart: the reply's `step`
       is the collector's record, floor/actions.sh already proves the collector
       writes it, and this asserts the page says it. */
    const said = await page.evaluate(() => ({
      forced: window.FLOORDEV.cmdSay('restart', [
        { box: 'ff-wedged', ok: true, step: 'force-stop' },
        { box: 'ff-wedged', ok: true, step: 'start' }]),
      graceful: window.FLOORDEV.cmdSay('restart', [
        { box: 'ff-idle', ok: true, step: 'down' },
        { box: 'ff-idle', ok: true, step: 'start' }]),
      own: window.FLOORDEV.cmdSay('force-stop', [
        { box: 'ff-wedged', ok: true, step: 'force-stop' }]),
      /* N6 — the failure path. The guest WAS killed and then would not come
         back: the row that failed is `start`, the row that says so is the
         force-stop beside it, and this sentence used to carry neither. */
      failedAfterForce: window.FLOORDEV.cmdSayFail('restart', [
        { box: 'ff-wedged', ok: true, step: 'force-stop' },
        { box: 'ff-wedged', ok: false, step: 'start' }], 'ff-wedged: boom'),
      /* ...and the gentle failure must not grow the claim. */
      failedGently: window.FLOORDEV.cmdSayFail('restart', [
        { box: 'ff-idle', ok: true, step: 'down' },
        { box: 'ff-idle', ok: false, step: 'start' }], 'ff-idle: boom'),
      /* A force stop that FAILED killed nothing, and the error already names
         it. Claiming the kill here would be the disclosure lying the other
         way — worse than silence, because an operator would write the session
         off. */
      failedToForce: window.FLOORDEV.cmdSayFail('restart', [
        { box: 'ff-wedged', ok: false, step: 'force-stop' }], 'ff-wedged: boom'),
    }));
    ok('force: a restart that escalated says so afterwards',
       /force-stopped ff-wedged/.test(said.forced), said.forced);
    ok('force: a graceful restart claims nothing of the kind',
       said.graceful === 'restart ok', said.graceful);
    ok('force: the force-stop verb does not narrate itself twice',
       said.own === 'force-stop ok', said.own);
    ok('force: a restart that killed the guest and then FAILED still says so',
       /force-stopped ff-wedged/.test(said.failedAfterForce)
         && /ff-wedged: boom/.test(said.failedAfterForce), said.failedAfterForce);
    ok('force: a gentle failure claims no kill',
       said.failedGently === 'restart FAILED — ff-idle: boom', said.failedGently);
    ok('force: a force stop that itself failed is not reported as a kill',
       !/force-stopped/.test(said.failedToForce), said.failedToForce);
  } else if (LIVE) {
    skip('#486 force/mode fixture assertions',
         'real fleet has no guaranteed ff-wedged box');
  }

  /* Checked HERE, before the fleet-wide action below: that action deliberately
     targets an unreachable box, and the 500 it earns is a correct answer the
     browser always logs. Asserting cleanliness afterwards would mean either a
     permanently red test or a filter loose enough to hide a real error. */
  ok('no console errors', consoleErrors.length === 0, consoleErrors.slice(0, 2).join(' | '));
  const beforeFleet = consoleErrors.length;

  // ---- fleet-wide ---------------------------------------------------------
  if (LIVE && !READONLY) {
    await page.click('#g-wake');
    /* Poll until the status is TERMINAL. Reading it a fixed 2.5s after the
       click asserted the optimistic "wake-silent…" in-flight message, while
       the action itself takes >=8s against the wedged fixture — three
       assertions that could not fail. */
    let msg = '';
    for (let i = 0; i < 30; i++) {
      await page.waitForTimeout(1000);
      msg = (await page.locator('#livestat').textContent()).trim();
      if (/ok$|FAILED|failed/.test(msg)) break;
    }
    ok('fleet: wake-silent reaches a terminal status', /ok$|FAILED|failed/.test(msg), msg);
    ok('fleet: wake-silent reports a result', /wake-silent/.test(msg), msg);
    // The partial failure must reach the operator as a named box, not a code.
    ok('fleet: a partial failure names the box', !/HTTP \d+$/.test(msg), msg);
    const added = consoleErrors.slice(beforeFleet);
    ok('fleet: only the expected 500 was logged',
       added.every((e) => /500/.test(e)), added.join(' | '));
  }

  await browser.close();
  console.log(`  -- browser: ${pass} ok, ${skipped} skipped, ${fails.length} failed`);
  process.exit(fails.length ? 1 : 0);
})().catch((e) => { console.error('HARNESS ERROR:', e.stack || e.message); process.exit(2); });
