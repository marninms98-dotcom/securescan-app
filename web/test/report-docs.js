/* TEST-ONLY documents for the assessment report, using the owner's real site photos in reference/.
   Never shipped in editor.html. Photos are prepared as the editor stores them: oriented, 1280 px long edge,
   JPEG quality 70, as data URLs. */
'use strict';
const sharp = require('/opt/npm-tools/node_modules/sharp');
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..', '..');
const WEB = path.resolve(__dirname, '..');
const json = f => JSON.parse(fs.readFileSync(path.join(WEB, f), 'utf8'));
const cache = new Map();
async function photo(name) {
  if (!cache.has(name)) {
    const buf = await sharp(path.join(ROOT, 'reference', name)).rotate().resize(1280, 1280, { fit: 'inside' }).jpeg({ quality: 70 }).toBuffer();
    cache.set(name, 'data:image/jpeg;base64,' + buf.toString('base64'));
  }
  return cache.get(name);
}
const iso = (base, sec) => new Date(Date.parse(base) + sec * 1000).toISOString().replace(/\.\d+Z$/, 'Z');

/* The small sample with real photos on readings, photo notes, the source and one moisture-line point;
   meter values set to what the photographed meter shows; `cam` on several items. */
async function smallPhotoDoc() {
  const d = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'sample-single-visit.json'), 'utf8')), m = d.markup, R = id => m.readings.find(r => r.id === id);
  Object.assign(R('m1'), { value: 44, photo: await photo('reading-44pct-tape.jpg'), cam: [2.45, 3.6], note: 'Skirting behind washer, tape at 600' });
  Object.assign(R('m5'), { photo: await photo('moisture-skirting.jpg'), cam: [1.2, 3.55] });
  Object.assign(R('m6'), { value: 43, photo: await photo('reading-43pct-carpet.jpg'), cam: [0.1, 5.4] });
  Object.assign(R('m8'), { value: 12, photo: await photo('reading-12pct-tape.jpg'), cam: [0.9, 1.6] });
  Object.assign(R('p1'), { photo: await photo('inspection-opening.jpg'), cam: [1.4, 3.3] });
  Object.assign(R('p2'), { photo: await photo('cupboard-overview.jpg'), cam: [1.0, 3.75] });
  Object.assign(R('b1'), { photo: await photo('wall-blue-tape-marks.jpg'), cam: [2.2, 2.0] });
  Object.assign(m.sources[0], { photo: await photo('moisture-wall.jpg'), cam: [2.2, 3.7] });
  m.report = { title: 'Water Damage Assessment', preparedBy: 'Marnin, SecureWorks WA', preparedFor: 'Claims team', claimRef: 'CLM-00-000001',
    summary: '', recommendations: '', include: { roomPages: true, notes: true, readingsTable: true, method: true } };
  return d;
}

/* The large house with ~25 photo items spread over the rooms: long captions and spoken notes, missing
   fields, portrait and landscape photos, floor and wall items, a moisture line, removals. */
