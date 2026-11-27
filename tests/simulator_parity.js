// Parity of docs/rds_compliance_simulator.html (its JS evaluator) with the real script, in both check modes.
// The simulator builds mock servers (buildResource), the real rds_backup_compliance_report.sh evaluates the same data
// with --merge (date frozen with a date shim), and every status / count / gap / per-point reason must match.
// Usage: node tests/simulator_parity.js [seed]   (needs node, jq, bash 4.4+; no browser). Exit 1 on any difference.
'use strict';
const fs = require('fs'), os = require('os'), path = require('path'), cp = require('child_process');
const ROOT = path.resolve(__dirname, '..');
const SCRIPT = path.join(ROOT, 'rds_backup_compliance_report.sh'), BASECONF = path.join(ROOT, 'rds_backup_compliance_report.conf');
const HTML = process.env.SIM_HTML || path.join(ROOT, 'docs', 'rds_compliance_simulator.html');
const html = fs.readFileSync(HTML, 'utf8');
const a = html.indexOf('/* ===== CORE'), b = html.indexOf('/* ===== END CORE ===== */');
if (a < 0 || b < 0) { console.error('CORE markers not found in ' + HTML); process.exit(1); }
const sim = new Function(html.slice(a, b) + ';return {evaluate,parseConf,buildResource,DEFAULT_CONF,isoToEpoch,isoToDay,dayOf,diso,dow,firstdow,monthIndex};')();
let seed = +(process.argv[2] || 20261127); const rnd = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; };
const pick = l => l[Math.floor(rnd() * l.length)], chance = p => rnd() < p;
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'simparity-'));
const fd = path.join(tmp, 'fd'); fs.mkdirSync(fd);
fs.writeFileSync(path.join(fd, 'date'), '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in -d|-d*|--date*) exec /bin/date "$@" ;; esac; done\nexec /bin/date -d "@$FAKE_NOW" "$@"\n', {mode: 0o755});
let checks = 0; const fails = [];
const eq = (x, y, msg) => { checks++; if (JSON.stringify(x) !== JSON.stringify(y)) fails.push(msg + ' | script=' + JSON.stringify(x) + ' | simulator=' + JSON.stringify(y)); };

