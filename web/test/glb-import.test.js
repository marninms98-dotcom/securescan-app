#!/usr/bin/env node
// Plain Node test for web/glb-import.js (node 22, no installs).  Run: node web/test/glb-import.test.js
// The real-house checks use private-fixtures/polycam-example.glb, which is NOT in the
// public repo; they are skipped with a message when it is absent. The synthetic and
// error-path tests always run.
'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const G = require('../glb-import.js');

let passed = 0, failed = 0, skipped = 0;
function test(name, fn) {
  try { fn(); passed++; console.log('  ok   ' + name); }
  catch (e) { failed++; console.log('  FAIL ' + name + '\n       ' + (e && e.message)); }
}
function skip(name, why) { skipped++; console.log('  skip ' + name + ' (' + why + ')'); }

// ---------------------------------------------------------------- helpers
const dist = (p, q) => Math.hypot(p[0] - q[0], p[1] - q[1]);
function distToSegment(p, a, b) {
  const dx = b[0] - a[0], dy = b[1] - a[1], L2 = dx * dx + dy * dy;
  const t = Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / L2));
  return dist(p, [a[0] + t * dx, a[1] + t * dy]);
}
function area(poly) { let s = 0; poly.forEach((p, i) => { const q = poly[(i + 1) % poly.length]; s += p[0] * q[1] - q[0] * p[1]; }); return s / 2; }
function segsCross(p1, p2, p3, p4) {
  const d = (a, b, c) => (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
  const d1 = d(p3, p4, p1), d2 = d(p3, p4, p2), d3 = d(p1, p2, p3), d4 = d(p1, p2, p4);
  return ((d1 > 1e-12 && d2 < -1e-12) || (d1 < -1e-12 && d2 > 1e-12)) && ((d3 > 1e-12 && d4 < -1e-12) || (d3 < -1e-12 && d4 > 1e-12));
}
function isSimple(poly) {
  const n = poly.length;
  for (let i = 0; i < n; i++) for (let j = i + 1; j < n; j++) {
    if (j === i + 1 || (i === 0 && j === n - 1)) continue;
    if (segsCross(poly[i], poly[(i + 1) % n], poly[j], poly[(j + 1) % n])) return false;
  }
  return true;
}
function centroid(poly) { let a = 0, cx = 0, cy = 0; poly.forEach((p, i) => { const q = poly[(i + 1) % poly.length], c = p[0] * q[1] - q[0] * p[1]; a += c; cx += (p[0] + q[0]) * c; cy += (p[1] + q[1]) * c; }); return [cx / (3 * a), cy / (3 * a)]; }
function walkNumbers(v, cb, at) {
  if (typeof v === 'number') cb(v, at);
  else if (Array.isArray(v)) v.forEach((x, i) => walkNumbers(x, cb, at + '[' + i + ']'));
  else if (v && typeof v === 'object') Object.keys(v).forEach((k) => walkNumbers(v[k], cb, at + '.' + k));
}

// Minimal GLB writer for synthetic fixtures.
// meshes: [{ positions:[x,y,z,...], indices?:[...], indexType?:5121|5123|5125, interleave?:bool }]
// nodes: glTF nodes (name, mesh, children, translation/rotation/scale/matrix)
function buildGLB(meshes, nodes, sceneRoots) {
  const chunks = [], bufferViews = [], accessors = [];
  let off = 0;
  const push = (buf, extra) => { const pad = (4 - (buf.length % 4)) % 4; bufferViews.push(Object.assign({ buffer: 0, byteOffset: off, byteLength: buf.length }, extra || {})); chunks.push(buf, Buffer.alloc(pad)); off += buf.length + pad; return bufferViews.length - 1; };
  const gltfMeshes = meshes.map((m) => {
    const n = m.positions.length / 3, prim = { attributes: {}, mode: 4 };
    let min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity];
    for (let i = 0; i < n; i++) for (let c = 0; c < 3; c++) { min[c] = Math.min(min[c], m.positions[i * 3 + c]); max[c] = Math.max(max[c], m.positions[i * 3 + c]); }
    if (m.interleave) {   // position + a dummy vec2, 20-byte stride, position at byteOffset 8 of a 4-byte lead-in
      const b = Buffer.alloc(8 + n * 20);
      for (let i = 0; i < n; i++) for (let c = 0; c < 3; c++) b.writeFloatLE(m.positions[i * 3 + c], 8 + i * 20 + c * 4);
      const bv = push(b, { byteStride: 20 });
      accessors.push({ bufferView: bv, byteOffset: 8, componentType: 5126, count: n, type: 'VEC3', min, max });
    } else {
      const b = Buffer.alloc(n * 12); m.positions.forEach((v, i) => b.writeFloatLE(v, i * 4));
      accessors.push({ bufferView: push(b), componentType: 5126, count: n, type: 'VEC3', min, max });
    }
    prim.attributes.POSITION = accessors.length - 1;
    if (m.indices) {
      const t = m.indexType || 5123, sz = { 5121: 1, 5123: 2, 5125: 4 }[t], b = Buffer.alloc(m.indices.length * sz);
      m.indices.forEach((v, i) => (sz === 1 ? b.writeUInt8(v, i) : sz === 2 ? b.writeUInt16LE(v, i * 2) : b.writeUInt32LE(v, i * 4)));
      accessors.push({ bufferView: push(b), componentType: t, count: m.indices.length, type: 'SCALAR' });
      prim.indices = accessors.length - 1;
    }
    return { primitives: [prim] };
  });
  const bin = Buffer.concat(chunks);
  const json = { asset: { version: '2.0' }, scene: 0, scenes: [{ nodes: sceneRoots }], nodes, meshes: gltfMeshes, accessors, bufferViews, buffers: [{ byteLength: bin.length }] };
  let js = Buffer.from(JSON.stringify(json)); js = Buffer.concat([js, Buffer.alloc((4 - (js.length % 4)) % 4, 0x20)]);
  const header = Buffer.alloc(12); header.writeUInt32LE(0x46546C67, 0); header.writeUInt32LE(2, 4); header.writeUInt32LE(12 + 8 + js.length + 8 + bin.length, 8);
  const ch = (len, type) => { const b = Buffer.alloc(8); b.writeUInt32LE(len, 0); b.writeUInt32LE(type, 4); return b; };
  const out = Buffer.concat([header, ch(js.length, 0x4E4F534A), js, ch(bin.length, 0x004E4942), bin]);
  return out.buffer.slice(out.byteOffset, out.byteOffset + out.byteLength);
}
// axis-aligned box as 8 verts + 12 tris
function box(x0, y0, z0, x1, y1, z1) {
  const p = [x0, y0, z0, x1, y0, z0, x1, y0, z1, x0, y0, z1, x0, y1, z0, x1, y1, z0, x1, y1, z1, x0, y1, z1];
  const i = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7];
  return { positions: p, indices: i };
}
function unindexed(m) { const p = []; m.indices.forEach((k) => p.push(m.positions[k * 3], m.positions[k * 3 + 1], m.positions[k * 3 + 2])); return { positions: p }; }

