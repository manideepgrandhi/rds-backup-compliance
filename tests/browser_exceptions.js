// Headless check of the v1.6.0 compliance exceptions in the backup HTML (report built with tests' exceptions fixture).
// Usage: node browser_exceptions.js <report.html> [screenshot-dir] -> JSON {checks, fails}; exit 1 on any failure.
const p = require('puppeteer-core'); const path = require('path'), fs = require('fs');
const fails = []; let n = 0; const ok = (c, m) => { n++; if (!c) fails.push(m); };
const sleep = ms => new Promise(x => setTimeout(x, ms));
(async () => {
  const file = path.resolve(process.argv[2]), shots = process.argv[3];
  if (shots) fs.mkdirSync(shots, {recursive: true});
  const b = await p.launch({executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox']});
  const g = await b.newPage(); const errs = [];
  g.on('pageerror', e => errs.push(e.message)); g.on('console', m => m.type() === 'error' && errs.push(m.text()));
  await g.setViewport({width: 1500, height: 1000});
  await g.goto('file://' + file, {waitUntil: 'load'});
  await g.evaluate(() => { localStorage.clear(); window.__csv = []; const o = URL.createObjectURL; URL.createObjectURL = b => { b.arrayBuffer().then(a => window.__csv.push(new TextDecoder('utf-8', {ignoreBOM: true}).decode(a))); return o(b); }; });
  await g.reload({waitUntil: 'load'});
  await g.evaluate(() => { window.__csv = []; const o = URL.createObjectURL; URL.createObjectURL = b => { b.arrayBuffer().then(a => window.__csv.push(new TextDecoder('utf-8', {ignoreBOM: true}).decode(a))); return o(b); }; });
  const sel = async (id, v) => { await g.select('#' + id, v); await sleep(60); };
  const st = () => g.evaluate(() => {
    const card = k => { const c = document.querySelector('.card[data-k="' + k + '"]'); return c ? c : null; };
    const rows = [...document.querySelectorAll('#main tbody tr.res')];
    const ths = [...document.querySelectorAll('#main thead th')].map(t => t.textContent);
    const xi = ths.indexOf('Exception');
    return {rows: rows.length, ids: rows.map(r => r.textContent), comp: +card('compliant').querySelector('.v').textContent,
      nc: +card('non-compliant').querySelector('.v').textContent, compSub: (card('compliant').querySelector('.xs') || {}).textContent || '',
      pop: [...card('compliant').querySelectorAll('.pop div')].map(d => d.textContent),
      pct: (card('compliance') || {textContent: ''}).textContent, ths, xi,
      xcells: rows.map(r => xi >= 0 && r.children[xi] ? r.children[xi].textContent : ''),
      stat: rows.map(r => [...r.children].find(c => /^s-/.test(c.className)) ? [...r.children].find(c => /^s-/.test(c.className)).textContent : ''),
      note: (document.getElementById('exc-note') || {textContent: ''}).textContent,
      regions: [...document.querySelectorAll('#regions tbody tr')].length, count: document.getElementById('f-count').textContent}; });
  let s = await st();
  ok(errs.length === 0, 'no JS errors: ' + errs.join('; '));
  ok(s.xi >= 0, 'Exception column present');
  ok(!!(await g.$('#f-exc')), 'Exceptions quick filter present');
  ok(s.comp === 4 && s.nc === 2, 'cards: compliant 4, non-compliant 2 (got ' + s.comp + ', ' + s.nc + ')');
  ok(/incl\. 3 exceptions/.test(s.compSub), 'compliant card: incl. 3 exceptions (' + s.compSub + ')');
  ok(s.pop.length === 3 && /Compliant\s*4 \(incl\. 3 exceptions\)/.test(s.pop[0]) && /Non-compliant\s*2/.test(s.pop[1]) && /expiring soon or no longer needed\s*2/.test(s.pop[2]), 'pop-up 3 lines: ' + s.pop.join(' / '));
  ok(/67/.test(s.pct), 'compliance % 67 (' + s.pct + ')');
  ok(s.stat.filter(t => /COMPLIANT \(EXCEPTION\)/.test(t)).length === 3, 'three COMPLIANT (EXCEPTION) badges');
  ok(s.stat.some(t => /COMPLIANT \(EXCEPTION\)actual NON-COMPLIANT/.test(t)), 'badge shows actual status');
  ok(s.xcells.some(t => /expiring soon/.test(t)) && s.xcells.some(t => /no longer needed/.test(t)) && s.xcells.some(t => /exception expired/.test(t)), 'flag badges in Exception column');
  ok(/1 expired/.test(s.note) && /gone-db/.test(s.note), 'notice: expired + unmatched (' + s.note + ')');
  const all = s.rows, allReg = s.regions;
  await sel('f-exc', 'yes'); s = await st();
  ok(s.rows === 3 && s.comp === 3 && s.nc === 0, 'Exceptions only: 3 rows, cards follow (' + s.rows + ',' + s.comp + ',' + s.nc + ')');
  ok(/incl\. 3 exceptions/.test(s.compSub), 'filtered card still incl. 3');
  await sel('f-exc', 'no'); s = await st();
  ok(s.rows === all - 3 && s.comp === 1 && s.nc === 2 && !s.pop.some(t => /expiring/.test(t)), 'Non-exceptions: rows ' + s.rows + ', comp ' + s.comp + ', pop without attention line');
  await sel('f-exc', 'attn'); s = await st();
  ok(s.rows === 2 && s.ids.some(t => /reports-pg/.test(t)) && s.ids.some(t => /orders-aurora-pg15/.test(t)), 'Expiring soon or no longer needed: 2 rows');
  await sel('f-exc', 'expired'); s = await st();
  ok(s.rows === 1 && /shop-dr-mysql/.test(s.ids[0]), 'Expired: 1 row');
  // combines with existing filters
  await sel('f-exc', 'yes'); await sel('f-region', await g.evaluate(() => [...document.querySelectorAll('#f-region option')].map(o => o.value).find(v => /us-east-1/.test(v)))); s = await st();
  ok(s.rows === 3 && s.regions <= allReg, 'Exceptions only + region us-east-1: 3 rows');
  await sel('f-status', 'NON-COMPLIANT'); s = await st();
  ok(s.rows === 0, 'Exceptions only + NON-COMPLIANT: 0 rows (excepted servers count as compliant)');
  await sel('f-status', ''); await sel('f-region', '');
  await sel('f-exc', 'yes');
  // CSV export follows the filter and carries the exception columns
  await g.click('#f-csv'); await sleep(60); await g.click('#cp [data-a=go]'); await sleep(300);
  const csv = await g.evaluate(() => window.__csv[window.__csv.length - 1] || '');
  const lines = csv.replace(/^\uFEFF/, '').trim().split(/\r?\n/);
  ok(/"exception","exception_reason","exception_expires","exception_flag","actual_status"$/.test(lines[0]), 'CSV header has exception columns');
  ok(lines.length === 4 && lines.slice(1).every(l => /COMPLIANT \(EXCEPTION\)/.test(l)), 'CSV export follows the filter: 3 exception rows (' + (lines.length - 1) + ')');
  if (shots) { await sel('f-exc', ''); await g.screenshot({path: path.join(shots, 'exceptions_all.png'), fullPage: true});
    await g.hover('.card[data-k="compliant"]'); await sleep(100); await g.screenshot({path: path.join(shots, 'exceptions_pop.png')}); }
  await b.close();
  console.log(JSON.stringify({checks: n, fails}));
  process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log(JSON.stringify({error: String(e)})); process.exit(1); });
