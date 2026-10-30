# rds_backup_compliance_report.sh - evaluation and rendering (jq 1.6+; no strftime %G/%V so jq.exe on Windows works).
# Input: one data document {schema, accounts, regions, resources}. Args: $mode (rows|json|csv|bcsv|mcsv|ocsv|osum|txt|html),
# $now (epoch), $cfg (thresholds + tz), $page (JS, html only), $tool (version).
def r1: (. * 10 | round) / 10;
def utc: if . == null then "" else (floor | todate | sub("T"; " ") | sub(":[0-9]{2}Z$"; " UTC")) end;
def loc: if . == null then "" else ((. + $cfg.tz_offset) | floor | todate | sub("T"; " ") | sub(":[0-9]{2}Z$"; " " + $cfg.tz_label)) end;
def day: floor / 86400 | floor;
def week: (((. / 86400) | floor) + 3) / 7 | floor;            # Monday-based week number (epoch day 0 = Thursday)
def month: gmtime | "\(.[0])-\(.[1] + 1)";
def year: gmtime | .[0];

# class of an AWS Backup recovery point from its retention (days between creation and DeleteAt; no DeleteAt = yearly)
def rp_class:
  if .expires_epoch == null then "yearly"
  else ((.expires_epoch - .created_epoch) / 86400 | round) as $d
    | if $d < $cfg.weekly_min_days then "short"
      elif $d <= $cfg.weekly_max_days then "weekly"
      elif $d <= $cfg.monthly_max_days then "monthly"
      else "yearly" end end;
def rp_ret: if .expires_epoch == null then null else ((.expires_epoch - .created_epoch) / 86400 | round) end;

# one count check -> {have, need, st: OK|FAIL|DUE}
def cnt($have; $need; $age; $period):
  if $have >= $need then {have: $have, need: $need, st: "OK"}
  elif $age < ($need * $period) and $have >= (($age / $period | floor) - 1) then {have: $have, need: $need, st: "DUE"}
  else {have: $have, need: $need, st: "FAIL"} end;