// conf text with some keys replaced (the shipped conf is the base, like a real run)
function confText(over) {
  let t = fs.readFileSync(BASECONF, 'utf8');
  for (const k of Object.keys(over)) { const re = new RegExp('^' + k + '=.*$', 'm'); if (!re.test(t)) throw new Error('conf key missing: ' + k); t = t.replace(re, k + '=' + over[k]); }
  return t;
}
// run the real script on a data document; returns {identifier: row}
function realRows(resources, confOver, nowEpoch, tag) {
  const d = path.join(tmp, tag); fs.mkdirSync(d);
  fs.writeFileSync(path.join(d, 'data.json'), JSON.stringify({schema: 'rds_backup_compliance_data', schema_version: 1, collected_epoch: nowEpoch,
    accounts: [{account: '111111111111', name: '', collected_epoch: nowEpoch}], regions: [], resources, orphans: []}));
  fs.writeFileSync(path.join(d, 'c.conf'), confText(Object.assign({'output-dir': d + '/o', 'log-file': d + '/run.log'}, confOver)));
  const r = cp.spawnSync('bash', [SCRIPT, '--config', d + '/c.conf', '--merge', d + '/data.json', '-F', 'json', '-o', d + '/o'],
    {env: Object.assign({}, process.env, {HOME: process.env.HOME || '/home/box', PATH: fd + ':' + process.env.PATH, FAKE_NOW: String(nowEpoch)}), encoding: 'utf8'});
  const f = fs.readdirSync(d + '/o').find(x => /\.json$/.test(x));
  if (!f) throw new Error('script produced no json (' + tag + '): ' + r.stderr.slice(-600));
  const rows = {}; JSON.parse(fs.readFileSync(d + '/o/' + f, 'utf8')).rows.forEach(x => rows[x.identifier] = x); return rows;
}
const sel = s => (s.st === 'N/A' || s.st === 'UNKNOWN' || s.st === 'OFF') ? {st: s.st} : {st: s.st, have: s.have, need: s.need, target: s.target, full_on: s.full_on || '', gap: s.gap || ''};
function compare(tag, real, srow) {
  eq(real.status, srow.status, tag + ' status');
  eq(real.gaps, srow.gaps, tag + ' gaps');
  eq(real.not_yet_due, srow.not_yet_due, tag + ' not_yet_due');
  eq(real.warnings, srow.warnings, tag + ' warnings');
  eq(real.retention_mismatch, srow.retention_mismatch, tag + ' retention_mismatch');
  ['daily', 'weekly', 'monthly', 'yearly'].forEach(k => eq(sel(real[k]), sel(srow[k]), tag + ' ' + k));
  eq(real.recovery_points.map(p => [p.id, p.counted, p.reason]), srow.diag.map(p => [p.id, p.counted, p.reason]), tag + ' per-point reasons');
}
function baseState(id, run, over) {
  return Object.assign({id, engine: 'aurora-postgresql', role: 'primary', created: '2023-11-01', createdTime: '09:30', run: run.date, runTime: run.time, rdsRetention: '7',
    snapOk: true, backupOk: true, planWeekday: 6, planMonthWeekday: 0, planWeeklyRet: '30', planMonthlyRet: '365', dailyTime: '03:00', awsTime: '05:00', ov: {}, extra: []}, over);
}
function cfgOf(confOver, mode) { const c = Object.assign({}, sim.DEFAULT_CONF, confOver, {'check-mode': mode}); const pc = sim.parseConf(c); if (pc.errors.length) throw new Error(pc.errors.join('; ')); return pc.cfg; }
function runCase(tag, states, confOver, run) {
  const now = sim.isoToEpoch(run.date, run.time);
  const resources = states.map(s => sim.buildResource(s, now));
  ['schedule', 'counts'].forEach(mode => {
    const over = Object.assign({}, confOver, {'check-mode': mode});
    const real = realRows(resources, over, now, tag + '-' + mode), cfg = cfgOf(confOver, mode);
    resources.forEach(r => { if (!real[r.id]) { fails.push(tag + '-' + mode + ' ' + r.id + ' missing in script output'); return; } compare(tag + '-' + mode + ' ' + r.id, real[r.id], sim.evaluate(r, cfg, now)); });
  });
}
function randomState(i, run) {
  const now = sim.isoToEpoch(run.date, run.time), td = sim.dayOf(now), st = baseState('srv-' + i, run, {});
  st.created = sim.diso(td - pick([0, 1, 3, 6, 7, 8, 10, 14, 15, 20, 21, 22, 28, 29, 31, 35, 45, 75, 130, 200, 380, 400, 800, 1100])); st.createdTime = pick(['00:30', '09:30', '23:50']);
  st.rdsRetention = pick(['7', '7', '7', '1', '14', '0']); st.planWeekday = pick([6, 6, 0, 3]); st.planMonthWeekday = pick([0, 0, 5]);
  st.planWeeklyRet = pick(['30', '30', '35', '45', '10']); st.planMonthlyRet = pick(['365', '365', '380', '90']); st.dailyTime = pick(['03:00', '23:30']); st.awsTime = pick(['05:00', '22:00']);
  st.role = pick(['primary', 'primary', 'primary', 'replica', 'secondary']); st.engine = pick(['aurora-postgresql', 'postgres', 'oracle-ee', 'mysql']);
  if (chance(.05)) st.snapOk = false; if (chance(.07)) st.backupOk = false;
  for (let d = td - 12; d <= td; d++) if (chance(.07)) st.ov['d:' + sim.diso(d)] = {off: true};
  for (let d = td - 140; d <= td; d++) if (sim.dow(d) === st.planWeekday && chance(.35)) { const o = {}; if (chance(.4)) o.off = true; else if (chance(.5)) o.offset = pick([-3, -2, -1, 1, 2, 3]); else o.ret = pick([5, 21, 35, 60]); st.ov['w:' + sim.diso(d)] = o; }
  const mi = sim.monthIndex(now);
  for (let k = 0; k <= 26; k++) if (chance(.3)) { const o = {}; if (chance(.4)) o.off = true; else if (chance(.5)) o.offset = pick([-3, -2, 1, 2, 3]); else o.ret = pick([90, 330, 500]); st.ov['m:' + sim.diso(sim.firstdow(mi - k, st.planMonthWeekday))] = o; }
  if (chance(.25)) st.extra.push({date: sim.diso(td - pick([3, 20, 100, 500])), ret: pick([10, 30, 365, 800, 1500])});
  return st;
}

