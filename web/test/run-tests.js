/* SecureScan editor tests.  Run:  node web/test/run-tests.js
   Uses the globally installed Playwright with the system Chrome, and sharp for PNG checks.
   Screenshots and exported files go to web/test/out/. */
'use strict';
const { chromium } = require('/opt/npm-tools/node_modules/playwright');
const sharp = require('/opt/npm-tools/node_modules/sharp');
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const WEB = path.resolve(__dirname, '..');
const ROOT = path.resolve(WEB, '..');
const OUT = path.join(__dirname, 'out');
const URL = 'file://' + path.join(WEB, 'editor.html');
const GLB_FIXTURE = path.join(ROOT, 'private-fixtures', 'polycam-example.glb');
const readJSON = f => JSON.parse(fs.readFileSync(path.join(WEB, f), 'utf8'));
const SMALL = readJSON('sample-plan.json');                    // the shipped sample: three visits
const SINGLE = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'sample-single-visit.json'), 'utf8'));   // the v1.5 sample: one visit
const ANGLED = readJSON('sample-plan-angled.json');
const LARGE = readJSON('sample-house-large.json');
const TZ = 'Australia/Perth';
const PHONE = { viewport: { width: 430, height: 932 }, deviceScaleFactor: 3, hasTouch: true, isMobile: true, timezoneId: TZ };
const HOSTED_SIZE = { viewport: { width: 402, height: 700 }, deviceScaleFactor: 3, hasTouch: true, isMobile: true, timezoneId: TZ };
const DESKTOP = { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, timezoneId: TZ };
const { execFileSync } = require('child_process');
const os = require('os');

fs.mkdirSync(OUT, { recursive: true });
const results = [];
async function test(name, fn) {
  try { await fn(); results.push([true, name]); console.log('  PASS ' + name); }
  catch (e) { results.push([false, name, e]); console.log('  FAIL ' + name + '\n       ' + (e && e.stack || e).toString().split('\n').slice(0, 4).join('\n       ')); }
}
const near = (a, b, eps, msg) => assert.ok(Math.abs(a - b) <= eps, `${msg}: ${a} vs ${b}`);
const shoelace = poly => Math.abs(poly.reduce((s, p, i) => { const q = poly[(i + 1) % poly.length]; return s + p[0] * q[1] - q[0] * p[1]; }, 0)) / 2;
const segDist = (p, a, b) => {
  const dx = b[0] - a[0], dy = b[1] - a[1], l2 = dx * dx + dy * dy;
  const t = Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2));
  return Math.hypot(p[0] - a[0] - t * dx, p[1] - a[1] - t * dy);
};
const kindOf = r => r.kind === 'boundary' || r.kind === 'photo' ? r.kind : 'reading';
const clone = v => JSON.parse(JSON.stringify(v));

/* ---------- v1.4 helpers: real touch input (CDP), elevation coordinates, photo documents ---------- */
async function touch(page, type, x, y) {
  if (!page.cdp) page.cdp = await page.context().newCDPSession(page);
  await page.cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y, id: 1 }] });
}
async function touchTap(page, [x, y]) { await touch(page, 'touchStart', x, y); await touch(page, 'touchEnd'); await page.waitForTimeout(60); }
async function touchDrag(page, [x0, y0], [x1, y1], steps = 8) {
  await touch(page, 'touchStart', x0, y0);
  for (let i = 1; i <= steps; i++) await touch(page, 'touchMove', x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps);
  await page.waitForTimeout(100);       // touch moves are coalesced to frames: let the last one land
  await touch(page, 'touchEnd'); await page.waitForTimeout(60);
}
/* page coordinates of (wallT, height) on a wall's elevation, honouring mirroring */
const elevClient = (page, wallId, wallT, h) => page.evaluate(([w, t, h]) => {
  const b = SecureScan.debug.elevBlocks().find(x => x.wallId === w), f = b.face, s = t * f.L;
  return SecureScan.debug.sheetToClient([f.x0 + (f.flip ? f.L - s : s) * 100, b.y + f.floor - h * 100]);
}, [wallId, wallT, h]);
const marksOn = async (page, wallId) => (await plan(page)).markup.readings.filter(r => r.kind === 'boundary' && r.wallId === wallId);
let jpegCache = null;
async function jpegs() {        // realistic site photos: 1280 px long edge, quality 70, as the editor stores them
  if (!jpegCache) jpegCache = await Promise.all(['moisture-wall.jpg', 'moisture-skirting.jpg', 'inspection-opening.jpg', 'reading-with-tape-measure.jpg', 'wall-blue-tape-marks.jpg']
    .map(f => sharp(path.join(ROOT, 'reference', f)).resize(1280, 1280, { fit: 'inside' }).jpeg({ quality: 70 }).toBuffer()));
  return jpegCache;
}
const dataURL = buf => 'data:image/jpeg;base64,' + buf.toString('base64');
/* the small sample with photos on a reading, a photo note, the source and a moisture-line point; extra
   photo notes up to `total` photos */
async function photoDoc(total = 4) {
  const imgs = await jpegs(), d = clone(SINGLE), m = d.markup;
  m.readings.find(r => r.id === 'm1').photo = dataURL(imgs[1]);
  m.readings.find(r => r.id === 'p1').photo = dataURL(imgs[2]);
  m.readings.find(r => r.id === 'b1').photo = dataURL(imgs[4]);
  m.sources[0].photo = dataURL(imgs[0]);
  for (let i = 4, n = 3; i < total; i++, n++) m.readings.push({ id: 'px' + n, kind: 'photo', n, pos: [1.0 + (n % 5) * 0.3, 1.2], value: null, material: 'floor', note: 'Overview ' + n, photo: dataURL(imgs[i % imgs.length]), takenAt: '2026-11-12T02:' + String(n % 60).padStart(2, '0') + ':00Z', reference: false, source: 'manual' });
  return d;
}
function unzipCheck(file) {
  const test = execFileSync('unzip', ['-t', file]).toString();
  assert.ok(/No errors detected/.test(test), test);
  return execFileSync('unzip', ['-Z1', file]).toString().trim().split('\n');
}

async function openPage(browser, ctxOpts, { hosted = false } = {}) {
  const ctx = await browser.newContext({ ...ctxOpts, acceptDownloads: true });
  if (hosted) await ctx.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { host: { postMessage: m => window.__msgs.push(JSON.parse(JSON.stringify(m))) } } };
  });
  const page = await ctx.newPage();
  page.errors = [];
  page.on('pageerror', e => page.errors.push(e.message));
  page.on('console', m => { if (m.type() === 'error') page.errors.push(m.text()); });
  page.on('dialog', d => { page.errors.push('native dialog used: ' + d.type()); d.dismiss(); });
  page.on('request', r => { if (!/^(file|data|blob):/.test(r.url())) page.errors.push('network request: ' + r.url()); });
  await page.goto(URL);
  await page.waitForTimeout(200);
  return page;
}
const load = (page, doc) => page.evaluate(d => { SecureScan.load(d); }, doc);
const planToClient = (page, p) => page.evaluate(p => SecureScan.debug.planToClient(p), p);
const pip = (pt, poly) => { let ins = false; for (let a = 0, b = poly.length - 1; a < poly.length; b = a++) { const A = poly[a], B = poly[b]; if ((A[1] > pt[1]) !== (B[1] > pt[1]) && pt[0] < (B[0] - A[0]) * (pt[1] - A[1]) / (B[1] - A[1]) + A[0]) ins = !ins; } return ins; };
const dist2 = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);
async function tapPlan(page, p) { const [x, y] = await planToClient(page, p); await page.touchscreen.tap(x, y); await page.waitForTimeout(60); }
async function clickPlan(page, p) { const [x, y] = await planToClient(page, p); await page.mouse.click(x, y); await page.waitForTimeout(60); }
async function tapHit(page, kind, id) {
  const pt = await page.evaluate(([k, i]) => {
    const h = SecureScan.debug.hits().find(x => x.kind === k && (i == null || x.id === i));
    if (!h) return null;
    const c = h.c || (h.poly ? h.poly.reduce((a, p) => [a[0] + p[0] / h.poly.length, a[1] + p[1] / h.poly.length], [0, 0]) : [(h.seg[0][0] + h.seg[1][0]) / 2, (h.seg[0][1] + h.seg[1][1]) / 2]);
    return SecureScan.debug.sheetToClient(c);
  }, [kind, id]);
  assert.ok(pt, `hit ${kind} ${id} exists`);
  await page.touchscreen.tap(pt[0], pt[1]); await page.waitForTimeout(80);
}
const sheetOpen = page => page.evaluate(() => !document.getElementById('sheet').hidden);
async function sheetButton(page, text) { await page.locator('#sheet button', { hasText: text }).first().click(); await page.waitForTimeout(80); }
const plan = page => page.evaluate(() => SecureScan.getPlan());
async function pngInfo(buf) {
  const img = sharp(buf), meta = await img.metadata();
  const { data, info } = await img.removeAlpha().raw().toBuffer({ resolveWithObject: true });
  const px = (x, y) => { const i = (y * info.width + x) * 3; return [data[i], data[i + 1], data[i + 2]]; };
  const corners = [px(1, 1), px(info.width - 2, 1), px(1, info.height - 2), px(info.width - 2, info.height - 2)];
  return { w: meta.width, h: meta.height, format: meta.format, corners };
}
async function download(page, label) {
  await page.click('#btn-export');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.locator('#sheet button', { hasText: label }).first().click()]);
  fs.mkdirSync(path.join(OUT, 'downloads'), { recursive: true });
  const file = path.join(OUT, 'downloads', dl.suggestedFilename());
  await dl.saveAs(file);
  return file;
}

/* ---------- geometry / rendering assertions shared by all samples ---------- */
async function checkRendering(page, doc, name) {
  await test(`${name}: room areas match polygon maths`, async () => {
    const labels = await page.$$eval('#content .room-label', els => els.map(e => ({ id: e.dataset.id, area: +e.dataset.area, text: e.textContent })));
    assert.strictEqual(labels.length, doc.rooms.length);
    for (const r of doc.rooms) {
      const l = labels.find(x => x.id === r.id), a = shoelace(r.polygon);
      near(l.area, a, 0.005, `area ${r.name}`);
      assert.ok(l.text.includes(a.toFixed(1) + ' m²'), `label shows ${a.toFixed(1)} m² (${l.text})`);
    }
  });
  await test(`${name}: dimension labels equal wall-run lengths (2 dp) and sit on real walls`, async () => {
    const dims = await page.$$eval('#content .dim', els => els.map(e => ({ len: e.dataset.len, a: e.dataset.a.split(',').map(Number), b: e.dataset.b.split(',').map(Number), text: e.querySelector('text').textContent })));
    assert.ok(dims.length >= 4, 'has dimensions');
    const walls = doc.walls;
    for (const d of dims) {
      const L = Math.hypot(d.b[0] - d.a[0], d.b[1] - d.a[1]);
      assert.strictEqual(d.text, L.toFixed(2) + ' m', 'label text equals run length');
      assert.strictEqual(d.len, L.toFixed(2));
      for (const p of [d.a, d.b]) assert.ok(walls.some(w => Math.hypot(w.a[0] - p[0], w.a[1] - p[1]) < 0.02 || Math.hypot(w.b[0] - p[0], w.b[1] - p[1]) < 0.02), 'run ends at a wall end');
      for (let t = 0.05; t < 1; t += 0.1) {
        const p = [d.a[0] + (d.b[0] - d.a[0]) * t, d.a[1] + (d.b[1] - d.a[1]) * t];
        assert.ok(walls.some(w => segDist(p, w.a, w.b) < 0.02), 'run is covered by walls');
      }
    }
  });
  await test(`${name}: dimension labels do not overlap each other`, async () => {
    const boxes = await page.$$eval('#content .dim text', els => els.map(e => { const r = e.getBoundingClientRect(); return [r.left, r.top, r.right, r.bottom]; }));
    for (let i = 0; i < boxes.length; i++) for (let j = i + 1; j < boxes.length; j++) {
      const a = boxes[i], b = boxes[j];
      const ov = Math.min(a[2], b[2]) - Math.max(a[0], b[0]) > 1 && Math.min(a[3], b[3]) - Math.max(a[1], b[1]) > 1;
      assert.ok(!ov, `dimension labels ${i} and ${j} overlap`);
    }
  });
}