async function largePhotoDoc() {
  const d = json('sample-house-large.json'), m = d.markup;
  const walls = Object.fromEntries(d.walls.map(w => [w.id, w]));
  const on = (wid, t) => { const w = walls[wid]; return [+(w.a[0] + (w.b[0] - w.a[0]) * t).toFixed(3), +(w.a[1] + (w.b[1] - w.a[1]) * t).toFixed(3)]; };
  const base = '2026-11-13T01:05:00Z';
  const pics = ['reading-44pct-tape.jpg', 'reading-43pct-carpet.jpg', 'reading-64pct-cupboard.jpg', 'reading-12pct-tape.jpg', 'moisture-skirting.jpg',
    'moisture-wall.jpg', 'inspection-opening.jpg', 'room-overview.jpg', 'cupboard-overview.jpg', 'wall-blue-tape-marks.jpg'];
  const kitchenWalls = ['w5', 'w3', 'w9', 'w29', 'w36'];
  const spec = [
    // [wall or null, t, height, value, material, kind, photo index, note]
    ['w5', 0.3, 0.05, 64, 'skirting', 'reading', 2, 'Under the sink cabinet kickboard'],
    ['w5', 0.3, 0.3, 44, 'wall', 'reading', 0, ''],
    ['w5', 0.3, 0.6, 31, 'wall', 'reading', 5, ''],
    ['w5', 0.3, 0.9, 18, 'wall', 'reading', null, ''],
    ['w5', 0.3, 1.2, 12, 'wall', 'reading', 3, 'Tape held to 1200'],
    ['w3', 0.5, 0.05, 41, 'skirting', 'reading', 4, ''],
    ['w9', 0.4, 0.3, 27, 'wall', 'reading', null, ''],
    [null, [1.6, 6.2], null, 43, 'floor', 'reading', 1, 'Carpet edge at the kitchen threshold, underlay saturated when lifted at the corner'],
    [null, [2.8, 9.5], null, 22, 'floor', 'reading', null, ''],
    ['w36', 0.5, 0.05, 35, 'skirting', 'reading', 4, ''],
    ['w26', 0.2, 0.3, 9, 'wall', 'reading', 3, 'Dry control, living room, same plasterboard'],
    [null, [4.6, 12.6], null, 16, 'floor', 'reading', null, ''],
    ['w40', 0.8, 0.05, 25, 'skirting', 'reading', 4, ''],
    [null, [6.1, 9.8], null, 19, null, 'reading', 1, ''],
    ['w30', 0.6, 0.6, 14, 'wall', 'reading', 0, ''],
    [null, [1.5, 5.6], null, null, null, 'photo', 8, 'Overview — kitchen, cabinets and dishwasher pulled out, water staining visible along the full length of the kickboards and up the side panel of the pantry'],
    ['w5', 0.55, 0.4, null, null, 'photo', 6, 'Inspection opening — wall cavity behind the sink, timber bottom plate dark and wet to touch'],
    [null, [3.4, 12.3], null, null, null, 'photo', 7, 'Overview — living room'],
    [null, [8.6, 7.6], null, null, null, 'photo', 8, ''],
    ['w15', 0.3, 0.9, null, null, 'photo', 6, 'Window sill, no damage'],
    [null, [9.8, 9.5], null, null, null, 'photo', 7, 'Overview — Other 2 (hall), carpet runner lifted'],
    ['w34', 0.5, 0.3, 21, 'wall', 'reading', 0, ''],
    ['w33', 0.5, 0.05, 17, 'skirting', 'reading', 4, '']
  ];
  let n = 0, p = 0, sec = 120;
  for (const [wid, t, h, value, material, kind, pi, note] of spec) {
    sec += 47;
    const r = { id: (kind === 'photo' ? 'p' : 'm') + (kind === 'photo' ? ++p : ++n), kind: kind === 'photo' ? 'photo' : undefined, n: kind === 'photo' ? p : n,
      pos: wid ? on(wid, t) : t, value, material, note, photo: pi == null ? null : await photo(pics[pi]), takenAt: iso(base, sec), reference: value === 9, source: wid ? 'ar' : 'manual' };
    if (r.kind === undefined) delete r.kind;
    if (wid) Object.assign(r, { wallId: wid, wallT: t, height: h });
    if (material == null) delete r.material;               // missing field
    if (wid && n % 3 === 0) r.cam = [r.pos[0] + 1.1, r.pos[1] + 0.9];
    if (!wid && kind === 'photo') r.cam = [r.pos[0] - 0.9, r.pos[1] + 1.2];
    m.readings.push(r);
  }
  delete m.readings[13].takenAt;                            // a reading without a time
  // moisture line on the kitchen wall w5 (one point photographed)
  [[0.1, 1.3], [0.3, 1.25], [0.5, 1.05], [0.7, 0.8], [0.9, 0.6]].forEach(([t, h], i) => m.readings.push({ id: 'b' + (i + 1), kind: 'boundary', pos: on('w5', t), value: null, material: 'wall', note: '',
    photo: i === 2 ? null : null, takenAt: iso(base, 1400 + i * 30), height: h, wallId: 'w5', wallT: t, reference: false, source: 'ar' }));
  m.readings.find(r => r.id === 'b3').photo = await photo('wall-blue-tape-marks.jpg');
  m.sources.push({ id: 's1', pos: on('w5', 0.42), label: 'Dishwasher inlet hose split at the tap connector', takenAt: iso(base, 60), height: 0.25, wallId: 'w5', wallT: 0.42, source: 'ar', cam: [1.6, 5.9], photo: await photo('reading-64pct-cupboard.jpg') });
  const kitchen = d.rooms.find(r => r.id === 'r-kitchen');
  m.affected.push({ id: 'a1', polygon: kitchen.polygon.map(q => q.slice()), label: '' });
  m.affected.push({ id: 'a2', polygon: [[2.05, 11.04], [5.2, 11.04], [5.2, 13.1], [2.05, 13.1]], label: 'Living room carpet' });
  m.removals.push({ id: 'x1', wallId: 'w5', t0: 0, t1: 1, item: 'plasterboard', heightMm: 1200, note: '' },
    { id: 'x2', wallId: 'w3', t0: 0, t1: 1, item: 'skirting', heightMm: 100, note: '' },
    { id: 'x3', wallId: 'w36', t0: 0, t1: 1, item: 'cabinetry', heightMm: 900, note: 'Kickboards and pantry side panel' });
  m.meter = 'Ozito digital moisture meter';
  m.notes = [
    { id: 'n1', t: iso(base, 20), end: iso(base, 52), text: 'Kitchen at 18 Example Drive. The dishwasher was running overnight and the inlet hose split at the tap connector under the sink, owner found water across the kitchen floor this morning and it has run under the cabinets and into the living room carpet.', source: 'voice', audio: 'audio/001.m4a', audioOffset: 0, edited: false },
    { id: 'n2', t: iso(base, 160), end: iso(base, 175), text: 'Kickboard under the sink is 64, plasterboard 44 at 300, 31 at 600 and back to 12 by 1200.', source: 'voice', audio: 'audio/001.m4a', audioOffset: 140, edited: false },
    { id: 'n3', t: iso(base, 480), end: iso(base, 492), text: 'Carpet at the threshold is 43, underlay is saturated.', source: 'voice', audio: 'audio/001.m4a', audioOffset: 460, edited: true },
    { id: 'n4', t: iso(base, 640), end: iso(base, 650), text: 'Dry control in the living room, nine percent.', source: 'voice', audio: 'audio/001.m4a', audioOffset: 620, edited: false },
    { id: 'n5', t: iso(base, 900), text: 'Owner will move the fridge out before the crew arrives.', source: 'typed', edited: false },
    { id: 'n6', t: iso(base, 1100), end: iso(base, 1112), text: '', source: 'voice', audio: 'audio/002.m4a', audioOffset: 0, edited: false },
    { id: 'n7', t: iso(base, 1410), end: iso(base, 1440), text: 'Taped the moisture line along the kitchen wall, it sits at about 1300 at the laundry end and drops to 600 by the fridge. Photo of the tape taken.', source: 'voice', audio: 'audio/002.m4a', audioOffset: 310, edited: false }
  ];
  d.jobRef = 'HOL-55021';
  d.address = '18 Example Dr, Testvale, WA';
  m.report = { title: 'Water Damage Assessment', preparedBy: 'Marnin, SecureWorks WA', preparedFor: 'Holloway Insurance — Claims', claimRef: 'HOL-55021',
    summary: 'Water from a split dishwasher inlet hose spread across the kitchen floor, under the base cabinets and into the living room carpet.\n\nThis paragraph is the assessor\'s own text and is printed exactly as typed.',
    recommendations: 'Remove plasterboard to 1200 mm along the sink wall, remove skirting and kickboards, lift the living room carpet and underlay at the threshold, dry and recheck in 48 hours.' };
  return d;
}
/* The large house over four visits (13, 15, 19 and 27 Nov: not evenly spaced): ~25 points, most drying,
   two stalling and one rising; equipment placed on visit 1, some removed on visit 3, the rest on visit 4;
   a few points photographed again on the final visit. */