// ---------------------------------------------------------------- error paths
console.log('error paths');
test('garbage bytes -> "Not a GLB"', () => {
  const junk = new Uint8Array(4096); for (let i = 0; i < junk.length; i++) junk[i] = (i * 7919) & 255;
  assert.throws(() => G.toPlan(junk.buffer), /Not a GLB/);
});
test('empty / tiny input -> clear error', () => {
  assert.throws(() => G.toPlan(new ArrayBuffer(0)), /Not a GLB/);
  assert.throws(() => G.toPlan('hello'), /ArrayBuffer/);
});
test('.gltf JSON text -> asks for a binary .glb', () => {
  const b = Buffer.from(JSON.stringify({ asset: { version: '2.0' }, nodes: [] }) + '                    ');
  assert.throws(() => G.toPlan(b.buffer.slice(b.byteOffset, b.byteOffset + b.length)), /\.gltf \(JSON\)/);
});
test('valid GLB with no Polycam nodes (e.g. photo mesh) -> "does not contain a Polycam floor plan"', () => {
  const glb = buildGLB([box(0, 0, 0, 1, 1, 1)], [{ name: 'Mesh_0', mesh: 0 }], [0]);
  assert.throws(() => G.toPlan(glb), /does not contain a Polycam floor plan/);
  assert.throws(() => G.inspect(glb), /does not contain a Polycam floor plan/);
});
test('truncated GLB -> corrupt/truncated error', () => {
  const glb = buildGLB([box(0, 0, 0, 1, 1, 1)], [{ name: 'Wall_0', mesh: 0 }], [0]);
  assert.throws(() => G.toPlan(glb.slice(0, glb.byteLength - 40)), /truncated|corrupt|runs past/);
});
test('unsupported accessor (sparse / missing bufferView) -> clear error', () => {
  const glb = buildGLB([box(0, 0, 0, 4, 2.4, 0.1)], [{ name: 'Wall_0', mesh: 0 }], [0]);
  const u8 = new Uint8Array(glb), dv = new DataView(glb);
  const jl = dv.getUint32(12, true), json = JSON.parse(Buffer.from(u8.subarray(20, 20 + jl)).toString());
  delete json.accessors[0].bufferView;
  let js = Buffer.from(JSON.stringify(json)); js = Buffer.concat([js, Buffer.alloc((4 - (js.length % 4)) % 4, 0x20)]);
  const rest = Buffer.from(u8.subarray(20 + jl));
  const head = Buffer.alloc(20); head.writeUInt32LE(0x46546C67, 0); head.writeUInt32LE(2, 4); head.writeUInt32LE(20 + js.length + rest.length, 8); head.writeUInt32LE(js.length, 12); head.writeUInt32LE(0x4E4F534A, 16);
  const out = Buffer.concat([head, js, rest]);
  assert.throws(() => G.toPlan(out.buffer.slice(out.byteOffset, out.byteOffset + out.length)), /no stored position data/);
});

