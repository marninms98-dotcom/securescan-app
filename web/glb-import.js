/*
 * SecureScan — Polycam floor-plan (.glb) importer.            web/glb-import.js
 *
 * Pure, dependency-free. Works as a plain <script> (attaches globalThis.SecureScanGLB)
 * and in Node (module.exports). Never executes anything from the file: it only parses
 * the GLB container, the glTF JSON and binary accessor data.
 *
 *   SecureScanGLB.toPlan(arrayBuffer, { address, jobRef })  -> plan document (SPEC Contract 1)
 *   SecureScanGLB.convert(arrayBuffer, { address, jobRef }) -> { plan, warnings, summary }
 *   SecureScanGLB.inspect(arrayBuffer)                       -> summary (counts, size, warnings)
 *
 * Plan frame: planX = worldX, planY = worldZ (glTF is right-handed, Y up; seen from
 * above with +X to the right, +Z points down the page, so this is NOT a mirror image).
 * Then translated so the minimum x / y over all geometry is 0. Metres, radians.
 * Object rotation: angle (radians) of the object's local x axis (size[0]) measured from
 * plan +x towards plan +y (i.e. clockwise on screen, since y is down).
 * Room polygons: wound so the shoelace sum in plan coordinates is positive
 * (clockwise as seen on screen with y down).
 */
