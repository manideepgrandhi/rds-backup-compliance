# rds_backup_compliance_report.sh - evaluation and rendering (jq 1.6+; no strftime %G/%V so jq.exe on Windows works).
# Input: one data document {schema, accounts, regions, resources}. Args: $mode (rows|json|csv|bcsv|mcsv|ocsv|osum|txt|html),
# $now (epoch), $cfg (thresholds + tz), $page (JS, html only), $tool (version).
def r1: (. * 10 | round) / 10;
def utc: if . == null then "" else (floor | todate | sub("T"; " ") | sub(":[0-9]{2}Z$"; " UTC")) end;
def loc: if . == null then "" else ((. + $cfg.tz_offset) | floor | todate | sub("T"; " ") | sub(":[0-9]{2}Z$"; " " + $cfg.tz_label)) end;
def day: floor / 86400 | floor;
def year: gmtime | .[0];
def MON: ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
def DOW: ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
def dow: (. + 4) % 7;                                         # day number -> 0 = Sunday (epoch day 0 = Thursday)
def dgm: . * 86400 | gmtime;
def p2: if . < 10 then "0\(.)" else "\(.)" end;
def dshort: (dgm) as $g | "\(DOW[. | dow]) \($g[2] | p2) \(MON[$g[1]])";           # Sat 17 Oct
def dlong: (dgm) as $g | "\($g[2] | p2) \(MON[$g[1]]) \($g[0])";                   # 17 Oct 2026
def diso: (dgm) as $g | "\($g[0])-\($g[1] + 1 | p2)-\($g[2] | p2)";
def mlabel: (dgm) as $g | "\(MON[$g[1]]) \($g[0])";                               # Oct 2026
def firstdow($mi; $wd): ([($mi / 12 | floor), ($mi % 12), 1, 0, 0, 0, 0, 0] | mktime / 86400 | floor) as $d1
  | $d1 + (($wd - ($d1 | dow) + 7) % 7);                     # first <weekday> of month index y*12+m (0-based month)

