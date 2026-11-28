// Headless check of docs/rds_compliance_simulator.html (puppeteer-core + Chrome, like browser_check.js).
// Usage: node tests/browser_simulator.js [screenshot-dir]  -> JSON {checks, fails}; exit 1 on any failure.
// The page clock is frozen at Fri 27 Nov 2026 12:00 UTC so every preset is reproducible.
const p = require('puppeteer-core'), path = require('path'), fs = require('fs');
const ROOT = path.resolve(__dirname, '..'), FILE = process.env.SIM_HTML || path.join(ROOT, 'docs', 'rds_compliance_simulator.html'), shots = process.argv[2];
const FIX = Date.parse('2026-11-27T12:00:00Z');
const fails = []; let n = 0; const ok = (c, m) => { n++; if (!c) fails.push(m); };
const eq = (a, b, m) => ok(JSON.stringify(a) === JSON.stringify(b), m + ' | got ' + JSON.stringify(a) + ' want ' + JSON.stringify(b));
const sleep = ms => new Promise(x => setTimeout(x, ms));
// the shipped conf: key -> value (every setting in the file, in order)
const conf = {}; fs.readFileSync(path.join(ROOT, 'rds_backup_compliance_report.conf'), 'utf8').split('\n').forEach(l => { const m = /^([a-z][a-z-]*)=(.*)$/.exec(l); if (m) conf[m[1]] = m[2]; });
// statuses of the 15 original presets (schedule mode) as they were in v1.7.2 / before check-mode existed
const OLD = ['COMPLIANT', 'NOT YET DUE', 'NOT YET DUE', 'NOT YET DUE', 'NON-COMPLIANT', 'NON-COMPLIANT', 'COMPLIANT', 'NON-COMPLIANT', 'COMPLIANT', 'NON-COMPLIANT', 'NON-COMPLIANT', 'UNKNOWN', 'NOT YET DUE', 'NON-COMPLIANT', 'COMPLIANT'];
(async () => {
  if (shots) fs.mkdirSync(shots, {recursive: true});
  const b = await p.launch({executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox']});
  const g = await b.newPage(), errs = [], net = [];
  g.on('pageerror', e => errs.push(e.message)); g.on('console', m => m.type() === 'error' && errs.push(m.text()));
  await g.setRequestInterception(true); g.on('request', q => { if (!/^(file|blob|data):/.test(q.url())) net.push(q.url()); q.continue(); });
  await g.evaluateOnNewDocument(t => { const R = Date; class D extends R { constructor(...a) { if (a.length) super(...a); else super(t); } static now() { return t; } } window.Date = D; }, FIX);
  await g.setViewport({width: 1500, height: 1100}); await g.goto('file://' + FILE, {waitUntil: 'load'});
  const preset = async i => { await g.evaluate(i => window.__sim.applyPreset(i), i); await sleep(60); return g.evaluate(() => { const l = window.__last; return {status: l.row0.status, gaps: l.row0.gaps, w: [l.row0.weekly.have, l.row0.weekly.need, l.row0.weekly.target, l.row0.weekly.st], m: [l.row0.monthly.have, l.row0.monthly.need, l.row0.monthly.st], d: l.row0.daily.st, mode: l.cfg.check_mode, bar: document.getElementById('barin').textContent, right: document.getElementById('right').textContent}; }); };
  const setMode = async v => { await g.select('#c_check-mode', v); await sleep(60); };
  const names = await g.evaluate(() => window.__sim.PRESETS.map(p => p.n));
  eq(names.length, 19, 'presets: 15 original + 4 counts');
  // schedule mode: the original presets give the original statuses, and they run in schedule mode
  for (let i = 0; i < OLD.length; i++) { const r = await preset(i); ok(r.status === OLD[i] && r.mode === 'schedule', 'preset ' + i + ' ' + names[i] + ': ' + r.status + ' (' + r.mode + ') want ' + OLD[i] + ' (schedule)'); ok(!/Mode\s*counts/.test(r.bar), 'preset ' + i + ' shows no counts pill'); }
  // counts presets
  let r = await preset(15); eq([r.status, r.w, r.m, r.mode, r.gaps], ['COMPLIANT', [4, 4, 4, 'OK'], [12, 12, 'OK'], 'counts', ''], 'counts: Saturday missed, re-run Monday = weekly 4/4 COMPLIANT');
  ok(/Mode\s*counts/.test(r.bar), 'counts pill in the sticky bar'); ok(/any weekday/.test(r.right) && /not taken on the usual Saturday, but it counts/.test(r.right), 'counts explanation names the late point');
  if (shots) { const e = await g.$('#right'); await e.screenshot({path: path.join(shots, 'sim-counts.png')}); }
  await g.evaluate(() => window.__sim.applyPreset(15)); await g.evaluate(() => window.__sim.setConf('check-mode', 'schedule')); await sleep(60);
  r = await g.evaluate(() => ({s: window.__last.row0.status, g: window.__last.row0.gaps, w: window.__last.row0.weekly.st})); ok(r.s === 'NON-COMPLIANT' && r.w === 'FAIL' && /^weekly 3\/4 missing /.test(r.g), 'same data in schedule mode: the Monday re-run (2 days late) fails: ' + JSON.stringify(r));
  r = await preset(16); eq([r.status, r.w, r.gaps], ['NON-COMPLIANT', [3, 4, 4, 'FAIL'], 'weekly 3/4 in last 30d'], 'counts: a real miss = weekly 3/4 NON-COMPLIANT');
  ok(/1 more needed/.test(await g.evaluate(() => document.getElementById('right').innerHTML)), 'real miss shows "1 more needed"');
  r = await preset(17); eq([r.status, r.m], ['COMPLIANT', [12, 12, 'OK']], 'counts: monthly catch-up = 12/12 COMPLIANT');
  r = await preset(18); eq([r.status, r.w[3], r.m[2], r.d], ['NOT YET DUE', 'DUE', 'DUE', 'OK'], 'counts: young cluster NOT YET DUE (weekly, monthly), daily OK');
  ok(/NOT YET DUE until/.test(r.right), 'counts: young cluster explanation gives the due date');
  // conf form: the check-mode select, and the three ignored settings are greyed in counts mode only
  await preset(0);
  eq(await g.evaluate(() => ['weekly-weekday', 'monthly-rule', 'tolerance-days'].map(k => document.getElementById('r_' + k).classList.contains('ign'))), [false, false, false], 'schedule mode: nothing greyed out');
  await setMode('counts');
  eq(await g.evaluate(() => ['weekly-weekday', 'monthly-rule', 'tolerance-days'].map(k => document.getElementById('r_' + k).classList.contains('ign'))), [true, true, true], 'counts mode: weekly-weekday, monthly-rule, tolerance-days greyed');
  eq(await g.evaluate(() => document.getElementById('i_weekly-weekday').textContent), '(ignored in counts mode)', 'counts mode: the greyed row says why');
  eq(await g.evaluate(() => document.getElementById('r_check-mode').classList.contains('chg')), true, 'check-mode shows as changed from the default');
  // weekday / monthly-rule / tolerance have no effect in counts mode
  const sig = () => g.evaluate(() => JSON.stringify([window.__last.row0.status, window.__last.row0.gaps, window.__last.row0.weekly.have, window.__last.row0.monthly.have]));
  const s0 = await sig(); await g.evaluate(() => { window.__sim.setConf('weekly-weekday', 'wed'); window.__sim.setConf('monthly-rule', 'first-fri'); window.__sim.setConf('tolerance-days', '3'); }); await sleep(60);
  eq(await sig(), s0, 'counts mode ignores weekly-weekday, monthly-rule and tolerance-days');
  await setMode('schedule'); ok(await sig() !== s0, 'schedule mode does use them (different result)');
  // a bad value is refused like the script does
  await g.evaluate(() => { const o = document.getElementById('c_check-mode'); o.add(new Option('weekly', 'weekly')); o.value = 'weekly'; o.dispatchEvent(new Event('input', {bubbles: true})); }); await sleep(60);
  ok(/check-mode must be schedule or counts/.test(await g.evaluate(() => document.getElementById('right').textContent)), 'bad check-mode: the script would not run');
  // settings reference: the 44 conf keys, check-mode first in Schedule, defaults equal the conf file
  await g.evaluate(() => window.__tabs.showTab('settings')); await sleep(250);
  const ref = await g.evaluate(() => ({intro: document.querySelector('#tab-ref .runintro').textContent, sets: [...document.querySelectorAll('#tab-ref .set')].map(s => ({k: s.querySelector('code.key').textContent, d: s.querySelector('.dflt code').textContent, g: s.dataset.g, kind: s.dataset.kind, txt: s.textContent}))}));
  const keys = ref.sets.map(s => s.k).filter(k => /^[a-z][a-z-]*$/.test(k) && k in conf);
  eq(Object.keys(conf).length, 44, 'the shipped conf has 44 settings');
  eq(keys.slice().sort(), Object.keys(conf).sort(), 'the Settings reference lists exactly the 44 conf keys');
  ok(/44 key=value settings/.test(ref.intro), 'intro says 44 settings: ' + ref.intro.slice(0, 160));
  eq(ref.sets.filter(s => s.g === 'schedule')[0].k, 'check-mode', 'check-mode is the first Schedule setting (as in the conf)');
  ref.sets.forEach(s => { if (s.k in conf) { const want = conf[s.k] === '' ? '(empty)' : conf[s.k]; ok(s.d === want, 'default of ' + s.k + ' is ' + s.d + ', conf has ' + want); } });
  const get = k => ref.sets.find(s => s.k === k) || {txt: ''};
  ok(/schedule.*counts/.test(get('check-mode').txt) && /--check-mode MODE/.test(get('check-mode').txt) && /weekly-weekday, monthly-rule and tolerance-days/.test(get('check-mode').txt), 'check-mode entry: values, flag, ignored settings');
  ['attach-html', 'attach-csv', 'attach-prefix'].forEach(k => ok(get(k).txt.length > 100 && new RegExp('--' + k).test(get(k).txt), k + ' entry present with its flag'));
  ok(/short file names|sendmail/.test(get('attach-prefix').txt + get('attach-html').txt), 'attach entries describe the short attachment names / sendmail');
  ['weekly-weekday', 'monthly-rule', 'tolerance-days'].forEach(k => ok(/Ignored when check-mode=counts/.test(get(k).txt), k + ' says it is ignored in counts mode'));
  if (shots) { await g.evaluate(() => document.getElementById('grp-schedule').scrollIntoView()); await sleep(150); await g.screenshot({path: path.join(shots, 'sim-settings.png')}); }
  // run examples tab has the counts command
  await g.evaluate(() => window.__tabs.showTab('examples')); await sleep(200);
  ok(/--check-mode counts/.test(await g.evaluate(() => document.getElementById('tab-run').textContent)), 'Run examples has a --check-mode counts command');
  // version labels
  const page = await g.evaluate(() => document.body.innerText); ok(/v1\.8\.1/.test(page) && !/v1\.7\.2 exactly|rds_backup_compliance_report\.sh v1\.7\.2/.test(page), 'header / footer say v1.8.1');
  // light and dark colour scheme: the page has one fixed theme; both schemes must render identically and without errors
  const look = async () => g.evaluate(() => { const c = getComputedStyle(document.body); return [c.backgroundColor, c.color, document.getElementById('tab-sim').hidden]; });
  await g.evaluate(() => window.__tabs.showTab('sim')); await preset(15);
  await g.emulateMediaFeatures([{name: 'prefers-color-scheme', value: 'light'}]); const light = await look(); const lh = await g.evaluate(() => document.getElementById('right').innerHTML);
  if (shots) await g.screenshot({path: path.join(shots, 'sim-light.png')});
  await g.emulateMediaFeatures([{name: 'prefers-color-scheme', value: 'dark'}]); const dark = await look(); const dh = await g.evaluate(() => document.getElementById('right').innerHTML);
  if (shots) await g.screenshot({path: path.join(shots, 'sim-dark.png')});
  eq(dark, light, 'light and dark colour scheme render the same fixed theme'); ok(lh === dh, 'same content in light and dark'); ok(light[0] !== light[1], 'text colour differs from the background');
  ok(errs.length === 0, 'page errors: ' + errs.join(' | ')); ok(net.length === 0, 'network requests: ' + net.join(' '));
  await b.close();
  console.log(JSON.stringify({checks: n, fails: fails.length}));
  if (fails.length) { console.error(fails.join('\n')); process.exit(1); }
})().catch(e => { console.error(e); process.exit(1); });
