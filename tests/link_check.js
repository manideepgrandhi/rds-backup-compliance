// v1.4.1 cross-tab links: Backups -> Compliance, Compliance -> Backups, browser Back, deep links, duplicate identifiers, keyboard.
// Usage: node link_check.js <report.html> [screenshot-dir] -> JSON {checks, fails}; exit 1 on any failure.
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
  const url = 'file://' + file;
  const deep = async h => { await g.goto(url + h, {waitUntil: 'load'}); await g.reload({waitUntil: 'load'}); };
  await g.goto(url, {waitUntil: 'load'});
  const D = await g.evaluate(() => JSON.parse(document.getElementById('data').textContent));
  const K = r => r.account_id + '|' + r.region + '|' + r.identifier;
  const st = () => g.evaluate(() => ({tab: document.querySelector('.tabs button.on').dataset.t, hash: location.hash,
    rows: [...document.querySelectorAll('#main tr.res')].map(t => t.dataset.k), hl: [...document.querySelectorAll('#main tr.hl')].map(t => t.dataset.k),
    open: [...document.querySelectorAll('#main tr.res.open')].map(t => t.dataset.k), res: document.getElementById('b-res').value,
    acct: document.getElementById('f-acct').value, region: document.getElementById('f-region').value, q: document.getElementById('f-q').value,
    status: document.getElementById('f-status').value, inView: (() => { const t = document.querySelector('#main tr.hl'); if (!t) return false; const r = t.getBoundingClientRect(); return r.top >= 0 && r.bottom <= innerHeight; })(),
    empty: !!document.getElementById('b-empty')}));
  // pick a target: prefer an identifier that repeats across accounts / regions
  const cnt = {}; D.rows.forEach(r => { cnt[r.identifier] = (cnt[r.identifier] || 0) + 1; });
  const dup = D.rows.filter(r => cnt[r.identifier] > 1);
  const tgt = (dup.length ? dup[dup.length - 1] : D.rows[D.rows.length - 1]), tk = K(tgt);
  // Compliance -> Backups via the small "backups" link
  await g.select('#f-status', D.rows[0].status); await sleep(50);
  await g.select('#f-status', ''); await sleep(50);
  const sel = 'tr.res[data-k="' + tk.replace(/"/g, '\\"') + '"] a.bkl';
  ok(await g.$(sel + '') !== null, 'compliance row has a backups link');
  await g.click(sel); await sleep(100); let s = await st();
  ok(s.tab === 'bk' && s.res === tk, 'backups link opens Backups tab on that resource (' + s.res + ')');
  ok(s.hash === '#view=bk&res=' + encodeURIComponent(tk), 'hash updated for backups (' + s.hash + ')');
  if (shots) { await g.screenshot({path: path.join(shots, 'link_to_backups_desktop.png'), fullPage: true}); }
  // Back returns to Compliance
  await g.goBack(); await sleep(150); s = await st();
  ok(s.tab === 'comp' && s.hash === '', 'Back returns to Compliance tab (' + s.tab + ' ' + s.hash + ')');
  // Backups -> Compliance from all mode, on the duplicate id
  await g.click('.tabs button[data-t="bk"]'); await g.select('#b-res', '*all*'); await g.select('#b-period', 'all'); await sleep(80);
  const link = await g.$('#b-out a.go[data-c][data-k="' + tk.replace(/"/g, '\\"') + '"]');
  if (link) {
    await g.select('#f-status', 'COMPLIANT'); await sleep(30);   // a filter on the other tab is cleared by the link
    await link.click(); await sleep(150); s = await st();
    ok(s.tab === 'comp' && s.rows.length === 1 && s.rows[0] === tk, 'backups identifier link shows only that resource (' + s.rows + ')');
    ok(s.hl[0] === tk && s.open.includes(tk) && s.inView, 'row highlighted, expanded and scrolled into view');
    ok(s.acct === tgt.account_id && s.region === tgt.region && s.status === '' && s.q === '', 'filters cleared except account + region');
    if (dup.length) ok(D.rows.filter(r => r.identifier === tgt.identifier && K(r) !== tk).every(r => !s.rows.includes(K(r))), 'duplicate identifier in another account/region not shown');
    if (shots) await g.screenshot({path: path.join(shots, 'link_to_compliance_desktop.png'), fullPage: true});
    await g.goBack(); await sleep(150); s = await st();
    ok(s.tab === 'bk' && s.res === '*all*' && s.status === 'COMPLIANT', 'Back returns to Backups all mode with prior state (' + s.tab + ' ' + s.res + ' ' + s.status + ')');
    await g.goForward(); await sleep(150); s = await st();
    ok(s.tab === 'comp' && s.rows.length === 1, 'Forward re-applies the compliance link');
  } else ok(false, 'backups all-mode link for ' + tk);
  // Keyboard: focus the backups link and press Enter
  await deep(''); await sleep(50);
  await g.focus(sel); await g.keyboard.press('Enter'); await sleep(100); s = await st();
  ok(s.tab === 'bk' && s.res === tk, 'Enter on backups link works');
  // deep links on load
  await deep('#view=comp&id=' + encodeURIComponent(tk)); await sleep(100); s = await st();
  ok(s.tab === 'comp' && s.rows.length === 1 && s.hl[0] === tk, 'deep link to compliance row');
  await g.setViewport({width: 390, height: 844}); await sleep(100);
  if (shots) await g.screenshot({path: path.join(shots, 'link_to_compliance_mobile.png'), fullPage: true});
  await g.click('#f-unpin'); await sleep(50); s = await st();
  ok(s.rows.length === D.rows.filter(r => r.account_id === tgt.account_id && r.region === tgt.region).length && !(await g.$('#f-unpin')), 'clear chip shows the account + region again');
  await deep('#view=bk&res=' + encodeURIComponent(tk)); await sleep(100); s = await st();
  ok(s.tab === 'bk' && s.res === tk, 'deep link to backups');
  if (shots) await g.screenshot({path: path.join(shots, 'link_to_backups_mobile.png'), fullPage: true});
  await deep('#view=comp&id=nope%7Cx%7C%3Cimg%3E'); await sleep(50); s = await st();
  ok(s.tab === 'comp' && s.rows.length === D.rows.length, 'unknown deep link ignored');
  // empty state: a resource without backups (synthesised if the fixture has none)
  await g.setViewport({width: 1500, height: 1000});
  await deep('');
  const nob = await g.evaluate(() => { const D = JSON.parse(document.getElementById('data').textContent), s = {}; D.snaps.forEach(x => { if (x.s.length) s[x.k] = 1; });
    const r = D.rows.filter(r => !s[r.account_id + '|' + r.region + '|' + r.identifier])[0]; return r ? r.account_id + '|' + r.region + '|' + r.identifier : null; });
  if (nob) { await deep('#view=bk&res=' + encodeURIComponent(nob)); await sleep(80); s = await st();
    ok(s.empty, 'empty-state message for ' + nob);
    if (shots) await g.screenshot({path: path.join(shots, 'backups_empty_desktop.png'), fullPage: true}); }
  else { s = await st(); ok(!s.empty, 'no empty-state message when backups exist'); }
  ok(errs.length === 0, 'no JS errors: ' + errs.join(' | '));
  await b.close();
  console.log(JSON.stringify({checks: n, fails, nobackups: nob, dup: dup.length})); process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log(JSON.stringify({checks: n, fails: fails.concat(String(e.stack || e))})); process.exit(1); });
