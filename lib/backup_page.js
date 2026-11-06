// rds_backup_compliance_report.sh HTML page: Compliance tab (filters, cards, per-region breakdown, filtered CSV export)
// and Backups tab (one resource: manual / automated / AWS Backup, period 3 / 6 / 12 months; orphaned manual snapshots
// appear as "(deleted) <source>" pseudo-resources). No network access.
(function () {
  'use strict';
  var D = JSON.parse(document.getElementById('data').textContent);
  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]; }); };
  var pad = function (n) { return (n < 10 ? '0' : '') + n; };
  var fmt = function (e, off, lab) { if (e == null) return ''; var d = new Date((e + off) * 1000);
    return d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate()) + ' ' + pad(d.getUTCHours()) + ':' + pad(d.getUTCMinutes()) + ' ' + esc(lab); };
  var utc = function (e) { return fmt(e, 0, 'UTC'); }, loc = function (e) { return fmt(e, D.tz_offset, D.tz_label); };
  var uniq = function (a) { return a.filter(function (v, i) { return a.indexOf(v) === i; }).sort(); };
  var key = function (r) { return r.account_id + '|' + r.region + '|' + r.identifier; };
  // v1.5.3: account label = name (number); no name → number (profile) like patch; else bare number
  var alabel = function (id) {
    var a = (D.accounts || []).filter(function (x) { return x.account === id; })[0] || {};
    var n = a.name || ((D.rows || []).filter(function (x) { return x.account_id === id && x.account_name; })[0] || {}).account_name || '';
    if (n) return n + ' (' + id + ')';
    if (a.profile) return id + ' (' + a.profile + ')';
    return id;
  };
  var alab = function (r) { return r.account_name ? (r.account_name + ' (' + r.account_id + ')') : alabel(r.account_id); };
  var STATUSES = ['COMPLIANT', 'NON-COMPLIANT', 'NOT YET DUE', 'UNKNOWN'];
  var YON = !!(D.cfg && D.cfg.yearly > 0);   // yearly=0 (default): no Yearly column anywhere
  var ST = function (r) { return r.settings || {}; };
  var nyd = function (r) { return r.status === 'NOT YET DUE' || !!r.not_yet_due; };
  // v1.5.0: remembered filters / CSV columns (localStorage; ignored when storage is off), info tips built from the report's config
  var LS = {get: function (k) { try { return JSON.parse(localStorage.getItem('rbc-' + k) || 'null'); } catch (e) { return null; } },
    set: function (k, v) { try { localStorage.setItem('rbc-' + k, JSON.stringify(v)); } catch (e) { /* storage off */ } }};
  var cv = function (k) { return D.cfg && D.cfg[k] != null ? D.cfg[k] : '?'; };
  var MMIN = D.cfg && D.cfg.monthly_min_days != null ? D.cfg.monthly_min_days : cv('weekly_max_days') + 1;
  var WR = 'weekly = retention ' + cv('weekly_min_days') + '-' + cv('weekly_max_days') + 'd, monthly = ' + MMIN + '-' + cv('monthly_max_days') + 'd';
  var TIP = {nyd: 'Too new: not all ' + cv('daily') + ' daily / weekly / ' + cv('monthly') + ' monthly points can exist yet; left out of %',
    warn: 'AWS Backup points whose retention is outside ' + WR + ': not counted',
    retmis: 'Counted, but retention is not the expected weekly ' + cv('weekly_retention_days') + 'd / monthly ' + cv('monthly_retention_days') + 'd (±' + cv('ret_tolerance_days') + 'd)',
    excess: 'More points than the schedule needs (e.g. two plans select this resource)',
    overret: 'More automated backups than the RDS retention (+' + cv('ret_tolerance_days') + 'd) explains',
    'COMPLIANT': 'Every due daily / weekly / monthly point found', 'NON-COMPLIANT': 'At least one due point is missing',
    'UNKNOWN': 'Backups could not be read (access denied or error)',
    pitr: 'Continuous AWS Backup (point-in-time restore); never counted as daily / weekly / monthly',
    sched: 'Daily = RDS automated; ' + WR + '; Not counted = manual, PITR or other retention',
    glob: 'Aurora global database = one Aurora DB replicated across regions; Oracle, SQL Server and other engines are None'};
  TIP['NOT YET DUE'] = TIP.nyd;
  var tip = function (t) { return ' <span class="ti" tabindex="0" title="' + esc(t) + '">&#9432;</span>'; };
  document.addEventListener('click', function (e) { var t = e.target;
    document.querySelectorAll('.ti.open').forEach(function (x) { if (x !== t) x.classList.remove('open'); });
    if (t.classList && t.classList.contains('ti')) { e.preventDefault(); e.stopPropagation(); t.classList.toggle('open'); } }, true);
  var otip = function (id) { document.querySelectorAll('#' + id + ' option').forEach(function (o) { if (TIP[o.value]) o.title = TIP[o.value]; }); };
  var save = function (k, ids) { var v = {}; ids.forEach(function (id) { v[id] = document.getElementById(id).value; }); LS.set(k, v); };
  var load = function (k) { var v = LS.get(k) || {}; Object.keys(v).forEach(function (id) { var e = document.getElementById(id);
    if (e && (e.tagName !== 'SELECT' || [].some.call(e.options, function (o) { return o.value === v[id] && !o.disabled; }))) e.value = v[id]; }); };
  document.querySelectorAll('.tabs button').forEach(function (b) { b.onclick = function () {
    document.querySelectorAll('.tabs button, .tab').forEach(function (x) { x.classList.remove('on'); });
    b.classList.add('on'); document.getElementById(b.dataset.t).classList.add('on'); }; });

  // ---------------- Compliance tab
  var C = document.getElementById('comp');
  var opt = function (id, label, vals, txt) { return '<label>' + label + ' <select id="' + id + '"><option value="">All</option>' +
    vals.map(function (v) { return '<option value="' + esc(v) + '">' + esc(txt ? txt(v) : v) + '</option>'; }).join('') + '</select></label>'; };
  // fixed column widths (px), wrapping inside cells; the table scrolls sideways on narrow screens
  var W = [20, 104, 84, 160, 72, 88, 125, 105, 84, 60, 70, 160, 92, 88, 88].concat(YON ? [86] : [], [108, 160]);
  var NC = W.length;
  var WT = W.reduce(function (a, b) { return a + b; }, 0);
  var COLS = '<colgroup>' + W.map(function (w) { return '<col style="width:' + (100 * w / WT).toFixed(2) + '%">'; }).join('') + '</colgroup>';
  var OPEN = {}, PIN = '';   // PIN: account|region|identifier set by a cross-tab link (v1.4.1)
  // v1.5.0: "Aurora global DB" = membership of an Aurora global cluster ("unknown" = not readable, treated as not global)
  var isG = function (r) { return !!r.global_cluster && r.global_cluster !== 'unknown'; };
  var globals = uniq(D.rows.filter(isG).map(function (r) { return r.global_cluster; }));
  var gsel = globals.length ? '<label>Aurora global DB' + tip(TIP.glob) + ' <select id="f-global"><option value="">All</option><option value="*any*">All global databases</option><option value="*none*">None</option>' +
    globals.map(function (g) { return '<option value="' + esc(g) + '">' + esc(g) + '</option>'; }).join('') + '</select></label>' +
    '<label>Global role <select id="f-role"><option value="">All</option><option value="primary">Primary</option><option value="secondary">Secondary</option></select></label>'
    : '<select id="f-global" hidden><option value=""></option></select><select id="f-role" hidden><option value=""></option></select>';
  var ISSUES = ['nyd', 'warn', 'retmis', 'excess', 'overret'], ISL = {nyd: 'Not yet due', warn: 'Points not counted', retmis: 'Retention mismatch', excess: 'Excess backups', overret: 'Holds more than retention'};
  var SHOWN = STATUSES.filter(function (s) { return D.rows.some(function (r) { return r.status === s; }); });
  C.innerHTML = '<div class="cards" id="cards"></div><div class="filters">' +
    opt('f-acct', 'Account', uniq(D.rows.map(function (r) { return r.account_id; })), alabel) +
    opt('f-region', 'Region', uniq(D.rows.map(function (r) { return r.region; }))) +
    opt('f-type', 'Type', uniq(D.rows.map(function (r) { return r.type; }))) +
    opt('f-engine', 'Engine', uniq(D.rows.map(function (r) { return r.engine; }))) + gsel +
    opt('f-status', 'Status' + tip(SHOWN.map(function (s) { return s + ': ' + TIP[s]; }).join('\n')), SHOWN) +
    '<label>Issue' + tip(ISSUES.map(function (k) { return ISL[k] + ': ' + TIP[k]; }).join('\n')) + ' <select id="f-show"><option value="">All</option>' +
    ISSUES.map(function (k) { return '<option value="' + k + '">' + ISL[k] + '</option>'; }).join('') + '</select></label>' +
    '<input id="f-q" type="search" placeholder="Search identifier, engine, region, account, vault, plan" title="Identifier, engine, region, account, AWS Backup vault or plan contains"> <button id="f-reset">Reset</button> <button id="f-csv">Export CSV</button> <span id="f-count" class="muted"></span> <span id="f-pin" class="pin" hidden></span></div>' +
    '<h2>Per region</h2><div class="tw"><table id="regions"><thead><tr><th>Account</th><th>Region</th><th>Resources</th><th>Compliant</th><th>Non-compliant</th><th>Not yet due</th><th>Unknown</th><th>% compliant</th></tr></thead><tbody></tbody><tfoot></tfoot></table></div>' +
    '<div class="tw"><table id="main">' + COLS + '<thead><tr><th class="cx" title="Click a row to show its details"></th><th>Account</th><th>Region</th><th>Identifier</th><th>Type</th><th>Created</th><th>Engine</th><th>Aurora global DB</th><th>Global role</th>' +
    '<th>Retention</th><th>PITR' + tip(TIP.pitr) + '</th><th>Last automated</th><th>Daily</th><th>Weekly</th><th>Monthly</th>' + (YON ? '<th>Yearly</th>' : '') + '<th>Status</th><th>Gaps</th></tr></thead><tbody></tbody></table></div>' +
    '<div id="rerr"></div>';
  var OS = D.osum || {orphaned: 0, size_gb: 0, est_monthly_usd: 0, text: '0 orphaned snapshots, 0 GB, ~$0/month (estimate)', price_per_gb_month: 0.021};
  var oline = function () { var t = esc(OS.text), n = esc(OS.orphaned);
    if (OS.orphaned && t.indexOf(n) === 0) t = '<a href="#" class="osum-n" title="Show orphaned snapshots (all resources, any age)">' + n + '</a>' + t.slice(n.length);
    return '<b>Orphaned manual snapshots:</b> ' + t + ' <span class="muted">(size &times; $' + esc(OS.price_per_gb_month) +
    '/GB-month; rough upper estimate, snapshot billing is incremental' + (OS.shared ? '; ' + esc(OS.shared) + ' shared / cross-account not counted' : '') +
    (OS.unverified ? '; ' + esc(OS.unverified) + ' cross-region copies unverified' : '') + ')</span>'; };
  C.insertAdjacentHTML('afterbegin', '<div id="osum" class="osum">' + oline() + '' + '</div>');
  var F = ['f-acct', 'f-region', 'f-type', 'f-engine', 'f-role', 'f-global', 'f-status', 'f-show'];
  var val = function (id) { return document.getElementById(id).value; };
  // v1.4.0 notes (absent in rows built from older data: treated as none)
  var NOTE = {retmis: function (r) { return r.retention_mismatch || ''; }, excess: function (r) { return r.excess || ''; }, overret: function (r) { return r.over_retention || ''; }};
  var NOTEL = {retmis: 'Retention mismatch', excess: 'Excess backups', overret: 'Holds more than retention'};
  var hay = function (r) { return [r.identifier, r.engine, r.engine_version, r.region, r.account_id, r.account_name, ST(r).plans, ST(r).schedules]
    .concat((r.recovery_points || []).map(function (p) { return p.vault; })).filter(Boolean).join('\n').toLowerCase(); };
  var showOk = function (r, v) { return !v || (v === 'nyd' ? nyd(r) : v === 'warn' ? !!r.warnings : !!NOTE[v](r)); };
  var gOk = function (r) { var g = val('f-global'), ro = val('f-role');
    if (ro && !(isG(r) && r.global_role === ro)) return false;
    return !g || (g === '*any*' ? isG(r) : g === '*none*' ? !isG(r) : r.global_cluster === g); };
  var filtered = function () {
    var q = val('f-q').toLowerCase().trim();
    return D.rows.filter(function (r) {
      return (!val('f-acct') || r.account_id === val('f-acct')) && (!val('f-region') || r.region === val('f-region')) &&
        (!val('f-type') || r.type === val('f-type')) && (!val('f-engine') || r.engine === val('f-engine')) &&
        gOk(r) && (!val('f-status') || r.status === val('f-status')) &&
        showOk(r, val('f-show')) && (!q || hay(r).indexOf(q) >= 0) && (!PIN || key(r) === PIN); }); };
  // "NN% compliant (x of y)": not-yet-due resources are left out of the denominator
  var comp = function (rs) { var c = count(rs, 'COMPLIANT'), y = rs.filter(function (r) { return !nyd(r); }).length;
    return {c: c, y: y, n: rs.length - y, pct: y ? Math.round(100 * c / y) : null}; };
  var pctTxt = function (x) { return x.pct == null ? '-' : x.pct + '%'; };
  var ytags = function (r) { return Object.keys(NOTE).filter(function (k) { return NOTE[k](r); }).map(function (k) {
    return '<span class="ytag" title="' + esc(NOTEL[k] + ': ' + NOTE[k](r)) + '">' + esc(NOTEL[k]) + '</span>'; }).join(''); };
  var PL = {daily: 'Daily', weekly: 'Weekly', monthly: 'Monthly', yearly: 'Yearly'};
  // compact count cell: "3/4" (or "2/2 so far (target 4)") + red "N missing" tag; full dates in the tooltip and the row detail
  var td = function (r, k) { var c = r[k] || {}, x = (r.cc || {})[k] || {t: (r.cells || {})[k] || '', n: 0, m: ''}, cls = c.st === 'N/A' ? 'NA' : c.st;
    var tip = c.st + (x.m ? ' - missing ' + x.m : '') + (c.full_on ? ' - full on ' + c.full_on : '');
    return '<td class="' + esc(cls) + ' cnt" title="' + esc(tip) + '">' + esc(x.t) + (x.n ? '<span class="miss">' + esc(x.n) + ' missing</span>' : '') + '</td>'; };
  var PERIODS = ['daily', 'weekly', 'monthly'].concat(YON ? ['yearly'] : []);
  var detail = function (r) {
    var h = '<div class="dl"><b>Gaps:</b> ' + (r.gaps ? esc(r.gaps) : '<span class="muted">none</span>') + '</div>';
    if (r.not_yet_due) h += '<div class="dl muted nyd">' + esc(r.not_yet_due) + '</div>';
    if (r.warnings) h += '<div class="warn">' + esc(r.warnings) + '</div>';
    Object.keys(NOTE).forEach(function (k) { if (NOTE[k](r)) h += '<div class="warn yl-' + k + '"><b>' + esc(NOTEL[k]) + ':</b> ' + esc(NOTE[k](r)) +
      (k === 'overret' ? ' <span class="muted">Likely causes: backups stopped (old ones are not replaced), the retention period was lowered recently, the instance is stopped, or a snapshot is in use (copy / export / restore).</span>' : '') +
      (k === 'excess' ? ' <span class="muted">Likely causes: two backup plans or rules select this resource, or a manual on-demand job ran.</span>' : '') +
      (k === 'retmis' ? ' <span class="muted">Still counted; set the backup rule\'s retention to the expected value.</span>' : '') + '</div>'; });
    h += '<table><thead><tr><th>Check</th><th>Found / expected</th><th>Status</th><th>Missing</th><th>Full on</th></tr></thead><tbody>' + PERIODS.map(function (k) {
      var c = r[k] || {}, x = (r.cc || {})[k] || {};
      return '<tr><td>' + PL[k] + '</td><td>' + esc(x.t) + '</td><td>' + esc(c.st) + '</td><td>' + esc(x.m) + '</td><td>' + esc(c.full_on || '') + '</td></tr>'; }).join('') + '</tbody></table>';
    var rp = r.recovery_points;
    if (rp) h += '<div class="dl"><b>AWS Backup recovery points</b> <span class="muted">(' + rp.length + '; weekly = retention ' + esc(D.cfg.weekly_min_days) + '-' + esc(D.cfg.weekly_max_days) +
      'd, expected ' + esc(D.cfg.weekly_retention_days || 30) + 'd; monthly = ' + esc(D.cfg.monthly_min_days || (D.cfg.weekly_max_days + 1)) + '-' + esc(D.cfg.monthly_max_days) + 'd, expected ' + esc(D.cfg.monthly_retention_days || 365) + 'd)</span></div>' +
      (rp.length ? '<table class="rpd"><thead><tr><th>Created (UTC)</th><th>Retention</th><th>Class</th><th>Status</th><th>Counted</th><th>Reason</th><th>Vault</th><th>Recovery point</th></tr></thead><tbody>' +
        rp.map(function (p) { return '<tr' + (p.retention_mismatch ? ' class="yl" title="' + esc(p.retention_mismatch) + '"' : '') + '><td>' + esc(p.date) + '</td><td>' + (p.ret == null ? 'never expires' : esc(p.ret) + 'd') + '</td><td>' + esc(p.class) + '</td><td>' + esc(p.status) +
          '</td><td class="' + (p.counted ? 'cnt-y">yes' : 'cnt-n">no') + '</td><td>' + esc(p.reason) + '</td><td>' + esc(p.vault) + '</td><td>' + esc(p.id) + '</td></tr>'; }).join('') + '</tbody></table>'
        : '<div class="muted">none found in this region\'s backup vaults</div>');
    return h; };
  var count = function (rs, s) { return rs.filter(function (r) { return r.status === s; }).length; };
  var render = function () {
    var rs = filtered();
    var cp = comp(rs);
    document.getElementById('cards').innerHTML = '<div class="card pct" data-k="compliance" title="Compliant / resources that are due (not yet due are not counted)"><div class="v">' + pctTxt(cp) + '</div><div class="l">compliant (' + cp.c + ' of ' + cp.y + ')' +
      (cp.n ? '<br><span class="muted">' + cp.n + ' not yet due, not counted</span>' : '') + '</div></div>' + [['resources', 'Resources', rs.length]].concat(STATUSES.map(function (s) { return [s.toLowerCase().replace(/ /g, '-'), s, count(rs, s)]; }))
      .map(function (c) { var s = STATUSES.indexOf(c[1]) >= 0;
        return '<div class="card' + (s ? ' cl' + (val('f-status') === c[1] ? ' on' : '') : '') + '" data-k="' + c[0] + '"' + (s ? ' data-s="' + esc(c[1]) + '" title="' + esc(TIP[c[1]] + ' (click to filter)') + '"' : '') + '><div class="v">' + c[2] + '</div><div class="l">' + c[1] + '</div></div>'; }).join('');
    document.querySelectorAll('#cards .card.cl').forEach(function (c) { c.onclick = function () { var f = document.getElementById('f-status');
      f.value = f.value === c.dataset.s ? '' : c.dataset.s; render(); }; });
    document.querySelector('#main tbody').innerHTML = rs.map(function (r) {
      var k = key(r), op = !!OPEN[k];
      return '<tr class="res' + (op ? ' open' : '') + '" data-k="' + esc(k) + '"><td class="cx"><span class="car" role="button" tabindex="0" aria-expanded="' + op + '" title="Show details">&#9654;</span></td><td>' + esc(alab(r)) + '</td><td>' + esc(r.region) + '</td><td><a href="' + esc(href('bk', k)) + '" class="go" title="Show this resource\'s backups">' + esc(r.identifier) + '</a> <a href="' + esc(href('bk', k)) + '" class="bkl" title="Open the Backups tab for this resource">backups</a></td><td>' + esc(r.type) +
        '</td><td class="cr">' + (r.created_epoch != null ? esc(String(r.created).slice(0, 10)) + '<br><span class="muted">' + esc(r.age_days) + ' days</span>' : esc(r.created)) +
        '</td><td>' + esc(r.engine) + ' ' + esc(r.engine_version) + '</td><td>' + esc(r.global_cluster) + '</td><td>' + esc(r.global_role) + '</td><td>' + esc(r.retention_days) + 'd</td><td>' +
        (r.pitr && r.pitr.on ? '<span class="pitr">PITR</span>' + (r.pitr.since ? '<br><span class="muted">since ' + esc(String(r.pitr.since).slice(0, 10)) + '</span>' : '') : 'No') + '</td><td>' +
        esc(r.last_automated_utc) + '<br><span class="muted">' + esc(r.last_automated_local) + '</span></td>' +
        PERIODS.map(function (p) { return td(r, p); }).join('') +
        '<td class="s-' + esc(String(r.status).replace(/ /g, '-')) + '">' + esc(r.status) + '</td><td class="gaps" title="' + esc([r.gaps, r.not_yet_due, r.warnings].filter(Boolean).join(' | ')) + '">' +
        esc(r.gsum != null ? r.gsum : r.gaps) + ytags(r) + '</td></tr>' +
        '<tr class="det" data-k="' + esc(k) + '"' + (op ? '' : ' hidden') + '><td colspan="' + NC + '">' + detail(r) + '</td></tr>'; }).join('');
    document.getElementById('f-count').textContent = rs.length + ' of ' + D.rows.length + ' shown';
    save('comp', F.concat(['f-q']));
    var pin = document.getElementById('f-pin'), pr = PIN && D.rows.filter(function (x) { return key(x) === PIN; })[0];
    pin.hidden = !PIN; pin.innerHTML = PIN ? 'Only ' + esc(pr ? pr.identifier + ' (' + pr.account_id + ', ' + pr.region + ')' : PIN) + ' <button id="f-unpin" title="Show all resources again">&times; clear</button>' : '';
    if (PIN) document.getElementById('f-unpin').onclick = function () { PIN = ''; render(); };
    var g = {}; rs.forEach(function (r) { var k = r.account_id + '|' + r.region; (g[k] = g[k] || []).push(r); });
    var line = function (a, b, x) { return '<td>' + a + '</td><td>' + b + '</td><td>' + x.length + '</td>' + STATUSES.map(function (s) { return '<td>' + count(x, s) + '</td>'; }).join('') + '<td>' + pctTxt(comp(x)) + '</td>'; };
    document.querySelector('#regions tbody').innerHTML = Object.keys(g).sort().map(function (k) { var p = k.split('|'); return '<tr data-k="' + esc(k) + '">' + line(esc(alabel(p[0])), esc(p[1]), g[k]) + '</tr>'; }).join('');
    document.querySelector('#regions tfoot').innerHTML = '<tr><th colspan="2">All regions</th><th>' + rs.length + '</th>' + STATUSES.map(function (s) { return '<th>' + count(rs, s) + '</th>'; }).join('') + '<th>' + pctTxt(cp) + '</th></tr>';
    document.querySelectorAll('#main a.go, #main a.bkl').forEach(function (a) { a.onclick = function (e) { e.preventDefault(); e.stopPropagation(); showBackups(a.closest('tr').dataset.k); };
      a.onkeydown = function (e) { e.stopPropagation(); }; });
    document.querySelectorAll('#main tr.res').forEach(function (tr) {
      var tog = function () { var k = tr.dataset.k, d = tr.nextElementSibling, op = !OPEN[k]; if (op) OPEN[k] = 1; else delete OPEN[k];
        tr.classList.toggle('open', op); d.hidden = !op; tr.querySelector('.car').setAttribute('aria-expanded', String(op)); };
      tr.onclick = function (e) { if (window.getSelection && String(window.getSelection())) return; tog(); };
      tr.querySelector('.car').onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); tog(); } }; });
  };
  var errs = D.regions.filter(function (r) { return r.status === 'error'; });
  if (errs.length) document.getElementById('rerr').innerHTML = '<h2>Region errors</h2><ul>' + errs.map(function (r) { return '<li>' + esc(r.account + ' ' + r.region + ': ' + r.errors.join('; ')) + '</li>'; }).join('') + '</ul>';
  F.forEach(function (id) { document.getElementById(id).onchange = render; });
  document.getElementById('f-q').oninput = render;
  document.getElementById('f-reset').onclick = function () { PIN = ''; F.forEach(function (id) { document.getElementById(id).value = ''; }); document.getElementById('f-q').value = ''; render(); };
  var csvq = function (v) { v = v == null ? '' : String(v); if (/^[=+\-@]/.test(v)) v = "'" + v; return /[",\r\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; };
  var download = function (name, rows, q) {
    var b = new Blob(['\ufeff' + rows.map(function (r) { return r.map(q || csvq).join(','); }).join('\r\n') + '\r\n'], {type: 'text/csv'});
    var a = document.createElement('a'); a.href = URL.createObjectURL(b); a.download = name; document.body.appendChild(a); a.click(); a.remove(); };
  var acctTag = uniq(D.accounts.map(function (a) { return a.account; })).join('_');
  // same header, cells and quoting as the script's --format csv (jq @csv: every cell quoted, formula guard)
  var csvAll = function (v) { v = v == null ? '' : String(v); if (/^[=+\-@]/.test(v)) v = "'" + v; return '"' + v.replace(/"/g, '""') + '"'; };
  // v1.5.0 column picker: all ticked by default; unticked column names are remembered per tab
  var picker = function (tk, head, rows, name, q) {
    var old = document.getElementById('cp'); if (old) old.remove();
    var off = LS.get('cols-' + tk) || [], d = document.createElement('div'); d.id = 'cp'; d.className = 'cp';
    d.innerHTML = '<div class="cph"><b>CSV columns</b><br><button data-a="go">Download (' + rows.length + ' rows)</button><button data-a="x">Cancel</button><button data-a="all">All</button><button data-a="none">None</button></div><div class="cpl">' +
      head.map(function (h, i) { return '<label><input type="checkbox" value="' + i + '"' + (off.indexOf(h) < 0 ? ' checked' : '') + '> ' + esc(h) + '</label>'; }).join('') + '</div>';
    document.body.appendChild(d);
    var bx = d.querySelectorAll('input');
    d.onclick = function (e) { var a = e.target.dataset ? e.target.dataset.a : ''; if (!a) return;
      if (a === 'all' || a === 'none') bx.forEach(function (b) { b.checked = a === 'all'; });
      if (a === 'go') { var ix = [].filter.call(bx, function (b) { return b.checked; }).map(function (b) { return +b.value; }); if (!ix.length) return;
        LS.set('cols-' + tk, head.filter(function (h, i) { return ix.indexOf(i) < 0; }));
        download(name, [head].concat(rows).map(function (r) { return ix.map(function (i) { return r[i]; }); }), q); }
      if (a === 'go' || a === 'x') d.remove(); }; };
  document.getElementById('f-csv').onclick = function () {
    picker('comp', D.csvh, filtered().map(function (r) { return r.csv; }), 'rds_backup_compliance_' + acctTag + '_filtered.csv', csvAll); };

  // ---------------- Backups tab
  var B = document.getElementById('bk'), SN = {};
  D.snaps.forEach(function (s) { s.s.forEach(function (x) { x.src = 'EXISTING'; }); SN[s.k] = s.s; });
  // orphaned / shared / copied manual snapshots: one pseudo-resource per source (v1.0 / v1.1 data has no D.orph)
  var PFX = {ORPHANED: '(deleted) ', SHARED: '(shared) ', UNVERIFIED: '(copy, source region not scanned) ', EXISTING: '(cross-region copy) '};
  var SRCL = {EXISTING: 'Existing', ORPHANED: 'Orphaned', SHARED: 'Shared', UNVERIFIED: 'Unverified'};
  var PR = [], PRK = {};
  (D.orph || []).forEach(function (o) {
    var r = {account_id: o.a, region: o.r, identifier: PFX[o.src] + o.sid + (o.src === 'EXISTING' && o.sr ? ' @' + o.sr : ''), sid: o.sid, type: o.t, engine: o.eng, src: o.src, pseudo: true};
    var k = key(r) + '|' + o.t; r.k = k;
    if (!PRK[k]) { PRK[k] = r; PR.push(r); SN[k] = []; }
    SN[k].push({kind: 'manual', bt: 'manual', sc: 'not_counted', id: o.id, c: o.c, st: o.st, gb: o.gb, x: null, v: '', cl: '', rd: null, src: o.src, usd: o.usd, enc: o.enc, kms: o.kms, shared: o.kind === 'shared'}); });
  PR.sort(function (a, b) { return a.k < b.k ? -1 : 1; });
  var rkey = function (r) { return r.pseudo ? r.k : key(r); };
  var RR = D.rows.concat(PR);
  var ALL = '*all*';
  var KIND = {manual: 'Manual', automated: 'Automated', backup: 'AWS Backup'};
  var bopt = function (id, label, vals, txt) { return '<label class="ballf">' + label + ' <select id="' + id + '"><option value="">All</option>' +
    vals.map(function (v) { return '<option value="' + esc(v) + '">' + esc(txt ? txt(v) : v) + '</option>'; }).join('') + '</select></label>'; };
  // Age: "3/6/12" = created in the last N months; "o30.." = older than N days; "all" = any age
  var ropt = function (r) { return '<option value="' + esc(rkey(r)) + '">' + esc(r.identifier + ' (' + r.account_id + ', ' + r.region + ', ' + r.type + ')') + '</option>'; };
  B.innerHTML = '<div id="b-orph" class="osum">' + oline() + '</div><div class="filters">' +
    bopt('b-acct', 'Account', uniq(RR.map(function (r) { return r.account_id; })), alabel).replace('class="ballf"', 'class="bacct"') +
    bopt('b-region', 'Region', uniq(RR.map(function (r) { return r.region; }))) +
    '<label class="rsel">Resource <input id="b-rq" type="text" autocomplete="off" role="combobox" aria-controls="b-rl" placeholder="Type to filter" title="Identifier, engine, account or region contains; arrows + Enter to pick">' +
    '<ul id="b-rl" class="rl" role="listbox" hidden></ul><select id="b-res" hidden><option value="' + ALL + '">All clusters and instances</option>' + D.rows.map(ropt).join('') +
    (PR.length ? '<optgroup label="Snapshots whose source is not in this account + region">' + PR.map(ropt).join('') + '</optgroup>' : '') +
    '</select></label>' + bopt('b-engine', 'Engine', uniq(RR.map(function (r) { return r.engine; }).filter(Boolean))) + '<label>Backup type <select id="b-kind"><option value="">All types</option><option value="pitr">PITR (continuous)</option><option value="automated">Snapshot: automated</option><option value="manual">Snapshot: manual</option><option value="backup">Snapshot: AWS Backup</option></select></label>' +
    '<label>Schedule' + tip(TIP.sched) + ' <select id="b-sched"><option value="">All</option>' + [['daily', 'Daily'], ['weekly', 'Weekly'], ['monthly', 'Monthly']].concat(YON ? [['yearly', 'Yearly']] : [], [['not_counted', 'Not counted']])
      .map(function (o) { return '<option value="' + o[0] + '">' + o[1] + '</option>'; }).join('') + '</select></label>' +
    '<label>Age <select id="b-period"><optgroup label="Created in"><option value="3">Last 3 months</option><option value="6">Last 6 months</option><option value="12" selected>Last 12 months</option></optgroup>' +
    '<optgroup label="Older than (oldest first)"><option value="o30">Older than 30 days</option><option value="o90">Older than 90 days</option><option value="o180">Older than 180 days</option><option value="o365">Older than 365 days</option></optgroup>' +
    '<option value="all">Any age</option></select></label>' +
    '<label class="ballf">Source status <select id="b-src"><option value="">All</option><option value="EXISTING">Existing</option><option value="ORPHANED">Orphaned</option><option value="SHARED">Shared</option>' +
    ((D.orph || []).some(function (o) { return o.src === 'UNVERIFIED'; }) ? '<option value="UNVERIFIED">Unverified</option>' : '') + '</select></label>' +
    '<input id="b-q" type="search" placeholder="Search identifier, engine, region, account, vault, plan, snapshot" title="Resource identifier, engine, region, account, AWS Backup vault or plan, or snapshot / recovery point id contains"> ' +
    '<button id="b-reset" title="All clusters and instances, every filter cleared, search cleared, newest first">Reset</button> <button id="b-csv">Export CSV</button> <span id="b-sum" class="muted"></span></div><div id="b-out"></div>';
  var since = function (m) { var d = new Date(D.now * 1000); d.setUTCMonth(d.getUTCMonth() - m); return d.getTime() / 1000; };
  var isAll = function () { return val('b-res') === ALL; };
  var older = function () { var v = val('b-period'); return v.charAt(0) === 'o' ? +v.slice(1) : null; };
  var ageD = function (c) { return Math.floor((D.now - c) / 86400); };
  var ageOk = function (c) { var v = val('b-period'), o = older(); if (v === 'all') return true; if (o != null) return D.now - c > o * 86400; return c >= since(+v); };
  var kindOk = function (s) { var v = val('b-kind'); return (!v || (v === 'pitr' ? s.bt === 'pitr' : v === 'backup' ? s.kind === 'backup' && s.bt !== 'pitr' : s.kind === v)) &&
    (!val('b-sched') || (s.sc || '') === val('b-sched')); };
  var pb = function (s) { return s.bt === 'pitr' ? ' <span class="pitr" title="' + esc(TIP.pitr) + '">PITR</span>' : ''; };
  var srcOk = function (s) { return !isAll() || !val('b-src') || s.src === val('b-src'); };
  var usd = function (v) { return v == null ? '' : v >= 10 ? '$' + Math.round(v) : '$' + (Math.round(v * 100) / 100); };
  var order = function (a, b) { return older() != null ? a.c - b.c : b.c - a.c; };
  var rule = function (s) { return s.kind === 'backup' ? s.cl : s.kind === 'automated' ? 'daily' : ''; };
  var gb = function (xs) { return Math.round(xs.reduce(function (t, s) { return t + (+s.gb || 0); }, 0) * 10) / 10; };
  // search: matches the resource (identifier, engine, region, account, plan) or the backup (id, vault)
  var bq = function () { return val('b-q').toLowerCase().trim(); };
  var qOk = function (r, s, q) { return !q || hay(r).indexOf(q) >= 0 || [s.id, s.v].join('\n').toLowerCase().indexOf(q) >= 0; };
  var curR = function () { return RR.filter(function (x) { return rkey(x) === val('b-res'); })[0]; };
  var current = function () { var r = curR() || {}, q = bq(); return (SN[val('b-res')] || []).filter(function (s) { return ageOk(s.c) && kindOk(s) && qOk(r, s, q); }).sort(order); };
  var allRows = function () { var out = [], q = bq();
    RR.forEach(function (r) {
      if ((val('b-acct') && r.account_id !== val('b-acct')) || (val('b-region') && r.region !== val('b-region')) || (val('b-engine') && r.engine !== val('b-engine'))) return;
      (SN[rkey(r)] || []).forEach(function (s) { if (kindOk(s) && srcOk(s) && ageOk(s.c) && qOk(r, s, q)) out.push({r: r, s: s}); }); });
    return out.sort(function (a, b) { return order(a.s, b.s) || (rkey(a.r) < rkey(b.r) ? -1 : 1); }); };
  var sumTxt = function (xs) { return xs.length + ' backup(s), ' + gb(xs) + ' GB'; };
  var SECT = [['manual', 'Manual snapshots'], ['automated', 'Automated backups (RDS)'], ['backup', 'AWS Backup recovery points']];
  var renderAll = function () {
    var xs = allRows(), n = uniq(xs.map(function (x) { return rkey(x.r); })).length, ss = xs.map(function (x) { return x.s; });
    // optional columns are shown only when some visible row has a value (CSV columns stay fixed)
    var hasRule = ss.some(function (x) { return rule(x) !== ''; }), hasBk = ss.some(function (x) { return x.kind === 'backup'; });
    var hasSrc = ss.some(function (x) { return x.kind === 'manual'; }), orph = ss.filter(function (x) { return x.src === 'ORPHANED'; }), hasUsd = orph.length > 0;
    var title = (val('b-src') ? SRCL[val('b-src')] + ' source - ' : '') + (val('b-kind') ? KIND[val('b-kind')] + ' backups' : 'All backup types') + ' - all clusters and instances';
    document.getElementById('b-sum').textContent = sumTxt(ss) + ' across ' + n + ' resource(s)' + (hasUsd ? ' · ' + orph.length + ' orphaned, ~' + usd(orph.reduce(function (t, x) { return t + (x.usd || 0); }, 0)) + '/month (estimate)' : '');
    document.getElementById('b-out').innerHTML = '<h2 data-sec="all">' + esc(title) + ' (' + xs.length + ')</h2>' + (xs.length ?
      '<table class="bt" data-sec="all"><thead><tr><th>Account</th><th>Region</th><th>Resource</th><th>Resource type</th><th>Backup type</th><th>Snapshot / recovery point</th><th>Created (UTC)</th><th>Created (' + esc(D.tz_label) +
      ')</th><th>Age (days)</th><th>Status</th><th>Size GB</th>' + (hasSrc ? '<th>Source</th>' : '') + (hasUsd ? '<th>Est. $/month</th>' : '') + (hasRule ? '<th>Rule</th>' : '') + (hasBk ? '<th>Retention</th><th>Vault</th>' : '') + '</tr></thead><tbody>' +
      xs.map(function (x) { var s = x.s; return '<tr data-kind="' + esc(s.kind) + '" data-src="' + esc(s.src || '') + '"' + (s.src === 'ORPHANED' ? ' class="orph"' : s.fl ? ' class="yl" title="' + esc(s.fl) + '"' : '') + '><td>' + esc(alab(x.r)) + '</td><td>' + esc(x.r.region) + '</td><td><a href="' + esc(x.r.pseudo ? '#' : href('comp', rkey(x.r))) + '" class="go" data-k="' + esc(rkey(x.r)) + '"' + (x.r.pseudo ? ' title="Show this source\'s snapshots"' : ' data-c="1" title="Open this resource on the Compliance tab"') + '>' + esc(x.r.identifier) + '</a></td><td>' + esc(x.r.type) +
        '</td><td>' + esc(Object.prototype.hasOwnProperty.call(KIND, s.kind) ? KIND[s.kind] : s.kind) + (s.shared ? ' (shared)' : '') + pb(s) + '</td><td>' + esc(s.id) + '</td><td>' + utc(s.c) + '</td><td>' + loc(s.c) + '</td><td>' + ageD(s.c) + '</td><td>' + esc(s.st) + '</td><td>' + esc(s.gb) + '</td>' +
        (hasSrc ? '<td class="src-' + esc(s.src || '') + '">' + (s.kind === 'manual' ? esc(SRCL[s.src] || '') : '') + '</td>' : '') + (hasUsd ? '<td>' + (s.src === 'ORPHANED' ? usd(s.usd) : '') + '</td>' : '') + (hasRule ? '<td>' + esc(rule(s)) + '</td>' : '') +
        (hasBk ? '<td>' + (s.kind !== 'backup' ? '' : s.rd == null ? 'never expires' : esc(s.rd) + 'd') + '</td><td>' + esc(s.v) + '</td>' : '') + '</tr>'; }).join('') +
      '</tbody><tfoot><tr><th colspan="10">Total</th><th>' + gb(ss) + '</th>' + (hasSrc ? '<th></th>' : '') + (hasUsd ? '<th>' + usd(orph.reduce(function (t, x) { return t + (x.usd || 0); }, 0)) + '</th>' : '') + ((hasRule ? 1 : 0) + (hasBk ? 2 : 0) ? '<th colspan="' + ((hasRule ? 1 : 0) + (hasBk ? 2 : 0)) + '"></th>' : '') + '</tr></tfoot></table>' : '<div class="muted">None match these filters.</div>');
    document.querySelectorAll('#b-out a.go').forEach(function (a) { a.onclick = function (e) { e.preventDefault();
      if (a.dataset.c) return showCompliance(a.dataset.k); document.getElementById('b-res').value = a.dataset.k; renderB(); }; });
  };
  // Account works in every mode: it narrows the Resource list; a selected resource in another account switches to All
  var acctSync = function () { var a = val('b-acct'), sel = document.getElementById('b-res');
    Array.prototype.forEach.call(sel.options, function (o) { var r = o.value === ALL ? null : (PRK[o.value] || D.rows.filter(function (x) { return key(x) === o.value; })[0]);
      o.hidden = o.disabled = !!(a && r && r.account_id !== a); });
    if (sel.selectedOptions[0] && sel.selectedOptions[0].disabled) sel.value = ALL; };
  // v1.5.1 resource search: substring over identifier / engine / account / region; the hidden #b-res keeps the value
  var RQ = document.getElementById('b-rq'), RL = document.getElementById('b-rl'), RSEL = document.getElementById('b-res'), rIx = -1;
  var rlab = function (o) { return o.textContent; };
  var rqSync = function () { var o = RSEL.selectedOptions[0]; if (document.activeElement !== RQ) RQ.value = o ? rlab(o) : ''; };
  var rlist = function () { var q = RQ.value.toLowerCase(), cur = RSEL.selectedOptions[0];
    if (cur && RQ.value === rlab(cur)) q = '';
    var os = [].filter.call(RSEL.options, function (o) { var r = PRK[o.value] || rowOf(o.value);
      return !o.disabled && (o.value === ALL || !q || [o.textContent, r && r.engine, r && r.account_id, r && r.account_name, r && r.region, r && alabel(r.account_id)].join(' ').toLowerCase().indexOf(q) >= 0); });
    rIx = os.length ? 0 : -1;
    RL.innerHTML = os.map(function (o, i) { return '<li role="option" data-v="' + esc(o.value) + '"' + (i === rIx ? ' class="on"' : '') + '>' + esc(o.textContent) + '</li>'; }).join('') || '<li class="muted">No match</li>';
    RL.hidden = false; };
  var rpick = function (v) { RSEL.value = v; RL.hidden = true; RQ.blur(); renderB(); };
  RQ.onfocus = function () { RQ.select(); rlist(); }; RQ.oninput = rlist;
  RQ.onblur = function () { setTimeout(function () { RL.hidden = true; rqSync(); }, 150); };
  RQ.onkeydown = function (e) { var li = RL.querySelectorAll('li[data-v]');
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); if (RL.hidden) rlist(); if (!li.length) return;
      rIx = (rIx + (e.key === 'ArrowDown' ? 1 : li.length - 1)) % li.length; li.forEach(function (x, i) { x.classList.toggle('on', i === rIx); }); if (li[rIx].scrollIntoView) li[rIx].scrollIntoView({block: 'nearest'}); }
    else if (e.key === 'Enter') { e.preventDefault(); if (li[rIx]) rpick(li[rIx].dataset.v); }
    else if (e.key === 'Escape') { RL.hidden = true; RQ.blur(); } };
  RL.onmousedown = function (e) { var li = e.target.closest ? e.target.closest('li[data-v]') : null; if (li) { e.preventDefault(); rpick(li.dataset.v); } };
  var renderB = function () {
    acctSync(); rqSync(); save('bk', BF);
    document.querySelectorAll('.ballf').forEach(function (l) { l.style.display = isAll() ? '' : 'none'; });
    if (isAll()) return renderAll();
    var ss = current(), r = curR();
    document.getElementById('b-sum').textContent = (r && r.pseudo ? 'Source ' + r.sid + ': ' + ({ORPHANED: 'not found in this account + region (orphaned)', SHARED: 'in another account (shared / copied)',
        UNVERIFIED: 'in a region that was not scanned', EXISTING: 'exists in ' + (r.region) + "'s source region"})[r.src] + ' · ' : r ? r.status + (r.gaps ? ' - ' + r.gaps : '') + ' · ' : '') + sumTxt(ss);
    var t = r && !r.pseudo ? ST(r) : null, dash = function (v) { return v === '' || v == null ? '<span class="muted">-</span>' : esc(v); };
    var set = t ? '<h2 data-sec="settings">Retention settings</h2><table class="kv" id="b-settings"><tbody>' +
      '<tr><th>RDS automated retention</th><td>' + dash(r.retention_days == null ? '' : r.retention_days + ' days') + '</td></tr>' +
      '<tr><th>Preferred backup window (UTC)</th><td>' + dash(t.backup_window) + '</td></tr>' +
      '<tr><th>Copy tags to snapshots</th><td>' + dash(t.copy_tags === true ? 'Yes' : t.copy_tags === false ? 'No' : '') + '</td></tr>' +
      '<tr><th>AWS Backup retention seen</th><td>' + dash([t.weekly_retention ? 'weekly ' + t.weekly_retention : '', t.monthly_retention ? 'monthly ' + t.monthly_retention : '',
        t.yearly_retention ? 'yearly ' + t.yearly_retention : ''].filter(Boolean).join(' / ')) + '</td></tr>' +
      '<tr><th>Backup plan / rule</th><td>' + dash(t.plans) + '</td></tr>' + (t.schedules ? '<tr><th>Rule schedule</th><td>' + esc(t.schedules) + '</td></tr>' : '') +
      '<tr><th>Created</th><td>' + dash(r.created ? r.created + (r.age_days != null ? ' (' + r.age_days + ' days ago)' : '') : '') + '</td></tr>' +
      (r.not_yet_due ? '<tr><th>Building up</th><td>' + esc(r.not_yet_due) + '</td></tr>' : '') +
      (r.warnings ? '<tr><th>Warning</th><td class="warn">' + esc(r.warnings) + '</td></tr>' : '') +
      Object.keys(NOTE).map(function (k) { return NOTE[k](r) ? '<tr><th>' + esc(NOTEL[k]) + '</th><td class="warn">' + esc(NOTE[k](r)) + '</td></tr>' : ''; }).join('') + '</tbody></table>' : '';
    var none = r && !r.pseudo && !(SN[rkey(r)] || []).length;
    var top = r && !r.pseudo ? '<div class="blink"><a href="' + esc(href('comp', rkey(r))) + '" class="cgo" data-k="' + esc(rkey(r)) + '">' + esc(r.identifier) + '</a> <span class="muted">(' + esc(r.account_id + ', ' + r.region) + ') - open on the Compliance tab</span></div>' +
      (none ? '<div class="empty" id="b-empty">No backups found for ' + esc(r.identifier) + ' in ' + esc(r.account_id + ' ' + r.region) + ': no manual snapshots, automated backups or AWS Backup recovery points were collected.</div>' : '') : '';
    document.getElementById('b-out').innerHTML = top + set + SECT.filter(function (sec) { var kv = val('b-kind') === 'pitr' ? 'backup' : val('b-kind'); return !kv || sec[0] === kv; }).map(function (sec) {
      var xs = ss.filter(function (s) { return s.kind === sec[0]; }), bk = sec[0] === 'backup';
      return '<h2 data-sec="' + sec[0] + '">' + sec[1] + ' (' + xs.length + ')</h2>' + (xs.length ? '<table class="bt" data-sec="' + sec[0] + '"><thead><tr><th>Identifier</th><th>Created (UTC)</th><th>Created (' + esc(D.tz_label) + ')</th><th>Age (days)</th><th>Status</th><th>Size GB</th>' +
        (bk ? '<th>Class</th><th>Retention</th><th>Expires (UTC)</th><th>Vault</th>' : '') + '</tr></thead><tbody>' + xs.map(function (s) {
          return '<tr' + (s.fl ? ' class="yl" title="' + esc(s.fl) + '"' : '') + '><td>' + esc(s.id) + pb(s) + '</td><td>' + utc(s.c) + '</td><td>' + loc(s.c) + '</td><td>' + ageD(s.c) + '</td><td>' + esc(s.st) + '</td><td>' + esc(s.gb) + '</td>' +
            (bk ? '<td>' + esc(s.cl) + '</td><td>' + (s.rd == null ? 'never expires' : esc(s.rd) + 'd') + '</td><td>' + utc(s.x) + '</td><td>' + esc(s.v) + '</td>' : '') + '</tr>'; }).join('') +
        '</tbody></table>' : '<div class="muted">None match these filters.</div>'); }).join('');
    var cg = document.querySelector('#b-out a.cgo'); if (cg) cg.onclick = function (e) { e.preventDefault(); showCompliance(cg.dataset.k); }; };
  // ---------------- cross-tab links + URL hash (v1.4.1): #view=comp&id=<account|region|identifier> or #view=bk&res=<key>
  // Each link pushes a history entry holding the whole page state, so the browser Back button restores the previous view.
  var BF = ['b-res', 'b-kind', 'b-sched', 'b-period', 'b-acct', 'b-region', 'b-engine', 'b-src', 'b-q'];
  var tab = function (t) { document.querySelectorAll('.tabs button, .tab').forEach(function (x) { x.classList.remove('on'); });
    document.querySelector('.tabs button[data-t="' + t + '"]').classList.add('on'); document.getElementById(t).classList.add('on'); };
  var curTab = function () { var b = document.querySelector('.tabs button.on'); return b ? b.dataset.t : 'comp'; };
  var snap = function () { var v = {}; F.concat(['f-q'], BF).forEach(function (id) { v[id] = val(id); });
    return {rbc: 1, t: curTab(), v: v, pin: PIN, open: Object.keys(OPEN), y: window.scrollY}; };
  var restore = function (st) { Object.keys(st.v).forEach(function (id) { document.getElementById(id).value = st.v[id]; }); PIN = st.pin || '';
    OPEN = {}; (st.open || []).forEach(function (k) { OPEN[k] = 1; }); render(); renderB(); tab(st.t); window.scrollTo(0, st.y || 0); };
  var push = function (h) { try { history.replaceState(snap(), ''); history.pushState(null, '', h); } catch (e) { /* file:// in some browsers */ } };
  var rowOf = function (k) { return D.rows.filter(function (x) { return key(x) === k; })[0]; };
  var goComp = function (k) {
    var r = rowOf(k); if (!r) return false;
    F.forEach(function (id) { document.getElementById(id).value = ''; }); document.getElementById('f-q').value = '';
    document.getElementById('f-acct').value = r.account_id; document.getElementById('f-region').value = r.region;
    PIN = k; OPEN[k] = 1; render(); tab('comp');
    var tr = Array.prototype.filter.call(document.querySelectorAll('#main tr.res'), function (x) { return x.dataset.k === k; })[0];
    if (tr) { tr.classList.add('hl'); if (tr.scrollIntoView) tr.scrollIntoView({block: 'center'}); var a = tr.querySelector('a.go'); if (a) a.focus({preventScroll: true}); }
    return true; };
  var goBk = function (k) {
    var ok = k === ALL || RR.some(function (x) { return rkey(x) === k; }); if (!ok) return false;
    if (val('b-acct') && k !== ALL && (rowOf(k) || PRK[k] || {}).account_id !== val('b-acct')) document.getElementById('b-acct').value = '';
    document.getElementById('b-res').value = k; renderB(); tab('bk'); window.scrollTo(0, 0); return true; };
  var href = function (v, k) { return '#view=' + v + '&' + (v === 'comp' ? 'id' : 'res') + '=' + encodeURIComponent(k); };
  var showCompliance = function (k) { push(href('comp', k)); goComp(k); };
  window.showBackups = function (k) { push(href('bk', k)); goBk(k); };
  var showBackups = window.showBackups;
  var fromHash = function () { var h = {}; String(location.hash || '').replace(/^#/, '').split('&').forEach(function (p) { var i = p.indexOf('=');
      if (i > 0) { try { h[p.slice(0, i)] = decodeURIComponent(p.slice(i + 1)); } catch (e) { /* bad escape: ignore */ } } });
    if (h.view === 'comp' && h.id) return goComp(h.id); if (h.view === 'bk' && h.res) return goBk(h.res); return false; };
  window.addEventListener('popstate', function (e) { if (e.state && e.state.rbc) restore(e.state); else if (!fromHash()) { PIN = ''; render(); tab('comp'); } });
  ['b-res', 'b-kind', 'b-sched', 'b-period', 'b-acct', 'b-region', 'b-engine', 'b-src'].forEach(function (id) { document.getElementById(id).onchange = renderB; });
  document.getElementById('b-q').oninput = renderB;
  var showOrph = function () { document.getElementById('b-res').value = ALL; document.getElementById('b-kind').value = ''; document.getElementById('b-sched').value = ''; document.getElementById('b-src').value = 'ORPHANED';
    document.getElementById('b-period').value = 'all'; ['b-acct', 'b-region', 'b-engine'].forEach(function (id) { document.getElementById(id).value = ''; }); renderB(); };
  // Reset: every dropdown (Resource back to All), the search and the order (Last 12 months = newest first)
  document.getElementById('b-reset').onclick = function () {
    ['b-kind', 'b-sched', 'b-acct', 'b-region', 'b-engine', 'b-src', 'b-q'].forEach(function (id) { document.getElementById(id).value = ''; });
    document.getElementById('b-res').value = ALL; document.getElementById('b-period').value = '12'; renderB(); };
  document.querySelectorAll('.osum-n').forEach(function (a) { a.onclick = function (e) { e.preventDefault(); showOrph(); tab('bk'); }; });
  var H = ['account_id', 'region', 'identifier', 'type', 'kind', 'snapshot_or_recovery_point', 'created_utc', 'created_' + D.tz_label.toLowerCase(), 'age_days', 'status', 'size_gb', 'rule', 'retention_days', 'expires_utc', 'vault', 'source_status', 'backup_type', 'schedule'];
  var line = function (r, s) { return [r.account_id, r.region, r.pseudo ? r.sid : r.identifier, r.type, s.kind, s.id, utc(s.c), loc(s.c), ageD(s.c), s.st, s.gb, rule(s), s.kind === 'backup' ? s.rd : '', utc(s.x), s.v, s.src || '', s.bt || '', s.sc || '']; };
  document.getElementById('b-csv').onclick = function () {
    var tag = (val('b-kind') || 'all-types') + '_' + val('b-period').replace(/^(\d+)$/, '$1m').replace(/^o(\d+)$/, 'older-$1d');
    if (isAll()) return picker('bk', H, allRows().map(function (x) { return line(x.r, x.s); }), 'rds_backups_all_' + acctTag + '_' + tag + '.csv');
    var r = curR();
    picker('bk', H, current().map(function (s) { return line(r, s); }), 'rds_backup_' + r.account_id + '_' + (r.pseudo ? 'deleted-' + r.sid : r.identifier) + '_' + tag + '.csv'); };
  // default view stays the first resource; "All" is the first option
  if (D.rows.length) document.getElementById('b-res').value = key(D.rows[0]);
  otip('f-status'); otip('f-show'); if (!/view=/.test(location.hash)) { load('comp'); load('bk'); }   // remembered filters; a URL hash deep link (below) still wins
  render(); if (D.rows.length || PR.length) renderB();
  fromHash();
})();
