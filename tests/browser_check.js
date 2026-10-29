// Headless check of the backup compliance HTML (run_tests.sh runs it when puppeteer-core + Chrome are available).
// Usage: node browser_check.js <report.html> [screenshot-dir] -> JSON {checks, fails}; exit 1 on any failure.
const p = require('puppeteer-core'); const path = require('path'), fs = require('fs');
const fails = []; let n = 0; const ok = (c, m) => { n++; if (!c) fails.push(m); };
const sleep = ms => new Promise(x => setTimeout(x, ms));
(async () => {
  const file = path.resolve(process.argv[2]), shots = process.argv[3];
  if (shots) fs.mkdirSync(shots, {recursive: true});
  const b = await p.launch({executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox']});
  const g = await b.newPage(); const errs = [], net = [];
  g.on('pageerror', e => errs.push(e.message)); g.on('console', m => m.type() === 'error' && errs.push(m.text()));
  await g.setRequestInterception(true);
  g.on('request', q => { if (!/^(file|blob|data):/.test(q.url())) net.push(q.url()); q.continue(); });
  await g.setViewport({width: 1500, height: 1000});
  await g.goto('file://' + file, {waitUntil: 'load'});
  await g.evaluate(() => { window.__csv = []; const o = URL.createObjectURL; URL.createObjectURL = b => { b.arrayBuffer().then(a => window.__csv.push(new TextDecoder('utf-8', {ignoreBOM: true}).decode(a))); return o(b); }; });
  const st = () => g.evaluate(() => {
    const card = k => +document.querySelector('.card[data-k="' + k + '"] .v').textContent;
    return {rows: document.querySelectorAll('#main tbody tr').length, res: card('resources'), comp: card('compliant'), nc: card('non-compliant'),
      due: card('not-yet-due'), regions: [...document.querySelectorAll('#regions tbody tr')].map(t => t.dataset.k),
      foot: document.querySelector('#regions tfoot tr').textContent, count: document.getElementById('f-count').textContent,
      head: document.body.innerHTML.split('<div class="tabs">')[0]}; });
  const sel = async (id, v) => { await g.select('#' + id, v); await sleep(50); };
  let s = await st();
  ok(s.rows === s.res && s.rows > 0, 'rows = resources card');
  ok(!/(us|eu|ap|ca)-[a-z]+-\d/.test(s.head), 'no region names above the tabs');
  ok(!s.regions.some(k => /ca-central-1/.test(k)), 'empty region not listed');
  const all = s.rows;
  if (shots) await g.screenshot({path: path.join(shots, 'compliance_tab.png'), fullPage: true});
  await sel('f-status', 'NON-COMPLIANT'); s = await st();
  ok(s.rows === s.nc && s.comp === 0 && s.rows > 0, 'status filter NON-COMPLIANT');
  await g.click('#f-csv'); await sleep(200);
  const csv = await g.evaluate(() => window.__csv[window.__csv.length - 1]);
  const lines = csv.replace(/^\ufeff/, '').trim().split('\r\n');
  ok(csv.charCodeAt(0) === 0xfeff, 'csv BOM'); ok(lines.length === s.rows + 1, 'csv has filtered rows only (' + lines.length + ')');
  ok(/^account_id,region,identifier/.test(lines[0]) && !/arn|environment|owner|application|note/i.test(lines[0]), 'csv header');
  ok(lines.slice(1).every(l => /NON-COMPLIANT/.test(l)), 'csv rows all NON-COMPLIANT');
  await g.click('#f-reset'); await sleep(50);
  await sel('f-global', 'orders-global'); s = await st(); ok(s.rows === 2, 'global filter orders-global = 2 rows (' + s.rows + ')');
  await sel('f-global', '(not global)'); s = await st(); ok(s.rows > 0 && s.rows < all, 'global filter (not global)');
  await g.click('#f-reset'); await sleep(50);
  await sel('f-role', 'secondary'); s = await st(); ok(s.rows >= 1, 'role filter secondary');
  if (shots) await g.screenshot({path: path.join(shots, 'compliance_secondary_filter.png'), fullPage: true});
  await g.click('#f-reset'); await sleep(50); s = await st(); ok(s.rows === all, 'reset');
  ok(/All regions/.test(s.foot), 'per-region footer');
  // Backups tab via identifier link
  const has = await g.evaluate(() => !!document.querySelector('#main tr[data-k$="|orders-aurora-pg15"] a.go'));
  if (has) {
    await g.click('#main tr[data-k$="|orders-aurora-pg15"] a.go'); await sleep(100);
    const bt = () => g.evaluate(() => ({vis: document.getElementById('bk').offsetParent !== null,
      sec: Object.fromEntries([...document.querySelectorAll('#b-out h2')].map(h => [h.dataset.sec, +h.textContent.match(/\((\d+)\)/)[1]])),
      cols: [...document.querySelectorAll('#b-out table[data-sec="backup"] th')].map(t => t.textContent)}));
    let b12 = await bt(); ok(b12.vis, 'backups tab visible after click');
    ok(b12.sec.manual === 3, 'manual 12m = 3 (' + b12.sec.manual + ')'); ok(b12.sec.automated === 7, 'automated = 7 (' + b12.sec.automated + ')');
    ok(b12.cols.includes('Created (IST)') && b12.cols.includes('Created (UTC)') && b12.cols.includes('Class'), 'backup cols UTC+IST+class');
    if (shots) await g.screenshot({path: path.join(shots, 'backups_tab_12m.png'), fullPage: true});
    await sel('b-period', '6'); let b6 = await bt(); ok(b6.sec.manual === 2, 'manual 6m = 2 (' + b6.sec.manual + ')');
    await sel('b-period', '3'); let b3 = await bt(); ok(b3.sec.manual === 1, 'manual 3m = 1 (' + b3.sec.manual + ')');
    ok(b3.sec.backup < b12.sec.backup, 'AWS Backup points shrink with period (' + b3.sec.backup + ' < ' + b12.sec.backup + ')');
    if (shots) await g.screenshot({path: path.join(shots, 'backups_tab_3m.png'), fullPage: true});
    await g.click('#b-csv'); await sleep(200);
    const bc = await g.evaluate(() => window.__csv[window.__csv.length - 1]).then(t => t.replace(/^\ufeff/, '').trim().split('\r\n'));
    ok(bc.length === 1 + b3.sec.manual + b3.sec.automated + b3.sec.backup, 'backups csv rows = 3m view');
  }
  ok(errs.length === 0, 'no JS errors: ' + errs.join(' | ')); ok(net.length === 0, 'no network: ' + net.join(' '));
  await b.close();
  console.log(JSON.stringify({checks: n, fails})); process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log(JSON.stringify({checks: n, fails: fails.concat(String(e))})); process.exit(1); });
