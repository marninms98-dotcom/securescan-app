// Checks the claude.ai published-page export path: every export goes through claude.use("downloads").save().
const { chromium } = require('/opt/npm-tools/node_modules/playwright');
const path = require('path');
(async () => {
  const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome' });
  const page = await browser.newPage({ viewport: { width: 430, height: 932 }, hasTouch: true });
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  await page.addInitScript(() => {
    window.__saves = [];
    window.__printed = 0;
    window.print = () => { window.__printed++; };
    window.claude = { use: async name => name === 'downloads' ? {
      save: async ({ filename, data }) => {
        if (window.__decline) { const e = new Error('no'); e.code = 'declined'; throw e; }
        const size = data instanceof Blob ? data.size : String(data).length;
        const head = data instanceof Blob ? [...new Uint8Array(await data.slice(0, 4).arrayBuffer())] : [];
        window.__saves.push({ filename, size, isBlob: data instanceof Blob, type: data.type, head });
        return { status: 'saved' };
      } } : null };
  });
  await page.goto('file://' + path.resolve(__dirname, '../editor.html'));
  await page.waitForTimeout(600);
  const labels = ['Job pack', 'Inspection report (PDF)', 'Quote (PDF)', 'Floor plan PNG', 'Marked-up plan PNG', 'Wall elevations PNG', 'Moisture & scope sheet', 'Floor plan SVG', 'Marked-up plan SVG', 'Schedule CSV', 'Save plan.json'];
  for (const label of labels) {
    await page.getByRole('button', { name: 'Export', exact: true }).click();
    const n = await page.evaluate(() => window.__saves.length);
    const b = page.getByRole('button', { name: new RegExp('^' + label.replace(/[&.()]/g, m => '\\' + m)) });
    if (!(await b.isVisible())) await page.getByRole('button', { name: /^More exports/ }).click();      // the single files sit under More
    await b.click();
    await page.waitForFunction(n => window.__saves.length > n, n, { timeout: 30000 });
  }
  const saves = await page.evaluate(() => window.__saves);
  const printed = await page.evaluate(() => window.__printed);
  await page.evaluate(() => { window.__decline = true; document.getElementById('toast').textContent = ''; });
  await page.getByRole('button', { name: 'Export', exact: true }).click();
  await page.getByRole('button', { name: /^More exports/ }).click();
  await page.getByRole('button', { name: /^Schedule CSV/ }).click();
  await page.waitForTimeout(500);
  const toastAfterDecline = await page.evaluate(() => document.getElementById('toast').textContent);
  await browser.close();
  console.log(saves);
  const exts = saves.map(s => s.filename.split('.').pop());
  const pack = saves[0];
  const zipOk = pack.filename === '30-sample-cr-testwood-wa-job-pack.zip' && pack.type === 'application/zip' && pack.head.join(',') === '80,75,3,4' && pack.size > 100000;
  console.log('job pack', pack, zipOk ? 'ok' : 'BAD');
  const ok = zipOk && saves.length === 11 && exts.join(',') === 'zip,html,html,png,png,png,html,svg,svg,csv,json' && saves[1].filename === '30-sample-cr-testwood-wa-inspection-report.html' && saves[2].filename === '30-sample-cr-testwood-wa-quote.html' && saves.every(s => s.isBlob && s.size > 500) && printed === 0 && errors.length === 0 && !/Exported/.test(toastAfterDecline);
  console.log('printed', printed, 'errors', errors, 'toast after decline:', JSON.stringify(toastAfterDecline));
  console.log(ok ? 'PASS published-page exports' : 'FAIL published-page exports');
  process.exit(ok ? 0 : 1);
})();