// ---------------------------------------------------------------- synthetic Polycam-like model with node transforms
console.log('synthetic model (node TRS, interleaved/non-indexed/uint8/uint32 accessors)');
test('4 x 3 m room under a translated + 90deg-rotated parent converts correctly', () => {
  const T = 0.1, Hh = 2.4, h = T / 2;
  const meshes = [
    box(h, 0, -h, 4 - h, Hh, h),                      // Wall_0 along x at z=0 (ends stop at joint faces)
    Object.assign(unindexed(box(4 - h, 0, h, 4 + h, Hh, 3 - h)), { interleave: true }), // Wall_1 along z at x=4: non-indexed + strided
    Object.assign(box(h, 0, 3 - h, 4 - h, Hh, 3 + h), { indexType: 5121 }), // Wall_2
    Object.assign(box(-h, 0, h, h, Hh, 3 - h), { indexType: 5125 }),        // Wall_3
    box(-h, 0, -h, h, Hh, h), box(4 - h, 0, -h, 4 + h, Hh, h), box(4 - h, 0, 3 - h, 4 + h, Hh, 3 + h), box(-h, 0, 3 - h, h, Hh, 3 + h), // joints
    { positions: [0, 0, 0, 4, 0, 0, 4, 0, 3, 0, 0, 3], indices: [0, 2, 1, 0, 3, 2] },  // Floor_Bedroom_2 (flat sheet)
    { positions: [1, 0, 0, 1.8, 0, 0, 1.8, 2.04, 0, 1, 2.04, 0], indices: [0, 1, 2, 0, 2, 3] }, // Door_0 in Wall_0
    { positions: [4, 0.9, 1, 4, 0.9, 2.2, 4, 2.1, 2.2, 4, 2.1, 1], indices: [0, 1, 2, 0, 2, 3] }, // Window_0 in Wall_1
    box(1, 0, 1, 3, 0.5, 2)                            // bed_double_0
  ];
  const q = [0, Math.SQRT1_2, 0, Math.SQRT1_2];          // +90deg about Y
  const nodes = [
    { name: 'Polycam', children: [1], translation: [10, 0, 5], rotation: q },
    { name: 'Floor_1', children: [2, 3, 4, 5, 6] },
    { name: 'Walls', children: [7, 8, 9, 10, 11, 12, 13, 14] },
    { name: 'Openings', children: [15, 16] },
    { name: 'Floors', children: [17] },
    { name: 'Objects', children: [18] },
    { name: 'Ceilings' },
    { name: 'Wall_0', mesh: 0 }, { name: 'Wall_1', mesh: 1 }, { name: 'Wall_2', mesh: 2 }, { name: 'Wall_3', mesh: 3 },
    { name: 'Joint_0', mesh: 4 }, { name: 'Joint_1', mesh: 5 }, { name: 'Joint_2', mesh: 6 }, { name: 'Joint_3', mesh: 7 },
    { name: 'Door_0', mesh: 9 }, { name: 'Window_0', mesh: 10 },
    { name: 'Floor_Bedroom_2', mesh: 8 },
    { name: 'bed_double_0', mesh: 11 }
  ];
  const glb = buildGLB(meshes, nodes, [0]);
  const plan = G.toPlan(glb, { address: '1 Test St', jobRef: 'J1' });
  assert.strictEqual(plan.version, 1); assert.strictEqual(plan.address, '1 Test St'); assert.strictEqual(plan.jobRef, 'J1');
  assert.strictEqual(plan.walls.length, 4);
  // rotated 90deg: footprint becomes 3 (x) by 4 (y)
  const xs = plan.walls.flatMap((w) => [w.a[0], w.b[0]]), ys = plan.walls.flatMap((w) => [w.a[1], w.b[1]]);
  assert.ok(Math.abs(Math.max(...xs) - 3) < 1e-3 && Math.abs(Math.max(...ys) - 4) < 1e-3, 'footprint 3 x 4, got ' + Math.max(...xs) + ' x ' + Math.max(...ys));
  assert.strictEqual(Math.min(...xs), 0); assert.strictEqual(Math.min(...ys), 0);
  // closed corners: 4 distinct points, each used exactly twice
  const cnt = {}; plan.walls.forEach((w) => [w.a, w.b].forEach((p) => { cnt[p.join()] = (cnt[p.join()] || 0) + 1; }));
  assert.deepStrictEqual(Object.values(cnt), [2, 2, 2, 2]);
  plan.walls.forEach((w) => assert.ok(Math.abs(w.height - 2.4) < 1e-3));
  assert.strictEqual(plan.rooms.length, 1); assert.strictEqual(plan.rooms[0].name, 'Bedroom 2'); assert.strictEqual(plan.rooms[0].id, 'r-bedroom-2');
  assert.ok(Math.abs(Math.abs(area(plan.rooms[0].polygon)) - 12) < 1e-3);
  const door = plan.openings.find((o) => o.type === 'door'), win = plan.openings.find((o) => o.type === 'window');
  assert.strictEqual(door.wallId, 'w0'); assert.strictEqual(win.wallId, 'w1');
  assert.ok(Math.abs(dist(door.a, door.b) - 0.8) < 1e-3 && Math.abs(door.height - 2.04) < 1e-3 && door.sill === 0);
  assert.ok(Math.abs(dist(win.a, win.b) - 1.2) < 1e-3 && Math.abs(win.sill - 0.9) < 1e-3 && Math.abs(win.height - 1.2) < 1e-3);
  const bed = plan.objects[0];
  assert.strictEqual(bed.category, 'bed'); assert.strictEqual(bed.id, 'ob-bed-double-0');
  assert.ok(Math.abs(bed.size[0] - 1) < 1e-3 && Math.abs(bed.size[1] - 2) < 1e-3, 'bed rotated to 1 x 2 in plan, got ' + bed.size);
  // orientation: +90deg about Y maps +X to -Z, so Wall_0 (world +X direction) must run up the page (vertical)
  const w0 = plan.walls.find((w) => w.id === 'w0');
  assert.ok(Math.abs(w0.a[0] - w0.b[0]) < 1e-3 && Math.abs(Math.abs(w0.a[1] - w0.b[1]) - 4) < 1e-3);
});
test('room-name and category mapping', () => {
  const I = G._internal;
  assert.strictEqual(I.roomName('Floor_Living_Room'), 'Living Room');
  assert.strictEqual(I.roomName('Floor_Other_2'), 'Other 2');
  const m = { stove_0: 'stove', oven_0: 'oven', refrigerator_1: 'refrigerator', washer_dryer_0: 'washerDryer', television_0: 'television', sink_0: 'sink',
    sofa_rect_1: 'sofa', chair_dining_four_back_no_3: 'chair', table_dining_rect_0: 'table', storage_cabinet_mid2_0: 'storage', bed_double_0: 'bed',
    toilet_0: 'toilet', bathtub_0: 'bathtub', dishwasher_0: 'dishwasher', fireplace_0: 'fireplace', stairs_0: 'stairs', floor_lamp_2: 'floorLamp' };
  Object.keys(m).forEach((k) => assert.strictEqual(I.category(k), m[k], k));
});