(function (root) {
  'use strict';

  var MAX_FILE_BYTES = 512 * 1024 * 1024;   // refuse absurd inputs outright
  var MAX_VERTICES_PER_MESH = 2000000;      // Polycam parametric meshes are tiny
  var MAX_TOTAL_VERTICES = 5000000;
  var JOINT_SNAP = 0.12;                    // wall end -> joint centre snap distance (m)
  var ENDPOINT_MERGE = 0.02;                // merge leftover wall ends closer than this (m)

  function fail(msg) { var e = new Error(msg); e.name = 'GLBImportError'; throw e; }

  // ------------------------------------------------------------------ GLB container
  function toU8(input) {
    if (input instanceof ArrayBuffer) return new Uint8Array(input);
    if (ArrayBuffer.isView(input)) return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
    fail('Expected the .glb file contents as an ArrayBuffer.');
  }

  function utf8(u8) {
    if (typeof TextDecoder !== 'undefined') return new TextDecoder('utf-8').decode(u8);
    var s = ''; for (var i = 0; i < u8.length; i++) s += String.fromCharCode(u8[i]);
    return decodeURIComponent(escape(s));
  }

  function parseGLB(input) {
    var u8 = toU8(input);
    if (u8.byteLength > MAX_FILE_BYTES) fail('This file is too large to import (' + Math.round(u8.byteLength / 1048576) + ' MB).');
    if (u8.byteLength < 20) fail('Not a GLB file: the file is too short.');
    var dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
    if (dv.getUint32(0, true) !== 0x46546C67) {
      var head = utf8(u8.subarray(0, Math.min(64, u8.byteLength))).replace(/^﻿/, '').trim();
      if (head.charAt(0) === '{') fail('This looks like a .gltf (JSON) file. Please export the floor plan from Polycam as a binary .glb file.');
      fail('Not a GLB file (missing the "glTF" header). Please choose a .glb floor-plan export from Polycam.');
    }
    var version = dv.getUint32(4, true);
    if (version !== 2) fail('Unsupported glTF version ' + version + ' (only glTF 2.0 .glb files are supported).');
    var total = Math.min(dv.getUint32(8, true), u8.byteLength);
    var off = 12, json = null, bin = null;
    while (off + 8 <= total) {
      var len = dv.getUint32(off, true), type = dv.getUint32(off + 4, true);
      var start = off + 8;
      if (start + len > total) fail('The GLB file is truncated or corrupt (a chunk runs past the end of the file).');
      if (type === 0x4E4F534A && json === null) json = u8.subarray(start, start + len);
      else if (type === 0x004E4942 && bin === null) bin = u8.subarray(start, start + len);
      off = start + len + ((4 - (len % 4)) % 4);
    }
    if (!json) fail('The GLB file has no JSON chunk, so it cannot be read.');
    var gltf;
    try { gltf = JSON.parse(utf8(json).replace(/^﻿/, '')); }
    catch (e) { fail('The GLB file\'s JSON chunk is not valid JSON.'); }
    if (!gltf || typeof gltf !== 'object') fail('The GLB file\'s JSON chunk is empty.');
    if (!gltf.asset || String(gltf.asset.version || '').charAt(0) !== '2') fail('Unsupported glTF asset version (only glTF 2.0 is supported).');
    return { gltf: gltf, bin: bin };
  }

  // ------------------------------------------------------------------ accessors
  var COMP = {
    5120: { size: 1, get: 'getInt8', norm: 127 },
    5121: { size: 1, get: 'getUint8', norm: 255 },
    5122: { size: 2, get: 'getInt16', norm: 32767 },
    5123: { size: 2, get: 'getUint16', norm: 65535 },
    5125: { size: 4, get: 'getUint32', norm: 0 },
    5126: { size: 4, get: 'getFloat32', norm: 0 }
  };
  var NCOMP = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4, MAT2: 4, MAT3: 9, MAT4: 16 };

  // Returns a Float64Array of count*ncomp values (or Uint32Array for indices).
  function readAccessor(doc, index, what) {
    var g = doc.gltf, acc = g.accessors && g.accessors[index];
    if (!acc) fail('The model refers to ' + what + ' data (accessor ' + index + ') that does not exist.');
    var comp = COMP[acc.componentType], n = NCOMP[acc.type];
    if (!comp || !n) fail('Unsupported ' + what + ' data format in the model (accessor ' + index + ': componentType ' + acc.componentType + ', type ' + acc.type + ').');
    if (acc.sparse) fail('Unsupported ' + what + ' data in the model (sparse accessor ' + index + ').');
    if (acc.bufferView === undefined || acc.bufferView === null) fail('The model has no stored ' + what + ' data (accessor ' + index + ' has no bufferView).');
    var count = acc.count >>> 0;
    if (count > MAX_VERTICES_PER_MESH * 3) fail('The model is too large to import (accessor ' + index + ' has ' + count + ' items).');
    var bv = g.bufferViews && g.bufferViews[acc.bufferView];
    if (!bv) fail('The model refers to a missing bufferView (' + acc.bufferView + ').');
    if ((bv.buffer | 0) !== 0 || !doc.bin) fail('Unsupported model layout: ' + what + ' data is stored outside the .glb file (external buffer). Please export a self-contained .glb.');
    var elemBytes = comp.size * n;
    var stride = bv.byteStride || elemBytes;
    var base = (bv.byteOffset || 0) + (acc.byteOffset || 0);
    var bvEnd = (bv.byteOffset || 0) + (bv.byteLength || 0);
    if (count > 0 && (base + stride * (count - 1) + elemBytes > bvEnd || bvEnd > doc.bin.byteLength))
      fail('The model\'s ' + what + ' data (accessor ' + index + ') runs past the end of its buffer; the file is corrupt.');
    var dv = new DataView(doc.bin.buffer, doc.bin.byteOffset, doc.bin.byteLength);
    var out = (what === 'index') ? new Uint32Array(count * n) : new Float64Array(count * n);
    var normalise = acc.normalized && comp.norm;
    for (var i = 0; i < count; i++) {
      var p = base + i * stride;
      for (var c = 0; c < n; c++) {
        var v = dv[comp.get](p + c * comp.size, true);
        if (normalise) v = Math.max(v / comp.norm, -1);
        out[i * n + c] = v;
      }
    }
    return { data: out, count: count, n: n };
  }

  // ------------------------------------------------------------------ matrices (column-major, glTF)
  function identity() { return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]; }
  function mul(a, b) {
    var o = new Array(16);
    for (var c = 0; c < 4; c++) for (var r = 0; r < 4; r++) {
      var s = 0; for (var k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k];
      o[c * 4 + r] = s;
    }
    return o;
  }
  function nodeMatrix(node) {
    if (Array.isArray(node.matrix) && node.matrix.length === 16) return node.matrix.map(Number);
    var t = node.translation || [0, 0, 0], q = node.rotation || [0, 0, 0, 1], s = node.scale || [1, 1, 1];
    var x = q[0], y = q[1], z = q[2], w = q[3];
    var xx = x * x, yy = y * y, zz = z * z, xy = x * y, xz = x * z, yz = y * z, wx = w * x, wy = w * y, wz = w * z;
    return [
      (1 - 2 * (yy + zz)) * s[0], (2 * (xy + wz)) * s[0], (2 * (xz - wy)) * s[0], 0,
      (2 * (xy - wz)) * s[1], (1 - 2 * (xx + zz)) * s[1], (2 * (yz + wx)) * s[1], 0,
      (2 * (xz + wy)) * s[2], (2 * (yz - wx)) * s[2], (1 - 2 * (xx + yy)) * s[2], 0,
      t[0], t[1], t[2], 1
    ];
  }
  function isIdentity(m) { var I = identity(); for (var i = 0; i < 16; i++) if (Math.abs(m[i] - I[i]) > 1e-12) return false; return true; }

  // Walk the scene graph; returns [{name, mesh, matrix, path:[ancestor names]}] for mesh nodes,
  // plus the list of all node names.
  function collectNodes(g) {
    var nodes = Array.isArray(g.nodes) ? g.nodes : [];
    var roots;
    var sceneIdx = (typeof g.scene === 'number') ? g.scene : 0;
    if (Array.isArray(g.scenes) && g.scenes[sceneIdx] && Array.isArray(g.scenes[sceneIdx].nodes)) roots = g.scenes[sceneIdx].nodes.slice();
    else {
      var isChild = {};
      nodes.forEach(function (n) { (n.children || []).forEach(function (c) { isChild[c] = true; }); });
      roots = []; for (var i = 0; i < nodes.length; i++) if (!isChild[i]) roots.push(i);
    }
    var out = [], seen = {};
    var stack = roots.map(function (r) { return { i: r, m: identity(), path: [] }; });
    while (stack.length) {
      var it = stack.pop();
      if (seen[it.i] || !nodes[it.i]) continue;   // guards against cycles / bad indices
      seen[it.i] = true;
      var nd = nodes[it.i];
      var m = mul(it.m, nodeMatrix(nd));
      var name = String(nd.name == null ? '' : nd.name);
      if (typeof nd.mesh === 'number') out.push({ name: name, mesh: nd.mesh, matrix: m, path: it.path });
      var kids = nd.children || [];
      for (var k = kids.length - 1; k >= 0; k--) stack.push({ i: kids[k], m: m, path: it.path.concat(name) });
    }
    return out;
  }

  // World-space geometry of a mesh node: positions (Float64Array xyz) + triangle index list.
  function meshGeometry(doc, item, budget) {
    var mesh = doc.gltf.meshes && doc.gltf.meshes[item.mesh];
    if (!mesh || !Array.isArray(mesh.primitives)) fail('The model node "' + item.name + '" refers to a missing mesh.');
    var pos = [], tris = [], m = item.matrix, ident = isIdentity(m);
    mesh.primitives.forEach(function (p) {
      if (!p.attributes || p.attributes.POSITION === undefined) fail('The mesh for "' + item.name + '" has no vertex positions.');
      var mode = (p.mode === undefined) ? 4 : p.mode;
      var P = readAccessor(doc, p.attributes.POSITION, 'position');
      if (P.n !== 3) fail('The mesh for "' + item.name + '" has positions that are not 3D vectors.');
      budget.v += P.count;
      if (budget.v > MAX_TOTAL_VERTICES) fail('The model is too large to import (more than ' + MAX_TOTAL_VERTICES + ' vertices in floor-plan parts).');
      var base = pos.length / 3;
      for (var i = 0; i < P.count; i++) {
        var x = P.data[i * 3], y = P.data[i * 3 + 1], z = P.data[i * 3 + 2];
        if (!ident) {
          var X = m[0] * x + m[4] * y + m[8] * z + m[12], Y = m[1] * x + m[5] * y + m[9] * z + m[13], Z = m[2] * x + m[6] * y + m[10] * z + m[14], W = m[3] * x + m[7] * y + m[11] * z + m[15];
          if (W && W !== 1) { X /= W; Y /= W; Z /= W; }
          x = X; y = Y; z = Z;
        }
        if (!isFinite(x) || !isFinite(y) || !isFinite(z)) fail('The mesh for "' + item.name + '" contains invalid (non-finite) coordinates.');
        pos.push(x, y, z);
      }
      var idx;
      if (p.indices !== undefined && p.indices !== null) {
        var I = readAccessor(doc, p.indices, 'index');
        idx = I.data;
        for (var j = 0; j < idx.length; j++) if (idx[j] >= P.count) fail('The mesh for "' + item.name + '" has a triangle index out of range.');
      } else {
        idx = new Uint32Array(P.count); for (var q = 0; q < P.count; q++) idx[q] = q;
      }
      if (mode === 4) { for (var t = 0; t + 2 < idx.length; t += 3) tris.push(base + idx[t], base + idx[t + 1], base + idx[t + 2]); }
      else if (mode === 5) { for (var s = 0; s + 2 < idx.length; s++) { if (s % 2) tris.push(base + idx[s + 1], base + idx[s], base + idx[s + 2]); else tris.push(base + idx[s], base + idx[s + 1], base + idx[s + 2]); } }
      else if (mode === 6) { for (var f = 1; f + 1 < idx.length; f++) tris.push(base + idx[0], base + idx[f], base + idx[f + 1]); }
      // points/lines: positions still count for footprints, no triangles
    });
    if (!pos.length) fail('The mesh for "' + item.name + '" is empty.');
    return { pos: pos, tris: tris };
  }

  // ------------------------------------------------------------------ 2D geometry
  function planPoints(pos) { var pts = []; for (var i = 0; i < pos.length; i += 3) pts.push([pos[i], pos[i + 2]]); return pts; }
  function yRange(pos) { var lo = Infinity, hi = -Infinity; for (var i = 1; i < pos.length; i += 3) { if (pos[i] < lo) lo = pos[i]; if (pos[i] > hi) hi = pos[i]; } return [lo, hi]; }
  function cross(o, a, b) { return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]); }

  function convexHull(points) {
    var p = points.slice().sort(function (a, b) { return a[0] - b[0] || a[1] - b[1]; });
    var uniq = []; p.forEach(function (q) { var l = uniq[uniq.length - 1]; if (!l || Math.abs(l[0] - q[0]) > 1e-9 || Math.abs(l[1] - q[1]) > 1e-9) uniq.push(q); });
    if (uniq.length < 3) return uniq;
    var lower = [], upper = [], i;
    for (i = 0; i < uniq.length; i++) { while (lower.length >= 2 && cross(lower[lower.length - 2], lower[lower.length - 1], uniq[i]) <= 1e-12) lower.pop(); lower.push(uniq[i]); }
    for (i = uniq.length - 1; i >= 0; i--) { while (upper.length >= 2 && cross(upper[upper.length - 2], upper[upper.length - 1], uniq[i]) <= 1e-12) upper.pop(); upper.push(uniq[i]); }
    lower.pop(); upper.pop();
    return lower.concat(upper);
  }

  // Minimum-area oriented rectangle (rotating calipers over hull edge directions).
  // Returns { center, u (unit long axis), long, short }.
  function orientedRect(points) {
    var hull = convexHull(points);
    var dirs = [];
    if (hull.length === 1) dirs.push([1, 0]);
    for (var i = 0; i < hull.length && hull.length > 1; i++) {
      var a = hull[i], b = hull[(i + 1) % hull.length], dx = b[0] - a[0], dy = b[1] - a[1], L = Math.hypot(dx, dy);
      if (L > 1e-9) dirs.push([dx / L, dy / L]);
    }
    var best = null;
    dirs.forEach(function (u) {
      var v = [-u[1], u[0]], minU = Infinity, maxU = -Infinity, minV = Infinity, maxV = -Infinity;
      hull.forEach(function (p) { var s = p[0] * u[0] + p[1] * u[1], t = p[0] * v[0] + p[1] * v[1]; if (s < minU) minU = s; if (s > maxU) maxU = s; if (t < minV) minV = t; if (t > maxV) maxV = t; });
      var w = maxU - minU, h = maxV - minV, area = w * h;
      // tie-break near-degenerate (flat quads seen edge-on): prefer the longer extent
      if (!best || area < best.area - 1e-9 || (Math.abs(area - best.area) <= 1e-9 && Math.max(w, h) > best.longSide + 1e-9)) {
        var cu = (minU + maxU) / 2, cv = (minV + maxV) / 2;
        best = { area: area, longSide: Math.max(w, h), center: [cu * u[0] + cv * v[0], cu * u[1] + cv * v[1]], u: w >= h ? u : v, long: Math.max(w, h), short: Math.min(w, h) };
      }
    });
    return best;
  }

  function polyArea(poly) { var s = 0; for (var i = 0; i < poly.length; i++) { var a = poly[i], b = poly[(i + 1) % poly.length]; s += a[0] * b[1] - b[0] * a[1]; } return s / 2; }

  // Outer boundary of a triangulated floor mesh, in plan, largest loop.
  function floorOutline(pos, tris) {
    var key = {}, verts = [], map = [];
    for (var i = 0; i < pos.length / 3; i++) {
      var x = pos[i * 3], z = pos[i * 3 + 2], k = Math.round(x * 1000) + ',' + Math.round(z * 1000);
      if (key[k] === undefined) { key[k] = verts.length; verts.push([x, z]); }
      map.push(key[k]);
    }
    // Polycam floors are thin slabs (top, bottom and side faces). Use only the top
    // surface: horizontal triangles at the slab's highest level. If the mesh is a
    // single flat sheet this keeps everything.
    var topY = -Infinity, ti;
    for (ti = 1; ti < pos.length; ti += 3) if (pos[ti] > topY) topY = pos[ti];
    var top = [];
    for (ti = 0; ti + 2 < tris.length; ti += 3) {
      var i0 = tris[ti] * 3, i1 = tris[ti + 1] * 3, i2 = tris[ti + 2] * 3;
      if (topY - pos[i0 + 1] > 0.01 || topY - pos[i1 + 1] > 0.01 || topY - pos[i2 + 1] > 0.01) continue;
      top.push(tris[ti], tris[ti + 1], tris[ti + 2]);
    }
    if (top.length) tris = top;
    var count = {};
    for (var t = 0; t + 2 < tris.length; t += 3) {
      var a = map[tris[t]], b = map[tris[t + 1]], c = map[tris[t + 2]];
      if (a === b || b === c || a === c) continue;
      if (Math.abs(cross(verts[a], verts[b], verts[c])) < 1e-10) continue;
      [[a, b], [b, c], [c, a]].forEach(function (e) { var k2 = Math.min(e[0], e[1]) + '_' + Math.max(e[0], e[1]); count[k2] = (count[k2] || 0) + 1; });
    }
    var adj = {}, edges = [];
    Object.keys(count).forEach(function (k3) {
      if (count[k3] !== 1) return;
      var ab = k3.split('_').map(Number), id = edges.length;
      edges.push(ab);
      (adj[ab[0]] = adj[ab[0]] || []).push(id); (adj[ab[1]] = adj[ab[1]] || []).push(id);
    });
    if (!edges.length) {   // no triangles: fall back to the hull of the points
      return convexHull(verts);
    }
    var used = new Array(edges.length), loops = [];
    for (var e0 = 0; e0 < edges.length; e0++) {
      if (used[e0]) continue;
      used[e0] = true;
      var start = edges[e0][0], cur = edges[e0][1], loop = [start];
      var guard = edges.length + 2;
      while (cur !== start && guard-- > 0) {
        loop.push(cur);
        var next = (adj[cur] || []).filter(function (id) { return !used[id]; });
        if (!next.length) break;
        // at a pinch vertex prefer the edge that turns most to keep loops simple
        var id2 = next[0];
        used[id2] = true;
        cur = edges[id2][0] === cur ? edges[id2][1] : edges[id2][0];
      }
      if (loop.length >= 3) loops.push(loop.map(function (vi) { return verts[vi]; }));
    }
    if (!loops.length) return convexHull(verts);
    loops.sort(function (p, q) { return Math.abs(polyArea(q)) - Math.abs(polyArea(p)); });
    return loops[0];
  }

  function simplify(poly) {
    var pts = poly.slice(), changed = true;
    while (changed && pts.length > 3) {
      changed = false;
      for (var i = 0; i < pts.length && pts.length > 3; i++) {
        var a = pts[(i - 1 + pts.length) % pts.length], b = pts[i], c = pts[(i + 1) % pts.length];
        var L = Math.hypot(c[0] - a[0], c[1] - a[1]);
        var dup = Math.hypot(b[0] - a[0], b[1] - a[1]) < 0.002;
        // distance of b from line a-c below 3 mm => collinear
        if (dup || (L > 1e-9 && Math.abs(cross(a, b, c)) / L < 0.003 && ((b[0] - a[0]) * (c[0] - a[0]) + (b[1] - a[1]) * (c[1] - a[1])) > 0)) { pts.splice(i, 1); changed = true; i--; }
      }
    }
    if (polyArea(pts) < 0) pts.reverse();
    return pts;
  }

  // ------------------------------------------------------------------ naming
  function slug(s) { return String(s).replace(/([a-z0-9])([A-Z])/g, '$1-$2').replace(/[^A-Za-z0-9]+/g, '-').replace(/^-+|-+$/g, '').toLowerCase() || 'x'; }
  function roomName(nodeName) {
    var s = nodeName.replace(/^Floor_/i, '');
    return s.split(/[_\s]+/).filter(Boolean).map(function (w) { return w.charAt(0).toUpperCase() + w.slice(1); }).join(' ') || 'Room';
  }
  var CATEGORY_PREFIX = [
    [/^washer_?dryer|^washing_?machine|^dryer/, 'washerDryer'], [/^refrigerator|^fridge/, 'refrigerator'],
    [/^stove/, 'stove'], [/^oven/, 'oven'], [/^television|^tv(_|$)/, 'television'], [/^sink/, 'sink'],
    [/^sofa/, 'sofa'], [/^chair/, 'chair'], [/^table/, 'table'], [/^storage/, 'storage'], [/^bed/, 'bed'],
    [/^toilet/, 'toilet'], [/^bath_?tub/, 'bathtub'], [/^dish_?washer/, 'dishwasher'], [/^fireplace/, 'fireplace'], [/^stair/, 'stairs']
  ];
  function category(nodeName) {
    var n = nodeName.toLowerCase();
    for (var i = 0; i < CATEGORY_PREFIX.length; i++) if (CATEGORY_PREFIX[i][0].test(n)) return CATEGORY_PREFIX[i][1];
    var parts = n.replace(/_\d+$/, '').split(/[^a-z0-9]+/).filter(Boolean);
    if (!parts.length) return 'object';
    return parts[0] + parts.slice(1).map(function (w) { return w.charAt(0).toUpperCase() + w.slice(1); }).join('');
  }

  function uuid() {
    var c = root.crypto;
    if (c && typeof c.randomUUID === 'function') return c.randomUUID();
    var b = new Uint8Array(16);
    if (c && typeof c.getRandomValues === 'function') c.getRandomValues(b); else for (var i = 0; i < 16; i++) b[i] = Math.floor(Math.random() * 256);
    b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
    var h = Array.prototype.map.call(b, function (x) { return (x + 0x100).toString(16).slice(1); }).join('');
    return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
  }

  function r3(v) { var x = Math.round(v * 1000) / 1000; return x === 0 ? 0 : x; }   // mm precision, no -0
  function r4(v) { var x = Math.round(v * 10000) / 10000; return x === 0 ? 0 : x; }

  // ------------------------------------------------------------------ classification
  function classify(items) {
    var c = { walls: [], joints: [], doors: [], windows: [], floors: [], objects: [], other: [] };
    items.forEach(function (it) {
      var n = it.name, inObjects = it.path.some(function (p) { return /^(Objects|Appliances|Fixtures|Furniture)$/i.test(p); });
      if (/^Wall_\d+/i.test(n)) c.walls.push(it);
      else if (/^Joint_\d+/i.test(n)) c.joints.push(it);
      else if (/^Door_\d+/i.test(n)) c.doors.push(it);
      else if (/^Window_\d+/i.test(n)) c.windows.push(it);
      else if (/^Opening_\d+/i.test(n)) (c.openings = c.openings || []).push(it);
      else if (/^Floor_/i.test(n) && !inObjects) c.floors.push(it);
      else if (/^Ceiling/i.test(n)) { /* not needed for the plan */ }
      else if (inObjects) c.objects.push(it);
      else c.other.push(it);
    });
    c.openings = c.openings || [];
    return c;
  }

  function numSuffix(name) { var m = /_(\d+)$/.exec(name); return m ? +m[1] : 0; }
  function byIndex(a, b) { return numSuffix(a.name) - numSuffix(b.name) || (a.name < b.name ? -1 : 1); }

  // ------------------------------------------------------------------ main conversion
  function convert(input, opts) {
    opts = opts || {};
    var doc = parseGLB(input), g = doc.gltf;
    var items = collectNodes(g);
    var c = classify(items);
    // Bail out early (before reading any vertex data) if this isn't a Polycam floor plan.
    if (!c.walls.length && !c.floors.length) {
      var anyMesh = (g.meshes || []).length;
      fail(anyMesh
        ? 'This .glb does not contain a Polycam floor plan (no Wall_ or Floor_ parts found). It looks like a 3D scan mesh; in Polycam, export the floor plan ("Floor plan" > GLB) instead.'
        : 'This .glb contains no geometry.');
    }
    if (!c.walls.length) fail('This .glb has floor shapes but no walls (no Wall_ parts), so a floor plan cannot be built from it.');
    if (!doc.bin) fail('The .glb file has no binary data chunk, so its geometry cannot be read.');
    var warnings = [], budget = { v: 0 };

    // -------- walls
    var floorYs = [];
    var walls = c.walls.sort(byIndex).map(function (it) {
      var geo = meshGeometry(doc, it, budget), yr = yRange(geo.pos);
      var rect = orientedRect(planPoints(geo.pos));
      var h = rect.long / 2, u = rect.u;
      floorYs.push(yr[0]);
      return { node: it.name, id: 'w' + (/^Wall_(\d+)$/i.test(it.name) ? numSuffix(it.name) : slug(it.name)), a: [rect.center[0] - u[0] * h, rect.center[1] - u[1] * h], b: [rect.center[0] + u[0] * h, rect.center[1] + u[1] * h], thickness: rect.short, height: yr[1] - yr[0], y0: yr[0] };
    });
    var joints = c.joints.map(function (it) {
      var geo = meshGeometry(doc, it, budget), rect = orientedRect(planPoints(geo.pos));
      return { name: it.name, c: rect.center };
    });
    // snap wall ends to the joint they abut
    // Each end gets its nearest joint within JOINT_SNAP, but the two ends of one wall
    // must go to different joints and the wall must keep its direction (tiny filler
    // walls at cluttered corners otherwise collapse to a point).
    walls.forEach(function (w) {
      var cand = function (p) {
        var list = [{ j: null, d: JOINT_SNAP * 1.5 }];   // "no joint" costs more than any snap
        joints.forEach(function (j) { var d = Math.hypot(j.c[0] - p[0], j.c[1] - p[1]); if (d <= JOINT_SNAP) list.push({ j: j, d: d }); });
        return list;
      };
      var ca = cand(w.a), cb = cand(w.b), best = null;
      var dx0 = w.b[0] - w.a[0], dy0 = w.b[1] - w.a[1], L0 = Math.hypot(dx0, dy0);
      ca.forEach(function (x) { cb.forEach(function (y) {
        if (x.j && y.j && x.j === y.j) return;
        var a = x.j ? x.j.c : w.a, b = y.j ? y.j.c : w.b;
        var dx = b[0] - a[0], dy = b[1] - a[1], L = Math.hypot(dx, dy);
        if (L < 0.01 || (dx * dx0 + dy * dy0) / (L * L0) < Math.cos(25 * Math.PI / 180)) return;   // keep direction
        var cost = x.d + y.d;
        if (!best || cost < best.cost) best = { cost: cost, x: x, y: y };
      }); });
      if (best && best.x.j) { w.a = best.x.j.c.slice(); w.aJoint = best.x.j.name; }
      if (best && best.y.j) { w.b = best.y.j.c.slice(); w.bJoint = best.y.j.name; }
    });
    // merge any remaining near-coincident free ends (walls meeting without a joint post)
    var free = [];
    walls.forEach(function (w) { ['a', 'b'].forEach(function (e) { if (!w[e + 'Joint']) free.push({ w: w, e: e }); }); });
    walls.forEach(function (w) { ['a', 'b'].forEach(function (e) {
      if (w[e + 'Joint']) return;
      walls.forEach(function (o) { if (o === w) return; ['a', 'b'].forEach(function (oe) {
        if (Math.hypot(o[oe][0] - w[e][0], o[oe][1] - w[e][1]) < ENDPOINT_MERGE) w[e] = o[oe].slice();
      }); });
    }); });
    walls = walls.filter(function (w) { var ok = Math.hypot(w.b[0] - w.a[0], w.b[1] - w.a[1]) > 0.01; if (!ok) warnings.push('Skipped wall ' + w.node + ': zero length.'); return ok; });

    // -------- floor level
    var floorItems = c.floors.sort(function (a, b) { return a.name < b.name ? -1 : 1; });
    var floorGeo = floorItems.map(function (it) { return { it: it, geo: meshGeometry(doc, it, budget) }; });
    var floorY;
    // walking surface = top of the floor slabs (Polycam floors are ~0.1 m thick slabs)
    if (floorGeo.length) { var fy = floorGeo.map(function (f) { return yRange(f.geo.pos)[1]; }).sort(function (a, b) { return a - b; }); floorY = fy[Math.floor(fy.length / 2)]; }
    else { floorYs.sort(function (a, b) { return a - b; }); floorY = floorYs[0]; }

    // -------- openings
    var openings = [], unattached = [];
    function addOpening(it, type) {
      var geo = meshGeometry(doc, it, budget), yr = yRange(geo.pos), rect = orientedRect(planPoints(geo.pos));
      var h = rect.long / 2, u = rect.u;
      var a = [rect.center[0] - u[0] * h, rect.center[1] - u[1] * h], b = [rect.center[0] + u[0] * h, rect.center[1] + u[1] * h];
      var best = null;
      walls.forEach(function (w) {
        var dx = w.b[0] - w.a[0], dy = w.b[1] - w.a[1], L = Math.hypot(dx, dy), ux = dx / L, uy = dy / L;
        var cosang = Math.abs(ux * u[0] + uy * u[1]);
        if (cosang < Math.cos(10 * Math.PI / 180)) return;
        var perp = function (p) { return Math.abs((p[0] - w.a[0]) * -uy + (p[1] - w.a[1]) * ux); };
        var along = function (p) { return (p[0] - w.a[0]) * ux + (p[1] - w.a[1]) * uy; };
        var d = Math.max(perp(a), perp(b));
        if (d > Math.max(0.15, w.thickness)) return;
        var sa = along(a), sb = along(b), lo = Math.min(sa, sb), hi = Math.max(sa, sb);
        var overlap = Math.min(hi, L) - Math.max(lo, 0);
        if (overlap < Math.min(0.5 * (hi - lo), 0.05)) return;
        var score = d + Math.max(0, (hi - lo) - overlap);
        if (!best || score < best.score) best = { score: score, w: w, L: L, ux: ux, uy: uy, sa: sa, sb: sb };
      });
      var id = 'o-' + type + '-' + (/_(\d+)$/.test(it.name) ? numSuffix(it.name) : slug(it.name));
      var op = { id: id, type: type, wallId: null, a: a, b: b, height: yr[1] - yr[0], sill: type === 'window' ? Math.max(0, yr[0] - floorY) : 0 };
      if (type !== 'window') op.height = yr[1] - floorY;   // doors measured from the floor surface
      if (best) {
        var w = best.w, clamp = function (s) { return Math.max(0, Math.min(best.L, s)); };
        var s0 = clamp(Math.min(best.sa, best.sb)), s1 = clamp(Math.max(best.sa, best.sb));
        op.wallId = w.id;
        op.a = [w.a[0] + best.ux * s0, w.a[1] + best.uy * s0];
        op.b = [w.a[0] + best.ux * s1, w.a[1] + best.uy * s1];
      } else { unattached.push(it.name); warnings.push('Could not attach ' + it.name + ' to a wall; kept with wallId null.'); }
      openings.push(op);
    }
    c.doors.sort(byIndex).forEach(function (it) { addOpening(it, 'door'); });
    c.windows.sort(byIndex).forEach(function (it) { addOpening(it, 'window'); });
    c.openings.sort(byIndex).forEach(function (it) { addOpening(it, 'opening'); });

    // -------- rooms
    var usedIds = {};
    function uniqueId(id) { var k = id, n = 2; while (usedIds[k]) k = id + '-' + (n++); usedIds[k] = true; return k; }
    var rooms = [];
    floorGeo.forEach(function (f) {
      var poly = simplify(floorOutline(f.geo.pos, f.geo.tris));
      if (poly.length < 3 || Math.abs(polyArea(poly)) < 0.05) { warnings.push('Skipped floor ' + f.it.name + ': no usable outline.'); return; }
      var name = roomName(f.it.name);
      rooms.push({ id: uniqueId('r-' + slug(name)), name: name, polygon: poly });
    });

    // -------- objects
    var objects = [];
    c.objects.forEach(function (it) {
      var geo = meshGeometry(doc, it, budget), rect = orientedRect(planPoints(geo.pos));
      // pick the axis closest to plan +x for size[0]; rotation in (-pi/2, pi/2]
      var u = rect.u, v = [-u[1], u[0]], su = rect.long, sv = rect.short;
      if (Math.abs(v[0]) > Math.abs(u[0])) { var t = u; u = v; v = t; var ts = su; su = sv; sv = ts; }
      var rot = Math.atan2(u[1], u[0]);
      if (rot > Math.PI / 2) rot -= Math.PI; else if (rot <= -Math.PI / 2) rot += Math.PI;
      objects.push({ id: uniqueId('ob-' + slug(it.name)), category: category(it.name), center: rect.center, size: [su, sv], rotation: rot });
    });

    // -------- translate so min x / y = 0 (no rotation, no mirroring)
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    function acc(p) { if (p[0] < minX) minX = p[0]; if (p[1] < minY) minY = p[1]; if (p[0] > maxX) maxX = p[0]; if (p[1] > maxY) maxY = p[1]; }
    walls.forEach(function (w) { acc(w.a); acc(w.b); });
    openings.forEach(function (o) { acc(o.a); acc(o.b); });
    rooms.forEach(function (r) { r.polygon.forEach(acc); });
    objects.forEach(function (o) {
      var cs = Math.cos(o.rotation), sn = Math.sin(o.rotation), hx = o.size[0] / 2, hy = o.size[1] / 2;
      [[-1, -1], [1, -1], [1, 1], [-1, 1]].forEach(function (k) { acc([o.center[0] + cs * hx * k[0] - sn * hy * k[1], o.center[1] + sn * hx * k[0] + cs * hy * k[1]]); });
    });
    function T(p) { return [r3(Math.max(0, p[0] - minX)), r3(Math.max(0, p[1] - minY))]; }

    var now = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
    var plan = {
      version: 1,
      id: uuid(),
      address: opts.address != null ? String(opts.address) : '',
      jobRef: opts.jobRef != null ? String(opts.jobRef) : '',
      createdAt: now,
      updatedAt: now,
      walls: walls.map(function (w) { return { id: w.id, a: T(w.a), b: T(w.b), height: r3(w.height) }; }),
      openings: openings.map(function (o) { return { id: o.id, type: o.type, wallId: o.wallId, a: T(o.a), b: T(o.b), height: r3(o.height), sill: r3(o.sill) }; }),
      rooms: rooms.map(function (r) { var poly = r.polygon.map(T); return { id: r.id, name: r.name, polygon: poly, area: Math.round(Math.abs(polyArea(poly)) * 100) / 100 }; }),
      objects: objects.map(function (o) { return { id: o.id, category: o.category, center: T(o.center), size: [r3(o.size[0]), r3(o.size[1])], rotation: r4(o.rotation) }; }),
      markup: { sources: [], affected: [], removals: [], readings: [], thresholds: { damp: 15, wet: 20 } }
    };

    var totalArea = plan.rooms.reduce(function (s, r) { return s + r.area; }, 0);
    var summary = {
      walls: plan.walls.length,
      doors: plan.openings.filter(function (o) { return o.type === 'door'; }).length,
      windows: plan.openings.filter(function (o) { return o.type === 'window'; }).length,
      openings: plan.openings.filter(function (o) { return o.type === 'opening'; }).length,
      rooms: plan.rooms.length,
      objects: plan.objects.length,
      joints: joints.length,
      roomNames: plan.rooms.map(function (r) { return r.name; }),
      totalArea: Math.round(totalArea * 10) / 10,
      size: [r3(maxX - minX), r3(maxY - minY)],
      unattachedOpenings: unattached,
      warnings: warnings
    };
    summary.message = 'Polycam floor plan: ' + summary.walls + ' walls, ' + summary.doors + ' doors, ' + summary.windows + ' windows, ' +
      summary.rooms + ' rooms (' + summary.totalArea + ' m²), ' + summary.objects + ' furniture/fixtures; about ' +
      summary.size[0].toFixed(1) + ' × ' + summary.size[1].toFixed(1) + ' m.' + (unattached.length ? ' ' + unattached.length + ' opening(s) could not be placed on a wall.' : '');
    // which Joint_N post each wall end was snapped to (null = free end); for tests / debugging
    var wallEnds = {};
    walls.forEach(function (w) { wallEnds[w.id] = { node: w.node, a: w.aJoint || null, b: w.bJoint || null, thickness: r3(w.thickness) }; });
    return { plan: plan, warnings: warnings, summary: summary, wallEnds: wallEnds };
  }

  var api = {
    version: '1.0.0',
    toPlan: function (arrayBuffer, opts) { return convert(arrayBuffer, opts).plan; },
    convert: convert,
    inspect: function (arrayBuffer) { return convert(arrayBuffer, {}).summary; },
    // exposed for tests
    _internal: { parseGLB: parseGLB, orientedRect: orientedRect, convexHull: convexHull, polyArea: polyArea, roomName: roomName, category: category }
  };
  root.SecureScanGLB = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : (typeof window !== 'undefined' ? window : this));
