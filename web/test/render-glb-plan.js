#!/usr/bin/env node
// Throwaway visual check for web/glb-import.js. Converts the private Polycam fixture,
// writes web/test/out/polycam-example.plan.json + .svg + .png (all git-ignored).
// Usage: node web/test/render-glb-plan.js
'use strict';
const fs = require('fs');
const path = require('path');
const G = require('../glb-import.js');

const FIX = path.join(__dirname, '..', '..', 'private-fixtures', 'polycam-example.glb');
const OUT = path.join(__dirname, 'out');
if (!fs.existsSync(FIX)) { console.log('SKIP: private fixture ' + FIX + ' not present.'); process.exit(0); }
fs.mkdirSync(OUT, { recursive: true });

const res = G.convert(fs.readFileSync(FIX), { address: '(private fixture)' });
const plan = res.plan;
fs.writeFileSync(path.join(OUT, 'polycam-example.plan.json'), JSON.stringify(plan, null, 2));

const S = 70, M = 1.2;   // px per metre, margin (m)
const W = res.summary.size[0] + 2 * M, H = res.summary.size[1] + 2 * M + 0.6;
const X = (p) => ((p[0] + M) * S).toFixed(1), Y = (p) => ((p[1] + M + 0.6) * S).toFixed(1);
const tints = ['#eef0fb', '#fbf1ea', '#f3f3f3', '#eef7f1', '#f8f3e4', '#f1ecf7'];
const esc = (s) => String(s).replace(/[<&>]/g, (c) => ({ '<': '&lt;', '&': '&amp;', '>': '&gt;' }[c]));
let s = `<svg xmlns="http://www.w3.org/2000/svg" width="${(W * S) | 0}" height="${(H * S) | 0}" viewBox="0 0 ${(W * S) | 0} ${(H * S) | 0}" font-family="Helvetica,Arial,sans-serif">\n`;
s += `<rect width="100%" height="100%" fill="#fff"/>\n<text x="${(W * S / 2) | 0}" y="40" text-anchor="middle" font-size="26" font-weight="bold">Floorplan (import check)</text>\n`;
s += `<text x="${(W * S / 2) | 0}" y="70" text-anchor="middle" font-size="16">Approximately ${res.summary.totalArea} m² total · ${res.summary.size[0]} × ${res.summary.size[1]} m</text>\n`;
function centroid(poly) {
  let a = 0, cx = 0, cy = 0;
  for (let i = 0; i < poly.length; i++) { const p = poly[i], q = poly[(i + 1) % poly.length], c = p[0] * q[1] - q[0] * p[1]; a += c; cx += (p[0] + q[0]) * c; cy += (p[1] + q[1]) * c; }
  return [cx / (3 * a), cy / (3 * a)];
}
plan.rooms.forEach((r, i) => {
  s += `<polygon points="${r.polygon.map((p) => X(p) + ',' + Y(p)).join(' ')}" fill="${tints[i % tints.length]}" stroke="#c9c9d6" stroke-width="1"/>\n`;
});
plan.objects.forEach((o) => {
  const cs = Math.cos(o.rotation), sn = Math.sin(o.rotation), hx = o.size[0] / 2, hy = o.size[1] / 2;
  const pts = [[-1, -1], [1, -1], [1, 1], [-1, 1]].map((k) => [o.center[0] + cs * hx * k[0] - sn * hy * k[1], o.center[1] + sn * hx * k[0] + cs * hy * k[1]]);
  s += `<polygon points="${pts.map((p) => X(p) + ',' + Y(p)).join(' ')}" fill="none" stroke="#9a9aa8" stroke-width="1"/>\n`;
});
plan.walls.forEach((w) => { s += `<line x1="${X(w.a)}" y1="${Y(w.a)}" x2="${X(w.b)}" y2="${Y(w.b)}" stroke="#5b5f7b" stroke-width="${0.12 * S}" stroke-linecap="square"/>\n`; });
plan.openings.forEach((o) => {
  s += `<line x1="${X(o.a)}" y1="${Y(o.a)}" x2="${X(o.b)}" y2="${Y(o.b)}" stroke="#fff" stroke-width="${0.13 * S}"/>\n`;
  if (o.type === 'window') s += `<line x1="${X(o.a)}" y1="${Y(o.a)}" x2="${X(o.b)}" y2="${Y(o.b)}" stroke="#5b5f7b" stroke-width="5" /><line x1="${X(o.a)}" y1="${Y(o.a)}" x2="${X(o.b)}" y2="${Y(o.b)}" stroke="#fff" stroke-width="3"/>\n`;
  else s += `<line x1="${X(o.a)}" y1="${Y(o.a)}" x2="${X(o.b)}" y2="${Y(o.b)}" stroke="#d04040" stroke-width="1.5"/>\n`;
  [o.a, o.b].forEach((p) => { s += `<circle cx="${X(p)}" cy="${Y(p)}" r="2.5" fill="#d04040"/>\n`; });
});
// wall ends: green = shared with another wall, orange = lone end
const cnt = {}; plan.walls.forEach((w) => [w.a, w.b].forEach((p) => { cnt[p.join()] = (cnt[p.join()] || 0) + 1; }));
Object.keys(cnt).forEach((k) => { const p = k.split(',').map(Number); s += `<circle cx="${X(p)}" cy="${Y(p)}" r="3" fill="${cnt[k] > 1 ? '#2a9d4a' : '#f08c00'}"/>\n`; });
plan.walls.forEach((w) => { const m = [(w.a[0] + w.b[0]) / 2, (w.a[1] + w.b[1]) / 2]; s += `<text x="${X(m)}" y="${Y(m)}" font-size="10" fill="#e33" text-anchor="middle">${w.id}</text>\n`; });
plan.rooms.forEach((r) => {
  const c = centroid(r.polygon);
  s += `<text x="${X(c)}" y="${Y(c)}" text-anchor="middle" font-size="15" fill="#222">${esc(r.name)}</text><text x="${X(c)}" y="${+Y(c) + 18}" text-anchor="middle" font-size="13" fill="#555">${r.area.toFixed(1)} m²</text>\n`;
});
s += `<line x1="${M * S}" y1="${(H - 0.4) * S}" x2="${(M + 1) * S}" y2="${(H - 0.4) * S}" stroke="#000" stroke-width="3"/><text x="${M * S}" y="${(H - 0.4) * S + 18}" font-size="13">1 m</text>\n</svg>\n`;
fs.writeFileSync(path.join(OUT, 'polycam-example.svg'), s);

console.log(res.summary.message);
console.log('Overall size: ' + res.summary.size[0] + ' m x ' + res.summary.size[1] + ' m');
plan.rooms.forEach((r) => console.log('  ' + r.name.padEnd(12) + r.area.toFixed(2) + ' m2'));
if (res.warnings.length) console.log('Warnings:\n  ' + res.warnings.join('\n  '));

(async () => {
  const png = path.join(OUT, 'polycam-example.png');
  try {
    const sharp = require('/opt/npm-tools/node_modules/sharp');
    await sharp(Buffer.from(s)).png().toFile(png);
  } catch (e) {
    const { chromium } = require('/opt/npm-tools/node_modules/playwright');
    const b = await chromium.launch({ executablePath: '/usr/bin/google-chrome' });
    const p = await b.newPage({ viewport: { width: (W * S) | 0, height: (H * S) | 0 } });
    await p.setContent(s); await p.screenshot({ path: png }); await b.close();
  }
  console.log('Wrote ' + png);
})();