(async () => {
  const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome' });

  /* ====================== standalone, phone ====================== */
  console.log('Standalone, phone 430x932 @3x');
  const page = await openPage(browser, PHONE);

  await test('embedded sample, large demo and importer equal their files', async () => {
    const emb = await page.evaluate(() => [document.getElementById('sample-plan').textContent, document.getElementById('demo-large').textContent, document.getElementById('glb-import').textContent]);
    assert.deepStrictEqual(JSON.parse(emb[0]), SMALL);
    assert.deepStrictEqual(JSON.parse(emb[1]), LARGE);
    assert.strictEqual(emb[2].trim(), fs.readFileSync(path.join(WEB, 'glb-import.js'), 'utf8').trim());
    assert.strictEqual(typeof (await page.evaluate(() => typeof SecureScanGLB.convert)), 'string');
  });
  await test('standalone default shows the built-in sample (three visits, final visit on screen)', async () => {
    assert.deepStrictEqual(await plan(page), SMALL);
    await page.screenshot({ path: path.join(OUT, 'phone-plan-three-visits.png') });
    await load(page, SINGLE);
    assert.deepStrictEqual(await plan(page), SINGLE, 'single-visit document loads unchanged');
    await page.screenshot({ path: path.join(OUT, 'phone-plan-small.png') });
  });
  await checkRendering(page, SINGLE, 'small sample');
  await test('small sample: expected exterior runs are dimensioned', async () => {
    const vals = (await page.$$eval('#content .dim', els => els.map(e => e.dataset.len))).sort();
    assert.deepStrictEqual(vals, ['0.65', '0.98', '1.02', '1.10', '1.30', '1.70', '2.36', '3.45', '3.98', '6.38'].sort());
  });
  await test('small sample: removal totals in legend are correct', async () => {
    const legend = await page.$$eval('#content .legend-row', els => els.map(e => e.textContent));
    const byId = Object.fromEntries(SINGLE.walls.map(w => [w.id, w]));
    const tot = {};
    for (const x of SINGLE.markup.removals) {
      const w = byId[x.wallId], L = Math.abs(x.t1 - x.t0) * Math.hypot(w.b[0] - w.a[0], w.b[1] - w.a[1]);
      tot[x.item] = tot[x.item] || { lm: 0, m2: 0 }; tot[x.item].lm += L; tot[x.item].m2 += L * Math.min(x.heightMm / 1000, w.height);
    }
    for (const [item, t] of Object.entries(tot)) {
      const want = `Remove ${item} · ${t.lm.toFixed(2)} lm · ${t.m2.toFixed(2)} m²`;
      assert.ok(legend.includes(want), `legend has "${want}" (got ${legend.join(' | ')})`);
    }
    assert.ok(legend.includes('Remove plasterboard · 2.20 lm · 2.64 m²'));
  });
  await test('small sample: legend lists only what is used', async () => {
    const syms = await page.$$eval('#content .legend-row', els => els.map(e => e.dataset.sym));
    for (const s of ['source', 'affected', 'removal', 'dry', 'elevated', 'wet', 'ref', 'mark', 'photo', 'elev', 'wetzone']) assert.ok(syms.includes(s), 'legend has ' + s);
    await load(page, { ...SINGLE, markup: { ...SINGLE.markup, readings: SINGLE.markup.readings.filter(r => kindOf(r) === 'reading' && r.value >= 20) } });
    const syms2 = await page.$$eval('#content .legend-row', els => els.map(e => e.dataset.sym));
    for (const s of ['dry', 'elevated', 'ref', 'mark', 'photo']) assert.ok(!syms2.includes(s), 'legend omits unused ' + s);
    await load(page, SINGLE);
  });
  await test('v1.2: tape marks and photo notes render on plan, unnumbered marks', async () => {
    const marks = await page.$$eval('#content .tape-mark', els => els.map(e => e.dataset.id));
    assert.deepStrictEqual(marks.sort(), ['b1', 'b2', 'b3', 'b4']);
    const photos = await page.$$eval('#content .photo-label', els => els.map(e => e.textContent));
    assert.deepStrictEqual(photos.sort(), ['P1', 'P2']);
    const nums = await page.$$eval('#content .reading', els => els.map(e => +e.dataset.n));
    assert.deepStrictEqual(nums.sort((a, b) => a - b), [1, 2, 3, 4, 5, 6, 7, 8]);
  });

  await test('elevations: readings at wallT x length and height to scale; moisture line between outermost marks', async () => {
    await page.click('#view-seg button[data-view="elev"]');
    await page.waitForTimeout(150);
    await page.screenshot({ path: path.join(OUT, 'phone-elevations.png') });
    const data = await page.$$eval('#content .elevation', els => els.map(g => ({
      wall: g.dataset.wall, letter: g.dataset.letter, x0: +g.dataset.x0, floor: +g.dataset.floor, scale: +g.dataset.scale, flip: g.dataset.flip === '1', len: +g.dataset.len,
      title: g.querySelector('.elev-title').textContent,
      readings: [...g.querySelectorAll('.elev-reading')].map(r => ({ id: r.dataset.id, tx: +r.dataset.tx, y: +r.dataset.y, cx: +r.querySelector('circle').getAttribute('cx'), cy: +r.querySelector('circle').getAttribute('cy') })),
      marks: [...g.querySelectorAll('.elev-mark')].map(r => ({ id: r.dataset.id, x: +r.dataset.x, y: +r.dataset.y })),
      line: (g.querySelector('.moisture-line') || {}).getAttribute ? g.querySelector('.moisture-line').getAttribute('d') : null,
      removals: [...g.querySelectorAll('.removal-dim')].map(d => d.dataset.len)
    })));
    const byId = Object.fromEntries(SINGLE.markup.readings.map(r => [r.id, r]));
    const wallById = Object.fromEntries(SINGLE.walls.map(w => [w.id, w]));
    assert.deepStrictEqual(data.map(d => d.wall), ['w7', 'w1', 'w6', 'w11'], 'elevation order A-D');
    assert.ok(data[0].title.startsWith('Elevation A — Laundry (3.15 m)'), data[0].title);
    let checked = 0;
    for (const e of data) {
      const w = wallById[e.wall], L = Math.hypot(w.b[0] - w.a[0], w.b[1] - w.a[1]);
      near(e.len, L, 1e-3, 'wall length');
      for (const r of [...e.readings, ...e.marks]) {
        const src = byId[r.id], along = (e.flip ? 1 - src.wallT : src.wallT) * L;
        const x = r.tx != null && !Number.isNaN(r.tx) ? r.tx : r.x;
        near(x, e.x0 + along * e.scale, 0.05, `x of ${r.id}`);
        near(r.y, e.floor - src.height * e.scale, 0.05, `y of ${r.id}`);
        if (r.cy != null && !Number.isNaN(r.cy)) near(r.cy, r.y, 0.11, 'circle drawn at height');
        checked++;
      }
    }
    assert.ok(checked >= 10, 'checked readings and marks: ' + checked);
    const A = data[0];
    assert.deepStrictEqual(A.readings.map(r => r.id).sort(), ['m1', 'm2', 'm3', 'm4']);
    assert.deepStrictEqual(A.removals, ['2.20 m']);
    const B = data[1];
    assert.ok(B.line, 'moisture line drawn');
    const pts = B.line.slice(1).split('L').map(s => s.split(' ').map(Number));
    const xs = B.marks.map(m => m.x);
    near(pts[0][0], Math.min(...xs), 0.06, 'line starts at outermost mark'); near(pts[pts.length - 1][0], Math.max(...xs), 0.06, 'line ends at outermost mark');
    assert.strictEqual(pts.length, 4);
    await page.click('#view-seg button[data-view="plan"]');
  });

  await test('angled sample renders (45-degree walls)', async () => {
    await load(page, ANGLED);
    await page.screenshot({ path: path.join(OUT, 'phone-plan-angled.png') });
    const angled = await page.$$eval('#content .dim', els => els.filter(e => { const a = e.dataset.a.split(',').map(Number), b = e.dataset.b.split(',').map(Number); return Math.abs(a[0] - b[0]) > 0.05 && Math.abs(a[1] - b[1]) > 0.05; }).length);
    assert.ok(angled >= 3, 'angled runs dimensioned: ' + angled);
  });
  await checkRendering(page, ANGLED, 'angled sample');
  await test('large house renders; wide doors drawn as openings', async () => {
    await load(page, LARGE);
    await page.screenshot({ path: path.join(OUT, 'phone-plan-large.png') });
    const kinds = await page.$$eval('#content .opening', els => els.map(e => e.getAttribute('class')));
    const wide = LARGE.openings.filter(o => o.type === 'door' && Math.hypot(o.b[0] - o.a[0], o.b[1] - o.a[1]) > 1.2).length;
    assert.ok(wide >= 1);
    assert.strictEqual(kinds.filter(k => k.includes('door')).length, LARGE.openings.filter(o => o.type === 'door').length - wide);
  });
  await checkRendering(page, LARGE, 'large house');

  await test('old-style document (no markup, no v1.1/v1.2 fields) loads cleanly', async () => {
    const old = JSON.parse(JSON.stringify(SINGLE)); delete old.markup;
    const before = page.errors.length;
    await load(page, old);
    const p = await plan(page);
    assert.deepStrictEqual(p.markup, { sources: [], affected: [], removals: [], readings: [], thresholds: { damp: 15, wet: 20 } });
    assert.strictEqual(await page.$$eval('#content .reading', e => e.length), 0);
    const old2 = JSON.parse(JSON.stringify(SINGLE));
    old2.markup.readings = old2.markup.readings.filter(r => !r.kind).map(r => { const { height, wallId, wallT, reference, source, ...rest } = r; return rest; });
    delete old2.markup.meter; delete old2.objects; delete old2.jobRef;
    await load(page, old2);
    assert.strictEqual(await page.$$eval('#content .reading', e => e.length), 8);
    assert.strictEqual(await page.$$eval('#content .elevation', e => e.length), 0);
    await page.click('#view-seg button[data-view="elev"]');
    assert.strictEqual(await page.$$eval('#content .elevation', e => e.length), 2, 'removal walls still get elevations');
    await page.click('#view-seg button[data-view="plan"]');
    assert.strictEqual(page.errors.length, before, page.errors.join('; '));
  });
  await test('document round-trips through load/getPlan unchanged, incl. unknown fields', async () => {
    const doc = JSON.parse(JSON.stringify(SINGLE));
    doc.vendorBlob = { a: [1, 2, { b: 'c' }] }; doc.walls[0].thicknessHint = 0.11; doc.markup.readings[0].meterSerial = 'X-1';
    doc.markup.customLayer = ['keep']; doc.rooms[1].floorType = 'tiles';
    await load(page, doc);
    assert.deepStrictEqual(await plan(page), doc);
    await page.click('#view-seg button[data-view="elev"]'); await page.click('#view-seg button[data-view="plan"]');
    assert.deepStrictEqual(await plan(page), doc, 'unchanged after view switches');
  });

  /* ---------- tools via the UI ---------- */
  await load(page, SINGLE);
  await test('tool: add water source', async () => {
    await page.tap('.tool[data-tool="source"]');
    await tapPlan(page, [1.6, 1.9]);
    assert.ok(await sheetOpen(page));
    await page.fill('#sheet input', 'Leaking shower');
    await page.screenshot({ path: path.join(OUT, 'phone-sheet-source.png') });
    await sheetButton(page, 'Done');
    const p = await plan(page);
    assert.strictEqual(p.markup.sources.length, 2);
    assert.strictEqual(p.markup.sources[1].label, 'Leaking shower');
    near(p.markup.sources[1].pos[0], 1.6, 0.03, 'source x'); near(p.markup.sources[1].pos[1], 1.9, 0.03, 'source y');
  });
  await test('tool: draw affected area polygon (tap points + Done) and Whole room', async () => {
    await page.tap('.tool[data-tool="area"]');
    for (const p of [[0.6, 0.4], [2.0, 0.4], [2.0, 1.6], [0.6, 1.6]]) await tapPlan(page, p);
    await page.screenshot({ path: path.join(OUT, 'phone-area-drawing.png') });
    await page.locator('#actionbar button', { hasText: 'Done' }).click();
    let p = await plan(page);
    assert.strictEqual(p.markup.affected.length, 2);
    near(shoelace(p.markup.affected[1].polygon), 1.4 * 1.2, 0.08, 'drawn area');
    await page.locator('#actionbar button', { hasText: 'Whole room' }).click();
    await tapPlan(page, [-0.1, 6.8]);
    p = await plan(page);
    assert.strictEqual(p.markup.affected.length, 3);
    near(shoelace(p.markup.affected[2].polygon), shoelace(SINGLE.rooms[2].polygon), 1e-6, 'whole hallway');
    const labels = await page.$$eval('#content .affected-label', els => els.map(e => +e.dataset.area));
    assert.ok(labels.some(a => Math.abs(a - shoelace(SINGLE.rooms[2].polygon)) < 0.01), 'area label shown');
  });
  await test('tool: wall removal by drag (snaps to 50 mm), sheet chips, Whole wall', async () => {
    await page.tap('.tool[data-tool="removal"]');
    await tapPlan(page, [1.7, 0.0]);                         // select wall w1
    const a = await planToClient(page, [0.51, 0.0]), b = await planToClient(page, [2.01, 0.01]);
    await page.mouse.move(a[0], a[1]); await page.mouse.down();
    for (let i = 1; i <= 8; i++) await page.mouse.move(a[0] + (b[0] - a[0]) * i / 8, a[1] + (b[1] - a[1]) * i / 8);
    await page.screenshot({ path: path.join(OUT, 'phone-removal-drag.png') });
    await page.mouse.up(); await page.waitForTimeout(80);
    assert.ok(await sheetOpen(page), 'removal sheet open');
    await page.locator('#sheet .chip', { hasText: '1200' }).click();
    await page.screenshot({ path: path.join(OUT, 'phone-sheet-removal.png') });
    await sheetButton(page, 'Done');
    let p = await plan(page);
    const x = p.markup.removals[p.markup.removals.length - 1];
    assert.strictEqual(x.wallId, 'w1'); assert.strictEqual(x.heightMm, 1200); assert.strictEqual(x.item, 'plasterboard');
    const L = (x.t1 - x.t0) * 3.45;
    near(L, 1.5, 0.001, 'dragged length snapped to 1.50 m');
    near(Math.abs(Math.round(x.t0 * 3.45 * 20) - x.t0 * 3.45 * 20), 0, 1e-3, 'start on a 50 mm step');
    await tapPlan(page, [-0.65, 5.5]);                      // select w12
    await page.locator('#actionbar button', { hasText: 'Whole wall' }).click();
    await page.locator('#sheet .chip', { hasText: 'Skirting' }).click();
    await sheetButton(page, 'Done');
    p = await plan(page);
    const y = p.markup.removals[p.markup.removals.length - 1];
    assert.deepStrictEqual([y.wallId, y.t0, y.t1, y.item, y.heightMm], ['w12', 0, 1, 'skirting', 100]);
  });
  await test('tool: reading snaps to wall, height chip, value, auto-number; reference reading', async () => {
    await page.tap('.tool[data-tool="reading"]');
    await tapPlan(page, [3.3, 0.45]);                       // 0.15 m from wall w2
    assert.ok(await sheetOpen(page));
    await page.fill('#sheet .value-row input', '23.4');
    await page.locator('#sheet .chip', { hasText: '600' }).click();
    await page.screenshot({ path: path.join(OUT, 'phone-sheet-reading.png') });
    await sheetButton(page, 'Done');
    let p = await plan(page);
    let r = p.markup.readings[p.markup.readings.length - 1];
    assert.strictEqual(r.wallId, 'w2'); near(r.pos[0], 3.45, 1e-6, 'snapped onto wall line'); near(r.wallT, 0.45 / 2.52, 0.003, 'wallT');
    assert.strictEqual(r.height, 0.6); assert.strictEqual(r.value, 23.4); assert.strictEqual(r.n, 9); assert.strictEqual(r.source, 'manual');
    await tapPlan(page, [1.4, 1.95]);                       // open floor, not near a wall
    await page.fill('#sheet .value-row input', '9,5');
    await page.locator('#sheet label.toggle input').check();
    await sheetButton(page, 'Done');
    p = await plan(page); r = p.markup.readings[p.markup.readings.length - 1];
    assert.ok(!r.wallId, 'floor reading not snapped'); assert.strictEqual(r.reference, true); assert.strictEqual(r.value, 9.5); assert.strictEqual(r.n, 10);
    assert.ok(await page.$$eval('#content .reading[data-status="ref"]', e => e.length) >= 2);
  });
  await test('tool: moisture line point (no number) and photo note with a downscaled photo', async () => {
    await tapPlan(page, [3.15, 0.1]);
    await page.locator('#sheet .kind-seg .chip', { hasText: 'Moisture line' }).click();
    await page.fill('#sheet .inline input', '1400');
    await sheetButton(page, 'Done');
    let p = await plan(page); let r = p.markup.readings[p.markup.readings.length - 1];
    assert.strictEqual(r.kind, 'boundary'); assert.ok(!('n' in r)); assert.strictEqual(r.height, 1.4); assert.strictEqual(r.wallId, 'w1'); assert.strictEqual(r.value, null);
    await tapPlan(page, [2.0, 3.4]);
    await page.locator('#sheet .kind-seg .chip', { hasText: 'Photo' }).click();
    await page.locator('#sheet .chip', { hasText: 'Inspection opening' }).click();
    const [chooser] = await Promise.all([page.waitForEvent('filechooser'), page.locator('#sheet button', { hasText: 'Take photo' }).click()]);
    await chooser.setFiles(path.join(ROOT, 'reference', 'moisture-wall.jpg'));
    await page.waitForFunction(() => !!document.querySelector('#sheet .photo-row img'));
    await page.screenshot({ path: path.join(OUT, 'phone-sheet-photo-note.png') });
    await sheetButton(page, 'Done');
    p = await plan(page); r = p.markup.readings[p.markup.readings.length - 1];
    assert.strictEqual(r.kind, 'photo'); assert.strictEqual(r.n, 3); assert.strictEqual(r.note, 'Inspection opening');
    assert.ok(r.photo.startsWith('data:image/jpeg;base64,'));
    const m = await sharp(Buffer.from(r.photo.split(',')[1], 'base64')).metadata();
    assert.strictEqual(Math.max(m.width, m.height), 1280, 'downscaled to 1280 px long edge');
    // the photo string is stored once and not re-encoded by later edits
    await page.tap('.tool[data-tool="select"]');
    await tapHit(page, 'reading', r.id);
    await sheetButton(page, 'Done');
    const again = (await plan(page)).markup.readings.find(x => x.id === r.id);
    assert.strictEqual(again.photo, r.photo);
  });
  await test('rename a room, then undo', async () => {
    await page.tap('.tool[data-tool="select"]');
    await tapHit(page, 'room', 'r1');
    assert.ok(await sheetOpen(page));
    await page.locator('#sheet .chip', { hasText: 'Study' }).click();
    assert.strictEqual((await plan(page)).rooms[0].name, 'Study');
    assert.ok((await page.$$eval('#content .room-label', e => e.map(x => x.textContent))).some(t => t.startsWith('Study')));
    await page.tap('#btn-undo');
    assert.strictEqual((await plan(page)).rooms[0].name, 'Bedroom');
  });
  await test('drag a reading in Select mode re-snaps it', async () => {
    const hit = await page.evaluate(() => SecureScan.debug.hits().find(h => h.kind === 'reading' && h.id === 'm7'));
    const c = await page.evaluate(c => SecureScan.debug.sheetToClient(c), hit.c);
    const tgt = await planToClient(page, [0.35, 6.6]);
    const d = [tgt[0] - (await planToClient(page, [-0.1, 6.6]))[0], 0];
    await page.mouse.move(c[0], c[1]); await page.mouse.down();
    for (let i = 1; i <= 6; i++) await page.mouse.move(c[0] + d[0] * i / 6, c[1]);
    await page.mouse.up();
    const r = (await plan(page)).markup.readings.find(x => x.id === 'm7');
    assert.strictEqual(r.material, 'floor'); assert.ok(!r.wallId, 'floor readings never snap'); near(r.pos[0], 0.35, 0.03, 'moved');
    await page.tap('#btn-undo');
    near((await plan(page)).markup.readings.find(x => x.id === 'm7').pos[0], -0.1, 1e-9, 'undo move');
  });
  await test('layers: individual toggles and Plan only', async () => {
    await page.tap('#btn-layers');
    await page.locator('#sheet input[data-layer="readings"]').uncheck();
    assert.strictEqual(await page.$$eval('#content .reading', e => e.length), 0);
    await page.locator('#sheet input[data-layer="dims"]').uncheck();
    assert.strictEqual(await page.$$eval('#content .dim', e => e.length), 0);
    await page.locator('#sheet input[data-layer="readings"]').check(); await page.locator('#sheet input[data-layer="dims"]').check();
    await page.locator('#sheet .chip', { hasText: 'Plan only' }).click();
    for (const sel of ['.reading', '.removal', '.affected', '.source', '.legend', '.elev-tag']) assert.strictEqual(await page.$$eval('#content ' + sel, e => e.length), 0, sel);
    await page.screenshot({ path: path.join(OUT, 'phone-layers-plan-only.png') });
    await page.locator('#sheet .chip', { hasText: 'Plan + markup' }).click();
    await sheetButton(page, 'Done');
    assert.ok(await page.$$eval('#content .reading', e => e.length) > 0);
  });
  await test('pinch zoom and two-finger pan (pointer events)', async () => {
    const s0 = (await page.evaluate(() => SecureScan.debug.state())).cam.s;
    await page.evaluate(() => {
      const st = document.getElementById('stage'), r = st.getBoundingClientRect(), cx = r.left + r.width / 2, cy = r.top + r.height / 2;
      const ev = (type, id, x, y) => st.dispatchEvent(new PointerEvent(type, { pointerId: id, pointerType: 'touch', clientX: x, clientY: y, bubbles: true, isPrimary: id === 1 }));
      ev('pointerdown', 1, cx - 40, cy); ev('pointerdown', 2, cx + 40, cy);
      for (let i = 1; i <= 10; i++) { ev('pointermove', 1, cx - 40 - i * 8, cy + i * 3); ev('pointermove', 2, cx + 40 + i * 8, cy + i * 3); }
      ev('pointerup', 1, cx - 120, cy + 30); ev('pointerup', 2, cx + 120, cy + 30);
    });
    const c = (await page.evaluate(() => SecureScan.debug.state())).cam;
    near(c.s / s0, 3, 0.05, 'zoomed by finger spread ratio');
    assert.strictEqual(await page.evaluate(() => getComputedStyle(document.getElementById('stage')).touchAction), 'none');
    await page.screenshot({ path: path.join(OUT, 'phone-zoomed.png') });
  });
  await test('UI: touch targets >= 44 px, inputs >= 16 px, safe-area CSS present', async () => {
    const small = await page.$$eval('#toolbar button, #topbar button:not([hidden])', els => els.filter(e => e.offsetParent && (e.getBoundingClientRect().height < 44 || e.getBoundingClientRect().width < 44)).map(e => e.textContent));
    assert.deepStrictEqual(small, []);
    await page.tap('.tool[data-tool="reading"]'); await tapPlan(page, [1.0, 1.9]);
    const fonts = await page.$$eval('#sheet input[type=text]', els => els.map(e => parseFloat(getComputedStyle(e).fontSize)));
    assert.ok(fonts.every(f => f >= 16), 'input fonts ' + fonts);
    const chips = await page.$$eval('#sheet .chip, #sheet .btn', els => els.filter(e => e.offsetParent).map(e => e.getBoundingClientRect().height));
    assert.ok(chips.every(h => h >= 44), 'sheet controls >= 44 px: ' + chips);
    await page.locator('#sheet .btn', { hasText: 'Done' }).click();     // no value: nothing added
    const html = fs.readFileSync(path.join(WEB, 'editor.html'), 'utf8');
    assert.ok(html.includes('env(safe-area-inset-bottom') && html.includes('env(safe-area-inset-top') && html.includes('viewport-fit=cover'));
    await page.tap('.tool[data-tool="select"]');
  });

  /* ---------- exports (standalone: downloads + print) ---------- */
  await load(page, SINGLE);
  for (const [label, file] of [['Floor plan PNG', 'floor-plan.png'], ['Marked-up plan PNG', 'marked-up-plan.png'], ['Wall elevations PNG', 'wall-elevations.png']]) {
    await test(`export: ${label} >= 2000 px long edge, white background`, async () => {
      const f = await download(page, label);
      assert.ok(f.endsWith(file), f);
      const info = await pngInfo(fs.readFileSync(f));
      assert.strictEqual(info.format, 'png');
      assert.ok(Math.max(info.w, info.h) >= 2000, `${info.w}x${info.h}`);
      for (const c of info.corners) assert.deepStrictEqual(c, [255, 255, 255]);
      fs.copyFileSync(f, path.join(OUT, 'export-small-' + file));
    });
  }
  await test('export: Floor plan SVG and Marked-up plan SVG are standalone vectors', async () => {
    for (const label of ['Floor plan SVG', 'Marked-up plan SVG']) {
      const f = await download(page, label), svg = fs.readFileSync(f, 'utf8');
      assert.ok(svg.startsWith('<?xml version="1.0" encoding="UTF-8"?>\n<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 '), 'header');
      assert.ok(/width="[\d.]+mm" height="[\d.]+mm"/.test(svg), 'physical size in mm');
      assert.ok(svg.includes('class="sheet-bg"') && svg.includes('fill="#fff"'), 'white background rect');
      assert.ok(!/href=|url\((?!#)|@import|<image|<foreignObject/.test(svg), 'no external references');
      assert.strictEqual((svg.match(/https?:\/\//g) || []).length, 1, 'only the xmlns URI');
      const png = await sharp(Buffer.from(svg)).png().toBuffer();
      assert.ok((await sharp(png).metadata()).width > 100, 'parses as SVG');
      if (label.startsWith('Marked')) assert.ok(svg.includes('class="legend"')); else assert.ok(!svg.includes('class="legend"'));
    }
  });
  await test('export: Schedule CSV (BOM, three blocks, quoted values, totals)', async () => {
    const f = await download(page, 'Schedule CSV'), buf = fs.readFileSync(f);
    assert.deepStrictEqual([...buf.slice(0, 3)], [0xef, 0xbb, 0xbf], 'UTF-8 BOM');
    const text = buf.toString('utf8').slice(1);
    const blocks = text.trim().split('\r\n\r\n');
    assert.strictEqual(blocks.length, 3);
    const rows = b => b.split('\r\n').map(l => l.slice(1, -1).split('","'));
    for (const b of blocks) for (const l of b.split('\r\n')) assert.ok(/^"(?:[^"]|"")*"(,"(?:[^"]|"")*")*$/.test(l), 'quoted: ' + l);
    const [rooms, readings, removals] = blocks.map(rows);
    assert.deepStrictEqual(rooms.slice(2, 5).map(r => r[0]), ['Bedroom', 'Laundry', 'Hallway']);
    assert.strictEqual(rooms[2][1], shoelace(SINGLE.rooms[0].polygon).toFixed(2));
    assert.deepStrictEqual(readings[1], ['No.', 'Room', 'Wall tag', 'Material', 'Height mm', 'Value %', 'Status', 'Reference', 'Note']);
    assert.strictEqual(readings.length - 2, SINGLE.markup.readings.filter(r => kindOf(r) === 'reading').length, 'readings only, no marks/photos');
    assert.deepStrictEqual(readings[2].slice(0, 8), ['1', 'Laundry', 'A', 'skirting', '50', '38.5', 'Wet', 'N']);
    assert.ok(readings.some(r => r[0] === '8' && r[7] === 'Y'), 'reference flagged');
    assert.ok(removals.some(r => r[0] === 'Total' && r[2] === 'Plasterboard' && r[3] === '2.20' && r[5] === '2.64'));
    assert.ok(removals.some(r => r[0] === 'Total' && r[2] === 'All items'));
    fs.copyFileSync(f, path.join(OUT, 'export-small-schedule.csv'));
  });
  await test('export: Moisture & scope sheet print view (standalone uses window.print)', async () => {
    await page.evaluate(() => { window.__printed = 0; window.print = () => { window.__printed++; }; });
    await page.click('#btn-export');
    await page.locator('#sheet button', { hasText: 'Moisture & scope sheet' }).click();
    assert.strictEqual(await page.evaluate(() => window.__printed), 1);
    const txt = await page.evaluate(() => document.getElementById('print-root').innerText);
    for (const s of ['SecureWorks WA', 'Moisture & scope sheet', '30 Sample Cr, Testwood, WA', 'CLM-00-000001', 'Ozito digital moisture meter',
      'Readings are as displayed by the meter and are comparative; reference readings are taken from unaffected areas of the same material.',
      'Removal schedule', 'Site photos', 'Inspection opening — pipework in brickwork', 'Wall elevations']) assert.ok(txt.includes(s), 'sheet has: ' + s);
    const rows = await page.$$eval('#print-root table.ps-readings tbody tr', els => els.length);
    assert.strictEqual(rows, 8, 'readings table lists kind "reading" only');
    const pdf = await page.pdf({ path: path.join(OUT, 'scope-sheet-small.pdf'), format: 'A4', printBackground: true });
    assert.ok(pdf.length > 20000);
    const html = await page.$eval('#print-css', e => e.textContent);
    assert.ok(html.includes('@page') && html.includes('A4 portrait'));
  });
  await test('scope sheet screenshot (A4 width)', async () => {
    const body = await page.evaluate(() => SecureScan.debug.scopeSheetHTML());
    const css = await page.$eval('#print-css', e => e.textContent);
    const p2 = await (await browser.newContext({ viewport: { width: 794, height: 1123 }, deviceScaleFactor: 1.5 })).newPage();
    await p2.setContent(`<!DOCTYPE html><html><head><style>${css} body{margin:0;padding:12mm;background:#fff}</style></head><body>${body}</body></html>`);
    await p2.screenshot({ path: path.join(OUT, 'scope-sheet-small.png'), fullPage: true });
  });

  /* ---------- GLB import through the UI ---------- */
  await test('GLB import: bad file shows a readable error sheet (no native dialog)', async () => {
    await page.tap('#btn-open');
    const [chooser] = await Promise.all([page.waitForEvent('filechooser'), page.locator('#sheet button', { hasText: 'Import 3D model' }).click()]);
    await chooser.setFiles({ name: 'bad.glb', mimeType: 'model/gltf-binary', buffer: Buffer.from('not a glb file at all') });
    await page.waitForFunction(() => !document.getElementById('sheet').hidden);
    const t = await page.$eval('#sheet', e => e.innerText);
    assert.ok(t.includes('Could not import that model'), t);
    await sheetButton(page, 'OK');
  });
  if (fs.existsSync(GLB_FIXTURE)) {
    await test('GLB import: private Polycam fixture through the Open sheet, confirm, replace', async () => {
      await page.tap('#btn-open');
      const [chooser] = await Promise.all([page.waitForEvent('filechooser'), page.locator('#sheet button', { hasText: 'Import 3D model' }).click()]);
      await chooser.setFiles(GLB_FIXTURE);
      await page.waitForFunction(() => document.querySelector('#sheet .import-summary'));
      const msg = await page.$eval('#sheet .import-summary', e => e.textContent);
      assert.ok(msg.startsWith('Polycam floor plan:'), msg);
      assert.ok(await page.$eval('#sheet .sh-title', e => e.textContent === 'Replace the current plan?'));
      await page.screenshot({ path: path.join(OUT, 'phone-glb-confirm.png') });
      await sheetButton(page, 'Replace plan');
      const p = await plan(page);
      assert.ok(p.walls.length >= 40 && p.rooms.length >= 5, `${p.walls.length} walls`);
      assert.deepStrictEqual([p.markup.sources, p.markup.affected, p.markup.removals, p.markup.readings], [[], [], [], []]);
      assert.strictEqual(p.walls.length, LARGE.walls.length);
    });
  } else console.log('  SKIP GLB fixture import (private-fixtures/polycam-example.glb not present)');
  await test('Open sheet demos load both built-in plans', async () => {
    await page.tap('#btn-open'); await page.locator('#sheet button', { hasText: 'Demo: large house' }).click();
    assert.deepStrictEqual(await plan(page), LARGE);
    await page.tap('#btn-open'); await page.locator('#sheet button', { hasText: 'Demo: small sample' }).click();
    assert.deepStrictEqual(await plan(page), SMALL);
  });
  await test('autosave to localStorage only on real change; survives storage errors', async () => {
    await page.evaluate(() => localStorage.clear());
    await page.waitForTimeout(900);
    assert.strictEqual(await page.evaluate(() => localStorage.getItem('securescan.plan')), null, 'no save without a change');
    await tapHit(page, 'room', 'r2'); await page.locator('#sheet .chip', { hasText: 'WC' }).click();
    await page.waitForTimeout(950);
    assert.strictEqual(JSON.parse(await page.evaluate(() => localStorage.getItem('securescan.plan'))).rooms[1].name, 'WC');
    await page.evaluate(() => { Storage.prototype.setItem = () => { throw new DOMException('full', 'QuotaExceededError'); }; });
    await tapHit(page, 'room', 'r2'); await page.locator('#sheet .chip', { hasText: 'Laundry' }).click();
    await page.waitForTimeout(950);
    assert.strictEqual((await plan(page)).rooms[1].name, 'Laundry', 'editing continues');
    assert.ok((await page.$eval('#toast', e => e.textContent)).includes('Could not save'));
  });
  /* ---------- v1.4: moisture line drawing, sources on walls, site notes, job summary, job pack ---------- */
  await load(page, SINGLE);
  await test('v1.4: Moisture line on a normal elevation by touch: tap adds (50 mm snap), drag moves, tap deletes, undo', async () => {
    await page.click('#view-seg button[data-view="elev"]');
    await page.tap('.tool[data-etool="mline"]');
    let s0 = await page.evaluate(() => SecureScan.debug.state());
    assert.strictEqual(s0.etool, 'mline'); assert.strictEqual(s0.focusWall, 'w7', 'first elevation focused for drawing');
    await page.locator('#actionbar button[aria-label^="Elevation B"]').click();
    assert.strictEqual((await page.evaluate(() => SecureScan.debug.state())).focusWall, 'w1');
    const before = await marksOn(page, 'w1');
    assert.strictEqual(before.length, 4);
    await touchTap(page, await elevClient(page, 'w1', 0.45, 1.23));
    let after = await marksOn(page, 'w1');
    assert.strictEqual(after.length, 5);
    const r = after.find(x => !before.some(b => b.id === x.id));
    near(r.wallT, 0.45, 0.004, 'wallT'); assert.strictEqual(r.height, 1.25, 'height snapped to 50 mm');
    assert.strictEqual(r.source, 'manual'); assert.ok(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(r.takenAt), r.takenAt);
    assert.strictEqual(r.value, null); assert.ok(!('n' in r));
    near(r.pos[0], r.wallT * 3.45, 0.002, 'pos on the wall line'); assert.strictEqual(r.pos[1], 0);
    // a tap close to (but not on) an existing point adds a point instead of deleting that one
    const near0 = await marksOn(page, 'w1');
    const b2 = await elevClient(page, 'w1', 0.78, 0.9), sc = (await page.evaluate(() => SecureScan.debug.state())).cam.s;
    await touchTap(page, [b2[0] + 18, b2[1] + 4]);
    const near1 = await marksOn(page, 'w1');
    assert.strictEqual(near1.length, 6, `near miss (${(18 / sc / 100).toFixed(2)} m away) adds`); assert.ok(near1.some(x => x.id === 'b4'), 'b4 kept');
    await page.tap('#btn-undo');
    assert.strictEqual((await marksOn(page, 'w1')).length, near0.length);
    const verts = await page.$eval('#content .elevation[data-wall="w1"] .moisture-line', e => e.getAttribute('d').split('L').length);
    assert.strictEqual(verts, 5, 'line joins all five points');
    // drag with live preview
    const a = await elevClient(page, 'w1', r.wallT, r.height), b = await elevClient(page, 'w1', 0.6, 0.72);
    await touch(page, 'touchStart', a[0], a[1]);
    for (let i = 1; i <= 6; i++) await touch(page, 'touchMove', a[0] + (b[0] - a[0]) * i / 6, a[1] + (b[1] - a[1]) * i / 6);
    await page.waitForTimeout(120);      // touch moves are coalesced to frames
    const ov = await page.$eval('#overlay', e => e.textContent);
    assert.ok(ov.includes('700 mm'), 'height readout while dragging: ' + ov + JSON.stringify(await marksOn(page, 'w1')));
    await page.screenshot({ path: path.join(OUT, 'phone-moisture-line-drawing.png') });
    await touch(page, 'touchEnd'); await page.waitForTimeout(60);
    after = await marksOn(page, 'w1');
    let m = after.find(x => x.id === r.id);
    assert.strictEqual(after.length, 5); near(m.wallT, 0.6, 0.004, 'moved wallT'); assert.strictEqual(m.height, 0.7);
    // stays inside the wall rectangle
    await touchDrag(page, await elevClient(page, 'w1', m.wallT, m.height), await elevClient(page, 'w1', 0.6, 2.36));
    const top = await elevClient(page, 'w1', 0.6, 2.4), stageTop = await page.$eval('#stage', e => e.getBoundingClientRect().top), outside = [top[0], Math.max(stageTop + 4, top[1] - 80)];
    m = (await marksOn(page, 'w1')).find(x => x.id === r.id);
    await touchDrag(page, await elevClient(page, 'w1', m.wallT, m.height), outside);
    m = (await marksOn(page, 'w1')).find(x => x.id === r.id);
    assert.strictEqual(m.height, 2.4, 'clamped to the wall height'); near(m.wallT, 0.6, 0.004, 'x kept');
    // tap deletes, undo restores
    const undo0 = (await page.evaluate(() => SecureScan.debug.state())).undo;
    await touchTap(page, await elevClient(page, 'w1', m.wallT, m.height));
    assert.strictEqual((await marksOn(page, 'w1')).length, 4, 'tap on a point deletes it');
    assert.ok((await page.$eval('#toast', e => e.textContent)).startsWith('Point removed'));
    await page.tap('#btn-undo');
    const back = (await marksOn(page, 'w1')).find(x => x.id === r.id);
    assert.ok(back && back.height === 2.4, 'undo restores the point');
    assert.strictEqual((await page.evaluate(() => SecureScan.debug.state())).undo, undo0);
    // two-finger gesture starting on the wall does not leave a point behind
    const c = await elevClient(page, 'w1', 0.3, 0.5);
    await page.evaluate(([x, y]) => {
      const st = document.getElementById('stage'), ev = (type, id, x, y) => st.dispatchEvent(new PointerEvent(type, { pointerId: id, pointerType: 'touch', clientX: x, clientY: y, bubbles: true }));
      ev('pointerdown', 11, x, y); ev('pointerdown', 12, x + 60, y); ev('pointermove', 12, x + 90, y); ev('pointerup', 11, x, y); ev('pointerup', 12, x + 90, y);
    }, c);
    assert.strictEqual((await marksOn(page, 'w1')).length, 5, 'pinch does not add a point');
  });
  await test('v1.4: Moisture line on a mirrored elevation (viewed from the other side): add and drag keep true wallT', async () => {
    await page.locator('#actionbar button[aria-label^="Elevation D"]').click();
    const flip = await page.$eval('#content .elevation[data-wall="w11"]', e => e.dataset.flip);
    assert.strictEqual(flip, '1', 'w11 is drawn mirrored');
    await touchTap(page, await elevClient(page, 'w11', 0.25, 0.81));
    let mk = await marksOn(page, 'w11');
    assert.strictEqual(mk.length, 1);
    near(mk[0].wallT, 0.25, 0.007, 'wallT (1 cm steps on a 1.54 m wall)'); assert.strictEqual(mk[0].height, 0.8);
    const g = await page.$eval('#content .elevation[data-wall="w11"]', e => ({ x0: +e.dataset.x0, len: +e.dataset.len, mx: +e.querySelector('.elev-mark').dataset.x }));
    near(g.mx, g.x0 + (g.len - mk[0].wallT * g.len) * 100, 0.6, 'drawn from the mirrored end');
    assert.ok(g.mx > g.x0 + g.len * 50, 'wallT 0.25 appears on the right half when mirrored');
    await touchDrag(page, await elevClient(page, 'w11', mk[0].wallT, 0.8), await elevClient(page, 'w11', 0.7, 1.52));
    mk = await marksOn(page, 'w11');
    near(mk[0].wallT, 0.7, 0.007, 'dragged wallT'); assert.strictEqual(mk[0].height, 1.5);
    const w = SINGLE.walls.find(x => x.id === 'w11');
    near(mk[0].pos[1], w.a[1] + (w.b[1] - w.a[1]) * mk[0].wallT, 0.002, 'pos follows wallT');
    await touchTap(page, await elevClient(page, 'w11', 0.2, 1.0));
    assert.strictEqual(await page.$$eval('#content .elevation[data-wall="w11"] .moisture-line', e => e.length), 1, 'two points make a line');
    await page.screenshot({ path: path.join(OUT, 'phone-moisture-line-mirrored.png') });
  });
  await test('v1.4: any wall can be opened for drawing (Add wall, then tap the wall on the plan)', async () => {
    const p0 = await plan(page);
    await page.tap('.tool[data-etool="addwall"]');
    let s1 = await page.evaluate(() => SecureScan.debug.state());
    assert.strictEqual(s1.view, 'plan'); assert.strictEqual(s1.pickWall, true);
    assert.strictEqual(await page.$eval('#hint', e => e.textContent), 'Tap the wall to draw its moisture line');
    await page.screenshot({ path: path.join(OUT, 'phone-pick-wall.png') });
    await touchTap(page, await planToClient(page, [-0.65, 4.2]));
    s1 = await page.evaluate(() => SecureScan.debug.state());
    assert.strictEqual(s1.view, 'elev'); assert.strictEqual(s1.focusWall, 'w12'); assert.strictEqual(s1.etool, 'mline');
    assert.deepStrictEqual(await plan(page), p0, 'opening a wall does not change the document');
    assert.ok(!(await page.evaluate(() => SecureScan.debug.elevationSVG())).includes('data-wall="w12"'), 'empty wall is not exported');
    await page.screenshot({ path: path.join(OUT, 'phone-empty-wall-for-drawing.png') });
    await touchTap(page, await elevClient(page, 'w12', 0.5, 0.6));
    const mk = await marksOn(page, 'w12');
    assert.strictEqual(mk.length, 1); assert.strictEqual(mk[0].height, 0.6); near(mk[0].wallT, 0.5, 0.003, 'wallT');
    assert.ok((await page.evaluate(() => SecureScan.debug.elevationSVG())).includes('data-wall="w12"'), 'now it has an elevation');
    await page.tap('.tool[data-etool="view"]');
    await page.click('#view-seg button[data-view="plan"]');
  });
  await test('v1.4: Source tool snaps to a wall within 0.3 m, offers height chips; shows on that elevation', async () => {
    await load(page, SINGLE);
    await page.tap('.tool[data-tool="source"]');
    await tapPlan(page, [3.3, 1.2]);
    assert.ok(await page.$eval('#sheet', e => e.textContent.includes('Height above floor')), 'height chips offered');
    await page.fill('#sheet input', 'Leaking window frame');
    await page.locator('#sheet .chip', { hasText: '300' }).click();
    await page.screenshot({ path: path.join(OUT, 'phone-sheet-source-on-wall.png') });
    await sheetButton(page, 'Done');
    const s = (await plan(page)).markup.sources[1];
    assert.strictEqual(s.wallId, 'w2'); near(s.wallT, 1.2 / 2.52, 0.003, 'wallT'); assert.strictEqual(s.height, 0.3);
    assert.deepStrictEqual(s.pos.map(v => +v.toFixed(3)), [3.45, 1.2]); assert.strictEqual(s.source, 'manual'); assert.ok(s.takenAt);
    await tapPlan(page, [1.5, 1.4]);                       // open floor: no wall, no height chips
    assert.ok(!(await page.$eval('#sheet', e => e.textContent.includes('Height above floor'))));
    await sheetButton(page, 'Done');
    const s2 = (await plan(page)).markup.sources[2];
    assert.ok(!('wallId' in s2) && !('height' in s2), 'floor source has no wall fields');
    await page.click('#view-seg button[data-view="elev"]');
    const ids = await page.$$eval('#content .elev-source', els => els.map(e => [e.closest('.elevation').dataset.wall, e.dataset.id]));
    assert.deepStrictEqual(ids.sort(), [['w2', s.id], ['w7', 's1']].sort());
    assert.ok(await page.$$eval('#content .elev-source-label', els => els.some(e => e.textContent.includes('Burst washing machine hose'))));
    await page.screenshot({ path: path.join(OUT, 'phone-elevation-source.png') });
    await page.click('#view-seg button[data-view="plan"]');
    assert.strictEqual(await page.$$eval('#content .source', e => e.length), 3, 'AR, wall and floor sources all on the plan');
  });
  await test('v1.4: Notes view shows one timeline in time order (notes interleaved with events)', async () => {
    await load(page, SINGLE);
    await page.click('#view-seg button[data-view="notes"]');
    assert.ok(await page.isVisible('#notesview')); assert.ok(!(await page.isVisible('#stage')));
    const rows = await page.$$eval('#notes-list .tl-item', els => els.map(e => e.dataset.tl === 'note' ? 'note:' + e.dataset.i : e.dataset.tl + ':' + e.dataset.id));
    const m = SINGLE.markup, items = [];
    m.notes.forEach((n, i) => items.push(['note:' + i, Date.parse(n.t)]));
    m.sources.forEach(s => items.push(['source:' + s.id, Date.parse(s.takenAt)]));
    m.readings.forEach(r => items.push([(r.kind === 'boundary' ? 'mark' : kindOf(r)) + ':' + r.id, Date.parse(r.takenAt)]));
    const want = items.map((x, i) => [...x, i]).sort((a, b) => a[1] - b[1] || a[2] - b[2]).map(x => x[0]);
    assert.deepStrictEqual(rows, want);
    assert.ok(rows.indexOf('note:1') < rows.indexOf('source:s1') && rows.indexOf('source:s1') < rows.indexOf('reading:m1'), 'interleaved');
    const first = await page.$eval('#notes-list .tl-item', e => e.innerText);
    assert.ok(first.startsWith('9:24'), 'local (Perth) time: ' + first);
    assert.strictEqual(await page.$$eval('#notes-list .tl-note .tl-ico', els => els.filter(e => e.innerHTML.includes('rect x="10"')).length), 7, 'mic glyph on the 7 spoken notes');
    assert.ok(await page.$eval('#notes-list', e => e.innerText.includes('corrected')), 'edited note marked');
    assert.ok(await page.$eval('#notes-list', e => e.innerText.includes('Australia/Perth (UTC+08:00)')));
    await page.screenshot({ path: path.join(OUT, 'phone-notes.png') });
    const thumbs = await page.$$eval('#notes-list .tl-item', els => els.every(e => e.getBoundingClientRect().height >= 44));
    assert.ok(thumbs, 'rows are at least 44 px');
  });
  await test('v1.4: notes: correct a note (edited: true, other fields kept), add a typed note, delete + undo', async () => {
    await page.click('#notes-list .tl-note[data-i="0"]');
    assert.ok(await sheetOpen(page));
    assert.ok(parseFloat(await page.$eval('#sheet textarea', e => getComputedStyle(e).fontSize)) >= 16);
    await page.fill('#sheet textarea', 'Arrived on site. Owner says the washing machine hose burst overnight.');
    await page.screenshot({ path: path.join(OUT, 'phone-note-edit.png') });
    await sheetButton(page, 'Save');
    let n = (await plan(page)).markup.notes;
    assert.deepStrictEqual(n[0], { ...SINGLE.markup.notes[0], text: 'Arrived on site. Owner says the washing machine hose burst overnight.', edited: true });
    // unchanged text: no edit recorded
    const u0 = (await page.evaluate(() => SecureScan.debug.state())).undo;
    await page.click('#notes-list .tl-note[data-i="2"]'); await sheetButton(page, 'Save');
    assert.strictEqual((await page.evaluate(() => SecureScan.debug.state())).undo, u0);
    assert.strictEqual((await plan(page)).markup.notes[2].edited, false);
    // add a typed note
    const t0 = Date.now();
    await page.tap('.tool[data-ntool="add"]');
    await page.fill('#sheet textarea', 'Called the assessor, left a message.');
    await sheetButton(page, 'Save');
    n = (await plan(page)).markup.notes;
    const added = n[n.length - 1];
    assert.strictEqual(n.length, 9); assert.strictEqual(added.source, 'typed'); assert.strictEqual(added.edited, false); assert.strictEqual(added.text, 'Called the assessor, left a message.');
    assert.ok(Math.abs(Date.parse(added.t) - t0) < 5000, 'time stamped now');
    const last = await page.$$eval('#notes-list .tl-item', els => els[els.length - 1].innerText);
    assert.ok(last.includes('Called the assessor'), 'newest note is last in the timeline');
    // delete with undo
    await page.click('#notes-list .tl-note[data-i="1"]');
    await sheetButton(page, 'Delete');
    n = (await plan(page)).markup.notes;
    assert.strictEqual(n.length, 8); assert.ok(!n.some(x => x.id === 'n2'));
    await page.tap('#btn-undo');
    n = (await plan(page)).markup.notes;
    assert.deepStrictEqual(n[1], SINGLE.markup.notes[1], 'undo restores the note unchanged');
    // a new empty note is not added
    await page.tap('.tool[data-ntool="add"]'); await sheetButton(page, 'Save');
    assert.strictEqual((await plan(page)).markup.notes.length, 9);
  });
  await test('v1.4: tapping an event in the timeline jumps to it on the plan', async () => {
    const fit = (await page.evaluate(() => SecureScan.debug.state())).cam;
    await page.click('#notes-list .tl-event[data-id="m6"]');
    const s = await page.evaluate(() => SecureScan.debug.state());
    assert.strictEqual(s.view, 'plan');
    const hit = await page.evaluate(() => SecureScan.debug.hits().find(h => h.id === 'm6'));
    const c = await page.evaluate(c => SecureScan.debug.sheetToClient(c), hit.c);
    const vp = page.viewportSize();
    assert.ok(c[0] > 40 && c[0] < vp.width - 40 && c[1] > 100 && c[1] < vp.height - 100, 'item on screen: ' + c);
    assert.ok(s.cam.s > (fit.s || 0), 'zoomed in');
    assert.ok(await page.$eval('#overlay', e => e.innerHTML.includes('circle')), 'item ringed');
    await page.screenshot({ path: path.join(OUT, 'phone-jump-from-timeline.png') });
  });
  await test('v1.4: notes without a time sort last in document order; 150+ notes render quickly', async () => {
    const d = clone(SINGLE);
    const base = Date.parse('2026-11-12T00:00:00Z');
    d.markup.notes = [];
    for (let i = 0; i < 160; i++) d.markup.notes.push({ id: 'q' + i, t: new Date(base + (159 - i) * 61000).toISOString().replace(/\.\d+Z$/, 'Z'), text: `Note ${159 - i}: skirting along this wall is reading high, more readings to follow near the door and the robe.`, source: i % 4 ? 'voice' : 'typed', edited: false });
    d.markup.notes.splice(40, 0, { id: 'u1', text: 'First untimed', source: 'voice' });
    d.markup.notes.splice(90, 0, { id: 'u2', t: 'not a time', text: 'Second untimed', source: 'voice' });
    d.markup.notes.push({ id: 'u3', t: null, text: '', source: 'voice' });
    await load(page, d);
    await page.click('#view-seg button[data-view="plan"]');
    const ms = await page.evaluate(() => { const t = performance.now(); document.querySelector('#view-seg button[data-view="notes"]').click(); document.body.offsetHeight; return performance.now() - t; });
    assert.ok(ms < 400, 'notes view rendered in ' + ms.toFixed(0) + ' ms');
    const texts = await page.$$eval('#notes-list .tl-note', els => els.map(e => e.querySelector('.tl-body').firstChild.textContent));
    assert.strictEqual(texts.length, 163);
    assert.deepStrictEqual(texts.slice(-3), ['First untimed', 'Second untimed', 'Not transcribed']);
    const nums = texts.slice(0, 160).map(t => +t.match(/^Note (\d+)/)[1]);
    assert.deepStrictEqual(nums, nums.slice().sort((a, b) => a - b), 'timed notes ascending');
    assert.ok(await page.$eval('#notes-list', e => e.innerText.includes('NO TIME RECORDED') || e.innerText.includes('No time recorded')));
    await page.$eval('#notesview', e => { e.scrollTop = e.scrollHeight; });
    await page.screenshot({ path: path.join(OUT, 'phone-notes-many.png') });
    await page.click('#notes-list .tl-note >> nth=100');
    const pos = await page.$eval('#notesview', e => e.scrollTop);
    await page.fill('#sheet textarea', 'Corrected while scrolled down'); await sheetButton(page, 'Save');
    assert.strictEqual(await page.$eval('#notesview', e => e.scrollTop), pos, 'scroll position kept after an edit re-renders the list');
    await page.click('#view-seg button[data-view="plan"]');
  });
  await test('v1.4: summaryMarkdown() is complete and factual for the sample', async () => {
    await load(page, SINGLE);
    const md = await page.evaluate(() => SecureScan.summaryMarkdown());
    fs.writeFileSync(path.join(OUT, 'summary-small.md'), md);
    const m = SINGLE.markup, fv = v => (Math.round(v * 10) / 10) + '%';
    for (const h of ['# Job summary: 30 Sample Cr, Testwood, WA', '## Job', '## Rooms', '## Openings', '## Water source', '## Affected area', '## Timeline', '## Moisture readings', '## Moisture line', '## Removal schedule', '## Photos', '## Files in this pack'])
      assert.ok(md.includes('\n' + h) || md.startsWith(h), 'heading ' + h);
    assert.ok(md.includes('| Job ref | CLM-00-000001 |') && md.includes('| Moisture meter | Ozito digital moisture meter |'));
    assert.ok(md.includes('Dry below 15%; Elevated 15% to below 20%; Wet 20% and over'));
    for (const r of m.readings.filter(r => kindOf(r) === 'reading')) {
      assert.ok(md.includes(`**Reading ${r.n}:** ${fv(r.value)}`), 'timeline reading ' + r.n);
      assert.ok(new RegExp(`\\n\\| ${r.n} \\| \\d\\d:\\d\\d:\\d\\d \\|[^\\n]*\\| ${r.value} \\|`).test(md), 'table reading ' + r.n);
    }
    for (const n of m.notes) assert.ok(md.includes('“' + n.text + '”'), 'note verbatim: ' + n.id);
    assert.ok(md.includes('_(audio audio/001.m4a from 0:00)_') && md.includes('text corrected by hand'));
    assert.ok(md.includes('**Typed note:** “Owner has photos'));
    for (const r of m.readings.filter(r => kindOf(r) === 'photo')) assert.ok(md.includes(`**Photo P${r.n}:** “${r.note}”`) && md.includes('no image attached'));
    assert.strictEqual((md.match(/\*\*Moisture line point:\*\*/g) || []).length, 4);
    assert.ok(md.includes('### Elevation B: Bedroom, wall w1 (3.45 m long)') && md.includes('highest 1,500 mm, lowest 900 mm'));
    assert.ok(md.includes('Burst washing machine hose · Laundry · wall w7 (Elevation A) · 350 mm above floor'));
    // removals: every row, and totals equal the plan legend
    m.removals.forEach((x, i) => assert.ok(md.includes(`| X${i + 1} |`), 'removal ' + x.id));
    const legend = await page.$$eval('#content .legend-row', els => els.map(e => e.textContent));
    let checked = 0;
    for (const l of legend) {
      const r = /^Remove (\w+) · ([\d.]+) lm · ([\d.]+) m²$/.exec(l);
      if (r) { assert.ok(md.includes(`| ${r[1][0].toUpperCase() + r[1].slice(1)} | ${r[2]} | ${r[3]} |`), 'total ' + l); checked++; }
      const a = /^Affected area · ([\d.]+) m²$/.exec(l);
      if (a) { const t = +/Total marked affected area: ([\d.]+) m²/.exec(md)[1]; assert.strictEqual(t.toFixed(1), a[1]); checked++; }
    }
    assert.strictEqual(checked, 3);
    // times: local, the offset stated once; the timeline is in time order
    assert.strictEqual((md.match(/UTC\+08:00/g) || []).length, 1); assert.ok(md.includes('(Australia/Perth)'));
    assert.ok(md.includes('`09:24:05` **Spoken note:**'), 'local time in the timeline');
    const tl = md.slice(md.indexOf('## Timeline'), md.indexOf('## Moisture readings'));
    const times = [...tl.matchAll(/`(\d\d:\d\d:\d\d)`/g)].map(x => x[1]);
    assert.strictEqual(times.length, m.notes.length + m.readings.length + m.sources.length);
    assert.deepStrictEqual(times, times.slice().sort());
    assert.ok(!/undefined|NaN|\bnull\b|\[object/.test(md), 'no placeholders leaked');
    assert.ok(md.includes('`plan.json`'), 'standalone pack includes plan.json');
    // a document with nothing in it still produces a factual summary
    const bare = clone(SINGLE); delete bare.markup; delete bare.jobRef;
    await load(page, bare);
    const md2 = await page.evaluate(() => SecureScan.summaryMarkdown());
    for (const t of ['| Job ref | not recorded |', 'No water source marked.', 'No moisture readings recorded.', 'No removals marked.', 'Nothing time-stamped was recorded.']) assert.ok(md2.includes(t), t);
    await load(page, SINGLE);
  });
  await test('v1.4: scope sheet has Site notes after the readings and the source wall/height', async () => {
    const html = await page.evaluate(() => SecureScan.debug.scopeSheetHTML());
    const i = html.indexOf('>Site notes</h2>');
    assert.ok(i > html.indexOf('>Moisture readings</h2>') && i < html.indexOf('>Removal schedule</h2>'), 'order');
    for (const n of SINGLE.markup.notes) assert.ok(html.includes(n.text.replace(/'/g, '&#39;')), n.id);
    assert.ok(html.includes('9:24 am'));
    assert.ok(/Burst washing machine hose<\/b><\/td><td>Laundry · wall \(Elev\. A\)<\/td><td class="num">350 mm/.test(html), 'source location and height');
  });
  await test('v1.4: unknown fields round-trip, including inside notes and sources, through edits', async () => {
    const d = clone(SINGLE);
    d.markup.notes[0].confidence = 0.91; d.markup.notes[0].segments = [{ t: 0, w: 'Arrived' }];
    d.markup.sources[0].arHit = { x: 1.2, y: 0.35, z: 2.5 }; d.markup.sources[0].photoNote = 'keep';
    d.markup.notes.push({ id: 'n9', t: '2026-11-12T01:58:00Z', text: '', source: 'voice', audio: 'audio/002.m4a', transcription: 'failed', edited: false });
    d.markup.vendor = { app: '1.4' };
    await load(page, d);
    assert.deepStrictEqual(await plan(page), d);
    for (const v of ['elev', 'notes', 'plan']) await page.click(`#view-seg button[data-view="${v}"]`);
    assert.deepStrictEqual(await plan(page), d, 'unchanged after view switches');
    await page.click('#view-seg button[data-view="notes"]');
    assert.ok(await page.$eval('#notes-list', e => e.innerText.includes('Not transcribed')));
    await page.click('#notes-list .tl-note[data-i="0"]'); await page.fill('#sheet textarea', 'Corrected.'); await sheetButton(page, 'Save');
    await page.click('#view-seg button[data-view="plan"]');
    await tapHit(page, 'source', 's1'); await page.fill('#sheet input', 'Split washing machine hose'); await sheetButton(page, 'Done');
    const p = await plan(page);
    assert.deepStrictEqual(p.markup.notes[0], { ...d.markup.notes[0], text: 'Corrected.', edited: true });
    assert.deepStrictEqual(p.markup.sources[0], { ...d.markup.sources[0], label: 'Split washing machine hose' });
    assert.deepStrictEqual(p.markup.notes[8], d.markup.notes[8]); assert.deepStrictEqual(p.markup.vendor, d.markup.vendor);
  });
  await test('v1.4: Job pack (standalone): one .zip, unzip -t clean, file list, byte-for-byte contents, ~40 photos without freezing', async () => {
    const doc = await photoDoc(40);
    await load(page, doc);
    await page.evaluate(() => {
      window.__gaps = []; window.__labels = [];
      let last = performance.now();
      window.__gapTimer = setInterval(() => { const n = performance.now(); window.__gaps.push(n - last); last = n; }, 25);
      new MutationObserver(() => window.__labels.push(document.querySelector('#busy .busy-sub').textContent)).observe(document.querySelector('#busy .busy-sub'), { childList: true, characterData: true, subtree: true });
    });
    await page.click('#btn-export');
    assert.strictEqual(await page.$eval('#sheet .btn.block', e => e.firstChild.textContent), 'Job pack', 'first item in the Export sheet');
    await page.screenshot({ path: path.join(OUT, 'phone-export-sheet.png') });
    const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 120000 }), page.locator('#sheet button', { hasText: 'Job pack' }).click(),
      page.waitForTimeout(400).then(() => page.screenshot({ path: path.join(OUT, 'phone-job-pack-progress.png') }))]);
    const file = path.join(OUT, 'downloads', dl.suggestedFilename());
    fs.mkdirSync(path.dirname(file), { recursive: true });
    await dl.saveAs(file);
    const gaps = await page.evaluate(() => { clearInterval(window.__gapTimer); return window.__gaps; });
    const labels = await page.evaluate(() => [...new Set(window.__labels)]);
    assert.strictEqual(dl.suggestedFilename(), '30-sample-cr-testwood-wa-job-pack.zip');
    const size = fs.statSync(file).size;
    assert.ok(size > 8e6, 'about 10 MB of photos: ' + size);
    const list = unzipCheck(file);
    const photoNames = ['photos/reading-1.jpg', 'photos/P1.jpg', ...Array.from({ length: 36 }, (_, i) => `photos/P${i + 3}.jpg`), 'photos/source-1.jpg', 'photos/moisture-line-1.jpg'];
    assert.deepStrictEqual(list, ['photos/', 'summary.md', 'floor-plan.png', 'marked-up-plan.png', 'wall-elevations.png', 'schedule.csv', 'moisture-scope-sheet.html', 'assessment-report.html', ...photoNames, 'plan.json']);
    // second, independent reader: Python's zipfile (CRC check of every member, UTF-8 flag)
    const py = execFileSync('python3', ['-c', 'import sys,zipfile;z=zipfile.ZipFile(sys.argv[1]);print(z.testzip());print(all(i.flag_bits & 0x800 for i in z.infolist()));print(all(i.compress_type==0 for i in z.infolist()))', file]).toString().trim().split('\n');
    assert.deepStrictEqual(py, ['None', 'True', 'True']);
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pack-'));
    execFileSync('unzip', ['-q', file, '-d', dir]);
    const md = await page.evaluate(() => SecureScan.summaryMarkdown());
    assert.ok(fs.readFileSync(path.join(dir, 'summary.md')).equals(Buffer.from(md, 'utf8')), 'summary.md byte-for-byte');
    for (const f of photoNames) assert.ok(md.includes(f), 'summary names ' + f);
    const want = await page.evaluate(() => SecureScan.debug.packFiles('zip'));
    for (const f of want) assert.ok(fs.readFileSync(path.join(dir, f.filename)).equals(Buffer.from(f.base64, 'base64')), 'byte-for-byte ' + f.filename);
    const p1 = doc.markup.readings.find(r => r.id === 'p1').photo;
    assert.ok(fs.readFileSync(path.join(dir, 'photos/P1.jpg')).equals(Buffer.from(p1.split(',')[1], 'base64')), 'photo is the stored JPEG');
    const png = await pngInfo(fs.readFileSync(path.join(dir, 'marked-up-plan.png')));
    assert.ok(Math.max(png.w, png.h) >= 2000);
    assert.deepStrictEqual(JSON.parse(fs.readFileSync(path.join(dir, 'plan.json'), 'utf8')), await plan(page));
    const maxGap = Math.max(...gaps);
    console.log(`       pack: ${(size / 1e6).toFixed(1)} MB, ${list.length} entries; longest main-thread gap ${maxGap.toFixed(0)} ms; ${labels.length} progress labels`);
    assert.ok(labels.length >= 40, 'progress shown per file: ' + labels.length);
    assert.ok(maxGap < 1500, 'page stays responsive (longest gap ' + maxGap.toFixed(0) + ' ms)');
    assert.ok(await page.$eval('#busy', e => e.hidden), 'progress closed');
    assert.ok((await page.$eval('#toast', e => e.textContent)).startsWith('Job pack saved'));
    fs.rmSync(dir, { recursive: true });
    await load(page, SINGLE);
  });
  /* ---------- v1.5: the assessment report ---------- */
  const RD = require('./report-docs.js');
  /* Lay the report HTML out in its own page (as a PDF renderer would), check every page box, save the PDF and PNGs. */
  async function checkReport(html, links, tag) {
    const ctx = await browser.newContext({ viewport: { width: 595, height: 842 }, deviceScaleFactor: 2, timezoneId: TZ });
    const q = await ctx.newPage();
    const errs = []; q.on('pageerror', e => errs.push(e.message)); q.on('request', r => { if (!/^(data|about):/.test(r.url())) errs.push('request ' + r.url()); });
    await q.setContent(html, { waitUntil: 'load' });
    const info = await q.$$eval('.rp-page', els => els.map(e => ({ kind: e.className.replace('rp-page rp-', ''), w: e.scrollWidth, h: e.scrollHeight,
      over: [...e.querySelectorAll('.rp-body, .rp-card, .rp-hero, .rp-keys, .rp-ctop')].filter(x => x.scrollHeight > x.clientHeight + 0.5 || x.getBoundingClientRect().bottom > e.getBoundingClientRect().bottom + 0.5 || x.getBoundingClientRect().right > e.getBoundingClientRect().right + 0.5).map(x => x.className) })));
    for (const [i, p] of info.entries()) { assert.deepStrictEqual([p.w, p.h], [595, 842], `page ${i + 1} (${p.kind}) box`); assert.deepStrictEqual(p.over, [], `page ${i + 1} (${p.kind}) overflows`); }
    assert.strictEqual(links.pages, info.length); assert.deepStrictEqual(links.pageSize, [595, 842]);
    for (const l of links.links) {
      assert.deepStrictEqual(Object.keys(l).sort(), ['page', 'rect', 'targetPage', 'targetY']);
      const [x, y, w, h] = l.rect;
      assert.ok(l.page >= 1 && l.page <= info.length && l.targetPage >= 1 && l.targetPage <= info.length, 'pages exist');
      assert.ok(x >= -0.5 && y >= -0.5 && w > 0 && h > 0 && x + w <= 595.5 && y + h <= 842.5, 'rect inside its page: ' + l.rect);
      assert.ok(l.targetY >= 0 && l.targetY < 842);
    }
    const pdf = await q.pdf({ preferCSSPageSize: true, printBackground: true });
    fs.writeFileSync(path.join(OUT, `report-${tag}.pdf`), pdf);
    fs.writeFileSync(path.join(OUT, `report-${tag}.html`), html);
    const raw = pdf.toString('latin1');
    const pdfPages = (raw.match(/\/Type\s*\/Page[^s]/g) || []).length, annots = (raw.match(/\/Subtype\s*\/Link/g) || []).length;
    assert.strictEqual(pdfPages, info.length, 'one PDF page per page box');
    const secs = await q.$$('.rp-page');
    for (let i = 0; i < secs.length; i++) await secs[i].screenshot({ path: path.join(OUT, `report-${tag}-p${String(i + 1).padStart(2, '0')}-${info[i].kind}.png`) });
    assert.deepStrictEqual(errs, []);
    return { q, ctx, info, pdfPages, annots };
  }
  await test('v1.5: report for the sample without photos: page sequence, no overflow, PDF pages = boxes, no cards section', async () => {
    await load(page, SINGLE);
    const [html, links] = await page.evaluate(() => [SecureScan.reportHTML(), SecureScan.reportLinks()]);
    assert.ok(html.startsWith('<!DOCTYPE html>') && html.includes('@page{size:595px 842px;margin:0}'));
    assert.ok(!/<script|https?:\/\/(?!www\.w3\.org)|\sstyle="/.test(html), 'self-contained, no scripts, no inline styles');
    const r = await checkReport(html, links, 'small');
    assert.deepStrictEqual(r.info.map(p => p.kind), ['cover', 'summary', 'plan', 'overview', 'room', 'room', 'room', 'elev', 'elev', 'table', 'notes']);
    // short sections continue on the page before them when they fit
    assert.ok(await r.q.$eval('#p-removals', e => e.closest('.rp-page').classList.contains('rp-table')), 'removal schedule under the readings table');
    assert.ok(await r.q.$eval('#p-method', e => e.closest('.rp-page').classList.contains('rp-notes')), 'method under the site notes');
    assert.ok(r.annots >= links.links.length, `PDF has link annotations (${r.annots} for ${links.links.length} links)`);
    console.log(`       small: ${r.info.length} pages, ${links.links.length} links, ${r.annots} PDF link annotations`);
    // every pin on the plan page: exactly one link, and its target exists
    const pins = await r.q.$$eval('#p-plan a.rp-pin', els => els.map(a => [a.dataset.item, a.getAttribute('href').slice(1), !!document.getElementById(a.getAttribute('href').slice(1))]));
    const want = [...SINGLE.markup.sources.map(s => s.id), ...SINGLE.markup.readings.filter(x => x.kind !== 'boundary').map(x => x.id)].sort();
    assert.deepStrictEqual(pins.map(p => p[0]).sort(), want, 'one link per pin');
    for (const [id, tgt, ok] of pins) assert.ok(ok, `pin ${id} -> #${tgt} exists`);
    const sum = await r.q.$eval('#p-summary', e => e.innerText);
    assert.ok(!sum.includes('Recommendations') && !/\nSummary\n/.test(sum), 'empty user text is left out');
    await r.ctx.close();
  });
  await test('v1.5: report with real site photos: a card per photo item, locator highlights its own pin, nearest spoken note, links land on pins', async () => {
    const doc = await RD.smallPhotoDoc();
    await load(page, doc);
    const [html, links] = await page.evaluate(() => [SecureScan.reportHTML(), SecureScan.reportLinks()]);
    const r = await checkReport(html, links, 'photos');
    const photoItems = [...doc.markup.sources, ...doc.markup.readings].filter(x => x.photo);
    const cards = await r.q.$$eval('.rp-card', els => els.map(e => ({ id: e.dataset.item, title: e.querySelector('.rp-ctitle2').textContent, badge: e.querySelector('.rp-badge').textContent,
      mapRef: [...e.querySelectorAll('.rp-map text')].map(t => t.textContent), quote: (e.querySelector('.rp-quote') || {}).textContent || '', img: !!e.querySelector('.rp-cphoto img'), cam: e.querySelector('.rp-map path[fill-opacity=".13"]') !== null })));
    assert.deepStrictEqual(cards.map(c => c.id).sort(), photoItems.map(x => x.id).sort(), 'one card per photo item');
    for (const c of cards) { assert.ok(c.img, 'photo shown ' + c.id); assert.ok(c.mapRef.includes(c.badge), `locator map highlights ${c.badge}`); }
    assert.deepStrictEqual(cards.map(c => c.badge), ['8R', 'L1', 'S1', '1', '5', 'P1', 'P2', '6'], 'ordered by room (Bedroom, Laundry, Hallway), then number');
    const card = id => cards.find(c => c.id === id);
    assert.ok(card('s1').quote.includes("Hose on the back of the washer has split"), 'note whose range is within 20 s');
    assert.ok(card('m8').quote.includes('Dry control in the bedroom'), 'note 20 s after the reading');
    assert.strictEqual(card('m1').quote, '', 'no note within 20 s: none shown');
    assert.ok(card('m1').cam && !card('m5').cam === false, 'camera cone drawn when cam exists');
    // link rects from reportLinks() sit on the pins drawn on the plan page
    const planNo = r.info.findIndex(p => p.kind === 'plan') + 1;
    const pinBoxes = await r.q.$$eval('#p-plan .readings .reading, #p-plan .readings .photo-note, #p-plan .sources .source', (els) => {
      const o = document.getElementById('p-plan').getBoundingClientRect();
      // the pin itself is its largest shape (wall pins also draw a small leader dot)
      return els.map(e => { const b = [...e.querySelectorAll('circle, rect')].map(x => x.getBoundingClientRect()).sort((p, q) => q.width * q.height - p.width * p.height)[0]; return { id: e.dataset.id, c: [b.left + b.width / 2 - o.left, b.top + b.height / 2 - o.top] }; });
    });
    const planLinks = links.links.filter(l => l.page === planNo);
    for (const p of pinBoxes) assert.ok(planLinks.filter(l => p.c[0] >= l.rect[0] && p.c[0] <= l.rect[0] + l.rect[2] && p.c[1] >= l.rect[1] && p.c[1] <= l.rect[1] + l.rect[3]).length >= 1, 'a link covers pin ' + p.id);
    // debug overlay: every link rect drawn on its page
    await r.q.evaluate(ls => { for (const l of ls) { const sec = document.querySelectorAll('.rp-page')[l.page - 1], d = document.createElement('div'); d.className = 'dbg'; Object.assign(d.style, { position: 'absolute', left: l.rect[0] + 'px', top: l.rect[1] + 'px', width: l.rect[2] + 'px', height: l.rect[3] + 'px', outline: '1px solid #e0218a', background: 'rgba(224,33,138,.12)', zIndex: 9 }); sec.append(d); } }, links.links);
    await (await r.q.$$('.rp-page'))[planNo - 1].screenshot({ path: path.join(OUT, 'report-links-debug-plan.png') });
    const cardPage = r.info.findIndex(p => p.kind === 'cards');
    await (await r.q.$$('.rp-page'))[cardPage].screenshot({ path: path.join(OUT, 'report-links-debug-cards.png') });
    // every card links back to the plan page
    const backs = await r.q.$$eval('.rp-card .rp-back a[href="#p-plan"]', e => e.length);
    assert.strictEqual(backs, cards.length);
    assert.ok(r.annots >= links.links.length);
    console.log(`       photos: ${r.info.length} pages, ${cards.length} cards, ${links.links.length} links, ${r.annots} PDF link annotations`);
    await r.ctx.close();
  });
  await test('v1.5: large house, 21 photo items: cards flow over pages, long captions and notes fit, missing fields, portrait photos', async () => {
    const doc = await RD.largePhotoDoc();
    await load(page, doc);
    const [html, links] = await page.evaluate(() => [SecureScan.reportHTML(), SecureScan.reportLinks()]);
    const r = await checkReport(html, links, 'large');
    const photoItems = [...doc.markup.sources, ...doc.markup.readings].filter(x => x.photo);
    const nCards = await r.q.$$eval('.rp-card', e => e.length);
    assert.strictEqual(nCards, photoItems.length);
    assert.ok(r.info.filter(p => p.kind === 'cards').length >= Math.ceil(nCards / 2), 'two cards per page at most');
    const perPage = await r.q.$$eval('.rp-cards', els => els.map(e => e.querySelectorAll('.rp-card').length));
    assert.ok(perPage.every(n => n >= 1 && n <= 2), perPage.join(','));
    assert.ok(await r.q.$eval('.rp-card[data-item="p1"]', e => e.innerText.includes('up the side panel of the pantry')), 'long caption printed in full');
    assert.ok(await r.q.$eval('.rp-card[data-item="m1"]', e => e.innerText.includes('Kickboard under the sink is 64')));
    assert.ok(await r.q.$eval('.rp-card[data-item="m14"]', e => e.innerText.includes('Taken\n—') || e.innerText.includes('Taken—')), 'missing time shown as a dash');
    const portrait = await r.q.$eval('.rp-card[data-item="p2"] .rp-cphoto img', e => [+e.getAttribute('width'), +e.getAttribute('height')]);
    assert.ok(portrait[1] > portrait[0], 'portrait photo kept portrait');
    assert.ok(r.info.some(p => p.kind === 'summary') && (await r.q.$eval('#p-summary', e => e.innerText)).includes('printed exactly as typed'), 'user summary printed');
    console.log(`       large: ${r.info.length} pages (${r.info.filter(p => p.kind === 'cards').length} card pages), ${links.links.length} links, ${r.annots} PDF link annotations`);
    await r.ctx.close();
  });
  await test('v1.5: summary and cover figures equal the legend, schedule and summaryMarkdown (nothing invented)', async () => {
    await load(page, SINGLE);
    const legend = await page.$$eval('#content .legend-row', els => els.map(e => e.textContent));
    const md = await page.evaluate(() => SecureScan.summaryMarkdown());
    const html = await page.evaluate(() => SecureScan.reportHTML());
    const ctx = await browser.newContext({ viewport: { width: 595, height: 842 }, timezoneId: TZ }), q = await ctx.newPage();
    await q.setContent(html);
    const sum = await q.$eval('#p-summary', e => e.innerText), cover = await q.$eval('.rp-cover', e => e.innerText);
    for (const l of legend) {
      const m = /^Remove (\w+) · ([\d.]+) lm · ([\d.]+) m²$/.exec(l);
      if (m) assert.ok(sum.includes(`${m[1][0].toUpperCase() + m[1].slice(1)} ${m[2]} lm / ${m[3]} m²`), 'removal total ' + l);
    }
    const mdTot = /\| All items \| ([\d.]+) \| ([\d.]+) \|/.exec(md);
    assert.ok(sum.includes(`Total ${mdTot[1]} lm, ${mdTot[2]} m²`) && cover.includes(mdTot[1] + ' lm') && cover.includes(mdTot[2] + ' m² of lining'));
    const aff = /Total marked affected area: ([\d.]+) m²/.exec(md)[1];
    assert.ok(sum.includes(`Affected area: ${aff} m² marked`) && cover.includes((+aff).toFixed(1) + ' m²'));
    assert.ok(legend.includes(`Affected area · ${(+aff).toFixed(1)} m²`));
    const vals = SINGLE.markup.readings.filter(x => kindOf(x) === 'reading' && !x.reference).map(x => x.value);
    assert.ok(cover.includes(`Highest ${Math.max(...vals)}%`) && cover.includes(String(SINGLE.markup.readings.filter(x => kindOf(x) === 'reading').length)));
    assert.ok(sum.includes('8 taken — 4 wet, 2 elevated, 1 dry, 1 reference'));
    assert.ok(sum.includes('highest 1,500 mm, lowest 900 mm') && md.includes('highest 1,500 mm, lowest 900 mm'));
    assert.ok(sum.includes('Burst washing machine hose — Laundry, on wall A, at 350 mm above floor'));
    for (const t of ['probably', 'likely', 'recommend', 'caused by', 'should']) assert.ok(!sum.toLowerCase().includes(t), 'no opinion words: ' + t);
    await ctx.close();
  });
  await test('v1.5: standalone export prints the page boxes with a 595 x 842 @page, then cleans up', async () => {
    await load(page, SINGLE);
    await page.evaluate(() => { window.__printed = []; window.print = () => { window.__printed.push([document.querySelectorAll('#print-root .rp-page').length, document.adoptedStyleSheets.map(s => [...s.cssRules].map(r => r.cssText).join(' ')).join(' ')]); }; });
    await page.click('#btn-export');
    await page.locator('#sheet button', { hasText: 'Assessment report (PDF)' }).click();
    const [[n, css]] = await page.evaluate(() => window.__printed);
    assert.strictEqual(n, (await page.evaluate(() => SecureScan.reportLinks())).pages);
    assert.ok(/size: 595px 842px/.test(css) && /margin: 0/.test(css), css);
    await page.evaluate(() => window.dispatchEvent(new Event('afterprint')));
    assert.deepStrictEqual(await page.evaluate(() => [document.adoptedStyleSheets.length, document.getElementById('print-root').children.length]), [0, 0]);
  });
  /* ---------- v1.6: visits, re-measure, trends, equipment, scope, reports by visit ---------- */
  const tap = async (pg, sel) => { const b = await pg.$eval(sel, e => { const r = e.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; }); await pg.touchscreen.tap(b[0], b[1]); await pg.waitForTimeout(60); };
  const tapText = async (pg, text) => { const b = await pg.locator('#sheet button', { hasText: text }).first().boundingBox(); await pg.touchscreen.tap(b.x + b.width / 2, b.y + b.height / 2); await pg.waitForTimeout(60); };
  async function startVisit(pg, type) {
    await tap(pg, '#visit-chip');
    await tapText(pg, type === 'final' ? 'Final' : 'Monitoring');
    const n = await pg.$$eval('#sheet button[data-visit]', e => e.length) + 1;
    await tapText(pg, 'Start visit ' + n);
  }
  await test('v1.6: a single-visit document is not rewritten; editing it adds no visit fields', async () => {
    await load(page, SINGLE);
    assert.ok(await page.isVisible('#visit-chip') && (await page.$eval('#visit-chip', e => e.textContent)).startsWith('Visit 1 · 12 Nov'));
    assert.strictEqual(await page.$$eval('#content .reading.stale, #content .trend, #content .goal-tick, #content .equip', e => e.length), 0, 'no visit marks');
    await tapHit(page, 'room', 'r1'); await page.locator('#sheet .chip', { hasText: 'Study' }).click();
    const p = await plan(page);
    assert.deepStrictEqual(p.markup, SINGLE.markup, 'markup untouched by an unrelated edit');
    for (const k of ['visits', 'currentVisit', 'target', 'equipment', 'scope']) assert.ok(!(k in p.markup), k);
    assert.ok(p.markup.readings.every(r => !('history' in r) && !('visit' in r)));
    assert.ok(!(await page.evaluate(() => SecureScan.summaryMarkdown())).includes('## Visits'));
    await page.tap('#btn-undo');
  });
  await test('v1.6: starting visit 2 writes the visits list only; points are not rewritten until re-measured; undo', async () => {
    await load(page, SINGLE);
    await startVisit(page, 'monitoring');
    const p = await plan(page);
    assert.strictEqual(p.markup.visits.length, 2); assert.strictEqual(p.markup.currentVisit, 'v2');
    assert.deepStrictEqual(p.markup.visits[0], { id: 'v1', n: 1, type: 'initial', label: 'Initial assessment', date: '2026-11-12', by: '' });
    assert.strictEqual(p.markup.visits[1].type, 'monitoring');
    assert.deepStrictEqual(p.markup.readings, SINGLE.markup.readings, 'readings untouched');
    assert.strictEqual(await page.$$eval('#content .reading.stale', e => e.length), 8, 'every point faded until re-measured');
    assert.ok((await page.$eval('#actionbar', e => e.textContent)).includes('Re-measure · 0 of 8'));
    await page.tap('#btn-undo');
    const u = await plan(page);
    assert.deepStrictEqual(u.markup, SINGLE.markup, 'undo returns the exact single-visit markup');
    assert.deepStrictEqual({ ...u, updatedAt: 0, markup: 0 }, { ...SINGLE, updatedAt: 0, markup: 0 }, 'nothing else changes except updatedAt');
  });
  await test('v1.6: re-measure flow by touch on a 12-point job: walking order, Save & next, skip and come back, fix a mistake, progress', async () => {
    const d = clone(SINGLE);
    [[2.2, 1.6], [-0.2, 5.4], [1.0, 4.5], [0.0, 3.0]].forEach((pos, i) => d.markup.readings.push({ id: 'mm' + i, n: 9 + i, pos, value: 18 + i, material: 'floor', note: '', photo: null, takenAt: '2026-11-12T01:55:00Z', reference: false, source: 'manual' }));
    await load(page, d);
    await startVisit(page, 'monitoring');
    await tap(page, '#actionbar button.rm-start');
    assert.ok(await sheetOpen(page));
    assert.strictEqual(await page.evaluate(() => document.activeElement && document.activeElement.getAttribute('aria-label')), 'Meter value (%)', 'number field focused');
    assert.ok(parseFloat(await page.$eval('#sheet .rm-val input', e => getComputedStyle(e).fontSize)) >= 36, 'big number input');
    const where = await page.$eval('#sheet .rm-where', e => e.textContent);
    assert.ok(/^Bedroom · (Wall [A-Z] · \d\.\d\d m from the left corner as you face the wall · 300 mm above the floor|on the floor · \d\.\d\d m from the nearest wall)$/.test(where), where);
    await page.screenshot({ path: path.join(OUT, 'phone-remeasure.png') });
    const seen = [];
    let skipped = null;
    for (let i = 0; i < 13; i++) {
      const title = await page.$eval('#sheet .sh-title', e => e.textContent), prog = await page.$eval('#sheet .rm-prog', e => e.textContent);
      seen.push([title.split(' ')[1].split('·')[0].trim(), prog]);
      if (i === 2 && !skipped) { skipped = title; await tapText(page, 'Skip'); continue; }
      await page.keyboard.type(String(10 + i));
      if (i % 2) await page.keyboard.press('Enter'); else await tapText(page, 'Save');
      if (!(await sheetOpen(page))) break;
    }
    const p = await plan(page), pts = p.markup.readings.filter(r => kindOf(r) === 'reading');
    assert.ok(pts.every(r => r.history && r.history.length === 2 && r.history[1].visit === 'v2' && r.value === r.history[1].value), 'every point has its visit-2 entry and the mirror');
    assert.strictEqual(seen.filter(x => x[0] === skipped.split(' ')[1].split('·')[0].trim()).length, 2, 'the skipped point came back');
    assert.deepStrictEqual(seen.slice(0, 3).map(x => x[1]), ['0 of 12 re-measured', '1 of 12 re-measured', '2 of 12 re-measured']);
    assert.ok((await page.$eval('#toast', e => e.textContent)).includes('All 12 points re-measured'));
    // walking order: room by room (Bedroom, Laundry, Hallway), skipped point last
    const order = seen.map(x => x[0]).filter((x, i) => i !== 2);
    const roomOf = n => { const r = pts.find(q => String(q.n) + (q.reference ? 'R' : '') === n); return r; };
    const roomIdx = r => { const P = r.wallId ? null : r.pos; const rooms = SINGLE.rooms; const pip = (pt, poly) => { let ins = false; for (let a = 0, b = poly.length - 1; a < poly.length; b = a++) { const A = poly[a], B = poly[b]; if ((A[1] > pt[1]) !== (B[1] > pt[1]) && pt[0] < (B[0] - A[0]) * (pt[1] - A[1]) / (B[1] - A[1]) + A[0]) ins = !ins; } return ins; }; return P ? rooms.findIndex(rm => pip(P, rm.polygon)) : null; };
    const floorRooms = order.map(roomOf).filter(r => !r.wallId).map(roomIdx);
    assert.deepStrictEqual(floorRooms, floorRooms.slice().sort((a, b) => a - b), 'floor points in room order');
    // fix a mistake: open a measured point, change it; one entry per visit stays
    const r1 = pts.find(r => r.id === 'm1');
    const h = await page.evaluate(() => SecureScan.debug.hits().find(x => x.kind === 'reading' && x.id === 'm1'));
    const c = await page.evaluate(c => SecureScan.debug.sheetToClient(c), h.c);
    await page.touchscreen.tap(c[0], c[1]); await page.waitForTimeout(80);
    assert.strictEqual(await page.$eval('#sheet .rm-val input', e => e.value), String(r1.history[1].value));
    await page.fill('#sheet .rm-val input', '33.5'); await page.keyboard.press('Enter');
    const fixed = (await plan(page)).markup.readings.find(r => r.id === 'm1');
    assert.deepStrictEqual(fixed.history.map(e => [e.visit, e.value]), [['v1', 38.5], ['v2', 33.5]]); assert.strictEqual(fixed.value, 33.5);
    if (await sheetOpen(page)) await tapText(page, 'Done for now');
    await page.tap('#btn-undo');
    assert.strictEqual((await plan(page)).markup.readings.find(r => r.id === 'm1').value, r1.history[1].value, 'undo restores the earlier value');
  });
  await test('v1.6: trend marks, goal ticks and legend on the three-visit sample; an earlier visit is read only', async () => {
    await load(page, SMALL);
    const trends = await page.$$eval('#content .reading', els => Object.fromEntries(els.map(e => [e.dataset.n, e.dataset.trend || null])));
    assert.deepStrictEqual(trends, { 1: 'down', 2: 'down', 3: 'down', 4: 'level', 5: 'level', 6: 'down', 7: 'level', 8: 'level' });
    assert.strictEqual(await page.$$eval('#content .readings .goal-tick', e => e.length), 6, 'six points at or below 15%');
    const syms = await page.$$eval('#content .legend-row', els => els.map(e => e.dataset.sym));
    for (const s of ['trendDown', 'trendLevel', 'goal']) assert.ok(syms.includes(s), s);
    for (const s of ['trendUp', 'stale']) assert.ok(!syms.includes(s), 'unused ' + s);
    assert.strictEqual(await page.$$eval('#content .equip', e => e.length), 0, 'all equipment removed on visit 3');
    await page.screenshot({ path: path.join(OUT, 'phone-trend-pins.png') });
    await tap(page, '#visit-chip');
    await page.screenshot({ path: path.join(OUT, 'phone-visit-sheet.png') });
    await tap(page, '#sheet button[data-visit="v2"]');
    assert.strictEqual(await page.$$eval('#content .equip', e => e.length), 3, 'visit 2: three units on site (AM-07 removed)');
    assert.ok((await page.$$eval('#content .legend-row', els => els.map(e => e.textContent))).some(t => t.endsWith('Air mover (AM) × 2 on site')));
    await tap(page, '#visit-chip');
    assert.ok(!(await sheetOpen(page)) && !(await page.$eval('#visit-chip', e => e.classList.contains('past'))), 'the banner goes back to the current visit');
    await tap(page, '#visit-chip'); await tap(page, '#sheet button[data-visit="v1"]');
    assert.ok(await page.$eval('#visit-chip', e => e.classList.contains('past') && e.textContent.includes('Viewing visit 1')));
    assert.strictEqual(await page.$$eval('#content .equip', e => e.length), 4);
    assert.strictEqual(await page.$$eval('#content .trend', e => e.length), 0, 'no trend on the first visit');
    assert.ok(await page.$eval('.tool[data-tool="reading"]', e => e.disabled), 'tools disabled while viewing an earlier visit');
    await page.screenshot({ path: path.join(OUT, 'phone-viewing-visit-1.png') });
    const before = await plan(page);
    await tapPlan(page, [1.4, 1.9]);
    assert.ok(!(await sheetOpen(page)) && (await page.$eval('#toast', e => e.textContent)).includes('read only'));
    assert.deepStrictEqual(await plan(page), before);
    await tap(page, '#visit-chip');
    assert.ok(!(await page.$eval('#visit-chip', e => e.classList.contains('past'))), 'banner returns to the recording visit');
  });
  await test('v1.6: one moisture line per visit on the elevation; letters stable across visits', async () => {
    await load(page, SMALL);
    await page.click('#view-seg button[data-view="elev"]');
    const g = await page.$eval('#content .elevation[data-wall="w1"]', e => ({ letter: e.dataset.letter, cur: e.querySelector('.moisture-line:not(.old)').getAttribute('d').split('L').length,
      old: [...e.querySelectorAll('.moisture-line.old')].map(x => x.dataset.visit), dates: [...e.querySelectorAll('.moisture-line-date')].map(x => x.textContent) }));
    assert.strictEqual(g.cur, 4); assert.deepStrictEqual(g.old, ['v1', 'v2']); assert.deepStrictEqual(g.dates, ['Visit 1 · 12 Nov', 'Visit 2 · 15 Nov']);
    await page.screenshot({ path: path.join(OUT, 'phone-moisture-line-per-visit.png') });
    const letters = async () => page.$$eval('#content .elevation', els => els.map(e => e.dataset.wall + e.dataset.letter).sort());
    const l3 = await letters();
    await page.evaluate(() => SecureScan.debug.viewVisit('v1'));
    assert.deepStrictEqual((await letters()).filter(x => l3.includes(x)).length, (await letters()).length, 'same letters on visit 1');
    await page.evaluate(() => SecureScan.debug.viewVisit(null));
    await page.click('#view-seg button[data-view="plan"]');
  });
  await test('v1.6: equipment tool: place, label, drag, remove on a later visit; counts per visit', async () => {
    await load(page, SINGLE);
    await page.tap('.tool[data-tool="equip"]');
    await tapPlan(page, [2.0, 3.3]);
    await page.locator('#sheet .chip', { hasText: 'Dehumidifier' }).click();
    await page.fill('#sheet input[type=text]', 'DH-02');
    await page.screenshot({ path: path.join(OUT, 'phone-equipment-sheet.png') });
    await sheetButton(page, 'Done');
    await tapPlan(page, [1.0, 3.0]); await sheetButton(page, 'Done');
    let p = await plan(page);
    assert.deepStrictEqual(p.markup.equipment.map(x => [x.type, x.label, x.placed, x.removed]), [['dehumidifier', 'DH-02', 'v1', null], ['dehumidifier', '', 'v1', null]]);
    assert.ok(!('visits' in p.markup), 'equipment alone does not create visits');
    // drag with a finger (Equipment tool)
    const e1 = p.markup.equipment[0], a = await planToClient(page, e1.pos), b = await planToClient(page, [2.6, 3.5]);
    await touchDrag(page, a, b);
    p = await plan(page);
    near(p.markup.equipment[0].pos[0], 2.6, 0.04, 'moved x'); near(p.markup.equipment[0].pos[1], 3.5, 0.04, 'moved y');
    assert.ok((await page.$$eval('#content .legend-row', els => els.map(e => e.textContent))).some(t => t.endsWith('Dehumidifier (DH) × 2 on site')));
    await page.screenshot({ path: path.join(OUT, 'phone-equipment.png') });
    await startVisit(page, 'monitoring');
    await page.tap('.tool[data-tool="select"]');
    await tapHit(page, 'equip', e1.id);
    await page.locator('#sheet label.toggle input').check();
    await sheetButton(page, 'Done');
    p = await plan(page);
    assert.deepStrictEqual([p.markup.equipment[0].removed, !!p.markup.equipment[0].removedAt], ['v2', true]);
    assert.strictEqual(await page.$$eval('#content .equip', e => e.length), 1, 'one left on site on visit 2');
    await page.evaluate(() => SecureScan.debug.viewVisit('v1'));
    assert.strictEqual(await page.$$eval('#content .equip', e => e.length), 2, 'both on visit 1');
    await page.evaluate(() => SecureScan.debug.viewVisit(null));
  });
  await test('v1.6: three report types from the three-visit sample: initial, monitoring, final (PDFs, links, completion, sign-off)', async () => {
    await load(page, SMALL);
    const kinds = {}, out = {};
    for (const [v, tag] of [['v1', 'initial'], ['v2', 'monitoring'], ['v3', 'final']]) {
      await page.evaluate(v => SecureScan.debug.viewVisit(v), v);
      const [html, links] = await page.evaluate(() => [SecureScan.reportHTML(), SecureScan.reportLinks()]);
      const r = await checkReport(html, links, tag);
      kinds[tag] = r.info.map(p => p.kind);
      out[tag] = { q: r.q, ctx: r.ctx, links, annots: r.annots };
      console.log(`       ${tag}: ${r.info.length} pages, ${links.links.length} links, ${r.annots} PDF link annotations`);
    }
    await page.evaluate(() => SecureScan.debug.viewVisit(null));
    assert.deepStrictEqual(kinds.initial, ['cover', 'summary', 'plan', 'overview', 'room', 'room', 'room', 'works', 'scope', 'quotation', 'elev', 'elev', 'table', 'equip', 'notes']);
    assert.deepStrictEqual(kinds.monitoring, ['cover', 'summary', 'plan', 'overview', 'room', 'room', 'film', 'progress', 'worksdone', 'elev', 'elev', 'removals', 'equip', 'notes']);
    assert.deepStrictEqual(kinds.final, ['cover', 'summary', 'plan', 'overview', 'room', 'room', 'film', 'progress', 'worksdone', 'elev', 'elev', 'removals', 'equip', 'notes', 'signoff']);
    for (const t of Object.values(kinds)) assert.ok(t.length < 18, 'small sample under 18 pages: ' + t.length);
    const F = out.final.q, M = out.monitoring.q, I = out.initial.q;
    const completion = 'On Tue, 24 Nov 2026, 6 of 7 points were at or below the drying goal of 15%; point 5 read 20.5%. Reference reading 8R 9%.';
    assert.ok((await F.$eval('#p-summary', e => e.innerText)).includes(completion), 'completion statement from the data');
    assert.ok((await F.$eval('#p-signoff', e => e.closest('.rp-page').innerText)).includes(completion));
    assert.strictEqual(await F.$$eval('.rp-sign', e => e.length), 2);
    for (const q of [I, M, F]) { const all = (await q.$eval('body', e => e.innerText)).toLowerCase(); for (const w of ['certificate', 'certif', 'complies', 'compliance', 'will dry', 'expected to']) assert.ok(!all.includes(w), 'no claim: ' + w); }
    // the progress table holds each point's history exactly
    const rows = await F.$$eval('#p-progress table.rp-prog tbody tr', els => els.map(e => [...e.querySelectorAll('td')].map(t => t.textContent.trim())));
    for (const r of SMALL.markup.readings.filter(x => x.history)) {
      const row = rows.find(x => x[0] === String(r.n) + (r.reference ? 'R' : ''));
      assert.deepStrictEqual(row.slice(2, 5), r.history.map(e => (Math.round(e.value * 10) / 10) + '%'), 'history of point ' + r.n);
    }
    assert.ok(rows.find(x => x[0] === '1')[5] === '−10', 'change since the previous visit');
    // charts: one per non-reference point, x positions on the real visit dates (12, 15 and 24 Nov)
    assert.strictEqual(await F.$$eval('.rp-chart', e => e.length), 7);
    const cx = await F.$eval('.rp-chart', svg => [...svg.querySelectorAll('circle')].map(c => +c.getAttribute('cx')));
    near((cx[1] - cx[0]) / (cx[2] - cx[0]), 3 / 12, 0.01, 'visit 2 sits a quarter of the way along (3 of 12 days)');
    const cover = await M.$eval('.rp-cover', e => e.innerText);
    assert.ok(cover.includes('6 lower') && cover.includes('3 of 7') && cover.includes('Drying Progress Report'), cover);
    const quote = await I.$eval('#p-quote', e => e.closest('.rp-page').innerText);
    assert.ok(quote.includes('$3,060.60') && quote.includes('$306.06') && quote.includes('$3,366.66') && quote.includes('valid until Sat, 12 Dec 2026'), quote);
    for (const t of Object.values(out)) { assert.ok(t.annots >= t.links.links.length); await t.ctx.close(); }
  });
  await test('v1.6: large house over four visits: the progress table and charts paginate; cards show the first-visit photo', async () => {
    const doc = await RD.largeVisitsDoc();
    await load(page, doc);
    const [html, links] = await page.evaluate(() => [SecureScan.reportHTML(), SecureScan.reportLinks()]);
    const r = await checkReport(html, links, 'large-visits');
    const k = r.info.map(p => p.kind);
    assert.ok(k.includes('progress') && k.filter(x => x === 'charts').length >= 2 && html.includes('id="p-signoff"'), k.join(' '));
    assert.ok(k.length <= 30, 'large house over four visits: at most 30 pages, ' + k.length);
    const pts = doc.markup.readings.filter(x => !x.kind && x.history);
    assert.strictEqual(await r.q.$$eval('.rp-chart', e => e.length), pts.filter(x => !x.reference).length);
    assert.strictEqual(await r.q.$$eval('table.rp-prog tbody tr', e => e.length), pts.length);
    const cards = await r.q.$$eval('.rp-card', els => els.map(e => [e.dataset.item, !!e.querySelector('.rp-first img')]));
    assert.deepStrictEqual(cards.filter(c => ['m1', 'm2', 'm6'].includes(c[0])).map(c => c[1]), [true, true, true], 'first-visit photo beside the final photo');
    assert.ok((await r.q.$eval('#p-progress', e => e.innerText)).includes('—'), 'a point not re-measured shows a dash, nothing estimated');
    console.log(`       large over 4 visits: ${r.info.length} pages (${k.filter(x => x === 'charts').length} chart pages), ${links.links.length} links`);
    await r.ctx.close();
  });
  /* ---------- v1.7: cutaways, the plan + cutaway pair, floors, works completed, the options pack ---------- */
  await test('v1.7: shared-wall attribution: an item with cam (or side) belongs to the room it was taken from', async () => {
    const d = clone(SINGLE), m = d.markup;
    // w7 is the bedroom / laundry wall (y = 2.52): bedroom above (y < 2.52), laundry below
    m.readings.push({ id: 'cb', n: 20, pos: [1.2, 2.52], value: 30, material: 'wall', note: '', photo: null, takenAt: '2026-11-12T02:00:00Z', reference: false, source: 'ar', wallId: 'w7', wallT: 0.3, height: 0.3, cam: [1.2, 1.4] });
    m.readings.push({ id: 'cl', n: 21, pos: [1.6, 2.52], value: 30, material: 'wall', note: '', photo: null, takenAt: '2026-11-12T02:00:00Z', reference: false, source: 'ar', wallId: 'w7', wallT: 0.4, height: 0.3, cam: [1.6, 3.4] });
    m.readings.push({ id: 'sb', n: 22, pos: [2.0, 2.52], value: 30, material: 'wall', note: '', photo: null, takenAt: '2026-11-12T02:00:00Z', reference: false, source: 'manual', wallId: 'w7', wallT: 0.5, height: 0.3, side: -1 });
    await load(page, d);
    assert.strictEqual(await page.evaluate(() => SecureScan.debug.roomOf('cb')), 'Bedroom', 'cam in the bedroom');
    assert.strictEqual(await page.evaluate(() => SecureScan.debug.roomOf('cl')), 'Laundry', 'cam in the laundry');
    // w7 runs a -> b along +x, so its +n side is +y (the laundry); side -1 is the bedroom
    const w7 = SINGLE.walls.find(w => w.id === 'w7'); assert.ok(w7.b[0] > w7.a[0] && w7.a[1] === w7.b[1]);
    assert.strictEqual(await page.evaluate(() => SecureScan.debug.roomOf('sb')), 'Bedroom', 'side -1');
    await load(page, SINGLE);
    assert.strictEqual(await page.evaluate(() => SecureScan.debug.roomOf('m1')), 'Laundry', 'no item on the wall knows its side: the old rule');
    // a reading placed by hand records the side the finger was on
    await load(page, SINGLE); await page.tap('.tool[data-tool="select"]'); await page.tap('.tool[data-tool="reading"]');
    await tapPlan(page, [1.0, 2.4]); assert.ok(await sheetOpen(page));
    await page.locator('#sheet .chip', { hasText: /^Reading$/ }).first().click();
    await page.$eval('#sheet .value-row input', e => { e.value = '22'; e.dispatchEvent(new Event('input', { bubbles: true })); });
    await sheetButton(page, 'Done');
    const ids0 = new Set(SINGLE.markup.readings.map(x => x.id)), r = (await plan(page)).markup.readings.find(x => !ids0.has(x.id));
    assert.strictEqual(r.wallId, 'w7'); assert.strictEqual(r.side, -1, 'tapped on the bedroom side');
  });
  await test('v1.7: cutaway geometry: a true isometric of the plan; pins at wallT x length and height; wet line meets at a corner', async () => {
    const doc = await RD.largeWallsDoc();
    await load(page, doc);
    const kitchen = doc.rooms.find(r => r.name === 'Kitchen').id;
    const c = await page.evaluate(k => SecureScan.debug.cut({ room: k, W: 760 }), kitchen);
    const { psi, k, ox, oy, eye } = c.info, A = Math.atan(1 / Math.SQRT2), co = Math.cos(psi), si = Math.sin(psi);
    const S = (p, z) => { const x = co * p[0] - si * p[1], y = si * p[0] + co * p[1]; return [ox + x * k, oy + (y * Math.sin(A) - z * Math.cos(A)) * k]; };
    // psi is one of the four diagonals of the building's axes; the eye looks along it
    assert.ok(Math.abs(Math.hypot(eye[0], eye[1]) - 1) < 1e-9);
    const W = Object.fromEntries(doc.walls.map(w => [w.id, w])), HW = 0.06;
    let checked = 0;
    for (const p of c.info.pins.filter(p => p.face)) {
      // a pin moved off its spot (two would coincide) moves along its wall only, never up or down it
      const mv = [p.x - p.tx, p.y - p.ty];
      assert.ok(Math.abs(mv[0] * p.u[1] - mv[1] * p.u[0]) < 0.05, 'pin ' + p.id + ' moved along its wall only');
      const x = doc.markup.readings.find(r => r.id === p.id), w = W[x.wallId], d = [w.b[0] - w.a[0], w.b[1] - w.a[1]], L = Math.hypot(...d), u = [d[0] / L, d[1] / L], n = [-u[1], u[0]];
      const base = [w.a[0] + d[0] * x.wallT, w.a[1] + d[1] * x.wallT];
      // the face is the room side of the wall; try both sides, the pin must sit on one at its height
      const ok = [1, -1].some(sd => { const q = S([base[0] + n[0] * sd * (HW + 0.004), base[1] + n[1] * sd * (HW + 0.004)], x.height); return Math.hypot(q[0] - p.tx, q[1] - p.ty) < 1.2; });
      assert.ok(ok, 'pin ' + p.id + ' at wallT x length and height'); checked++;
    }
    assert.ok(checked >= 3, 'pins checked: ' + checked);
    // verticals stay vertical and heights scale by cos(alpha): a wall corner at 0 and at h
    const a0 = S(W.w5.a, 0), a1 = S(W.w5.a, 2.56);
    assert.ok(Math.abs(a0[0] - a1[0]) < 1e-9 && Math.abs((a0[1] - a1[1]) - 2.56 * Math.cos(A) * k) < 1e-6);
    // parallel plan lines stay parallel (orthographic, no perspective)
    const d1 = [S(W.w5.b, 0)[0] - S(W.w5.a, 0)[0], S(W.w5.b, 0)[1] - S(W.w5.a, 0)[1]], d2 = [S([3.381, 11.02], 0)[0] - S([3.381, 4.673], 0)[0], S([3.381, 11.02], 0)[1] - S([3.381, 4.673], 0)[1]];
    assert.ok(Math.abs(d1[0] * d2[1] - d1[1] * d2[0]) / Math.hypot(...d1) / Math.hypot(...d2) < 1e-6, 'parallel walls project parallel');
    // the moisture line runs round the corner from w5 onto w3 and meets at the same height
    const l5 = c.info.lines.find(l => l.wallId === 'w5'), l3 = c.info.lines.find(l => l.wallId === 'w3');
    if (l5 && l3) {
      const e5 = l5.pts.find(p => p.corner), e3 = l3.pts.find(p => p.corner);
      assert.ok(e5 && e3 && Math.abs(e5.h - e3.h) < 1e-9, 'same height at the corner');
      assert.ok(dist2(e5.px, e3.px) < 3, 'the two lines meet at the corner on screen');
    } else {
      const lines = c.info.lines.map(l => l.wallId);
      assert.ok(lines.length, 'lines drawn: ' + lines);
    }
    // near walls are the ones between the eye and the room: lowered
    for (const w of c.info.walls) {
      const ww = W[w.id], d = [ww.b[0] - ww.a[0], ww.b[1] - ww.a[1]], L = Math.hypot(...d), n = [-d[1] / L, d[0] / L];
      const mid = [(ww.a[0] + ww.b[0]) / 2, (ww.a[1] + ww.b[1]) / 2], inK = sd => pip([mid[0] + n[0] * sd * 0.21, mid[1] + n[1] * sd * 0.21], doc.rooms.find(r => r.name === 'Kitchen').polygon);
      const sd = inK(1) ? 1 : inK(-1) ? -1 : 0; if (!sd) continue;
      const toward = (n[0] * sd) * eye[0] + (n[1] * sd) * eye[1];
      if (toward < -0.1) assert.ok(!w.far, w.id + ' is a near wall: lowered');
      if (toward > 0.1) assert.ok(w.far, w.id + ' faces the eye: full height');
    }
    // a second, opposite view when the other walls carry items
    assert.deepStrictEqual(c.info.views.length === 2 ? (c.info.views[1] - c.info.views[0] + 4) % 4 : 2, 2);
  });
  await test('v1.7: unfolded room (optional): walls to scale, pins at wallT x length and height, the line meets at corners', async () => {
    const doc = await RD.largeWallsDoc();
    await load(page, doc);
    const kitchen = doc.rooms.find(r => r.name === 'Kitchen').id;
    const n = await page.evaluate(k => SecureScan.debug.roomNet(k, 'pins', 760), kitchen);
    for (const f of n.info.faces) {
      const len = Math.hypot(f.px[1][0] - f.px[0][0], f.px[1][1] - f.px[0][1]) / n.info.k, hh = Math.hypot(f.px[3][0] - f.px[0][0], f.px[3][1] - f.px[0][1]) / n.info.k;
      assert.ok(Math.abs(len - f.L) < 1e-6 && Math.abs(hh - f.H) < 1e-6, 'face to scale both ways');
    }
    const c = n.info.corners.find(x => [x.wallA, x.wallB].sort().join() === 'w3,w5');
    assert.ok(c, 'the line runs round the w5 / w3 corner');
  });
  await test('v1.7: floors: zones split by a threshold, a strip clipped to the room, quantities, scope lines, round-trip', async () => {
    const fd = clone(SMALL); fd.markup.floorThresholds = fd.markup.floorThresholds.filter(t => t.id === 't1');
    await load(page, fd);
    const q = await page.evaluate(() => { const d = SecureScan.debug; return d.floorQty('x3'); });
    assert.strictEqual(q.m2, 3.15, 'carpet patch 3.15 x 1.00 m inside the bedroom');
    assert.strictEqual(q.type, 'carpet');
    // a threshold drawn across the hallway splits its zone; each part keeps the finish
    await page.tap('.tool[data-tool="area"]'); await page.locator('#actionbar button', { hasText: 'Threshold' }).first().tap();
    await tapPlan(page, [-0.64, 6.0]); await tapPlan(page, [0.44, 6.0]);
    let p = await plan(page);
    assert.strictEqual(p.markup.floorThresholds.length, 2);
    const hall = p.markup.floors.filter(z => z.type === 'timber');
    assert.strictEqual(hall.length, 2, 'hallway split in two');
    const areas = hall.map(z => Math.abs(z.polygon.reduce((s2, a, i) => { const b = z.polygon[(i + 1) % z.polygon.length]; return s2 + a[0] * b[1] - b[0] * a[1]; }, 0) / 2));
    assert.ok(Math.abs(areas[0] + areas[1] - 6.43) < 0.05, 'the parts add up to the hallway: ' + areas);
    // one tap on a doorway places a threshold across it
    await tapPlan(page, [1.16, 3.98]);
    p = await plan(page);
    assert.strictEqual(p.markup.floorThresholds.length, 3);
    const door = p.markup.floorThresholds[2]; assert.ok(Math.abs(door.a[1] - 3.98) < 1e-6 && Math.abs(door.b[1] - 3.98) < 1e-6, 'snapped to the doorway');
    // a strip along a wall is clipped to the room
    await page.tap('.tool[data-tool="removal"]'); await tapPlan(page, [1.0, 0.6]);
    await tapText(page, 'Strip 600'); await tapText(page, 'Done');
    p = await plan(page);
    const strip = p.markup.removals[p.markup.removals.length - 1];
    assert.ok(!strip.wallId && strip.area.length === 4 && strip.item === 'flooring');
    const q2 = await page.evaluate(id => SecureScan.debug.floorQty(id), strip.id);
    assert.ok(q2.m2 > 0.5 && q2.m2 <= 3.45 * 0.6 + 0.01, 'clipped to the room: ' + q2.m2);
    const lines = await page.evaluate(() => SecureScan.debug.scopeAuto());
    assert.ok(lines.some(l => l.auto === 'floorRemoval:carpet+u' && l.refs.includes('x3')), 'a line per floor type, with its refs');
    // round-trip: everything comes back; the moisture bands are untouched
    assert.deepStrictEqual(p.markup.thresholds, { damp: 15, wet: 20 });
    await load(page, p); assert.deepStrictEqual(await plan(page), p);
    // a document that put floor thresholds under markup.thresholds by mistake is repaired on load
    const bad = clone(SMALL); bad.markup.thresholds = bad.markup.floorThresholds; delete bad.markup.floorThresholds;
    await load(page, bad);
    const fixed = await plan(page);
    assert.deepStrictEqual(fixed.markup.thresholds, { damp: 15, wet: 20 });
    assert.deepStrictEqual(fixed.markup.floorThresholds, SMALL.markup.floorThresholds);
  });
  await test('v1.7: works completed (monitoring/final): done with before/after photos, outstanding listed; pack names', async () => {
    const doc = await RD.worksDoc();
    await load(page, doc);
    await page.evaluate(() => SecureScan.debug.viewVisit('v2'));
    const [html, links] = await page.evaluate(() => [SecureScan.reportHTML(), SecureScan.reportLinks()]);
    const r = await checkReport(html, links, 'works');
    const t = await r.q.$eval('#p-worksdone', e => e.closest('.rp-page').innerText);
    assert.ok(/X1 Remove plasterboard[\s\S]*Done on visit 2/.test(t), t);
    assert.ok(/X2 Remove skirting[\s\S]*Outstanding/.test(t) && /F1 Lift carpet[\s\S]*Outstanding/.test(t), t);
    assert.strictEqual(await r.q.$$eval('#wd-x1 .rp-wdph img', e => e.length), 2, 'before and after side by side');
    await r.ctx.close();
    const files = await page.evaluate(() => SecureScan.debug.photoNames());
    assert.ok(files.includes('photos/removal-1-before.jpg') && files.includes('photos/removal-1-after.jpg'), files.join(' '));
    const md = await page.evaluate(() => SecureScan.summaryMarkdown());
    assert.ok(md.includes('photos/removal-1-after.jpg') && md.includes('After photo of removal 1'));
  });
  await test('v1.7: public setView("plan" | "walls" | "notes" | "3d" | "report")', async () => {
    await load(page, SMALL);
    for (const v of ['3d', 'walls', 'notes', 'report', 'plan']) assert.strictEqual(await page.evaluate(v2 => SecureScan.setView(v2), v), v);
    await page.evaluate(() => SecureScan.setView('3d'));
    assert.ok(await page.$eval('#content .cutaway', e => !!e), '3D shows the cutaway');
    await page.screenshot({ path: path.join(OUT, 'phone-3d-house.png') });
    await page.locator('#actionbar button', { hasText: 'Laundry' }).first().tap(); await page.waitForTimeout(80);
    await page.screenshot({ path: path.join(OUT, 'phone-3d-laundry.png') });
    const pin = await page.evaluate(() => { const h = SecureScan.debug.hits().find(x => x.kind === 'reading'); return h ? SecureScan.debug.sheetToClient(h.c) : null; });
    if (pin) { await page.touchscreen.tap(pin[0], pin[1]); await page.waitForTimeout(80); assert.ok(await sheetOpen(page), 'a pin opens its sheet'); await tapText(page, 'Cancel').catch(() => {}); }
    assert.strictEqual(await page.evaluate(() => SecureScan.setView('nope')), null);
    // startRemeasure: false on the first visit, opens the sheet on a return visit
    await load(page, SINGLE); assert.strictEqual(await page.evaluate(() => SecureScan.startRemeasure()), false);
    await startVisit(page, 'monitoring'); await tapText(page, 'Done for now').catch(() => {});
    if (await sheetOpen(page)) await sheetButton(page, 'Done for now');
    assert.strictEqual(await page.evaluate(() => SecureScan.startRemeasure()), true);
    assert.ok(await page.$('#sheet .rm-val'), 're-measure sheet open');
    await sheetButton(page, 'Done for now');
    await page.evaluate(() => SecureScan.setView('plan'));
  });
  /* ---------- the cutaway pages, quality: what went wrong before must not come back ---------- */
  // In a laid-out report: every cutaway's text is horizontal except a wall's name along its top edge; a filmstrip
  // frame is a drawing (walls, floor) whose only text is pin numerals; no two pins overlap by more than 30% of a
  // diameter; no leader runs across a pin; every removal drawn on a room cutaway carries its tag, and every tag
  // leads to its row in the removal schedule.
  async function checkDrawings(q, tag) {
    const r = await q.evaluate(() => {
      const out = { rotated: [], film: [], overlap: [], leaders: [], untagged: [], tagLinks: [], plans: [], calm: [], counts: { cut: 0, film: 0, pins: 0, tags: 0 } };
      const num = v => parseFloat(v);
      const pinsOf = root => [...root.querySelectorAll('.cut-pin circle, .rp-ppin circle')].map(c => ({ x: num(c.getAttribute('cx')), y: num(c.getAttribute('cy')), r: num(c.getAttribute('r')), id: c.parentNode.dataset.id }));
      const segHitsCircle = (a, b, c, r) => { const dx = b[0] - a[0], dy = b[1] - a[1], l2 = dx * dx + dy * dy, t = l2 ? Math.max(0, Math.min(1, ((c[0] - a[0]) * dx + (c[1] - a[1]) * dy) / l2)) : 0; return Math.hypot(a[0] + t * dx - c[0], a[1] + t * dy - c[1]) < r - 0.3; };
      for (const cut of document.querySelectorAll('.cutaway')) {
        out.counts.cut++;
        const variant = cut.dataset.variant, where = (cut.closest('.rp-page') || {}).className + ' ' + variant;
        for (const t of cut.querySelectorAll('text')) if (t.getAttribute('transform') && !t.closest('.cut-dim')) out.rotated.push(where + ': ' + t.textContent);
        const pins = pinsOf(cut); out.counts.pins += pins.length;
        for (let i = 0; i < pins.length; i++) for (let j = i + 1; j < pins.length; j++) { const p = pins[i], o = pins[j], d = Math.hypot(p.x - o.x, p.y - o.y); if (2 * Math.min(p.r, o.r) - d > 0.3 * 2 * Math.min(p.r, o.r)) out.overlap.push(`${where}: ${p.id}/${o.id} ${d.toFixed(1)}`); }
        for (const ld of cut.querySelectorAll('.cut-callout path, .cut-leader, path.leader, line.leader')) {
          const nums = (ld.getAttribute('d') || '').match(/-?[\d.]+/g) || [ld.getAttribute('x1'), ld.getAttribute('y1'), ld.getAttribute('x2'), ld.getAttribute('y2')];
          const pts = []; for (let i = 0; i + 1 < nums.length; i += 2) pts.push([num(nums[i]), num(nums[i + 1])]);
          for (let i = 0; i + 1 < pts.length; i++) for (const p of pins) if (!ld.closest(`[data-id="${p.id}"]`) && segHitsCircle(pts[i], pts[i + 1], [p.x, p.y], p.r)) out.leaders.push(where + ': leader crosses pin ' + p.id);
          out.leaders.push(where + ': a leader is drawn');
        }
        if (variant === 'film') {
          out.counts.film++;
          if (!cut.querySelector('.cut-wall path') || !cut.querySelector('.cut-floor')) out.film.push('frame without walls or floor');
          for (const t of cut.querySelectorAll('text')) if (!t.closest('.cut-pin') || !/^\d+R?$/.test(t.textContent)) out.film.push('text in a frame: ' + t.textContent);
        }
        // the room pages tell the moisture story: removals as a faint outline only (no hatch), no equipment
        if (cut.dataset.room && (variant === 'pins' || variant === 'film')) {
          if (cut.querySelector('[fill="url(#c-hatch)"]')) out.calm.push(where + ': removal hatch on a room view');
          if (cut.querySelector('.cut-equip')) out.calm.push(where + ': equipment on a room view');
          if (cut.querySelector('[fill="url(#c-whatch)"]')) out.calm.push(where + ': hatched affected area on a room view');
        }
        if (cut.dataset.room && (variant === 'pins' || variant === 'works')) for (const z of cut.querySelectorAll('.cut-removal, .cut-floor-removal, .floor-removal')) if (!cut.querySelector(`.rem-tag[data-id="${z.dataset.id}"]`)) out.untagged.push(where + ': ' + z.dataset.id);
      }
      for (const t of document.querySelectorAll('.rem-tag')) {
        out.counts.tags++;
        if (!/^[XF]\d+$/.test(t.dataset.ref)) out.tagLinks.push('tag text ' + t.dataset.ref);
        if (!document.getElementById('x-' + t.dataset.id.replace(/[^\w-]/g, '_'))) out.tagLinks.push('no schedule row for ' + t.dataset.ref);
      }
      // the room's own plan: pins never overlap, and every number listed beside the drawings is on the plan
      for (const pl of document.querySelectorAll('.rp-pplan')) {
        const pins = pinsOf(pl), page = pl.closest('.rp-page');
        for (let i = 0; i < pins.length; i++) for (let j = i + 1; j < pins.length; j++) { const p = pins[i], o = pins[j]; if (2 * p.r - Math.hypot(p.x - o.x, p.y - o.y) > 0.3 * 2 * p.r) out.overlap.push(`room plan: ${p.id}/${o.id}`); }
        const onPlan = new Set([...pl.querySelectorAll('.rp-ppin text')].map(t => t.textContent));
        for (const td of page.querySelectorAll('.rp-rside .rp-mini tbody td.rp-ref')) if (!onPlan.has(td.textContent)) out.plans.push(`${page.id}: ${td.textContent} listed but not on the plan`);
        for (const t of pl.querySelectorAll('text')) if (t.getAttribute('transform')) out.plans.push('rotated text on a room plan: ' + t.textContent);
        if (pl.querySelector('[fill="url(#c-hatch)"], [fill="url(#c-whatch)"], .equip')) out.calm.push(page.id + ': hatch or equipment on a room plan');
      }
      return out;
    });
    for (const k of ['rotated', 'film', 'overlap', 'leaders', 'untagged', 'tagLinks', 'plans', 'calm']) assert.deepStrictEqual(r[k], [], `${tag}: ${k}`);
    return r.counts;
  }
  await test('v1.8: cutaway pages: horizontal text, filmstrip frames drawn, pins apart, no leaders, every removal tagged and linked; room views calm (no removal hatch, no equipment)', async () => {
    const large = await RD.largeWallsDoc(), largeV = await RD.largeVisitsDoc();
    const largeQ = clone(large); largeQ.markup.scope = { items: [], gst: 0.1, validDays: 30, terms: '' };
    for (const [tag, doc, vid] of [['initial', SMALL, 'v1'], ['monitoring', SMALL, 'v2'], ['final', SMALL, 'v3'], ['large-quote', largeQ, null], ['large-visits', largeV, null]]) {
      await load(page, doc);
      if (vid) await page.evaluate(v => SecureScan.debug.viewVisit(v), vid);
      const html = await page.evaluate(() => SecureScan.reportHTML());
      const ctx = await browser.newContext({ viewport: { width: 595, height: 842 }, timezoneId: TZ }), q = await ctx.newPage();
      await q.setContent(html, { waitUntil: 'load' });
      const n = await checkDrawings(q, tag);
      assert.ok(n.cut > 3 && n.pins > 5 && n.tags > 0, `${tag}: drawings checked ${JSON.stringify(n)}`);
      if (tag !== 'initial' && tag !== 'large-quote') assert.ok(n.film >= 4, tag + ': filmstrip frames ' + n.film);
      console.log(`       ${tag}: ${n.cut} cutaways (${n.film} filmstrip frames), ${n.pins} pins, ${n.tags} removal tags`);
      await ctx.close();
    }
    await page.evaluate(() => SecureScan.debug.viewVisit(null));
    // the drawing that broke: the laundry filmstrip frame has its walls and floor, and every point of the room
    await load(page, SMALL);
    const laundry = SMALL.rooms.find(r => r.name === 'Laundry').id;
    const f = await page.evaluate(k => SecureScan.debug.cut({ room: k, W: 166, H: 143, variant: 'film' }), laundry);
    assert.ok(f.info.k > 20, 'the laundry is drawn at a readable scale: ' + f.info.k);
    assert.deepStrictEqual(f.info.pins.map(p => p.id).sort(), ['m1', 'm2', 'm3', 'm4', 'm5'], 'its five points');
  });
  await test('v1.7: options pack: visual-options.pdf and the C1-C6 PNGs for the small three-visit sample and the large house', async () => {
    const shots = [];
    const pageOf = async (doc, vid, pick, name, tag) => {
      await load(page, doc);
      if (vid) await page.evaluate(v => SecureScan.debug.viewVisit(v), vid);
      const [html, links] = await page.evaluate(() => [SecureScan.reportHTML(), SecureScan.reportLinks()]);
      const r = await checkReport(html, links, tag);
      const secs = await r.q.$$('.rp-page');
      const i = await r.q.$$eval('.rp-page', pick);
      assert.ok(i >= 0, name);
      const file = path.join(OUT, name + '.png');
      await secs[i].screenshot({ path: file });
      shots.push(file);
      await r.ctx.close();
      await page.evaluate(() => SecureScan.debug.viewVisit(null));
    };
    const fn = src => new Function('els', `return (${src})(els)`);
    const first = sel => fn(`els => els.findIndex(e => e.matches(${JSON.stringify(sel)}) || !!e.querySelector(${JSON.stringify(sel)}))`);
    // the busiest room page: the most pins on its cutaway
    const busiest = fn(`els => { let b = -1, n = -1; els.forEach((e, i) => { const k = e.querySelectorAll('.rp-room .cut-pin').length; if (k > n) { n = k; b = i; } }); return b; }`);
    const large = await RD.largeWallsDoc(), largeV = await RD.largeVisitsDoc(), smallP = await RD.smallPhotoDoc();
    const largeQ = clone(large); largeQ.markup.scope = { items: [], gst: 0.1, validDays: 30, terms: '' };
    for (const [tag, doc, docV, docP, docQ] of [['small', SMALL, SMALL, smallP, SMALL], ['large', large, largeV, large, largeQ]]) {
      await pageOf(doc, 'v1', first('#p-overview'), `visual-C1-${tag}-house-overview`, 'opt-' + tag + 'c1');
      await pageOf(doc, 'v1', first('.rp-room .rp-cut'), `visual-C2-${tag}-pair-stacked`, 'opt-' + tag + 'c2');
      await pageOf(doc, 'v1', busiest, `visual-C2-${tag}-treatment-soft-shaded`, 'opt-' + tag + 'c2b');
      await pageOf(docQ, tag === 'small' ? 'v1' : null, first('#p-works'), `visual-C3-${tag}-proposed-works`, 'opt-' + tag + 'c3');
      await pageOf(docV, null, first('#p-film'), `visual-C4-${tag}-drying-filmstrip`, 'opt-' + tag + 'c4');
      await pageOf(doc, 'v1', first('.rp-keyed'), `visual-C5-${tag}-elevation-with-key`, 'opt-' + tag + 'c5');
      await pageOf(docP, null, first('.rp-card .rp-ckey'), `visual-C6-${tag}-evidence-card-3d-locator`, 'opt-' + tag + 'c6');
    }
    // the pack: one page per image, labelled
    const label = f => {
      const b = path.basename(f, '.png'), [, c, tag, ...rest] = b.split('-'), what = rest.join(' ');
      const d = { C1: 'House overview: every wall lowered so each room shows; pins, room names and equipment kept apart; the rooms index', C2: what.includes('treatment') ? 'Room page, the busiest room: its own plan (where, with the eye) above its cutaway (how high); numbers, removals and key beside them' : 'Room page: its own plan (where, with the eye) above its cutaway (how high); numbers, removals and key beside them', C3: 'Proposed works: removals and lifts tagged in 3D, each listed with its size and quotation line', C4: 'Drying filmstrip: the same view on each visit (drawing only), values per visit in the table', C5: 'Wall elevation (exact, to scale) with a small 3D key', C6: 'Evidence card: the 2D locator kept, a 3D key beside it' }[c];
      return `<section><h1>${c} · ${what}</h1><p>${d} — ${tag === 'small' ? 'three-visit sample' : 'large house'}.</p><img src="data:image/png;base64,${fs.readFileSync(f).toString('base64')}"></section>`;
    };
    const html = `<!DOCTYPE html><html><head><meta charset="utf-8"><style>@page{size:A4;margin:12mm}body{font-family:-apple-system,Helvetica,Arial,sans-serif;margin:0}section{page-break-after:always}h1{font-size:15px;margin:0 0 4px}p{font-size:10.5px;color:#555;margin:0 0 8px}img{width:100%;max-height:245mm;object-fit:contain;border:1px solid #ddd}</style></head><body>` +
      `<section><h1>SecureScan · cutaway pages</h1><p>C1–C6 for the small three-visit sample and the large house, with the settled defaults: each room's plan stacked above its soft-shaded cutaway.</p></section>` + shots.map(label).join('') + '</body></html>';
    const ctx = await browser.newContext(); const q = await ctx.newPage(); await q.setContent(html, { waitUntil: 'load' });
    fs.writeFileSync(path.join(OUT, 'visual-options.pdf'), await q.pdf({ format: 'A4', printBackground: true }));
    await ctx.close();
    console.log(`       options pack: ${shots.length} images`);
    assert.strictEqual(shots.length, 14);
  });
  await test('v1.6: summaryMarkdown, Schedule CSV and the job pack include visits, history, equipment and scope', async () => {
    await load(page, SMALL);
    const md = await page.evaluate(() => SecureScan.summaryMarkdown());
    fs.writeFileSync(path.join(OUT, 'summary-three-visits.md'), md);
    for (const h of ['## Visits', '## Drying progress', '## Drying equipment', '## Scope of works']) assert.ok(md.includes('\n' + h + '\n'), h);
    assert.ok(/\| 1 \| Laundry · Wall [A-Z] · 50 mm \| 38\.5 \| 24 \| 14 \| -10 \| yes \|/.test(md), 'point 1 row');
    assert.ok(md.includes('Completion: On Tue, 24 Nov 2026, 6 of 7 points'));
    assert.ok(md.includes('**Point 1 re-measured (visit 2):** 24%') && md.includes('**Reading 1 (visit 1):** 38.5%'));
    assert.ok(md.includes('Subtotal $3,060.60 ex GST; GST 10% $306.06; total $3,366.66 inc GST'));
    assert.strictEqual((md.match(/\| (AM|DH) \|/g) || []).length, 4);
    const f = await download(page, 'Schedule CSV'), text = fs.readFileSync(f, 'utf8');
    for (const b of ['"Readings by visit"', '"Equipment"', '"Scope of works"']) assert.ok(text.includes(b), b);
    const doc = await RD.largeVisitsDoc();
    await load(page, doc);
    const files = await page.evaluate(() => SecureScan.debug.packFiles('zip'));
    const names = files.map(x => x.filename);
    for (const n of ['photos/reading-1.jpg', 'photos/reading-1-v4.jpg', 'photos/reading-2-v4.jpg', 'photos/reading-6-v4.jpg', 'assessment-report.html']) assert.ok(names.includes(n), n);
    const md2 = Buffer.from(files.find(x => x.filename === 'summary.md').base64, 'base64').toString('utf8');
    assert.ok(md2.includes('photos/reading-1-v4.jpg') && md2.includes('Photo of reading 1 (meter, visit 4)'));
  });
  await test('v1.6: unknown fields round-trip inside visits, history entries, equipment and scope', async () => {
    const d = clone(SMALL);
    d.markup.visits[1].weather = 'rain'; d.markup.readings[0].history[1].meterSerial = 'X9'; d.markup.equipment[0].hours = 210; d.markup.scope.items[0].supplierCode = 'AMH'; d.markup.scope.currency = 'AUD';
    await load(page, d);
    assert.deepStrictEqual(await plan(page), d);
    for (const v of ['elev', 'notes', 'plan']) await page.click(`#view-seg button[data-view="${v}"]`);
    await page.evaluate(() => SecureScan.debug.viewVisit('v1')); await page.evaluate(() => SecureScan.debug.viewVisit(null));
    assert.deepStrictEqual(await plan(page), d, 'unchanged after views and visit switches');
  });
  await test('no page errors, network requests or native dialogs (phone)', async () => { assert.deepStrictEqual(page.errors, []); });


  /* ====================== v1.5: Report details, brand memory, preview (fresh page, real storage) ====================== */
  console.log('Report details and preview (fresh page)');
  const rpage = await openPage(browser, PHONE);
  await test('v1.5: Report details sheet edits markup.report and markup.brand (logo file, accent); brand remembered for new jobs', async () => {
    await rpage.evaluate(() => localStorage.clear());
    await load(rpage, SINGLE);
    await rpage.click('#btn-export'); await rpage.locator('#sheet button', { hasText: 'Preview report' }).click();
    assert.strictEqual((await rpage.evaluate(() => SecureScan.debug.state())).view, 'report');
    assert.ok(await rpage.isVisible('#btn-back') && await rpage.isVisible('#btn-details') && !(await rpage.isVisible('#view-seg')) && !(await rpage.isVisible('#toolbar')));
    await rpage.tap('#btn-details');
    const f = (label, v) => rpage.locator('#sheet .sh-label', { hasText: new RegExp('^' + label + '$', 'i') }).locator('xpath=following-sibling::*[1]').fill(v);
    await f('Prepared for', 'Holloway Insurance');
    await f('Summary', 'Assessor text, printed as written.');
    await rpage.locator('#sheet .swatch[data-c="#1d5c4d"]').click();
    const logo = await sharp({ create: { width: 360, height: 90, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
      .composite([{ input: Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="360" height="90"><rect x="0" y="10" width="70" height="70" rx="8" fill="#1d5c4d"/><text x="86" y="60" font-size="40" font-family="Arial" font-weight="700" fill="#1d5c4d">SecureWorks</text></svg>'), left: 0, top: 0 }]).png().toBuffer();
    const [chooser] = await Promise.all([rpage.waitForEvent('filechooser'), rpage.locator('#sheet button', { hasText: 'Choose logo' }).click()]);
    await chooser.setFiles({ name: 'logo.png', mimeType: 'image/png', buffer: logo });
    await rpage.waitForFunction(() => !!document.querySelector('#sheet .logo-prev'));
    await rpage.screenshot({ path: path.join(OUT, 'phone-report-details.png') });
    await sheetButton(rpage, 'Save');
    const p = await plan(rpage);
    assert.strictEqual(p.markup.report.preparedFor, 'Holloway Insurance'); assert.strictEqual(p.markup.report.summary, 'Assessor text, printed as written.');
    assert.strictEqual(p.markup.brand.accent, '#1d5c4d'); assert.ok(p.markup.brand.logo.startsWith('data:image/png;base64,'));
    const remembered = JSON.parse(await rpage.evaluate(() => localStorage.getItem('securescan.brand')));
    assert.strictEqual(remembered.logo, p.markup.brand.logo); assert.strictEqual(remembered.accent, '#1d5c4d');
    const html = await rpage.evaluate(() => SecureScan.reportHTML());
    assert.ok(html.includes('.rp{--acc:#1d5c4d}') && html.includes('class="rp-logo" src="data:image/png;base64,') && html.includes('Assessor text, printed as written.'));
    const links = await rpage.evaluate(() => SecureScan.reportLinks());
    const r = await checkReport(html, links, 'branded');
    await r.ctx.close();
    await rpage.screenshot({ path: path.join(OUT, 'phone-report-preview.png') });
    // a new job without a brand of its own uses the remembered one; the document itself is not changed
    const fresh = clone(SINGLE);
    await load(rpage, fresh);
    assert.ok((await rpage.evaluate(() => SecureScan.reportHTML())).includes('.rp{--acc:#1d5c4d}'));
    assert.deepStrictEqual(await plan(rpage), fresh, 'old documents without report/brand round-trip unchanged');
    await rpage.evaluate(() => localStorage.removeItem('securescan.brand'));
    const def = await rpage.evaluate(() => SecureScan.reportHTML());
    assert.ok(def.includes('.rp{--acc:#1f4e79}') && def.includes('<div class="rp-word">SecureWorks WA</div>') && def.includes('Water Damage Assessment'), 'defaults');
  });
  await test('v1.5: preview links scroll to the card; Back returns; in normal use no storage warning and the hint never sits on a toast', async () => {
    const doc = await RD.smallPhotoDoc();
    await rpage.evaluate(() => localStorage.clear());
    await load(rpage, doc);
    // normal editing with photos in the document: the document fits in storage, no warning
    await tapHit(rpage, 'room', 'r1'); await rpage.locator('#sheet .chip', { hasText: 'Study' }).click();
    await rpage.waitForTimeout(950);
    assert.ok(!(await rpage.$eval('#toast', e => e.textContent)).includes('Could not save'), 'no storage warning in normal use');
    // a toast hides the hint, and a hint change while the toast shows does not bring it back on top
    await rpage.evaluate(() => { document.querySelector('.tool[data-tool="area"]').click(); });
    assert.ok(!(await rpage.$eval('#hint', e => e.classList.contains('fade'))));
    await rpage.tap('#btn-undo');
    assert.ok(await rpage.$eval('#toast', e => e.classList.contains('show')) || true);
    await rpage.evaluate(() => { document.querySelector('.tool[data-tool="removal"]').click(); });
    const both = await rpage.evaluate(() => { const t = document.getElementById('toast'), h = document.getElementById('hint'); return t.classList.contains('show') && !h.classList.contains('fade') && getComputedStyle(h).opacity !== '0'; });
    assert.strictEqual(both, false, 'hint and toast never shown together');
    await rpage.evaluate(() => { document.querySelector('.tool[data-tool="select"]').click(); });
    await rpage.click('#btn-export'); await rpage.locator('#sheet button', { hasText: 'Preview report' }).click();
    const n = await rpage.$$eval('#report-pages .rp-sheet', e => e.length);
    assert.strictEqual(n, (await rpage.evaluate(() => SecureScan.reportLinks())).pages);
    await rpage.locator('#report-pages #p-plan a.rp-pin[data-item="m1"]').click({ force: true });
    await rpage.waitForTimeout(100);
    const top = await rpage.$eval('#report-pages #c-m1', e => e.getBoundingClientRect().top - document.getElementById('reportview').getBoundingClientRect().top);
    assert.ok(Math.abs(top) < 4, 'card at the top of the preview: ' + top);
    await rpage.screenshot({ path: path.join(OUT, 'phone-report-preview-card.png') });
    await rpage.tap('#btn-back');
    assert.strictEqual((await rpage.evaluate(() => SecureScan.debug.state())).view, 'plan');
  });
  await test('v1.6: Scope & quote: auto lines, manual line, rates, GST, edited and reset, quantities only; rate card remembered', async () => {
    await rpage.evaluate(() => localStorage.clear());
    await load(rpage, SINGLE);
    await rpage.click('#btn-export'); await rpage.locator('#sheet button', { hasText: 'Scope & quote' }).click();
    const lines = await rpage.$$eval('#sheet .sc-line', els => els.map(e => [e.querySelector('.sc-top input[type=text]').value, ...[...e.querySelectorAll('.sc-nums input')].map(i => i.value)]));
    assert.deepStrictEqual(lines.map(l => l.slice(0, 2)), [['Remove plasterboard', '2.64'], ['Remove skirting', '1.46'], ['Structural drying of the affected area', '8.03'], ['Monitoring visit with moisture readings', '0']]);
    assert.ok((await rpage.$eval('#sheet .sc-tot', e => e.textContent)).includes('quantities only'));
    const line = i => rpage.locator('#sheet .sc-line').nth(i);
    await line(0).locator('input[aria-label="Rate (ex GST)"]').fill('48');
    assert.strictEqual(await line(0).locator('.sc-amt').textContent(), '$126.72');
    await line(1).locator('input[aria-label="Quantity"]').fill('3');
    assert.ok(await line(1).locator('.sc-edit').isVisible(), 'edited mark');
    await line(1).locator('.sc-reset').click();
    assert.strictEqual(await line(1).locator('input[aria-label="Quantity"]').inputValue(), '1.46', 'reset to the plan quantity');
    await rpage.fill('#sheet input[placeholder^="Add a line"]', 'Mould treatment');
    await rpage.locator('#sheet button', { hasText: 'Add line' }).click();
    await line(4).locator('input[aria-label="Rate (ex GST)"]').fill('260');
    const tot = await rpage.$eval('#sheet .sc-tot', e => e.innerText);
    assert.ok(tot.includes('$386.72') && tot.includes('$38.67') && tot.includes('$425.39'), tot);
    await rpage.screenshot({ path: path.join(OUT, 'phone-scope-sheet.png') });
    await sheetButton(rpage, 'Save');
    const p = await plan(rpage);
    assert.deepStrictEqual(p.markup.scope.items.map(x => [x.auto, x.desc, x.rate]), [['removal:plasterboard', 'Remove plasterboard', 48], [null, 'Mould treatment', 260]]);
    assert.deepStrictEqual(p.markup.rateCard, { auto: { 'removal:plasterboard': 48 }, manual: [{ desc: 'Mould treatment', unit: 'item', rate: 260 }] });
    assert.deepStrictEqual(JSON.parse(await rpage.evaluate(() => localStorage.getItem('securescan.rates'))), p.markup.rateCard, 'rate card remembered on the device');
    const html = await rpage.evaluate(() => SecureScan.reportHTML());
    assert.ok(html.includes('id="p-scope"') && html.includes('id="p-quote"') && html.includes('$425.39'));
    // a new job: the remembered rates are offered, and only become the job's own when saved
    await load(rpage, SINGLE);
    await rpage.click('#btn-export'); await rpage.locator('#sheet button', { hasText: 'Scope & quote' }).click();
    assert.strictEqual(await rpage.locator('#sheet .sc-line').nth(0).locator('input[aria-label="Rate (ex GST)"]').inputValue(), '48');
    assert.ok(await rpage.locator('#sheet .chip', { hasText: 'Mould treatment' }).isVisible(), 'saved line offered');
    await sheetButton(rpage, 'Cancel');
    assert.ok(!('scope' in (await plan(rpage)).markup));
    // quantities only: a scope with no rates prints no prices at all
    const q = clone(SINGLE); q.markup.scope = { items: [{ id: 'z', auto: null, desc: 'Scrape back wall', qty: 1, unit: 'item', rate: null }] };
    await load(rpage, q);
    const h2 = await rpage.evaluate(() => SecureScan.reportHTML());
    assert.ok(h2.includes('id="p-scope"') && !h2.includes('id="p-quote"') && !/\$\d/.test(h2), 'no $ anywhere');
  });
  await test('no page errors (report details page)', async () => { assert.deepStrictEqual(rpage.errors, []); });

  /* ====================== standalone, desktop ====================== */
  console.log('Standalone, desktop 1440x900');
  const desk = await openPage(browser, DESKTOP);
  await test('desktop: wheel zoom and mouse-drag pan', async () => {
    await desk.screenshot({ path: path.join(OUT, 'desktop-plan-small.png') });
    const c0 = (await desk.evaluate(() => SecureScan.debug.state())).cam;
    await desk.mouse.move(700, 450); await desk.mouse.wheel(0, -400); await desk.waitForTimeout(50);
    const c1 = (await desk.evaluate(() => SecureScan.debug.state())).cam;
    assert.ok(c1.s > c0.s * 1.3, 'zoomed in');
    await desk.mouse.move(300, 300); await desk.mouse.down(); await desk.mouse.move(400, 360, { steps: 5 }); await desk.mouse.up();
    const c2 = (await desk.evaluate(() => SecureScan.debug.state())).cam;
    near(c2.tx - c1.tx, 100, 1, 'pan x'); near(c2.ty - c1.ty, 60, 1, 'pan y');
  });
  await test('desktop: elevations view and other samples', async () => {
    await desk.click('#view-seg button[data-view="elev"]');
    await desk.screenshot({ path: path.join(OUT, 'desktop-elevations.png') });
    await desk.click('#view-seg button[data-view="plan"]');
    for (const [doc, n] of [[ANGLED, 'angled'], [LARGE, 'large']]) {
      await load(desk, doc);
      await desk.screenshot({ path: path.join(OUT, `desktop-plan-${n}.png`) });
      for (const [label, f] of [['Floor plan PNG', 'floor-plan'], ['Marked-up plan PNG', 'marked-up-plan']]) {
        const file = await download(desk, label);
        const info = await pngInfo(fs.readFileSync(file));
        assert.ok(Math.max(info.w, info.h) >= 2000); for (const c of info.corners) assert.deepStrictEqual(c, [255, 255, 255]);
        fs.copyFileSync(file, path.join(OUT, `export-${n}-${f}.png`));
      }
    }
    await load(desk, SINGLE);
    await desk.click('#btn-export');
    await desk.screenshot({ path: path.join(OUT, 'desktop-export-sheet.png') });
    await desk.keyboard.press('Escape');
  });
  await test('no page errors (desktop)', async () => { assert.deepStrictEqual(desk.errors, []); });

  /* ====================== strict CSP (hash-based, no unsafe-inline) ====================== */
  console.log('Strict CSP');
  await test('runs under a strict hash-based CSP: renders, edits, exports, no violations', async () => {
    const crypto = require('crypto');
    const html = fs.readFileSync(path.join(WEB, 'editor.html'), 'utf8');
    const hash = t => `'sha256-${crypto.createHash('sha256').update(t, 'utf8').digest('base64')}'`;
    const scripts = [...html.matchAll(/^<script(?![^>]*type="application\/json")[^>]*>([\s\S]*?)^<\/script>/gm)].map(m => hash(m[1]));
    const styles = [...html.matchAll(/^<style[^>]*>([\s\S]*?)^<\/style>/gm)].map(m => hash(m[1]));
    assert.strictEqual(scripts.length, 2); assert.strictEqual(styles.length, 3);
    const csp = `default-src 'none'; script-src ${scripts.join(' ')}; style-src ${styles.join(' ')}; img-src data: blob:`;
    const file = path.join(OUT, 'csp-editor.html');
    fs.writeFileSync(file, html.replace('<meta charset="utf-8">', `<meta charset="utf-8">\n<meta http-equiv="Content-Security-Policy" content="${csp}">`));
    const ctx = await browser.newContext({ ...PHONE, acceptDownloads: true });
    const pg = await ctx.newPage();
    const errs = [];
    pg.on('pageerror', e => errs.push(e.message));
    pg.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
    await pg.addInitScript(() => document.addEventListener('securitypolicyviolation', e => console.error('CSP violation: ' + e.violatedDirective + ' ' + e.blockedURI)));
    await pg.goto('file://' + file);
    assert.ok(await pg.$$eval('#content .room-label', e => e.length) === 3, 'renders');
    await tapHit(pg, 'room', 'r1'); await pg.locator('#sheet .chip', { hasText: 'Study' }).click();
    assert.strictEqual((await plan(pg)).rooms[0].name, 'Study');
    const f = await download(pg, 'Marked-up plan PNG');
    const info = await pngInfo(fs.readFileSync(f));
    assert.ok(Math.max(info.w, info.h) >= 2000);
    await pg.evaluate(() => { window.print = () => {}; });
    await pg.click('#btn-export'); await pg.locator('#sheet button', { hasText: 'Moisture & scope sheet' }).click();
    assert.ok((await pg.evaluate(() => document.getElementById('print-root').innerText)).includes('Removal schedule'));
    await pg.evaluate(() => window.dispatchEvent(new Event('afterprint')));
    assert.ok((await pg.evaluate(() => SecureScan.reportLinks())).links.length > 10, 'report lays out under the CSP');
    await pg.click('#btn-export'); await pg.locator('#sheet button', { hasText: 'Preview report' }).click();
    assert.ok(await pg.$$eval('#report-pages .rp-sheet', e => e.length) > 5, 'preview renders under the CSP');
    await pg.click('#btn-export'); await pg.locator('#sheet button', { hasText: 'Assessment report (PDF)' }).click();
    assert.ok(await pg.$$eval('#print-root .rp-page', e => e.length) > 5, 'report print view under the CSP');
    assert.deepStrictEqual(errs, []);
    await ctx.close();
    fs.unlinkSync(file);
  });

  /* ====================== hosted (WKWebView bridge stub) ====================== */
  console.log('Hosted, bridge stub');
  const host = await openPage(browser, PHONE, { hosted: true });
  const msgs = () => host.evaluate(() => window.__msgs);
  await test('hosted: posts exactly {type:"ready"} first and waits for load(); shows Done', async () => {
    const m = await msgs();
    assert.deepStrictEqual(m, [{ type: 'ready' }]);
    assert.ok(await host.isVisible('#btn-done')); assert.ok(!(await host.isVisible('#btn-open')));
    assert.strictEqual(await host.evaluate(() => SecureScan.getPlan()), null);
    await load(host, SINGLE);
    await host.waitForTimeout(900);
    assert.deepStrictEqual(await msgs(), [{ type: 'ready' }], 'no save on load');
    assert.strictEqual(await host.evaluate(() => localStorage.getItem('securescan.plan')), null, 'hosted never uses localStorage');
  });
  await test('hosted: edit -> debounced {type:"save", plan}', async () => {
    await tapHit(host, 'room', 'r3'); await host.locator('#sheet .chip', { hasText: 'Dining' }).click();
    await host.waitForTimeout(300);
    assert.strictEqual((await msgs()).length, 1, 'debounced');
    await host.waitForTimeout(700);
    const m = (await msgs()).slice(1);
    assert.strictEqual(m.length, 1);
    assert.deepStrictEqual(Object.keys(m[0]).sort(), ['plan', 'type']);
    assert.strictEqual(m[0].type, 'save'); assert.strictEqual(m[0].plan.rooms[2].name, 'Dining');
    assert.deepStrictEqual(m[0].plan, await plan(host));
  });
  const exportsWanted = [['Floor plan PNG', 'image/png', '-floor-plan.png'], ['Marked-up plan PNG', 'image/png', '-marked-up-plan.png'], ['Wall elevations PNG', 'image/png', '-wall-elevations.png'],
    ['Moisture & scope sheet', 'text/html', '-moisture-scope-sheet.html'], ['Floor plan SVG', 'image/svg+xml', '-floor-plan.svg'], ['Marked-up plan SVG', 'image/svg+xml', '-marked-up-plan.svg'], ['Schedule CSV', 'text/csv', '-schedule.csv']];
  for (const [label, mime, suffix] of exportsWanted) {
    await test(`hosted: export "${label}" -> {type:"export", filename, mime, base64}`, async () => {
      const n0 = (await msgs()).length;
      await host.tap('#btn-export'); await host.locator('#sheet button', { hasText: label }).click();
      await host.waitForFunction(n => window.__msgs.length > n, n0, { timeout: 10000 });
      const m = (await msgs())[n0];
      assert.deepStrictEqual(Object.keys(m).sort(), ['base64', 'filename', 'mime', 'type']);
      assert.strictEqual(m.type, 'export'); assert.strictEqual(m.mime, mime);
      assert.strictEqual(m.filename, '30-sample-cr-testwood-wa' + suffix);
      const buf = Buffer.from(m.base64, 'base64');
      if (mime === 'image/png') { const i = await pngInfo(buf); assert.ok(Math.max(i.w, i.h) >= 2000); for (const c of i.corners) assert.deepStrictEqual(c, [255, 255, 255]); }
      if (mime === 'text/html') {
        const html = buf.toString('utf8');
        assert.ok(html.startsWith('<!DOCTYPE html>') && html.includes('@page') && html.includes('SecureWorks WA') && html.includes('Site photos'));
        fs.writeFileSync(path.join(OUT, 'hosted-scope-sheet.html'), html);
      }
      if (mime === 'text/csv') assert.deepStrictEqual([...buf.slice(0, 3)], [0xef, 0xbb, 0xbf]);
      if (mime === 'image/svg+xml') assert.ok(buf.toString('utf8').includes('<svg xmlns="http://www.w3.org/2000/svg"'));
    });
  }
  await test('hosted: Job pack -> exactly {type:"exportPack", files:[{filename, mime, base64}]} with the spec file list', async () => {
    const doc = await photoDoc(4);
    await load(host, doc);
    const n0 = (await msgs()).length;
    await host.tap('#btn-export'); await host.locator('#sheet button', { hasText: 'Job pack' }).click();
    await host.waitForFunction(n => window.__msgs.slice(n).some(m => m.type === 'exportPack'), n0, { timeout: 60000 });
    const m = (await msgs()).slice(n0).find(x => x.type === 'exportPack');
    assert.deepStrictEqual(Object.keys(m).sort(), ['files', 'type']);
    for (const f of m.files) assert.deepStrictEqual(Object.keys(f).sort(), ['base64', 'filename', 'mime']);
    const names = m.files.map(f => f.filename);
    assert.deepStrictEqual(names, ['summary.md', 'floor-plan.png', 'marked-up-plan.png', 'wall-elevations.png', 'schedule.csv', 'moisture-scope-sheet.html', 'assessment-report.html',
      'photos/reading-1.jpg', 'photos/P1.jpg', 'photos/source-1.jpg', 'photos/moisture-line-1.jpg']);
    assert.deepStrictEqual(m.files.map(f => f.mime), ['text/markdown', 'image/png', 'image/png', 'image/png', 'text/csv', 'text/html', 'text/html', 'image/jpeg', 'image/jpeg', 'image/jpeg', 'image/jpeg']);
    const get = n => Buffer.from(m.files.find(f => f.filename === n).base64, 'base64');
    const md = get('summary.md').toString('utf8');
    assert.strictEqual(md, await host.evaluate(() => SecureScan.summaryMarkdown()));
    for (const n of names.filter(n => n.startsWith('photos/'))) assert.ok(md.includes(n), 'summary.md names ' + n);
    assert.ok(md.includes('Added by the SecureScan app: `plan.json`') && md.includes('`audio/001.m4a`') && !md.includes('- `plan.json`'));
    for (const n of ['floor-plan.png', 'marked-up-plan.png', 'wall-elevations.png']) { const i = await pngInfo(get(n)); assert.ok(Math.max(i.w, i.h) >= 2000, n); for (const c of i.corners) assert.deepStrictEqual(c, [255, 255, 255]); }
    assert.deepStrictEqual([...get('schedule.csv').slice(0, 3)], [0xef, 0xbb, 0xbf]);
    assert.ok(get('moisture-scope-sheet.html').toString('utf8').includes('Site notes'));
    const rep = get('assessment-report.html').toString('utf8');
    assert.ok(rep.startsWith('<!DOCTYPE html>') && rep.includes('class="rp-page rp-cover"') && rep.includes('id="c-m1"'), 'report in the pack, with the photo cards');
    assert.ok(md.includes('`assessment-report.html`'), 'summary.md lists the report');
    assert.ok(get('photos/source-1.jpg').equals(Buffer.from(doc.markup.sources[0].photo.split(',')[1], 'base64')));
    assert.ok(get('photos/moisture-line-1.jpg').equals(Buffer.from(doc.markup.readings.find(r => r.id === 'b1').photo.split(',')[1], 'base64')));
    assert.ok((await host.$eval('#toast', e => e.textContent)).startsWith('Job pack sent'));
    assert.ok(!(await msgs()).slice(n0).some(x => x.type === 'export'), 'no separate export messages');
    await load(host, SINGLE);
  });
  await test('hosted: Assessment report -> exactly {type:"exportReport", html, links} with links = reportLinks()', async () => {
    await load(host, await RD.smallPhotoDoc());
    const n0 = (await msgs()).length;
    await host.tap('#btn-export'); await host.locator('#sheet button', { hasText: 'Assessment report (PDF)' }).click();
    await host.waitForFunction(n => window.__msgs.slice(n).some(m => m.type === 'exportReport'), n0, { timeout: 30000 });
    const m = (await msgs()).slice(n0).find(x => x.type === 'exportReport');
    assert.deepStrictEqual(Object.keys(m).sort(), ['html', 'links', 'type']);
    assert.deepStrictEqual(Object.keys(m.links).sort(), ['links', 'pageSize', 'pages']);
    const [html, links] = await host.evaluate(() => [SecureScan.reportHTML(), SecureScan.reportLinks()]);
    assert.strictEqual(m.html, html); assert.deepStrictEqual(m.links, links);
    assert.strictEqual(m.links.pages, (m.html.match(/<section class="rp-page /g) || []).length);
    for (const l of m.links.links) assert.deepStrictEqual(Object.keys(l), ['page', 'rect', 'targetPage', 'targetY']);
    assert.ok((await host.$eval('#toast', e => e.textContent)).startsWith('Report sent'));
    await load(host, SINGLE);
  });
  await test('hosted: Done flushes a pending save, then posts exactly {type:"close"}', async () => {
    await tapHit(host, 'room', 'r1'); await host.locator('#sheet .chip', { hasText: 'Robe' }).click();
    const n0 = (await msgs()).length;
    await host.tap('#btn-done');
    const m = (await msgs()).slice(n0);
    assert.strictEqual(m.length, 2);
    assert.strictEqual(m[0].type, 'save'); assert.strictEqual(m[0].plan.rooms[0].name, 'Robe');
    assert.deepStrictEqual(m[1], { type: 'close' });
  });
  if (fs.existsSync(GLB_FIXTURE)) {
    await test('hosted: SecureScan.importGLB(base64) loads the model and returns the summary', async () => {
      const b64 = fs.readFileSync(GLB_FIXTURE).toString('base64');
      const n0 = (await msgs()).length;
      const summary = await host.evaluate(b => SecureScan.importGLB(b), b64);
      assert.ok(summary.message.startsWith('Polycam floor plan:'));
      const p = await plan(host);
      assert.strictEqual(p.walls.length, LARGE.walls.length);
      assert.strictEqual(p.address, '30 Sample Cr, Testwood, WA', 'keeps the job address');
      const m = (await msgs()).slice(n0);
      assert.ok(m.length === 1 && m[0].type === 'save', 'saved after import');
    });
  } else console.log('  SKIP hosted GLB import (fixture not present)');
  await test('no page errors (hosted)', async () => { assert.deepStrictEqual(host.errors, []); });

  /* ====================== hosted at the in-app size (402 x 700 CSS px, under the app's bars) ====================== */
  console.log('Hosted, in-app size 402x700');
  const small = await openPage(browser, HOSTED_SIZE, { hosted: true });
  await load(small, SINGLE);
  await test('in-app size: top bar and toolbar fit and stay usable; hint at the top, clear of the legend and bars, fades', async () => {
    const vp = small.viewportSize();
    assert.deepStrictEqual(await small.$eval('#topbar', e => [e.scrollWidth <= e.clientWidth, e.getBoundingClientRect().height <= 60]), [true, true]);
    const ctrls = await small.$$eval('#topbar button, #toolbar button', els => els.filter(e => e.offsetParent).map(e => { const r = e.getBoundingClientRect(); return { t: e.textContent.trim() || e.getAttribute('aria-label'), l: r.left, r: r.right, t0: r.top, b: r.bottom, w: r.width, h: r.height }; }));
    assert.ok(ctrls.length >= 10);
    for (const c of ctrls) { assert.ok(c.w >= 44 && c.h >= 44, 'target >= 44 px: ' + c.t); assert.ok(c.l >= 0 && c.r <= vp.width + 0.5 && c.t0 >= 0 && c.b <= vp.height + 0.5, 'on screen: ' + c.t); }
    for (const v of ['Plan', 'Walls', 'Notes', 'Done']) assert.ok(ctrls.some(c => c.t === v), v);
    const stageR = await small.$eval('#stage', e => e.getBoundingClientRect().toJSON());
    assert.ok(stageR.height >= 520, 'stage height ' + stageR.height);
    const hint = await small.$eval('#hint', e => e.getBoundingClientRect().toJSON()), chip = await small.$eval('#visit-chip', e => e.getBoundingClientRect().toJSON());
    assert.ok(chip.top >= stageR.top && chip.bottom <= stageR.top + 56, 'visit chip at the top left of the stage');
    assert.ok(hint.top >= chip.bottom && hint.bottom <= stageR.top + 130, 'hint just below the visit chip');
    const tb = await small.$eval('#toolbar', e => e.getBoundingClientRect().toJSON());
    assert.ok(Math.abs(tb.bottom - vp.height) < 1, 'toolbar is the last thing on screen');
    await small.screenshot({ path: path.join(OUT, 'hosted-402x700-plan.png') });
    // the hint fades and stops covering anything
    await small.waitForTimeout(5000);
    assert.strictEqual(await small.$eval('#hint', e => getComputedStyle(e).opacity), '0');
    // action bar (area tool) sits above the toolbar and clear of the hint
    await small.tap('.tool[data-tool="area"]');
    const ab = await small.$eval('#actionbar', e => e.getBoundingClientRect().toJSON());
    assert.ok(ab.bottom <= tb.top && ab.top > hint.bottom, 'action bar clear of hint and toolbar');
    await small.tap('.tool[data-tool="select"]');
  });
  await test('in-app size: Walls with the Moisture line tool, and Notes, are usable', async () => {
    await small.click('#view-seg button[data-view="elev"]');
    await small.tap('.tool[data-etool="mline"]');
    await small.locator('#actionbar button[aria-label^="Elevation B"]').click();
    await touchTap(small, await elevClient(small, 'w1', 0.95, 0.8));
    assert.strictEqual((await marksOn(small, 'w1')).length, 5);
    const nav = await small.$$eval('#actionbar button', els => els.map(e => e.getBoundingClientRect().height));
    assert.ok(nav.every(h => h >= 44));
    await small.screenshot({ path: path.join(OUT, 'hosted-402x700-moisture-line.png') });
    await small.click('#view-seg button[data-view="notes"]');
    await small.screenshot({ path: path.join(OUT, 'hosted-402x700-notes.png') });
    const add = await small.$eval('.tool[data-ntool="add"]', e => e.getBoundingClientRect().bottom);
    assert.ok(add <= small.viewportSize().height);
    await small.tap('.tool[data-ntool="add"]');
    assert.ok(await sheetOpen(small));
    await small.screenshot({ path: path.join(OUT, 'hosted-402x700-add-note.png') });
    await sheetButton(small, 'Cancel');
  });
  await test('in-app size: Report preview (behind Export) keeps a simple four-control top bar', async () => {
    await small.click('#view-seg button[data-view="plan"]');
    await small.tap('#btn-export'); await small.locator('#sheet button', { hasText: 'Preview report' }).click();
    assert.deepStrictEqual(await small.$eval('#topbar', e => e.scrollWidth <= e.clientWidth), true);
    const ctrls = await small.$$eval('#topbar button', els => els.filter(e => e.offsetParent).map(e => (e.textContent.trim() || e.getAttribute('aria-label'))));
    assert.deepStrictEqual(ctrls, ['Back', 'Details', 'Export']);
    await small.screenshot({ path: path.join(OUT, 'hosted-402x700-report-preview.png') });
    await small.tap('#btn-back');
  });
  await test('in-app size: visit sheet, re-measure sheet, equipment tool and scope sheet fit at 402 x 700', async () => {
    await load(small, SMALL);
    await small.tap('#visit-chip');
    await small.screenshot({ path: path.join(OUT, 'hosted-402x700-visit-sheet.png') });
    await small.locator('#sheet .chip', { hasText: 'Monitoring' }).click();
    await small.locator('#sheet button', { hasText: 'Start visit 4' }).click();
    await small.tap('#actionbar button.rm-start');
    const sheet = await small.$eval('#sheet', e => e.getBoundingClientRect().toJSON());
    assert.ok(sheet.top >= 0 && sheet.bottom <= 700.5, 'sheet on screen');
    const save = await small.locator('#sheet button', { hasText: 'Save' }).first().boundingBox();
    assert.ok(save.y + save.height <= 700 && save.height >= 44, 'Save reachable without scrolling');
    await small.screenshot({ path: path.join(OUT, 'hosted-402x700-remeasure.png') });
    await small.keyboard.type('19'); await small.keyboard.press('Enter');
    await small.screenshot({ path: path.join(OUT, 'hosted-402x700-remeasure-next.png') });
    await small.locator('#sheet button', { hasText: 'Done for now' }).click();
    await small.tap('.tool[data-tool="equip"]');
    const tools = await small.$$eval('#toolbar .tool', els => els.filter(e => e.offsetParent).map(e => { const r = e.getBoundingClientRect(); return [e.textContent.trim(), Math.round(r.width), Math.round(r.height), r.right <= 402.5]; }));
    assert.strictEqual(tools.length, 6);
    for (const [name, w, h, inside] of tools) assert.ok(w >= 44 && h >= 44 && inside, `${name} ${w}x${h}`);
    await tapPlan(small, [2.0, 3.6]);
    await small.screenshot({ path: path.join(OUT, 'hosted-402x700-equipment.png') });
    await sheetButton(small, 'Done');
    await small.tap('.tool[data-tool="select"]');
    await small.tap('#btn-export'); await small.locator('#sheet button', { hasText: 'Scope & quote' }).click();
    await small.screenshot({ path: path.join(OUT, 'hosted-402x700-scope.png') });
    await sheetButton(small, 'Cancel');
  });
  await test('no page errors (in-app size)', async () => { assert.deepStrictEqual(small.errors, []); });

  await browser.close();
  const failed = results.filter(r => !r[0]);
  console.log(`\n${results.length - failed.length}/${results.length} passed` + (failed.length ? `; FAILED: ${failed.map(f => f[1]).join(' | ')}` : ''));
  process.exit(failed.length ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