// ---------------------------------------------------------------- the real Polycam export (private)
const FIX = path.join(__dirname, '..', '..', 'private-fixtures', 'polycam-example.glb');
console.log('real Polycam export (private fixture)');
if (!fs.existsSync(FIX)) {
  skip('polycam-example.glb checks', 'private fixture ' + path.relative(process.cwd(), FIX) + ' is not present — it is a client\'s house and is not in the public repo');
} else {
  const buf = fs.readFileSync(FIX);
  const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
  const t0 = Date.now();
  const res = G.convert(ab, { address: 'Test address' });
  const ms = Date.now() - t0;
  const plan = res.plan;
  const wallById = Object.fromEntries(plan.walls.map((w) => [w.id, w]));

  test('converts quickly (' + ms + ' ms) and inspect() agrees', () => {
    assert.ok(ms < 3000);
    const s = G.inspect(ab);
    assert.deepStrictEqual([s.walls, s.doors, s.windows, s.rooms, s.objects], [43, 13, 4, 6, plan.objects.length]);
    assert.ok(/43 walls/.test(s.message));
  });
  test('document shape per Contract 1', () => {
    assert.strictEqual(plan.version, 1);
    assert.ok(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(plan.id));
    assert.ok(!isNaN(Date.parse(plan.createdAt)) && plan.createdAt === plan.updatedAt);
    assert.deepStrictEqual(plan.markup, { sources: [], affected: [], removals: [], readings: [], thresholds: { damp: 15, wet: 20 } });
    const ids = [].concat(plan.walls, plan.openings, plan.rooms, plan.objects).map((x) => x.id);
    assert.strictEqual(new Set(ids).size, ids.length, 'ids unique');
    assert.ok(G.toPlan(ab).id !== plan.id, 'fresh UUID each conversion');
    assert.deepStrictEqual(G.toPlan(ab).walls, plan.walls, 'geometry deterministic');
  });
  test('no NaN / Infinity anywhere, all coordinates >= 0, min x and min y are 0', () => {
    let minX = Infinity, minY = Infinity;
    walkNumbers(plan, (v, at) => { assert.ok(Number.isFinite(v), 'non-finite at ' + at); if (!/rotation$/.test(at)) assert.ok(v >= 0, 'negative at ' + at); });
    const pts = [].concat(plan.walls.flatMap((w) => [w.a, w.b]), plan.openings.flatMap((o) => [o.a, o.b]), plan.rooms.flatMap((r) => r.polygon), plan.objects.map((o) => o.center));
    pts.forEach((p) => { minX = Math.min(minX, p[0]); minY = Math.min(minY, p[1]); });
    assert.ok(minX === 0 && minY === 0, 'min ' + minX + ',' + minY);
  });
  test('43 walls, ids from node names, heights ~2.56 m', () => {
    assert.strictEqual(plan.walls.length, 43);
    plan.walls.forEach((w) => { assert.ok(/^w\d+$/.test(w.id)); assert.ok(Math.abs(w.height - 2.56) < 0.03, w.id + ' height ' + w.height); assert.ok(dist(w.a, w.b) > 0.01, w.id + ' zero length'); });
  });
  test('wall ends snapped to a Joint post coincide exactly with another wall end; every joint closes a corner', () => {
    const at = {}; plan.walls.forEach((w) => ['a', 'b'].forEach((e) => { (at[w[e].join()] = at[w[e].join()] || []).push(w.id); }));
    let jointEnds = 0; const perJoint = {};
    plan.walls.forEach((w) => ['a', 'b'].forEach((e) => {
      const j = res.wallEnds[w.id][e]; if (!j) return;
      jointEnds++; (perJoint[j] = perJoint[j] || new Set()).add(w[e].join());
      assert.ok(at[w[e].join()].length >= 2, w.id + '.' + e + ' at ' + j + ' is not shared');
    }));
    assert.strictEqual(Object.keys(perJoint).length, 33, 'all 33 joints used');
    Object.keys(perJoint).forEach((j) => assert.strictEqual(perJoint[j].size, 1, j + ' maps to one point'));
    assert.ok(jointEnds >= 70, 'most ends sit at joints (' + jointEnds + ')');
    // free ends (stub walls / open ends) are few and match the drawing
    const free = plan.walls.flatMap((w) => ['a', 'b'].filter((e) => at[w[e].join()].length === 1).map((e) => w.id + e));
    assert.ok(free.length <= 13, 'free ends: ' + free.join(' '));
  });
  test('13 doors + 4 windows, all attached to a wall and lying on it (within 2 cm)', () => {
    const doors = plan.openings.filter((o) => o.type === 'door'), wins = plan.openings.filter((o) => o.type === 'window');
    assert.strictEqual(doors.length, 13); assert.strictEqual(wins.length, 4);
    assert.deepStrictEqual(res.summary.unattachedOpenings, []);
    plan.openings.forEach((o) => {
      const w = wallById[o.wallId]; assert.ok(w, o.id + ' not attached');
      assert.ok(distToSegment(o.a, w.a, w.b) <= 0.02 && distToSegment(o.b, w.a, w.b) <= 0.02, o.id + ' not on ' + w.id);
      assert.ok(dist(o.a, o.b) > 0.4 && dist(o.a, o.b) < 3.5, o.id + ' width ' + dist(o.a, o.b));
      assert.ok(o.height > 0.5 && o.height < 2.6, o.id + ' height ' + o.height);
      if (o.type === 'door') assert.strictEqual(o.sill, 0); else assert.ok(o.sill > 0.3 && o.sill + o.height < 2.6);
    });
    assert.ok(/^o-door-\d+$/.test(doors[0].id) && /^o-window-\d+$/.test(wins[0].id));
  });
  test('6 rooms with the right names, simple polygons, plausible areas', () => {
    assert.deepStrictEqual(plan.rooms.map((r) => r.name).sort(), ['Kitchen', 'Living Room', 'Other 1', 'Other 2', 'Other 3', 'Other 4']);
    assert.ok(plan.rooms.some((r) => r.id === 'r-kitchen') && plan.rooms.some((r) => r.id === 'r-living-room'));
    let total = 0;
    plan.rooms.forEach((r) => {
      assert.ok(r.polygon.length >= 4, r.name + ' polygon');
      assert.ok(isSimple(r.polygon), r.name + ' self-intersects');
      const a = area(r.polygon); assert.ok(a > 0, r.name + ' winding'); total += a;
      assert.ok(Math.abs(a - r.area) < 0.01);
    });
    assert.ok(total > 95 && total < 140, 'total room area ' + total.toFixed(1));
  });
  test('layout matches Polycam\'s drawing (orientation not mirrored or rotated)', () => {
    const c = Object.fromEntries(plan.rooms.map((r) => [r.name, centroid(r.polygon)]));
    // Reference picture: Kitchen far left, Other 3 far right, Living Room bottom-left, Other 1 top/centre, Other 4 right of Other 1
    assert.ok(c.Kitchen[0] < c['Living Room'][0] && c['Living Room'][0] < c['Other 1'][0] && c['Other 1'][0] < c['Other 4'][0] && c['Other 4'][0] < c['Other 3'][0]);
    assert.ok(c['Living Room'][1] > c.Kitchen[1] && c['Living Room'][1] > c['Other 1'][1] && c['Other 4'][1] < c['Other 2'][1]);
    assert.ok(Math.abs(res.summary.size[0] - 14.35) < 0.3 && Math.abs(res.summary.size[1] - 14.7) < 0.3, 'size ' + res.summary.size);
  });
  test('objects: categories mapped, footprints sane', () => {
    const cats = new Set(plan.objects.map((o) => o.category));
    ['stove', 'oven', 'refrigerator', 'washerDryer', 'television', 'sink', 'sofa', 'chair', 'table', 'storage'].forEach((k) => assert.ok(cats.has(k), 'has ' + k));
    plan.objects.forEach((o) => { assert.ok(o.size[0] > 0.02 && o.size[1] > 0.02 && o.size[0] < 6 && o.size[1] < 6, o.id); assert.ok(o.rotation > -Math.PI / 2 - 1e-9 && o.rotation <= Math.PI / 2 + 1e-9); });
  });
}

console.log('\n' + passed + ' passed, ' + failed + ' failed' + (skipped ? ', ' + skipped + ' skipped' : ''));
process.exit(failed ? 1 : 0);
