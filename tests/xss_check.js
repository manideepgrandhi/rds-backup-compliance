// Regression check (v1.2.1): a tampered --merge data file must not execute script in the HTML report.
// Usage: node xss_check.js <report.html>  -> prints JSON {checks, fails}; exit 1 if any injected payload ran.
// Opens every tab, cycles every <select> option, follows the in-page "go" links, then looks for injected elements.
const p = require('puppeteer-core');
const path = require('path');
const sleep = ms => new Promise(r => setTimeout(r, ms));
(async () => {
  const fails = []; let checks = 0; const ok = (c, m) => { checks++; if (!c) fails.push(m); };
  const b = await p.launch({executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox']});
  const g = await b.newPage(); const dialogs = [];
  g.on('dialog', d => { dialogs.push(d.message()); d.dismiss(); });
  await g.goto('file://' + path.resolve(process.argv[2]), {waitUntil: 'load'});
  const clickAll = async sel => { for (const x of await g.$$(sel)) { try { if (await x.isVisible()) await x.click(); } catch (e) {} } };
  for (const tab of await g.$$eval('.tabs button', bs => bs.map((_, i) => i))) {
    await g.evaluate(i => document.querySelectorAll('.tabs button')[i].click(), tab); await sleep(100);
    const sels = await g.$$eval('select', s => s.filter(x => x.offsetParent !== null && x.id).map(x => [x.id, [...x.options].map(o => o.value)]));
    for (const [id, vals] of sels) { for (const v of vals) { await g.select('#' + id, v); } await g.select('#' + id, vals[0]); }
    await clickAll('a.go');
  }
  await sleep(300);
  const st = await g.evaluate(() => ({xss: window.__xss || null, injected: document.querySelectorAll('[data-xss],img[src="x"],svg[onload]').length}));
  ok(st.xss === null, 'payload executed (window.__xss=' + JSON.stringify(st.xss) + ')');
  ok(st.injected === 0, st.injected + ' injected element(s) in the DOM');
  ok(dialogs.length === 0, 'dialog opened: ' + dialogs.join('|'));
  await b.close();
  console.log(JSON.stringify({checks, fails})); process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log(JSON.stringify({checks: 0, fails: [String(e)]})); process.exit(1); });
