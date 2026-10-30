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
    ok(await g.evaluate(() => document.getElementById('b-res').value !== '*all*'), 'single resource selected after link click');
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
    // "All clusters and instances" mode: manual snapshots only, with account/region/resource/type columns
    const firstOpt = await g.evaluate(() => document.querySelector('#b-res option').value);
    ok(firstOpt === '*all*', 'All option is first in resource dropdown');
    const av = () => g.evaluate(() => ({sec: [...document.querySelectorAll('#b-out h2')].map(h => h.dataset.sec),
      cols: [...document.querySelectorAll('#b-out table[data-sec="manual-all"] th')].map(t => t.textContent),
      rows: [...document.querySelectorAll('#b-out table[data-sec="manual-all"] tbody tr')].map(t => [...t.children].map(c => c.textContent)),
      filt: [...document.querySelectorAll('.ballf')].map(l => l.style.display !== 'none')}));
    await sel('b-period', '12'); await sel('b-res', '*all*'); let a12 = await av();
    ok(a12.sec.length === 1 && a12.sec[0] === 'manual-all', 'all mode shows only the manual section (' + a12.sec + ')');
    ok(['Account', 'Region', 'Resource', 'Type', 'Snapshot', 'Created (UTC)', 'Created (IST)'].every(c => a12.cols.includes(c)), 'all mode columns');
    ok(a12.rows.length >= 3 && a12.rows.some(r => r[2] === 'orders-aurora-pg15'), 'all mode lists manual snapshots of several resources (' + a12.rows.length + ')');
    ok(new Set(a12.rows.map(r => r[2])).size > 1, 'all mode spans more than one resource');
    ok(a12.filt.length === 3 && a12.filt.every(Boolean), 'account/region/engine filters visible in all mode');
    await sel('b-period', '3'); let a3 = await av(); ok(a3.rows.length < a12.rows.length, 'all mode period 3m < 12m (' + a3.rows.length + ' < ' + a12.rows.length + ')');
    await sel('b-period', '12');
    const reg = a12.rows[0][1]; await sel('b-region', reg); let ar = await av();
    ok(ar.rows.length > 0 && ar.rows.every(r => r[1] === reg) && ar.rows.length <= a12.rows.length, 'all mode region filter');
    await g.click('#b-csv'); await sleep(200);
    const ac = await g.evaluate(() => window.__csv[window.__csv.length - 1]).then(t => t.replace(/^\ufeff/, '').trim().split('\r\n'));
    ok(/^account_id,region,identifier,type,kind,/.test(ac[0]) && ac.length === ar.rows.length + 1 && ac.slice(1).every(l => l.includes(',manual,')), 'all mode csv = filtered table (' + ac.length + ')');
    await sel('b-region', ''); const accts = [...new Set(a12.rows.map(r => r[0]))];
    await sel('b-acct', accts[0]); let aa = await av(); ok(aa.rows.every(r => r[0] === accts[0]), 'all mode account filter');
    await sel('b-acct', '');
    if (shots) await g.screenshot({path: path.join(shots, 'backups_all_manual.png'), fullPage: true});
    await g.click('#b-out a.go'); await sleep(100); let back = await bt();
    ok(['manual', 'automated', 'backup'].every(k => k in back.sec), 'resource link in all mode opens single view');
    const hid = await g.evaluate(() => [...document.querySelectorAll('.ballf')].every(l => l.style.display === 'none'));
    ok(hid, 'all-mode filters hidden in single view');
  }
  ok(errs.length === 0, 'no JS errors: ' + errs.join(' | ')); ok(net.length === 0, 'no network: ' + net.join(' '));
  await b.close();
  console.log(JSON.stringify({checks: n, fails})); process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log(JSON.stringify({checks: n, fails: fails.concat(String(e))})); process.exit(1); });