def evaluate:
  . as $r
  | (($now - ($r.created_epoch // $now)) / 86400) as $age
  | [ $r.snapshots[]? | select(.kind == "automated" and (.status // "available") == "available") ] as $auto
  | ($auto | map(.created_epoch) | max) as $last_auto
  | ([ $r.snapshots[]? | select(.kind == "backup" and .status == "COMPLETED" and (.expires_epoch == null or .expires_epoch > $now))
       | . + {class: rp_class} ]) as $rps
  | (if $r.snap_ok == false then {st: "UNKNOWN", have: null, need: $cfg.daily, gap: "snapshots unreadable"}
     else ([ $auto[] | select(.created_epoch > $now - (($r.retention // 0) + 1) * 86400) | .created_epoch | day ] | unique | length) as $n
       | (if $last_auto == null then null else (($now - $last_auto) / 3600 | r1) end) as $h
       | cnt($n; $cfg.daily; $age; 1) as $c
       | [ (if ($r.retention // 0) < $cfg.daily then "daily: retention \($r.retention // 0)d < \($cfg.daily)d" else empty end),
           (if $h == null then (if $age * 24 > $cfg.daily_max_age_h then "daily: no automated backup" else empty end)
            elif $h > $cfg.daily_max_age_h then "daily: last automated \($h)h ago" else empty end),
           (if $c.st == "FAIL" then "daily \($n)/\($cfg.daily)" else empty end) ] as $g
       | {have: $n, need: $cfg.daily, last_h: $h, gap: ($g | join("; ")),
          st: (if ($g | length) > 0 then "FAIL" elif $c.st == "DUE" or $h == null then "DUE" else "OK" end)} end) as $daily
  | (if $r.global_role == "secondary" or $r.global_role == "replica" then
       {weekly: {st: "N/A"}, monthly: {st: "N/A"}, yearly: {st: "N/A"}}
     elif $r.backup_ok == false then
       {weekly: {st: "UNKNOWN"}, monthly: {st: "UNKNOWN"}, yearly: {st: "UNKNOWN"}}
     else
       {weekly: cnt([ $rps[] | select(.class == "weekly") | .created_epoch | week ] | unique | length; $cfg.weekly; $age; 7),
        monthly: cnt([ $rps[] | select(.class == "monthly") | .created_epoch | month ] | unique | length; $cfg.monthly; $age; 30.44),
        yearly: cnt([ $rps[] | select(.class == "yearly") | .created_epoch | year ] | unique | length; $cfg.yearly; $age; 365.25)} end) as $wmy
  | ([ ($daily | select(.st == "FAIL") | .gap),
       (if $daily.st == "UNKNOWN" then "daily: snapshots unreadable" else empty end),
       ($wmy | to_entries[] | select(.value.st == "FAIL") | "\(.key) \(.value.have)/\(.value.need)"),
       (if $wmy.weekly.st == "UNKNOWN" then "AWS Backup recovery points unreadable" else empty end) ] | join("; ")) as $gaps
  | ([ $daily.st, $wmy[].st ]) as $sts
  | { account_id: $r.account_id, region: $r.region, identifier: $r.id, type: $r.type, engine: $r.engine,
      engine_version: $r.engine_version, global_cluster: ($r.global_cluster // ""), global_role: ($r.global_role // "none"),
      created: ($r.created_epoch | utc), retention_days: $r.retention, last_automated_utc: ($last_auto | utc),
      last_automated_local: ($last_auto | loc), daily: $daily, weekly: $wmy.weekly, monthly: $wmy.monthly, yearly: $wmy.yearly,
      status: (if any($sts[]; . == "FAIL") then "NON-COMPLIANT" elif any($sts[]; . == "UNKNOWN") then "UNKNOWN"
               elif any($sts[]; . == "DUE") then "NOT YET DUE" else "COMPLIANT" end),
      gaps: $gaps,
      manual: ([ $r.snapshots[]? | select(.kind == "manual") ] | length), automated: ($auto | length), backup_points: ($rps | length) };

def cell($c): if $c.st == "N/A" then "N/A" elif $c.st == "UNKNOWN" then "?" else "\($c.have)/\($c.need)" end;
def csvrow: map(if . == null then "" else tostring end
                | if test("^[=+@-]") then "'" + . else . end) | @csv;   # formula-injection guard
def rows: [ .resources[] | evaluate ] | sort_by(.account_id, .region, .identifier);
def totals($rs): {resources: ($rs | length),
  compliant: ([ $rs[] | select(.status == "COMPLIANT") ] | length),
  non_compliant: ([ $rs[] | select(.status == "NON-COMPLIANT") ] | length),
  not_yet_due: ([ $rs[] | select(.status == "NOT YET DUE") ] | length),
  unknown: ([ $rs[] | select(.status == "UNKNOWN") ] | length)};
def accounts_label: [ .accounts[].account ] | join(", ");

# orphaned manual snapshots (data .orphans, absent in v1.0/v1.1 files). Source status of one entry:
# SHARED     shared to this account, or copied from a snapshot in another account
# EXISTING   cross-region copy whose source still exists in its source region (same account, region scanned)
# UNVERIFIED cross-region copy whose source region was not scanned
# ORPHANED   source cluster / instance is not in this account + region (deleted, or only a same-name one elsewhere)
def osrc($regs):
  if .kind == "shared" or (.source_account != null and .source_account != .account_id) then "SHARED"
  elif .source_region != null and .source_region != .region then
    . as $o | ([ $regs[] | select(.account == $o.account_id and .region == $o.source_region and .existing != null) ] | first) as $sr
    | if $sr == null then "UNVERIFIED"
      elif ($sr.existing[if .type == "cluster" then "clusters" else "instances" end] | index([$o.source_id])) then "EXISTING"
      else "ORPHANED" end
  else "ORPHANED" end;
def price: ($cfg.snapshot_price_per_gb // 0.021);
def usd: (. * 100 | round) / 100;
def orows($D): [ ($D.orphans // [])[] | . + {source_status: osrc($D.regions)}
                 | . + {age_days: (if .created_epoch == null then null else (($now - .created_epoch) / 86400 | floor) end),
                        est_monthly_usd: (if .size_gb == null then null else (.size_gb * price | usd) end)} ]
               | sort_by(.created_epoch, .account_id, .region, .id);
def ototals($O): [ $O[] | select(.source_status == "ORPHANED") ] as $o
  | {orphaned: ($o | length), size_gb: ([ $o[].size_gb // 0 ] | add // 0), est_monthly_usd: ([ $o[].est_monthly_usd // 0 ] | add // 0 | usd),
     shared: ([ $O[] | select(.source_status == "SHARED") ] | length), unverified: ([ $O[] | select(.source_status == "UNVERIFIED") ] | length),
     price_per_gb_month: price};
def gbtxt: if . >= 1024 then "\(. / 1024 | r1) TB" else "\(. | r1 | tostring | sub("\\.0$"; "")) GB" end;
def osumtxt($t): "\($t.orphaned) orphaned snapshot\(if $t.orphaned == 1 then "" else "s" end), \($t.size_gb | gbtxt), ~$\(if $t.est_monthly_usd >= 10 then ($t.est_monthly_usd | round) else $t.est_monthly_usd end)/month (estimate)";

. as $D | rows as $R | orows($D) as $O | ototals($O) as $OT
| if $mode == "rows" then $R
  elif $mode == "osum" then osumtxt($OT)
  elif $mode == "ocsv" then   # orphaned manual snapshots only, oldest first
    (["account_id","region","snapshot_id","type","source_id","engine","engine_version","created_utc","created_" + ($cfg.tz_label | ascii_downcase),
      "age_days","size_gb","est_monthly_usd","encrypted","kms_key"] | csvrow),
    ($O[] | select(.source_status == "ORPHANED")
     | [.account_id, .region, .id, .type, .source_id, .engine, .engine_version, (.created_epoch | utc), (.created_epoch | loc),
        .age_days, .size_gb, .est_monthly_usd, .encrypted, .kms_key] | csvrow)
  elif $mode == "json" then
    {tool: "rds_backup_compliance_report", version: $tool, generated_utc: ($now | utc), generated_local: ($now | loc),
     accounts: $D.accounts, thresholds: ($cfg | del(.tz_offset)), totals: totals($R),
     regions: [ $D.regions[] | select(.status != "empty") | del(.existing) ], rows: $R,
     orphan_totals: ($OT + {summary: osumtxt($OT)}),
     orphaned_snapshots: [ $O[] | . + {created_utc: (.created_epoch | utc), created_local: (.created_epoch | loc)} ]}
  elif $mode == "csv" then
    (["account_id","region","identifier","type","engine","engine_version","global_cluster","global_role","retention_days",
      "last_automated_utc","last_automated_" + ($cfg.tz_label | ascii_downcase),"daily","weekly","monthly","yearly","status","gaps"] | csvrow),
    ($R[] | [.account_id, .region, .identifier, .type, .engine, .engine_version, .global_cluster, .global_role, .retention_days,
             .last_automated_utc, .last_automated_local, cell(.daily), cell(.weekly), cell(.monthly), cell(.yearly), .status, .gaps] | csvrow)
  elif $mode == "bcsv" then   # same columns and order as the HTML Backups tab "Export CSV"
    (["account_id","region","identifier","type","kind","snapshot_or_recovery_point","created_utc","created_" + ($cfg.tz_label | ascii_downcase),
      "age_days","status","size_gb","rule","retention_days","expires_utc","vault","source_status"] | csvrow),
    ($D.resources | sort_by(.account_id, .region, .id)[] as $r
     | $r.snapshots | sort_by(-.created_epoch)[]
     | [$r.account_id, $r.region, $r.id, $r.type, .kind, .id, (.created_epoch | utc), (.created_epoch | loc),
        (if .created_epoch == null then null else (($now - .created_epoch) / 86400 | floor) end), .status, .size_gb,
        (if .kind == "backup" then rp_class elif .kind == "automated" then "daily" else "" end),
        (if .kind == "backup" then rp_ret else null end), (.expires_epoch | utc), (.vault // ""), "EXISTING"] | csvrow),
    ($O | sort_by(.account_id, .region, .source_id, -.created_epoch)[]
     | [.account_id, .region, .source_id, .type, "manual", .id, (.created_epoch | utc), (.created_epoch | loc), .age_days, .status, .size_gb,
        "", null, "", "", .source_status] | csvrow)
  elif $mode == "mcsv" then
    (["account_id","region","identifier","type","engine","snapshot","created_utc","created_" + ($cfg.tz_label | ascii_downcase),"age_days","status","size_gb","source_status"] | csvrow),
    ([ $D.resources[] as $r | $r.snapshots[]? | select(.kind == "manual" and .created_epoch != null
         and ($now - .created_epoch) > ($cfg.manual_older_than // 0) * 86400) | {r: $r, s: ., o: "EXISTING"} ]
     + [ $O[] | select(.created_epoch != null and ($now - .created_epoch) > ($cfg.manual_older_than // 0) * 86400)
         | {r: {account_id, region, id: .source_id, type, engine}, s: ., o: .source_status} ]
     | sort_by(.s.created_epoch, .r.account_id, .r.id)[]
     | [.r.account_id, .r.region, .r.id, .r.type, .r.engine, .s.id, (.s.created_epoch | utc), (.s.created_epoch | loc),
        (($now - .s.created_epoch) / 86400 | floor), .s.status, .s.size_gb, .o] | csvrow)
  elif $mode == "txt" then
    totals($R) as $t
    | "RDS backup compliance - account \($D | accounts_label)",
      "Generated \($now | utc) / \($now | loc)",
      "Rule: daily >= \($cfg.daily) (RDS automated, last <= \($cfg.daily_max_age_h)h), weekly >= \($cfg.weekly), monthly >= \($cfg.monthly), yearly >= \($cfg.yearly) (AWS Backup); global secondaries daily only",
      "Orphaned manual snapshots: \(osumtxt($OT)) at $\(price)/GB-month - rough upper estimate, snapshot billing is incremental",
      "Resources \($t.resources): compliant \($t.compliant), non-compliant \($t.non_compliant), not yet due \($t.not_yet_due), unknown \($t.unknown)",
      "",
      ([ "ACCOUNT", "REGION", "IDENTIFIER", "TYPE", "ROLE", "DAILY", "WEEKLY", "MONTHLY", "YEARLY", "STATUS", "GAPS" ] | join("\t")),
      ($R[] | [ .account_id, .region, .identifier, .type, .global_role, cell(.daily), cell(.weekly), cell(.monthly), cell(.yearly), .status, .gaps ] | join("\t")),
      (if any($D.regions[]; .status == "error") then "", "Region errors:", ($D.regions[] | select(.status == "error") | "  \(.account) \(.region): \(.errors | join("; "))") else empty end)
  elif $mode == "html" then
    {generated_utc: ($now | utc), generated_local: ($now | loc), tz_label: $cfg.tz_label, tz_offset: $cfg.tz_offset, now: $now,
     cfg: ($cfg | del(.tz_offset)), version: $tool, accounts: $D.accounts,
     regions: [ $D.regions[] | select(.status != "empty") | del(.existing) ],
     orph: [ $O[] | {a: .account_id, r: .region, t: .type, id, sid: .source_id, kind, eng: .engine, ev: .engine_version, c: .created_epoch,
                     st: .status, gb: .size_gb, usd: .est_monthly_usd, enc: .encrypted, kms: (.kms_key // ""), src: .source_status,
                     sr: (.source_region // ""), sa: (.source_account // "")} ],
     osum: ($OT + {text: osumtxt($OT)}),
     rows: [ $R[] | . + {cells: {daily: cell(.daily), weekly: cell(.weekly), monthly: cell(.monthly), yearly: cell(.yearly)}} ],
     snaps: [ $D.resources[] | {k: "\(.account_id)|\(.region)|\(.id)",
               s: [ .snapshots[] | {kind, id, c: .created_epoch, st: .status, gb: .size_gb, x: .expires_epoch, v: (.vault // ""),
                                    cl: (if .kind == "backup" then rp_class else "" end), rd: (if .kind == "backup" then rp_ret else null end)} ]} ]}
    | tojson | gsub("</"; "<\\/") as $json
    | "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><title>RDS backup compliance - \($D | accounts_label)</title>\n<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:16px;color:#222;font-size:13px}h1{font-size:18px;margin:0 0 4px}.sub{color:#666;margin-bottom:10px}
.tabs button{padding:6px 14px;border:1px solid #bbb;background:#f4f4f4;cursor:pointer;font-size:13px}.tabs button.on{background:#1f5fa8;color:#fff;border-color:#1f5fa8}
.tab{display:none;margin-top:10px}.tab.on{display:block}.cards{display:flex;gap:8px;flex-wrap:wrap;margin:8px 0}.card{border:1px solid #ddd;border-radius:6px;padding:6px 12px;min-width:90px}
.card .v{font-size:20px;font-weight:600}.card .l{color:#666;font-size:11px}.filters{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:8px 0}
select,input{font-size:13px;padding:3px}table{border-collapse:collapse;margin:6px 0 14px}th,td{border:1px solid #ddd;padding:3px 7px;text-align:left;white-space:nowrap}
th{background:#f0f3f7}td.OK{background:#e6f4ea}td.FAIL{background:#fde7e7}td.DUE{background:#fff6dc}td.UNKNOWN{background:#eee}td.NA{color:#999}
.s-COMPLIANT{color:#137333;font-weight:600}.s-NON-COMPLIANT{color:#b3261e;font-weight:600}.s-NOT-YET-DUE{color:#a56a00;font-weight:600}.s-UNKNOWN{color:#666;font-weight:600}
td.gaps{white-space:normal;max-width:380px}.osum{background:#fff6dc;border:1px solid #f0d58c;border-radius:4px;padding:5px 9px;margin:6px 0}tr.orph td{background:#fff3f0}td.src-ORPHANED{color:#b3261e;font-weight:600}td.src-SHARED{color:#1f5fa8}h2{font-size:15px;margin:14px 0 4px}.muted{color:#777}
</style></head><body>
<h1>RDS backup compliance - account \($D | accounts_label)</h1>
<div class=\"sub\">Generated \($now | utc) / \($now | loc) &middot; daily &ge; \($cfg.daily) (RDS automated) &middot; weekly &ge; \($cfg.weekly), monthly &ge; \($cfg.monthly), yearly &ge; \($cfg.yearly) (AWS Backup) &middot; global secondaries: daily only</div>
<div class=\"tabs\"><button data-t=\"comp\" class=\"on\">Compliance</button><button data-t=\"bk\">Backups</button></div>
<div id=\"comp\" class=\"tab on\"></div><div id=\"bk\" class=\"tab\"></div>
<script id=\"data\" type=\"application/json\">\($json)</script>
<script>\($page)</script></body></html>"
  else error("unknown mode \($mode)") end