# class of an AWS Backup recovery point from its retention (days between creation and DeleteAt)
def rp_ret: if .expires_epoch == null then null else ((.expires_epoch - .created_epoch) / 86400 | round) end;
def rp_class: rp_ret as $d
  | if $d != null and $d >= $cfg.weekly_min_days and $d <= $cfg.weekly_max_days then "weekly"
    elif $d != null and $d >= ($cfg.monthly_min_days // ($cfg.weekly_max_days + 1)) and $d <= $cfg.monthly_max_days then "monthly"
    elif ($cfg.yearly // 0) > 0 and ($d == null or $d > $cfg.monthly_max_days) then "yearly"
    else "mismatch" end;

# schedule check. $cand: candidate scheduled day numbers, newest first. $pts: epochs. $tol: days either side.
# A day whose tolerance window has not closed yet and has no point is pending (not expected yet).
# $n: number of days expected (null = all candidates above $low). Days on or before $cday (creation day) are never expected.
def sched($cand; $pts; $tol; $n; $low; $cday):
  [ $cand[] | . as $d | {d: $d, hit: any($pts[]; . >= ($d - $tol) * 86400 and . < ($d + 1 + $tol) * 86400),
                          closed: ((($d + 1 + $tol) * 86400) <= $now)} | select(.hit or .closed) ] as $c
  | (if $n == null then [ $c[] | select(.d > $low) ] else $c[:$n] end) as $full
  | [ $full[] | select(.d > $cday) ] as $exp
  | {have: ([ $exp[] | select(.hit) ] | length), need: ($exp | length), target: ($full | length),
     missing: [ $exp[] | select(.hit | not) | .d ] | reverse};
def stx($c): if $c.have < $c.need then "FAIL" elif $c.need < $c.target then "DUE" else "OK" end;

def evaluate:
  . as $r
  | ($now | day) as $today
  | (if $r.created_epoch == null then -1 else ($r.created_epoch | day) end) as $cday
  | (($now - ($r.created_epoch // $now)) / 86400) as $age
  | ($cfg.tolerance_days // 1) as $tol
  | [ $r.snapshots[]? | select(.kind == "automated" and (.status // "available") == "available") ] as $auto
  | ($auto | map(.created_epoch) | max) as $last_auto
  | ([ $r.snapshots[]? | select(.kind == "backup" and .status == "COMPLETED" and (.expires_epoch == null or .expires_epoch > $now))
       | . + {class: rp_class, ret: rp_ret} ]) as $rps
  | (if $r.snap_ok == false then {st: "UNKNOWN", have: null, need: $cfg.daily, gap: "snapshots unreadable", missing: []}
     else sched([ range(0; $cfg.daily + 2) | $today - . ]; [ $auto[].created_epoch ]; 0; $cfg.daily; null; $cday) as $s
       | (if $last_auto == null then null else (($now - $last_auto) / 3600 | r1) end) as $h
       | [ (if ($r.retention // 0) < $cfg.daily then "daily: retention \($r.retention // 0)d < \($cfg.daily)d" else empty end),
           (if $h == null then (if $age * 24 > $cfg.daily_max_age_h then "daily: no automated backup" else empty end)
            elif $h > $cfg.daily_max_age_h then "daily: last automated \($h)h ago" else empty end),
           (if stx($s) == "FAIL" then "daily \($s.have)/\($s.need) missing \([ $s.missing[] | dshort ] | join(", "))" else empty end) ] as $g
       | $s + {last_h: $h, gap: ($g | join("; ")), full_on: (if $s.need < $s.target then ($cday + $s.target) | dlong else null end),
               st: (if ($g | length) > 0 then "FAIL" elif stx($s) == "DUE" or $h == null then "DUE" else "OK" end)} end) as $daily
  | ($cfg.weekly_weekday // 6) as $wd | ($cfg.monthly_weekday // 0) as $md
  | (if $cfg.weekly == "auto" or $cfg.weekly == null then null else $cfg.weekly end) as $wn
  | (($today - (($today | dow) - $wd + 7) % 7)) as $lastw
  | ($now | gmtime | .[0] * 12 + .[1]) as $mi
  | (if $r.global_role == "secondary" or $r.global_role == "replica" then
       {weekly: {st: "N/A"}, monthly: {st: "N/A"}, yearly: {st: "N/A"}}
     elif $r.backup_ok == false then
       {weekly: {st: "UNKNOWN"}, monthly: {st: "UNKNOWN"}, yearly: {st: "UNKNOWN"}}
     else
       ([ $rps[] | select(.class == "weekly") | .created_epoch ]) as $wp
       | ([ $rps[] | select(.class == "monthly") | .created_epoch ]) as $mp
       | sched([ range(0; ($wn // ($cfg.weekly_window_days / 7 | floor)) + 3) | $lastw - 7 * . ]; $wp; $tol; $wn; $today - $cfg.weekly_window_days; $cday) as $w
       | sched([ range(0; $cfg.monthly + 2) | firstdow($mi - .; $md) ]; $mp; $tol; $cfg.monthly; null; $cday) as $m
       | {weekly: ($w + {st: stx($w), dfmt: "week",
                         full_on: (if $w.need < $w.target then
                                     (if $wn == null then $cday + $cfg.weekly_window_days
                                      else (($cday + 1) as $f | $f + (($wd - ($f | dow) + 7) % 7) + 7 * ($wn - 1)) end) | dlong else null end)}),
          monthly: ($m + {st: stx($m), dfmt: "month",
                          full_on: (if $m.need < $m.target then
                                      ([ range(0; $cfg.monthly + 14) | firstdow(($cday | dgm | .[0] * 12 + .[1]) + .; $md) | select(. > $cday) ][$cfg.monthly - 1]) | dlong
                                    else null end)}),
          yearly: (if ($cfg.yearly // 0) > 0 then
                     ([ $rps[] | select(.class == "yearly") | .created_epoch | year ] | unique | length) as $y
                     | {have: $y, need: $cfg.yearly, target: $cfg.yearly, missing: [],
                        st: (if $y >= $cfg.yearly then "OK" elif $age < $cfg.yearly * 365.25 then "DUE" else "FAIL" end)}
                   else {st: "OFF"} end)} end) as $wmy
  | def mtxt($k; $c): if $k == "monthly" then [ $c.missing[] | mlabel ] else [ $c.missing[] | dshort ] end | join(", ");
  ([ ($daily | select(.st == "FAIL") | .gap),
       (if $daily.st == "UNKNOWN" then "daily: snapshots unreadable" else empty end),
       ($wmy | to_entries[] | select(.value.st == "FAIL") | "\(.key) \(.value.have)/\(.value.need)"
          + (if (.value.missing // []) | length > 0 then " missing " + mtxt(.key; .value) else "" end)),
       (if $wmy.weekly.st == "UNKNOWN" then "AWS Backup recovery points unreadable" else empty end) ] | join("; ")) as $gaps
  | ([ $rps[] | select(.class == "mismatch") ]) as $mis
  | ([ $daily.st, ($wmy[] | .st | select(. != "OFF")) ]) as $sts
  | def rset($k): [ $rps[] | select(.class == $k) | .ret ] | unique | map("\(.)d") | join(", ");
  { account_id: $r.account_id, region: $r.region, identifier: $r.id, type: $r.type, engine: $r.engine,
      engine_version: $r.engine_version, global_cluster: ($r.global_cluster // ""), global_role: ($r.global_role // "none"),
      created: ($r.created_epoch | utc), created_epoch: $r.created_epoch,
      age_days: (if $r.created_epoch == null then null else ($age | floor) end),
      retention_days: $r.retention, last_automated_utc: ($last_auto | utc),
      last_automated_local: ($last_auto | loc), daily: $daily, weekly: $wmy.weekly, monthly: $wmy.monthly, yearly: $wmy.yearly,
      status: (if any($sts[]; . == "FAIL") then "NON-COMPLIANT" elif any($sts[]; . == "UNKNOWN") then "UNKNOWN"
               elif any($sts[]; . == "DUE") then "NOT YET DUE" else "COMPLIANT" end),
      gaps: $gaps,
      not_yet_due: ([ ({k: "daily", v: $daily}, ($wmy | to_entries[] | {k: .key, v: .value})) | select(.v.full_on != null) | "\(.k) full on \(.v.full_on)" ] | join("; ")),
      warnings: (if ($mis | length) == 0 then "" else "retention doesn't match: \($mis | length) recovery point\(if ($mis | length) == 1 then "" else "s" end) ("
                   + ([ $mis[] | if .ret == null then "never expires" else "\(.ret)d" end ] | unique | join(", ")) + ") not counted" end),
      settings: {backup_window: ($r.backup_window // ""), copy_tags: (if $r.copy_tags == null then "" else $r.copy_tags end),
                 weekly_retention: rset("weekly"), monthly_retention: rset("monthly"), yearly_retention: rset("yearly"),
                 plans: ([ $rps[] | select(.plan != null or .rule != null) | "\(.plan // "?") / \(.rule // "?")" ] | unique | join(", ")),
                 schedules: ([ $rps[] | select(.cron != null) | .cron + (if .rtz then " (\(.rtz))" else "" end) ] | unique | join(", "))},
      manual: ([ $r.snapshots[]? | select(.kind == "manual") ] | length), automated: ($auto | length), backup_points: ($rps | length) };

def cell($c): if $c.st == "N/A" then "N/A" elif $c.st == "UNKNOWN" then "?" elif $c.st == "OFF" then ""
  else (if ($c.target // $c.need) > $c.need then "\($c.have)/\($c.need) so far (target \($c.target))" else "\($c.have)/\($c.need)" end)
       + (if ($c.missing // []) | length > 0 then " · missing " + ([ $c.missing[] | if $c.dfmt == "month" then mlabel else dshort end ] | join(", ")) else "" end) end;
def yon: ($cfg.yearly // 0) > 0;
def ycols($a): if yon then $a else [] end;
def csvrow: map(if . == null then "" else tostring end
                | if test("^[=+@-]") then "'" + . else . end) | @csv;   # formula-injection guard
def rows: [ .resources[] | evaluate ] | sort_by(.account_id, .region, .identifier);
def totals($rs): {resources: ($rs | length),
  compliant: ([ $rs[] | select(.status == "COMPLIANT") ] | length),
  non_compliant: ([ $rs[] | select(.status == "NON-COMPLIANT") ] | length),
  not_yet_due: ([ $rs[] | select(.status == "NOT YET DUE") ] | length),
  unknown: ([ $rs[] | select(.status == "UNKNOWN") ] | length)};
def wdname($n): ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"][$n];
def ruletxt: "daily: each of the last \($cfg.daily) days (RDS automated, last <= \($cfg.daily_max_age_h)h)"
  + " · weekly every \(wdname($cfg.weekly_weekday // 6)) " + (if $cfg.weekly == "auto" or $cfg.weekly == null then "in the last \($cfg.weekly_window_days // 30) days" else "x\($cfg.weekly)" end)
  + " (retention \($cfg.weekly_min_days)-\($cfg.weekly_max_days)d)"
  + " · monthly first \(wdname($cfg.monthly_weekday // 0)) x\($cfg.monthly) (retention \($cfg.monthly_min_days // ($cfg.weekly_max_days + 1))-\($cfg.monthly_max_days)d)"
  + (if yon then " · yearly x\($cfg.yearly)" else "" end)
  + " · ±\($cfg.tolerance_days // 1)d, UTC dates · global secondaries: daily only";
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
      "created_utc","age_days","backup_window","copy_tags_to_snapshot","last_automated_utc","last_automated_" + ($cfg.tz_label | ascii_downcase),
      "daily","weekly","monthly"] + ycols(["yearly"]) + ["status","not_yet_due","gaps","warnings","weekly_retention","monthly_retention","backup_plans"] | csvrow),
    ($R[] | [.account_id, .region, .identifier, .type, .engine, .engine_version, .global_cluster, .global_role, .retention_days,
             .created, .age_days, .settings.backup_window, .settings.copy_tags, .last_automated_utc, .last_automated_local,
             cell(.daily), cell(.weekly), cell(.monthly)] + ycols([cell(.yearly)])
           + [.status, .not_yet_due, .gaps, .warnings, .settings.weekly_retention, .settings.monthly_retention, .settings.plans] | csvrow)
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
      "Rule: \(ruletxt)",
      "Orphaned manual snapshots: \(osumtxt($OT)) at $\(price)/GB-month - rough upper estimate, snapshot billing is incremental",
      "Resources \($t.resources): compliant \($t.compliant), non-compliant \($t.non_compliant), not yet due \($t.not_yet_due), unknown \($t.unknown)",
      "",
      ([ "ACCOUNT", "REGION", "IDENTIFIER", "TYPE", "ROLE", "AGE_DAYS", "DAILY", "WEEKLY", "MONTHLY" ] + ycols(["YEARLY"]) + [ "STATUS", "GAPS", "WARNINGS" ] | join("\t")),
      ($R[] | [ .account_id, .region, .identifier, .type, .global_role, (.age_days // "" | tostring), cell(.daily), cell(.weekly), cell(.monthly) ] + ycols([cell(.yearly)])
              + [ .status, ([.gaps, .not_yet_due] | map(select(. != "")) | join("; ")), .warnings ] | join("\t")),
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
                                    cl: (if .kind == "backup" then rp_class else "" end), rd: (if .kind == "backup" then rp_ret else null end),
                                    pl: (.plan // ""), ru: (.rule // "")} ]} ]}
    | tojson | gsub("</"; "<\\/") as $json
    | "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><title>RDS backup compliance - \($D | accounts_label)</title>\n<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:16px;color:#222;font-size:13px}h1{font-size:18px;margin:0 0 4px}.sub{color:#666;margin-bottom:10px}
.tabs button{padding:6px 14px;border:1px solid #bbb;background:#f4f4f4;cursor:pointer;font-size:13px}.tabs button.on{background:#1f5fa8;color:#fff;border-color:#1f5fa8}
.tab{display:none;margin-top:10px}.tab.on{display:block}.cards{display:flex;gap:8px;flex-wrap:wrap;margin:8px 0}.card{border:1px solid #ddd;border-radius:6px;padding:6px 12px;min-width:90px}
.card .v{font-size:20px;font-weight:600}.card .l{color:#666;font-size:11px}.filters{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:8px 0}
select,input{font-size:13px;padding:3px}table{border-collapse:collapse;margin:6px 0 14px}th,td{border:1px solid #ddd;padding:3px 7px;text-align:left;white-space:nowrap}
th{background:#f0f3f7}td.OK{background:#e6f4ea}td.FAIL{background:#fde7e7}td.DUE{background:#fff6dc}td.UNKNOWN{background:#eee}td.NA{color:#999}
.s-COMPLIANT{color:#137333;font-weight:600}.s-NON-COMPLIANT{color:#b3261e;font-weight:600}.s-NOT-YET-DUE{color:#a56a00;font-weight:600}.s-UNKNOWN{color:#666;font-weight:600}
td.gaps{white-space:normal;max-width:380px}.warn{background:#fff6dc;color:#7a5200;padding:1px 4px;border-radius:3px;margin-top:2px}.kv th{width:230px}.osum{background:#fff6dc;border:1px solid #f0d58c;border-radius:4px;padding:5px 9px;margin:6px 0}tr.orph td{background:#fff3f0}td.src-ORPHANED{color:#b3261e;font-weight:600}td.src-SHARED{color:#1f5fa8}h2{font-size:15px;margin:14px 0 4px}.muted{color:#777}
</style></head><body>
<h1>RDS backup compliance - account \($D | accounts_label)</h1>
<div class=\"sub\">Generated \($now | utc) / \($now | loc) &middot; \(ruletxt | @html)</div>
<div class=\"tabs\"><button data-t=\"comp\" class=\"on\">Compliance</button><button data-t=\"bk\">Backups</button></div>
<div id=\"comp\" class=\"tab on\"></div><div id=\"bk\" class=\"tab\"></div>
<script id=\"data\" type=\"application/json\">\($json)</script>
<script>\($page)</script></body></html>"
  else error("unknown mode \($mode)") end