const RUNS = [{date: '2026-11-27', time: '12:00'}, {date: '2026-03-31', time: '23:51'}, {date: '2028-02-29', time: '00:10'}, {date: '2026-12-31', time: '08:00'},
  {date: '2027-03-01', time: '06:30'}, {date: '2026-08-31', time: '15:00'}, {date: '2026-11-30', time: '05:30'}];
const VARIANTS = [
  {},
  {daily: '14', 'daily-max-age': '30', 'weekly-weekday': 'wed', 'monthly-rule': 'first-fri'},
  {weekly: '3', 'weekly-retention-days': '21', 'weekly-days': '15-30', 'weekly-window-days': '21', monthly: '6', 'monthly-days': '150-250', 'monthly-retention-days': '180'},
  {'tolerance-days': '0', monthly: '1'},
  {'tolerance-days': '3', monthly: '3', yearly: '1'},
  {'weekly-retention-days': '60', 'weekly-days': '45-70', monthly: '24', 'monthly-days': '600-800', 'monthly-retention-days': '730'},
  {'replica-exempt-engines': '', 'retention-tolerance-days': '0', 'daily-retention-days': '14'},
];

// 1) the named cases from the brief: a missed Saturday re-run on Monday, and a real miss
{
  const run = RUNS[0], td = sim.isoToDay(run.date), sat = td - ((sim.dow(td) - 6 + 7) % 7);          // Fri 27 Nov 2026 -> last Saturday = 21 Nov
  const ok = baseState('all-good', run, {});
  const rerun = baseState('sat-miss-mon-rerun', run, {ov: {['w:' + sim.diso(sat - 7)]: {offset: 2}}});          // Sat 14 Nov taken on Mon 16 Nov
  const real3 = baseState('real-miss-3-of-4', run, {ov: {['w:' + sim.diso(sat - 7)]: {off: true}}});
  const mcatch = baseState('monthly-catch-up', run, {ov: {['m:' + sim.diso(sim.firstdow(sim.monthIndex(sim.isoToEpoch(run.date, run.time)) - 3, 0))]: {offset: 3}}});
  const young = baseState('young-10d', run, {created: sim.diso(td - 10)});
  const now = sim.isoToEpoch(run.date, run.time), states = [ok, rerun, real3, mcatch, young];
  const resources = states.map(s => sim.buildResource(s, now));
  const rc = realRows(resources, {'check-mode': 'counts'}, now, 'named-counts'), rs = realRows(resources, {'check-mode': 'schedule'}, now, 'named-schedule');
  const cc = cfgOf({}, 'counts'), sc = cfgOf({}, 'schedule');
  const row = (r, c) => sim.evaluate(r, c, now);
  const by = {}; resources.forEach(r => by[r.id] = r);
  eq([rc['sat-miss-mon-rerun'].weekly.have, rc['sat-miss-mon-rerun'].weekly.need, rc['sat-miss-mon-rerun'].status], [4, 4, 'COMPLIANT'], 'script: counts, Saturday miss re-run Monday = 4/4 COMPLIANT');
  eq([row(by['sat-miss-mon-rerun'], cc).weekly.have, row(by['sat-miss-mon-rerun'], cc).weekly.need, row(by['sat-miss-mon-rerun'], cc).status], [4, 4, 'COMPLIANT'], 'simulator: counts, Saturday miss re-run Monday = 4/4 COMPLIANT');
  eq([rc['real-miss-3-of-4'].weekly.have, rc['real-miss-3-of-4'].weekly.need, rc['real-miss-3-of-4'].status, rc['real-miss-3-of-4'].gaps], [3, 4, 'NON-COMPLIANT', 'weekly 3/4 in last 30d'], 'script: counts, real miss = 3/4 NON-COMPLIANT');
  eq([row(by['real-miss-3-of-4'], cc).weekly.have, row(by['real-miss-3-of-4'], cc).weekly.need, row(by['real-miss-3-of-4'], cc).status, row(by['real-miss-3-of-4'], cc).gaps], [3, 4, 'NON-COMPLIANT', 'weekly 3/4 in last 30d'], 'simulator: counts, real miss = 3/4 NON-COMPLIANT');
  eq(rs['sat-miss-mon-rerun'].status, 'NON-COMPLIANT', 'script: schedule mode still fails the Monday re-run (+2 days is outside tolerance-days=1)');
  eq(row(by['sat-miss-mon-rerun'], sc).status, 'NON-COMPLIANT', 'simulator: schedule mode still fails the Monday re-run');
  eq(rc['monthly-catch-up'].monthly.have, 12, 'script: counts, monthly catch-up counts'); eq(row(by['monthly-catch-up'], cc).monthly.have, 12, 'simulator: counts, monthly catch-up counts');
  eq(rc['young-10d'].status, 'NOT YET DUE', 'script: counts, young cluster NOT YET DUE'); eq(row(by['young-10d'], cc).status, 'NOT YET DUE', 'simulator: counts, young cluster NOT YET DUE');
  states.forEach(s => { compare('named-counts ' + s.id, rc[s.id], row(by[s.id], cc)); compare('named-schedule ' + s.id, rs[s.id], row(by[s.id], sc)); });
}
// 2) window edges: one weekly / monthly point exactly on, and one day outside, each counted window (and creation dates around a whole week / month)
{
  const edge = (run, confOver, tag) => {
    const now = sim.isoToEpoch(run.date, run.time), td = sim.dayOf(now), cfgC = cfgOf(confOver, 'counts'), states = [], resources = [];
    const wst = td - cfgC.weekly_window_days + 1, mi = sim.monthIndex(now), dom = new Date(now * 1000).getUTCDate();
    const mfirst = m => sim.dayOf(Date.UTC(Math.floor(m / 12), m % 12, 1) / 1000), mst0 = Math.min(mfirst(mi - cfgC.monthly) + dom - 1, mfirst(mi - cfgC.monthly + 1) - 1), mst = mst0 - 7;
    const mk = (id, created, pts) => { const st = baseState(id, run, {created: sim.diso(created)}); const r = sim.buildResource(st, now);
      r.snapshots = r.snapshots.filter(x => x.kind === 'automated').concat(pts.map((q, i) => ({kind: 'backup', id: id + '-p' + i, created_epoch: q.d * 86400 + 5 * 3600, status: 'COMPLETED', expires_epoch: q.d * 86400 + 5 * 3600 + q.ret * 86400, vault: 'Default'})));
      resources.push(r); states.push(id); };
    for (let k = -2; k <= 2; k++) mk('w-edge' + k, td - 900, [{d: wst + k, ret: 30}]);
    for (let k = -2; k <= 2; k++) mk('m-edge' + k, td - 900, [{d: mst + k, ret: 365}]);
    for (const n of [6, 7, 8, 13, 14, 15, 21, 22, 28, 29, 30, 35]) mk('young-d' + n, td - n, [{d: td - 3, ret: 30}]);
    for (let m = 0; m <= 4; m++) { const cd = mfirst(mi - m); [-1, 0, 1, 14].forEach(o => mk('young-m' + m + '_' + o, cd + o, [{d: td - 1, ret: 365}])); }
    ['schedule', 'counts'].forEach(mode => { const over = Object.assign({}, confOver, {'check-mode': mode}), real = realRows(resources, over, now, tag + '-' + mode), cfg = cfgOf(confOver, mode);
      resources.forEach(r => compare(tag + '-' + mode + ' ' + r.id, real[r.id], sim.evaluate(r, cfg, now))); });
  };
  [[RUNS[0], {}], [RUNS[1], {}], [RUNS[2], {monthly: '3'}], [RUNS[1], {monthly: '1'}], [RUNS[3], {'weekly-window-days': '21', 'weekly-retention-days': '21', 'weekly-days': '15-30'}], [RUNS[6], {monthly: '2', weekly: '3'}]]
    .forEach((x, i) => edge(x[0], x[1], 'edge' + i));
}
// 3) random sweep: every variant x run date, 30 servers each, both modes, against the real script
VARIANTS.forEach((v, vi) => {
  const runs = [RUNS[vi % RUNS.length], RUNS[(vi + 3) % RUNS.length]];
  runs.forEach((run, ri) => runCase('v' + vi + 'r' + ri, Array.from({length: 30}, (_, i) => randomState(i, run)), v, run));
});
fs.rmSync(tmp, {recursive: true, force: true});
console.log(JSON.stringify({checks, fails: fails.length}));
if (fails.length) { console.error(fails.slice(0, 25).join('\n')); process.exit(1); }
