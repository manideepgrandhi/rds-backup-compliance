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
  var STATUSES = ['COMPLIANT', 'NON-COMPLIANT', 'NOT YET DUE', 'UNKNOWN'];
  var YON = !!(D.cfg && D.cfg.yearly > 0);   // yearly=0 (default): no Yearly column anywhere
  var ST = function (r) { return r.settings || {}; };
  var nyd = function (r) { return r.status === 'NOT YET DUE' || !!r.not_yet_due; };
  document.querySelectorAll('.tabs button').forEach(function (b) { b.onclick = function () {
    document.querySelectorAll('.tabs button, .tab').forEach(function (x) { x.classList.remove('on'); });
    b.classList.add('on'); document.getElementById(b.dataset.t).classList.add('on'); }; });

  // ---------------- Compliance tab
  var C = document.getElementById('comp');
  var opt = function (id, label, vals, txt) { return '<label>' + label + ' <select id="' + id + '"><option value="">All</option>' +
    vals.map(function (v) { return '<option value="' + esc(v) + '">' + esc(txt ? txt(v) : v) + '</option>'; }).join('') + '</select></label>'; };
  // fixed column widths (px), wrapping inside cells; the table scrolls sideways on narrow screens
  var W = [20, 104, 84, 160, 72, 88, 125, 105, 84, 60, 160, 92, 88, 88].concat(YON ? [86] : [], [108, 160]);
  var NC = W.length;
  var WT = W.reduce(function (a, b) { return a + b; }, 0);
  var COLS = '<colgroup>' + W.map(function (w) { return '<col style="width:' + (100 * w / WT).toFixed(2) + '%">'; }).join('') + '</colgroup>';
  var OPEN = {};
  var globals = uniq(D.rows.map(function (r) { return r.global_cluster; }).filter(Boolean));
  C.innerHTML = '<div class="cards" id="cards"></div><div class="filters">' +
    opt('f-acct', 'Account', uniq(D.rows.map(function (r) { return r.account_id; }))) +
    opt('f-region', 'Region', uniq(D.rows.map(function (r) { return r.region; }))) +
    opt('f-type', 'Type', uniq(D.rows.map(function (r) { return r.type; }))) +
    opt('f-engine', 'Engine', uniq(D.rows.map(function (r) { return r.engine; }))) +
    opt('f-role', 'Role', uniq(D.rows.map(function (r) { return r.global_role; }))) +
    opt('f-global', 'Global cluster', ['(not global)'].concat(globals)) +
    opt('f-status', 'Status', STATUSES.filter(function (s) { return D.rows.some(function (r) { return r.status === s; }); })) +
    '<label>Show <select id="f-show"><option value="">All</option><option value="nyd">Not yet due</option><option value="warn">Retention warnings</option></select></label>' +
    '<input id="f-q" placeholder="Identifier contains"> <button id="f-reset">Reset</button> <button id="f-csv">Export CSV</button> <span id="f-count" class="muted"></span></div>' +
    '<div class="tw"><table id="main">' + COLS + '<thead><tr><th class="cx" title="Click a row to show its details"></th><th>Account</th><th>Region</th><th>Identifier</th><th>Type</th><th>Created</th><th>Engine</th><th>Global cluster</th><th>Role</th>' +
    '<th>Retention</th><th>Last automated</th><th>Daily</th><th>Weekly</th><th>Monthly</th>' + (YON ? '<th>Yearly</th>' : '') + '<th>Status</th><th>Gaps</th></tr></thead><tbody></tbody></table></div>' +
    '<h2>Per region</h2><table id="regions"><thead><tr><th>Account</th><th>Region</th><th>Resources</th><th>Compliant</th><th>Non-compliant</th><th>Not yet due</th><th>Unknown</th></tr></thead><tbody></tbody><tfoot></tfoot></table>' +
    '<div id="rerr"></div>';
  var OS = D.osum || {orphaned: 0, size_gb: 0, est_monthly_usd: 0, text: '0 orphaned snapshots, 0 GB, ~$0/month (estimate)', price_per_gb_month: 0.021};
  var oline = function () { return '<b>Orphaned manual snapshots:</b> ' + esc(OS.text) + ' <span class="muted">(size &times; $' + esc(OS.price_per_gb_month) +
    '/GB-month; rough upper estimate, snapshot billing is incremental' + (OS.shared ? '; ' + esc(OS.shared) + ' shared / cross-account not counted' : '') +
    (OS.unverified ? '; ' + esc(OS.unverified) + ' cross-region copies unverified' : '') + ')</span>'; };
  C.insertAdjacentHTML('afterbegin', '<div id="osum" class="osum">' + oline() + (OS.orphaned ? ' <a href="#" id="osum-go">show</a>' : '') + '</div>');
  var F = ['f-acct', 'f-region', 'f-type', 'f-engine', 'f-role', 'f-global', 'f-status', 'f-show'];
  var val = function (id) { return document.getElementById(id).value; };
  var filtered = function () {
    var q = val('f-q').toLowerCase();
    return D.rows.filter(function (r) {
      return (!val('f-acct') || r.account_id === val('f-acct')) && (!val('f-region') || r.region === val('f-region')) &&
        (!val('f-type') || r.type === val('f-type')) && (!val('f-engine') || r.engine === val('f-engine')) &&
        (!val('f-role') || r.global_role === val('f-role')) && (!val('f-status') || r.status === val('f-status')) &&
        (!val('f-global') || (val('f-global') === '(not global)' ? !r.global_cluster : r.global_cluster === val('f-global'))) &&
        (!val('f-show') || (val('f-show') === 'nyd' ? nyd(r) : !!r.warnings)) &&
        (!q || r.identifier.toLowerCase().indexOf(q) >= 0); }); };
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
    h += '<table><thead><tr><th>Check</th><th>Found / expected</th><th>Status</th><th>Missing</th><th>Full on</th></tr></thead><tbody>' + PERIODS.map(function (k) {
      var c = r[k] || {}, x = (r.cc || {})[k] || {};
      return '<tr><td>' + PL[k] + '</td><td>' + esc(x.t) + '</td><td>' + esc(c.st) + '</td><td>' + esc(x.m) + '</td><td>' + esc(c.full_on || '') + '</td></tr>'; }).join('') + '</tbody></table>';
    var rp = r.recovery_points;
    if (rp) h += '<div class="dl"><b>AWS Backup recovery points</b> <span class="muted">(' + rp.length + '; weekly = retention ' + esc(D.cfg.weekly_min_days) + '-' + esc(D.cfg.weekly_max_days) +
      'd, monthly = ' + esc(D.cfg.monthly_min_days || (D.cfg.weekly_max_days + 1)) + '-' + esc(D.cfg.monthly_max_days) + 'd)</span></div>' +
      (rp.length ? '<table class="rpd"><thead><tr><th>Created (UTC)</th><th>Retention</th><th>Class</th><th>Status</th><th>Counted</th><th>Reason</th><th>Vault</th><th>Recovery point</th></tr></thead><tbody>' +
        rp.map(function (p) { return '<tr><td>' + esc(p.date) + '</td><td>' + (p.ret == null ? 'never expires' : esc(p.ret) + 'd') + '</td><td>' + esc(p.class) + '</td><td>' + esc(p.status) +
          '</td><td class="' + (p.counted ? 'cnt-y">yes' : 'cnt-n">no') + '</td><td>' + esc(p.reason) + '</td><td>' + esc(p.vault) + '</td><td>' + esc(p.id) + '</td></tr>'; }).join('') + '</tbody></table>'
        : '<div class="muted">none found in this region\'s backup vaults</div>');
    return h; };
  var count = function (rs, s) { return rs.filter(function (r) { return r.status === s; }).length; };
  var render = function () {
    var rs = filtered();
    document.getElementById('cards').innerHTML = [['resources', 'Resources', rs.length]].concat(STATUSES.map(function (s) { return [s.toLowerCase().replace(/ /g, '-'), s, count(rs, s)]; }))
      .map(function (c) { return '<div class="card" data-k="' + c[0] + '"><div class="v">' + c[2] + '</div><div class="l">' + c[1] + '</div></div>'; }).join('');
    document.querySelector('#main tbody').innerHTML = rs.map(function (r) {
      var k = key(r), op = !!OPEN[k];
      return '<tr class="res' + (op ? ' open' : '') + '" data-k="' + esc(k) + '"><td class="cx"><span class="car" role="button" tabindex="0" aria-expanded="' + op + '" title="Show details">&#9654;</span></td><td>' + esc(r.account_id) + '</td><td>' + esc(r.region) + '</td><td><a href="#" class="go">' + esc(r.identifier) + '</a></td><td>' + esc(r.type) +
        '</td><td class="cr">' + (r.created_epoch != null ? esc(String(r.created).slice(0, 10)) + '<br><span class="muted">' + esc(r.age_days) + ' days</span>' : esc(r.created)) +
        '</td><td>' + esc(r.engine) + ' ' + esc(r.engine_version) + '</td><td>' + esc(r.global_cluster) + '</td><td>' + esc(r.global_role) + '</td><td>' + esc(r.retention_days) + 'd</td><td>' +
        esc(r.last_automated_utc) + '<br><span class="muted">' + esc(r.last_automated_local) + '</span></td>' +
        PERIODS.map(function (p) { return td(r, p); }).join('') +
        '<td class="s-' + esc(String(r.status).replace(/ /g, '-')) + '">' + esc(r.status) + '</td><td class="gaps" title="' + esc([r.gaps, r.not_yet_due, r.warnings].filter(Boolean).join(' | ')) + '">' +
        esc(r.gsum != null ? r.gsum : r.gaps) + '</td></tr>' +
        '<tr class="det" data-k="' + esc(k) + '"' + (op ? '' : ' hidden') + '><td colspan="' + NC + '">' + detail(r) + '</td></tr>'; }).join('');
    document.getElementById('f-count').textContent = rs.length + ' of ' + D.rows.length + ' shown';
    var g = {}; rs.forEach(function (r) { var k = r.account_id + '|' + r.region; (g[k] = g[k] || []).push(r); });
    var line = function (a, b, x) { return '<td>' + a + '</td><td>' + b + '</td><td>' + x.length + '</td>' + STATUSES.map(function (s) { return '<td>' + count(x, s) + '</td>'; }).join(''); };
    document.querySelector('#regions tbody').innerHTML = Object.keys(g).sort().map(function (k) { var p = k.split('|'); return '<tr data-k="' + esc(k) + '">' + line(esc(p[0]), esc(p[1]), g[k]) + '</tr>'; }).join('');
    document.querySelector('#regions tfoot').innerHTML = '<tr><th colspan="2">All regions</th><th>' + rs.length + '</th>' + STATUSES.map(function (s) { return '<th>' + count(rs, s) + '</th>'; }).join('') + '</tr>';
    document.querySelectorAll('#main a.go').forEach(function (a) { a.onclick = function (e) { e.preventDefault(); e.stopPropagation(); showBackups(a.closest('tr').dataset.k); }; });
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
  document.getElementById('f-reset').onclick = function () { F.forEach(function (id) { document.getElementById(id).value = ''; }); document.getElementById('f-q').value = ''; render(); };
  var csvq = function (v) { v = v == null ? '' : String(v); if (/^[=+\-@]/.test(v)) v = "'" + v; return /[",\r\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; };
  var download = function (name, rows) {
    var b = new Blob(['\ufeff' + rows.map(function (r) { return r.map(csvq).join(','); }).join('\r\n') + '\r\n'], {type: 'text/csv'});
    var a = document.createElement('a'); a.href = URL.createObjectURL(b); a.download = name; document.body.appendChild(a); a.click(); a.remove(); };
  var acctTag = uniq(D.accounts.map(function (a) { return a.account; })).join('_');
  // same header, cells and quoting as the script's --format csv (jq @csv: every cell quoted, formula guard)
  var csvAll = function (v) { v = v == null ? '' : String(v); if (/^[=+\-@]/.test(v)) v = "'" + v; return '"' + v.replace(/"/g, '""') + '"'; };
  document.getElementById('f-csv').onclick = function () {
    var rows = [D.csvh].concat(filtered().map(function (r) { return r.csv; }));
    var b = new Blob(['\ufeff' + rows.map(function (r) { return r.map(csvAll).join(','); }).join('\r\n') + '\r\n'], {type: 'text/csv'});
    var a = document.createElement('a'); a.href = URL.createObjectURL(b); a.download = 'rds_backup_compliance_' + acctTag + '_filtered.csv'; document.body.appendChild(a); a.click(); a.remove(); };

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
    SN[k].push({kind: 'manual', id: o.id, c: o.c, st: o.st, gb: o.gb, x: null, v: '', cl: '', rd: null, src: o.src, usd: o.usd, enc: o.enc, kms: o.kms, shared: o.kind === 'shared'}); });
  PR.sort(function (a, b) { return a.k < b.k ? -1 : 1; });
  var rkey = function (r) { return r.pseudo ? r.k : key(r); };
  var RR = D.rows.concat(PR);
  var ALL = '*all*';
  var KIND = {manual: 'Manual', automated: 'Automated', backup: 'AWS Backup'};
  var bopt = function (id, label, vals) { return '<label class="ballf">' + label + ' <select id="' + id + '"><option value="">All</option>' +
    vals.map(function (v) { return '<option value="' + esc(v) + '">' + esc(v) + '</option>'; }).join('') + '</select></label>'; };
  // Age: "3/6/12" = created in the last N months; "o30.." = older than N days; "all" = any age
  var ropt = function (r) { return '<option value="' + esc(rkey(r)) + '">' + esc(r.identifier + ' (' + r.account_id + ', ' + r.region + ', ' + r.type + ')') + '</option>'; };
  B.innerHTML = '<div id="b-orph" class="osum">' + oline() + '</div><div class="filters"><label>Resource <select id="b-res"><option value="' + ALL + '">All clusters and instances</option>' + D.rows.map(ropt).join('') +
    (PR.length ? '<optgroup label="Snapshots whose source is not in this account + region">' + PR.map(ropt).join('') + '</optgroup>' : '') +
    '</select></label><label>Backup type <select id="b-kind"><option value="">All types</option><option value="manual">Manual</option><option value="automated">Automated</option><option value="backup">AWS Backup</option></select></label>' +
    '<label>Age <select id="b-period"><optgroup label="Created in"><option value="3">Last 3 months</option><option value="6">Last 6 months</option><option value="12" selected>Last 12 months</option></optgroup>' +
    '<optgroup label="Older than (oldest first)"><option value="o30">Older than 30 days</option><option value="o90">Older than 90 days</option><option value="o180">Older than 180 days</option><option value="o365">Older than 365 days</option></optgroup>' +
    '<option value="all">Any age</option></select></label>' +
    bopt('b-acct', 'Account', uniq(RR.map(function (r) { return r.account_id; }))) +
    bopt('b-region', 'Region', uniq(RR.map(function (r) { return r.region; }))) +
    bopt('b-engine', 'Engine', uniq(RR.map(function (r) { return r.engine; }).filter(Boolean))) +
    '<label class="ballf">Source status <select id="b-src"><option value="">All</option><option value="EXISTING">Existing</option><option value="ORPHANED">Orphaned</option><option value="SHARED">Shared</option>' +
    ((D.orph || []).some(function (o) { return o.src === 'UNVERIFIED'; }) ? '<option value="UNVERIFIED">Unverified</option>' : '') + '</select></label>' +
    '<button id="b-audit" title="All clusters and instances, Manual, Older than 90 days">Old manual snapshots (&gt; 90 days)</button> ' +
    '<button id="b-orphb" title="All clusters and instances, Source status Orphaned, Any age">Orphaned snapshots</button> ' +
    '<button id="b-reset" title="Clear the Backups filters and order (keeps the selected resource)">Reset</button> <button id="b-csv">Export CSV</button> <span id="b-sum" class="muted"></span></div><div id="b-out"></div>';
  var since = function (m) { var d = new Date(D.now * 1000); d.setUTCMonth(d.getUTCMonth() - m); return d.getTime() / 1000; };
  var isAll = function () { return val('b-res') === ALL; };
  var older = function () { var v = val('b-period'); return v.charAt(0) === 'o' ? +v.slice(1) : null; };
  var ageD = function (c) { return Math.floor((D.now - c) / 86400); };
  var ageOk = function (c) { var v = val('b-period'), o = older(); if (v === 'all') return true; if (o != null) return D.now - c > o * 86400; return c >= since(+v); };
  var kindOk = function (s) { return !val('b-kind') || s.kind === val('b-kind'); };
  var srcOk = function (s) { return !isAll() || !val('b-src') || s.src === val('b-src'); };
  var usd = function (v) { return v == null ? '' : v >= 10 ? '$' + Math.round(v) : '$' + (Math.round(v * 100) / 100); };
  var order = function (a, b) { return older() != null ? a.c - b.c : b.c - a.c; };
  var rule = function (s) { return s.kind === 'backup' ? s.cl : s.kind === 'automated' ? 'daily' : ''; };
  var gb = function (xs) { return Math.round(xs.reduce(function (t, s) { return t + (+s.gb || 0); }, 0) * 10) / 10; };
  var current = function () { return (SN[val('b-res')] || []).filter(function (s) { return ageOk(s.c) && kindOk(s); }).sort(order); };
  var allRows = function () { var out = [];
    RR.forEach(function (r) {
      if ((val('b-acct') && r.account_id !== val('b-acct')) || (val('b-region') && r.region !== val('b-region')) || (val('b-engine') && r.engine !== val('b-engine'))) return;
      (SN[rkey(r)] || []).forEach(function (s) { if (kindOk(s) && srcOk(s) && ageOk(s.c)) out.push({r: r, s: s}); }); });
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
      xs.map(function (x) { var s = x.s; return '<tr data-kind="' + esc(s.kind) + '" data-src="' + esc(s.src || '') + '"' + (s.src === 'ORPHANED' ? ' class="orph"' : '') + '><td>' + esc(x.r.account_id) + '</td><td>' + esc(x.r.region) + '</td><td><a href="#" class="go" data-k="' + esc(rkey(x.r)) + '">' + esc(x.r.identifier) + '</a></td><td>' + esc(x.r.type) +
        '</td><td>' + esc(Object.prototype.hasOwnProperty.call(KIND, s.kind) ? KIND[s.kind] : s.kind) + (s.shared ? ' (shared)' : '') + '</td><td>' + esc(s.id) + '</td><td>' + utc(s.c) + '</td><td>' + loc(s.c) + '</td><td>' + ageD(s.c) + '</td><td>' + esc(s.st) + '</td><td>' + esc(s.gb) + '</td>' +
        (hasSrc ? '<td class="src-' + esc(s.src || '') + '">' + (s.kind === 'manual' ? esc(SRCL[s.src] || '') : '') + '</td>' : '') + (hasUsd ? '<td>' + (s.src === 'ORPHANED' ? usd(s.usd) : '') + '</td>' : '') + (hasRule ? '<td>' + esc(rule(s)) + '</td>' : '') +
        (hasBk ? '<td>' + (s.kind !== 'backup' ? '' : s.rd == null ? 'never expires' : esc(s.rd) + 'd') + '</td><td>' + esc(s.v) + '</td>' : '') + '</tr>'; }).join('') +
      '</tbody><tfoot><tr><th colspan="10">Total</th><th>' + gb(ss) + '</th>' + (hasSrc ? '<th></th>' : '') + (hasUsd ? '<th>' + usd(orph.reduce(function (t, x) { return t + (x.usd || 0); }, 0)) + '</th>' : '') + ((hasRule ? 1 : 0) + (hasBk ? 2 : 0) ? '<th colspan="' + ((hasRule ? 1 : 0) + (hasBk ? 2 : 0)) + '"></th>' : '') + '</tr></tfoot></table>' : '<div class="muted">None match these filters.</div>');
    document.querySelectorAll('#b-out a.go').forEach(function (a) { a.onclick = function (e) { e.preventDefault(); document.getElementById('b-res').value = a.dataset.k; renderB(); }; });
  };
  var renderB = function () {
    document.querySelectorAll('.ballf').forEach(function (l) { l.style.display = isAll() ? '' : 'none'; });
    if (isAll()) return renderAll();
    var ss = current(), r = RR.filter(function (x) { return rkey(x) === val('b-res'); })[0];
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
      (r.warnings ? '<tr><th>Warning</th><td class="warn">' + esc(r.warnings) + '</td></tr>' : '') + '</tbody></table>' : '';
    document.getElementById('b-out').innerHTML = set + SECT.filter(function (sec) { return !val('b-kind') || sec[0] === val('b-kind'); }).map(function (sec) {
      var xs = ss.filter(function (s) { return s.kind === sec[0]; }), bk = sec[0] === 'backup';
      return '<h2 data-sec="' + sec[0] + '">' + sec[1] + ' (' + xs.length + ')</h2>' + (xs.length ? '<table class="bt" data-sec="' + sec[0] + '"><thead><tr><th>Identifier</th><th>Created (UTC)</th><th>Created (' + esc(D.tz_label) + ')</th><th>Age (days)</th><th>Status</th><th>Size GB</th>' +
        (bk ? '<th>Class</th><th>Retention</th><th>Expires (UTC)</th><th>Vault</th>' : '') + '</tr></thead><tbody>' + xs.map(function (s) {
          return '<tr><td>' + esc(s.id) + '</td><td>' + utc(s.c) + '</td><td>' + loc(s.c) + '</td><td>' + ageD(s.c) + '</td><td>' + esc(s.st) + '</td><td>' + esc(s.gb) + '</td>' +
            (bk ? '<td>' + esc(s.cl) + '</td><td>' + (s.rd == null ? 'never expires' : esc(s.rd) + 'd') + '</td><td>' + utc(s.x) + '</td><td>' + esc(s.v) + '</td>' : '') + '</tr>'; }).join('') +
        '</tbody></table>' : '<div class="muted">None match these filters.</div>'); }).join(''); };
  window.showBackups = function (k) { document.getElementById('b-res').value = k; renderB(); document.querySelector('.tabs button[data-t="bk"]').click(); };
  var showBackups = window.showBackups;
  ['b-res', 'b-kind', 'b-period', 'b-acct', 'b-region', 'b-engine', 'b-src'].forEach(function (id) { document.getElementById(id).onchange = renderB; });
  document.getElementById('b-audit').onclick = function () { document.getElementById('b-res').value = ALL; document.getElementById('b-kind').value = 'manual'; document.getElementById('b-period').value = 'o90'; document.getElementById('b-src').value = ''; renderB(); };
  var showOrph = function () { document.getElementById('b-res').value = ALL; document.getElementById('b-kind').value = ''; document.getElementById('b-src').value = 'ORPHANED';
    document.getElementById('b-period').value = 'all'; ['b-acct', 'b-region', 'b-engine'].forEach(function (id) { document.getElementById(id).value = ''; }); renderB(); };
  document.getElementById('b-orphb').onclick = showOrph;
  document.getElementById('b-reset').onclick = function () {
    ['b-kind', 'b-acct', 'b-region', 'b-engine', 'b-src'].forEach(function (id) { document.getElementById(id).value = ''; });
    document.getElementById('b-period').value = '12'; renderB(); };
  if (document.getElementById('osum-go')) document.getElementById('osum-go').onclick = function (e) { e.preventDefault(); showOrph(); document.querySelector('.tabs button[data-t="bk"]').click(); };
  var H = ['account_id', 'region', 'identifier', 'type', 'kind', 'snapshot_or_recovery_point', 'created_utc', 'created_' + D.tz_label.toLowerCase(), 'age_days', 'status', 'size_gb', 'rule', 'retention_days', 'expires_utc', 'vault', 'source_status'];
  var line = function (r, s) { return [r.account_id, r.region, r.pseudo ? r.sid : r.identifier, r.type, s.kind, s.id, utc(s.c), loc(s.c), ageD(s.c), s.st, s.gb, rule(s), s.kind === 'backup' ? s.rd : '', utc(s.x), s.v, s.src || '']; };
  document.getElementById('b-csv').onclick = function () {
    var tag = (val('b-kind') || 'all-types') + '_' + val('b-period').replace(/^(\d+)$/, '$1m').replace(/^o(\d+)$/, 'older-$1d');
    if (isAll()) return download('rds_backups_all_' + acctTag + '_' + tag + '.csv', [H].concat(allRows().map(function (x) { return line(x.r, x.s); })));
    var r = RR.filter(function (x) { return rkey(x) === val('b-res'); })[0];
    download('rds_backup_' + r.account_id + '_' + (r.pseudo ? 'deleted-' + r.sid : r.identifier) + '_' + tag + '.csv', [H].concat(current().map(function (s) { return line(r, s); }))); };
  // default view stays the first resource; "All" is the first option
  if (D.rows.length) document.getElementById('b-res').value = key(D.rows[0]);
  render(); if (D.rows.length || PR.length) renderB();
})();
