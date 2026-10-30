// rds_backup_compliance_report.sh HTML page: Compliance tab (filters, cards, per-region breakdown, filtered CSV export)
// and Backups tab (one resource: manual / automated / AWS Backup, period 3 / 6 / 12 months). No network access.
(function () {
  'use strict';
  var D = JSON.parse(document.getElementById('data').textContent);
  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]; }); };
  var pad = function (n) { return (n < 10 ? '0' : '') + n; };
  var fmt = function (e, off, lab) { if (e == null) return ''; var d = new Date((e + off) * 1000);
    return d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate()) + ' ' + pad(d.getUTCHours()) + ':' + pad(d.getUTCMinutes()) + ' ' + lab; };
  var utc = function (e) { return fmt(e, 0, 'UTC'); }, loc = function (e) { return fmt(e, D.tz_offset, D.tz_label); };
  var uniq = function (a) { return a.filter(function (v, i) { return a.indexOf(v) === i; }).sort(); };
  var key = function (r) { return r.account_id + '|' + r.region + '|' + r.identifier; };
  var STATUSES = ['COMPLIANT', 'NON-COMPLIANT', 'NOT YET DUE', 'UNKNOWN'];
  document.querySelectorAll('.tabs button').forEach(function (b) { b.onclick = function () {
    document.querySelectorAll('.tabs button, .tab').forEach(function (x) { x.classList.remove('on'); });
    b.classList.add('on'); document.getElementById(b.dataset.t).classList.add('on'); }; });

  // ---------------- Compliance tab
  var C = document.getElementById('comp');
  var opt = function (id, label, vals, txt) { return '<label>' + label + ' <select id="' + id + '"><option value="">All</option>' +
    vals.map(function (v) { return '<option value="' + esc(v) + '">' + esc(txt ? txt(v) : v) + '</option>'; }).join('') + '</select></label>'; };
  var globals = uniq(D.rows.map(function (r) { return r.global_cluster; }).filter(Boolean));
  C.innerHTML = '<div class="cards" id="cards"></div><div class="filters">' +
    opt('f-acct', 'Account', uniq(D.rows.map(function (r) { return r.account_id; }))) +
    opt('f-region', 'Region', uniq(D.rows.map(function (r) { return r.region; }))) +
    opt('f-type', 'Type', uniq(D.rows.map(function (r) { return r.type; }))) +
    opt('f-engine', 'Engine', uniq(D.rows.map(function (r) { return r.engine; }))) +
    opt('f-role', 'Role', uniq(D.rows.map(function (r) { return r.global_role; }))) +
    opt('f-global', 'Global cluster', ['(not global)'].concat(globals)) +
    opt('f-status', 'Status', STATUSES.filter(function (s) { return D.rows.some(function (r) { return r.status === s; }); })) +
    '<input id="f-q" placeholder="Identifier contains"> <button id="f-reset">Reset</button> <button id="f-csv">Export CSV</button> <span id="f-count" class="muted"></span></div>' +
    '<table id="main"><thead><tr><th>Account</th><th>Region</th><th>Identifier</th><th>Type</th><th>Engine</th><th>Global cluster</th><th>Role</th>' +
    '<th>Retention</th><th>Last automated</th><th>Daily</th><th>Weekly</th><th>Monthly</th><th>Yearly</th><th>Status</th><th>Gaps</th></tr></thead><tbody></tbody></table>' +
    '<h2>Per region</h2><table id="regions"><thead><tr><th>Account</th><th>Region</th><th>Resources</th><th>Compliant</th><th>Non-compliant</th><th>Not yet due</th><th>Unknown</th></tr></thead><tbody></tbody><tfoot></tfoot></table>' +
    '<div id="rerr"></div>';
  var F = ['f-acct', 'f-region', 'f-type', 'f-engine', 'f-role', 'f-global', 'f-status'];
  var val = function (id) { return document.getElementById(id).value; };
  var filtered = function () {
    var q = val('f-q').toLowerCase();
    return D.rows.filter(function (r) {
      return (!val('f-acct') || r.account_id === val('f-acct')) && (!val('f-region') || r.region === val('f-region')) &&
        (!val('f-type') || r.type === val('f-type')) && (!val('f-engine') || r.engine === val('f-engine')) &&
        (!val('f-role') || r.global_role === val('f-role')) && (!val('f-status') || r.status === val('f-status')) &&
        (!val('f-global') || (val('f-global') === '(not global)' ? !r.global_cluster : r.global_cluster === val('f-global'))) &&
        (!q || r.identifier.toLowerCase().indexOf(q) >= 0); }); };
  var td = function (c, t) { var cls = c.st === 'N/A' ? 'NA' : c.st; return '<td class="' + cls + '" title="' + esc(c.st) + '">' + esc(t) + '</td>'; };
  var count = function (rs, s) { return rs.filter(function (r) { return r.status === s; }).length; };
  var render = function () {
    var rs = filtered();
    document.getElementById('cards').innerHTML = [['resources', 'Resources', rs.length]].concat(STATUSES.map(function (s) { return [s.toLowerCase().replace(/ /g, '-'), s, count(rs, s)]; }))
      .map(function (c) { return '<div class="card" data-k="' + c[0] + '"><div class="v">' + c[2] + '</div><div class="l">' + c[1] + '</div></div>'; }).join('');
    document.querySelector('#main tbody').innerHTML = rs.map(function (r) {
      return '<tr data-k="' + esc(key(r)) + '"><td>' + esc(r.account_id) + '</td><td>' + esc(r.region) + '</td><td><a href="#" class="go">' + esc(r.identifier) + '</a></td><td>' + esc(r.type) +
        '</td><td>' + esc(r.engine) + ' ' + esc(r.engine_version) + '</td><td>' + esc(r.global_cluster) + '</td><td>' + esc(r.global_role) + '</td><td>' + esc(r.retention_days) + 'd</td><td>' +
        esc(r.last_automated_utc) + '<br><span class="muted">' + esc(r.last_automated_local) + '</span></td>' +
        td(r.daily, r.cells.daily) + td(r.weekly, r.cells.weekly) + td(r.monthly, r.cells.monthly) + td(r.yearly, r.cells.yearly) +
        '<td class="s-' + r.status.replace(/ /g, '-') + '">' + esc(r.status) + '</td><td class="gaps">' + esc(r.gaps) + '</td></tr>'; }).join('');
    document.getElementById('f-count').textContent = rs.length + ' of ' + D.rows.length + ' shown';
    var g = {}; rs.forEach(function (r) { var k = r.account_id + '|' + r.region; (g[k] = g[k] || []).push(r); });
    var line = function (a, b, x) { return '<td>' + a + '</td><td>' + b + '</td><td>' + x.length + '</td>' + STATUSES.map(function (s) { return '<td>' + count(x, s) + '</td>'; }).join(''); };
    document.querySelector('#regions tbody').innerHTML = Object.keys(g).sort().map(function (k) { var p = k.split('|'); return '<tr data-k="' + esc(k) + '">' + line(esc(p[0]), esc(p[1]), g[k]) + '</tr>'; }).join('');
    document.querySelector('#regions tfoot').innerHTML = '<tr><th colspan="2">All regions</th><th>' + rs.length + '</th>' + STATUSES.map(function (s) { return '<th>' + count(rs, s) + '</th>'; }).join('') + '</tr>';
    document.querySelectorAll('#main a.go').forEach(function (a) { a.onclick = function (e) { e.preventDefault(); showBackups(a.closest('tr').dataset.k); }; });
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
  document.getElementById('f-csv').onclick = function () {
    download('rds_backup_compliance_' + acctTag + '_filtered.csv', [['account_id', 'region', 'identifier', 'type', 'engine', 'engine_version', 'global_cluster', 'global_role', 'retention_days',
      'last_automated_utc', 'last_automated_' + D.tz_label.toLowerCase(), 'daily', 'weekly', 'monthly', 'yearly', 'status', 'gaps']].concat(filtered().map(function (r) {
      return [r.account_id, r.region, r.identifier, r.type, r.engine, r.engine_version, r.global_cluster, r.global_role, r.retention_days, r.last_automated_utc,
        r.last_automated_local, r.cells.daily, r.cells.weekly, r.cells.monthly, r.cells.yearly, r.status, r.gaps]; }))); };

  // ---------------- Backups tab
  var B = document.getElementById('bk'), SN = {};
  D.snaps.forEach(function (s) { SN[s.k] = s.s; });
  var ALL = '*all*';
  var bopt = function (id, label, vals) { return '<label class="ballf">' + label + ' <select id="' + id + '"><option value="">All</option>' +
    vals.map(function (v) { return '<option value="' + esc(v) + '">' + esc(v) + '</option>'; }).join('') + '</select></label>'; };
  B.innerHTML = '<div class="filters"><label>Resource <select id="b-res"><option value="' + ALL + '">All clusters and instances (manual snapshots)</option>' + D.rows.map(function (r) {
      return '<option value="' + esc(key(r)) + '">' + esc(r.identifier + ' (' + r.account_id + ', ' + r.region + ', ' + r.type + ')') + '</option>'; }).join('') +
    '</select></label><label>Period <select id="b-period"><option value="3">Last 3 months</option><option value="6">Last 6 months</option><option value="12" selected>Last 12 months</option></select></label>' +
    bopt('b-acct', 'Account', uniq(D.rows.map(function (r) { return r.account_id; }))) +
    bopt('b-region', 'Region', uniq(D.rows.map(function (r) { return r.region; }))) +
    bopt('b-engine', 'Engine', uniq(D.rows.map(function (r) { return r.engine; }))) +
    '<button id="b-csv">Export CSV</button> <span id="b-sum" class="muted"></span></div><div id="b-out"></div>';
  var since = function (m) { var d = new Date(D.now * 1000); d.setUTCMonth(d.getUTCMonth() - m); return d.getTime() / 1000; };
  var isAll = function () { return val('b-res') === ALL; };
  var current = function () { var k = val('b-res'), lim = since(+val('b-period'));
    return (SN[k] || []).filter(function (s) { return s.c >= lim; }).sort(function (a, b) { return b.c - a.c; }); };
  // All mode: manual snapshots of every resource matching the Backups-tab account/region/engine filters
  var allManual = function () { var lim = since(+val('b-period')), out = [];
    D.rows.forEach(function (r) {
      if ((val('b-acct') && r.account_id !== val('b-acct')) || (val('b-region') && r.region !== val('b-region')) || (val('b-engine') && r.engine !== val('b-engine'))) return;
      (SN[key(r)] || []).forEach(function (s) { if (s.kind === 'manual' && s.c >= lim) out.push({r: r, s: s}); }); });
    return out.sort(function (a, b) { return b.s.c - a.s.c || (key(a.r) < key(b.r) ? -1 : 1); }); };
  var SECT = [['manual', 'Manual snapshots'], ['automated', 'Automated backups (RDS)'], ['backup', 'AWS Backup recovery points']];
  var renderAll = function () {
    var xs = allManual(), n = uniq(xs.map(function (x) { return key(x.r); })).length;
    document.getElementById('b-sum').textContent = xs.length + ' manual snapshot(s) across ' + n + ' resource(s)';
    document.getElementById('b-out').innerHTML = '<h2 data-sec="manual-all">Manual snapshots - all clusters and instances (' + xs.length + ')</h2>' + (xs.length ?
      '<table class="bt" data-sec="manual-all"><thead><tr><th>Account</th><th>Region</th><th>Resource</th><th>Type</th><th>Snapshot</th><th>Created (UTC)</th><th>Created (' + esc(D.tz_label) + ')</th><th>Status</th><th>Size GB</th></tr></thead><tbody>' +
      xs.map(function (x) { return '<tr><td>' + esc(x.r.account_id) + '</td><td>' + esc(x.r.region) + '</td><td><a href="#" class="go" data-k="' + esc(key(x.r)) + '">' + esc(x.r.identifier) + '</a></td><td>' + esc(x.r.type) +
        '</td><td>' + esc(x.s.id) + '</td><td>' + utc(x.s.c) + '</td><td>' + loc(x.s.c) + '</td><td>' + esc(x.s.st) + '</td><td>' + esc(x.s.gb) + '</td></tr>'; }).join('') +
      '</tbody></table>' : '<div class="muted">None in this period.</div>') +
      '<div class="muted" id="b-allnote">Automated backups and AWS Backup recovery points are shown per resource: pick a cluster or instance above, or click a resource name.</div>';
    document.querySelectorAll('#b-out a.go').forEach(function (a) { a.onclick = function (e) { e.preventDefault(); document.getElementById('b-res').value = a.dataset.k; renderB(); }; });
  };
  var renderB = function () {
    document.querySelectorAll('.ballf').forEach(function (l) { l.style.display = isAll() ? '' : 'none'; });
    if (isAll()) return renderAll();
    var ss = current(), r = D.rows.filter(function (x) { return key(x) === val('b-res'); })[0];
    document.getElementById('b-sum').textContent = r ? r.status + (r.gaps ? ' - ' + r.gaps : '') : '';
    document.getElementById('b-out').innerHTML = SECT.map(function (sec) {
      var xs = ss.filter(function (s) { return s.kind === sec[0]; }), bk = sec[0] === 'backup';
      return '<h2 data-sec="' + sec[0] + '">' + sec[1] + ' (' + xs.length + ')</h2>' + (xs.length ? '<table class="bt" data-sec="' + sec[0] + '"><thead><tr><th>Identifier</th><th>Created (UTC)</th><th>Created (' + esc(D.tz_label) + ')</th><th>Status</th><th>Size GB</th>' +
        (bk ? '<th>Class</th><th>Retention</th><th>Expires (UTC)</th><th>Vault</th>' : '') + '</tr></thead><tbody>' + xs.map(function (s) {
          return '<tr><td>' + esc(s.id) + '</td><td>' + utc(s.c) + '</td><td>' + loc(s.c) + '</td><td>' + esc(s.st) + '</td><td>' + esc(s.gb) + '</td>' +
            (bk ? '<td>' + esc(s.cl) + '</td><td>' + (s.rd == null ? 'never expires' : s.rd + 'd') + '</td><td>' + utc(s.x) + '</td><td>' + esc(s.v) + '</td>' : '') + '</tr>'; }).join('') +
        '</tbody></table>' : '<div class="muted">None in this period.</div>'); }).join(''); };
  window.showBackups = function (k) { document.getElementById('b-res').value = k; renderB(); document.querySelector('.tabs button[data-t="bk"]').click(); };
  var showBackups = window.showBackups;
  ['b-res', 'b-period', 'b-acct', 'b-region', 'b-engine'].forEach(function (id) { document.getElementById(id).onchange = renderB; });
  document.getElementById('b-csv').onclick = function () {
    var H = ['account_id', 'region', 'identifier', 'type', 'kind', 'snapshot_or_recovery_point', 'created_utc', 'created_' + D.tz_label.toLowerCase(), 'status', 'size_gb'];
    if (isAll()) return download('rds_backup_manual_all_' + acctTag + '_' + val('b-period') + 'm.csv', [H].concat(allManual().map(function (x) {
      return [x.r.account_id, x.r.region, x.r.identifier, x.r.type, 'manual', x.s.id, utc(x.s.c), loc(x.s.c), x.s.st, x.s.gb]; })));
    var p = val('b-res').split('|');
    download('rds_backup_' + p[0] + '_' + p[2] + '_' + val('b-period') + 'm.csv', [['account_id', 'region', 'identifier', 'kind', 'snapshot_or_recovery_point', 'created_utc', 'created_' + D.tz_label.toLowerCase(),
      'status', 'size_gb', 'class', 'retention_days', 'expires_utc', 'vault']].concat(current().map(function (s) {
      return [p[0], p[1], p[2], s.kind, s.id, utc(s.c), loc(s.c), s.st, s.gb, s.cl, s.rd, utc(s.x), s.v]; }))); };
  // default view stays the first resource; "All" is the first option
  if (D.rows.length) document.getElementById('b-res').value = key(D.rows[0]);
  render(); if (D.rows.length) renderB();
})();