async function largeVisitsDoc() {
  const d = await largePhotoDoc(), m = d.markup;
  const extra = [[3.0, 6.0], [2.6, 7.6], [1.2, 9.6], [3.6, 13.6], [6.0, 12.8], [8.4, 4.4], [6.6, 6.6], [9.9, 8.2]];
  let n = Math.max(...m.readings.filter(r => !r.kind).map(r => r.n));
  extra.forEach((pos, i) => m.readings.push({ id: 'mx' + i, n: ++n, pos, value: 0, material: 'floor', note: '', photo: null, takenAt: '2026-11-13T01:50:00Z', reference: false, source: 'manual' }));
  const V = [['v1', 'initial', 'Initial assessment', '2026-11-13'], ['v2', 'monitoring', 'Monitoring visit', '2026-11-15'], ['v3', 'monitoring', 'Monitoring visit', '2026-11-19'], ['v4', 'final', 'Final inspection', '2026-11-27']];
  m.visits = V.map(([id, type, label, date], i) => ({ id, n: i + 1, type, label, date, by: 'Marnin' }));
  m.currentVisit = 'v4';
  m.target = { mode: 'value', value: 16 };
  const pts = m.readings.filter(r => !r.kind && r.value !== null);
  pts.forEach((r, i) => {
    const v1 = r.id.startsWith('mx') ? 18 + (i * 7) % 25 : r.value;
    const ratio = r.reference ? [1, 1, 0.98, 1] : i % 9 === 4 ? [1, 0.97, 0.96, 0.95] : i % 11 === 7 ? [1, 1.04, 1.12, 1.15] : [1, 0.74, 0.55, 0.42];
    const vals = ratio.map(k => Math.round(v1 * k * 2) / 2);
    r.history = V.map(([id, , , date], k) => ({ visit: id, value: vals[k], takenAt: (k ? date : '2026-11-13') + 'T0' + (1 + k) + ':' + String(10 + (i % 40)).padStart(2, '0') + ':00Z',
      ...(k === 0 && r.photo ? { photo: r.photo } : {}) }));
    if (r.id === 'm14') r.history.splice(3, 1);                 // not re-measured on the final visit
    r.value = r.history[r.history.length - 1].value; r.takenAt = r.history[r.history.length - 1].takenAt;
  });
  // the final visit photographs three points again
  for (const [id, pic] of [['m1', 'reading-12pct-tape.jpg'], ['m2', 'moisture-skirting.jpg'], ['m6', 'reading-43pct-carpet.jpg']]) {
    const r = m.readings.find(x => x.id === id); r.history[3].photo = await photo(pic); r.photo = r.history[3].photo;
  }
  m.equipment = [[1.4, 5.4, 'dehumidifier', 'v4'], [0.9, 6.6, 'airMover', 'v3'], [2.6, 8.3, 'airMover', 'v4'], [1.8, 10.2, 'airMover', 'v3'], [3.4, 12.2, 'airMover', 'v4'], [4.2, 12.9, 'dehumidifier', 'v4'], [2.8, 6.4, 'airScrubber', 'v3']]
    .map(([x, y, type, removed], i) => ({ id: 'e' + (i + 1), type, label: (type === 'dehumidifier' ? 'DH-0' : type === 'airMover' ? 'AM-1' : 'AS-0') + (i + 1), pos: [x, y], placed: 'v1', removed, placedAt: '2026-11-13T02:00:00Z', removedAt: removed === 'v3' ? '2026-11-19T03:00:00Z' : '2026-11-27T03:00:00Z', note: '' }));
  for (const x of m.removals) { x.status = 'done'; x.doneVisit = 'v2'; }
  m.scope = { items: [{ id: 'q1', auto: 'equipment:airMover', rate: 35 }, { id: 'q2', auto: 'equipment:dehumidifier', rate: 75 }, { id: 'q3', auto: null, desc: 'Mould treatment to the kitchen wall cavity', qty: 1, unit: 'item', rate: 260 }], gst: 0.1, validDays: 30, terms: '' };
  m.notes.push({ id: 'n20', t: '2026-11-19T02:20:00Z', text: 'Visit three. Kitchen sink wall well down. The living room threshold is still reading high, not drying.', source: 'voice', visit: 'v3', edited: false },
    { id: 'n21', t: '2026-11-27T02:05:00Z', text: 'Final visit. Most points at goal. The living room threshold has gone up again, needs investigating.', source: 'voice', visit: 'v4', edited: false });
  return d;
}
/* TEST-ONLY: the large house with realistic wall items for the unfolded room and the isometric (v1.7):
   readings at several heights on several walls, a moisture line that runs round the corner from the sink
   wall (w5) onto the angled wall (w3), removals on three kitchen walls and one living room wall, flooring
   lifted along two walls, drying equipment, and readings on the angled walls of "Other 1". */
