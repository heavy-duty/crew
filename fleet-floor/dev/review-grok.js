/* review-grok.js — screenshot the whiteboard for grok review loops.
 *
 *   node dev/review-grok.js [out-dir] [label]
 *
 * Opens whiteboard.html?agents=grok at large tile width, waits for
 * body[data-wb-done], screenshots the full page plus each tile.
 */
const { chromium } = require('playwright-core');
const fs = require('fs');
const path = require('path');

const CHROME = process.env.PW_CHROME
  || process.env.HOME + '/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome';

const OUT = process.argv[2] || path.join(__dirname, 'shots/grok-structure/review');
const LABEL = process.argv[3] || 'review';
const FILE = 'file://' + path.resolve(__dirname, 'whiteboard.html')
  + '?agents=grok&view=room&w=960&t=8&rooms=builder,reviewer,triage&states=working,idle,offline';

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch({
    executablePath: CHROME,
    args: ['--allow-file-access-from-files', '--disable-web-security'],
  });
  const page = await browser.newPage({ viewport: { width: 1400, height: 2400 } });
  await page.goto(FILE, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForFunction(() => document.body.dataset.wbDone === '1', { timeout: 60000 });
  await page.waitForTimeout(400);

  const full = path.join(OUT, LABEL + '-full.png');
  await page.screenshot({ path: full, fullPage: true });
  console.log('wrote', full);

  const tiles = await page.$$('.wb-tile');
  for (let i = 0; i < tiles.length; i++) {
    const name = await tiles[i].evaluate((el) => {
      const lab = el.querySelector('.wb-cap');
      return (lab && lab.textContent || ('tile-' + Math.random())).trim().replace(/\s+/g, '-').toLowerCase();
    });
    const p = path.join(OUT, LABEL + '-' + name + '.png');
    await tiles[i].screenshot({ path: p });
    console.log('wrote', p);
  }

  // Tight robot crop from builder·working
  const cropPath = path.join(OUT, LABEL + '-robot.png');
  const box = await page.evaluate(() => {
    const tiles = [...document.querySelectorAll('.wb-tile')];
    const t = tiles.find(el => {
      const c = (el.querySelector('.wb-cap') || {}).textContent || '';
      return /builder/.test(c) && /working/.test(c);
    }) || tiles[0];
    if (!t) return null;
    const r = t.getBoundingClientRect();
    return { x: r.x + window.scrollX, y: r.y + window.scrollY, w: r.width, h: r.height };
  });
  if (box) {
    await page.screenshot({
      path: cropPath,
      clip: {
        x: Math.max(0, box.x + box.w * 0.22),
        y: Math.max(0, box.y + box.h * 0.08),
        width: Math.min(box.w * 0.48, 480),
        height: Math.min(box.h * 0.78, 700),
      },
    });
    console.log('wrote', cropPath);
  }

  await browser.close();
  console.log('done', LABEL, '(' + tiles.length + ' tiles)');
})().catch(e => { console.error(e); process.exit(1); });