async function largeWallsDoc() {
  const d = await largePhotoDoc(), m = d.markup;
  const walls = Object.fromEntries(d.walls.map(w => [w.id, w]));
  const on = (wid, t) => { const w = walls[wid]; return [+(w.a[0] + (w.b[0] - w.a[0]) * t).toFixed(3), +(w.a[1] + (w.b[1] - w.a[1]) * t).toFixed(3)]; };
  let n = Math.max(...m.readings.filter(r => !r.kind).map(r => r.n)), b = 5, sec = 1600;
  const add = (wid, t, h, value, material, cam) => m.readings.push({ id: 'mw' + (++n), n, pos: on(wid, t), value, material, note: '', photo: null, takenAt: `2026-11-13T01:${String(30 + (++sec % 29)).padStart(2, '0')}:00Z`, reference: false, source: 'ar', wallId: wid, wallT: t, height: h, cam });
  // angled kitchen wall w3: the line continues round the corner from w5 (which ends at 600 mm near the corner)
  add('w3', 0.3, 0.05, 38, 'skirting', [1.4, 7.2]); add('w3', 0.3, 0.3, 29, 'wall', [1.4, 7.2]); add('w3', 0.3, 0.9, 13, 'wall', [1.4, 7.2]);
  add('w3', 0.75, 0.3, 22, 'wall', [2.2, 8.4]);
  [[0.12, 0.56], [0.4, 0.5], [0.7, 0.42], [0.92, 0.38]].forEach(([t, h]) => m.readings.push({ id: 'b' + (++b), kind: 'boundary', pos: on('w3', t), value: null, material: 'wall', note: '', photo: null, takenAt: `2026-11-13T01:5${b % 10}:00Z`, height: h, wallId: 'w3', wallT: t, reference: false, source: 'ar' }));
  // pantry wall w36 and the wall above the kitchen bench w9
  add('w36', 0.5, 0.05, 33, 'skirting', [2.9, 10]); add('w36', 0.5, 0.6, 19, 'wall', [2.9, 10]);
  add('w9', 0.5, 0.3, 16, 'wall', [2.6, 5.4]);
  // living room: the wall behind the carpet threshold
  add('w26', 0.15, 0.05, 27, 'skirting', [3, 11.8]); add('w26', 0.15, 0.3, 21, 'wall', [3, 11.8]); add('w26', 0.15, 0.9, 12, 'wall', [3, 11.8]);
  // "Other 1": readings on its angled walls
  add('w42', 0.5, 0.05, 24, 'skirting', [5.0, 5.3]); add('w42', 0.5, 0.6, 15, 'wall', [5.0, 5.3]); add('w34', 0.3, 0.6, 12, 'wall', [5.2, 5.4]);
  m.removals.find(x => x.id === 'x2').item = 'plasterboard';
  m.removals.find(x => x.id === 'x2').heightMm = 600;
  m.removals.push({ id: 'x4', wallId: 'w26', t0: 0, t1: 0.45, item: 'plasterboard', heightMm: 600, note: 'Living room side of the threshold' },
    { id: 'x5', wallId: 'w12', t0: 0, t1: 1, item: 'flooring', heightMm: 0, note: 'Carpet and underlay at the threshold', side: 1 },
    { id: 'x6', wallId: 'w36', t0: 0, t1: 1, item: 'flooring', heightMm: 0, note: 'Vinyl plank along the pantry', side: -1 },
    { id: 'x7', wallId: 'w42', t0: 0, t1: 1, item: 'skirting', heightMm: 100, note: '' });
  m.equipment = [[1.2, 5.6, 'dehumidifier', 'DH-01'], [0.8, 6.8, 'airMover', 'AM-11'], [1.6, 8.0, 'airMover', 'AM-12'], [2.7, 9.6, 'airMover', 'AM-13'], [3.4, 12.3, 'airMover', 'AM-14'], [4.4, 13.2, 'airScrubber', 'AS-01']]
    .map(([x, y, type, label], i) => ({ id: 'e' + (i + 1), type, label, pos: [x, y], placed: 'v1', removed: null, placedAt: '2026-11-13T02:00:00Z', note: '' }));
  return d;
}
/* TEST-ONLY: the three-visit sample with strip-out photos: the laundry plasterboard (x1) done on visit 2 with a
   before photo from visit 1 and an after photo from visit 2; the skirting (x2) and the bedroom carpet (x3) still to do. */
async function worksDoc() {
  const d = json('sample-plan.json'), m = d.markup;
  const x1 = m.removals.find(x => x.id === 'x1'), x2 = m.removals.find(x => x.id === 'x2');
  x1.photos = [{ visit: 'v1', photo: await photo('moisture-wall.jpg'), takenAt: '2026-11-12T02:01:00Z', stage: 'before', cam: [2.2, 3.4] },
    { visit: 'v2', photo: await photo('inspection-opening.jpg'), takenAt: '2026-11-15T01:40:00Z', stage: 'after', cam: [2.2, 3.4] }];
  x2.status = 'proposed'; delete x2.doneVisit;
  return d;
}
module.exports = { smallPhotoDoc, largePhotoDoc, largeVisitsDoc, largeWallsDoc, worksDoc, photo };
