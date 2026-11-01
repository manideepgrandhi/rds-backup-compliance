#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2012,SC2034  # cond && ok || bad is safe (ok returns 0); jq programs are single-quoted
# Tests for rds_backup_compliance_report.sh against the mock AWS CLI (tests/mock/aws). The mock must be the `aws`
# on PATH, credentials are fake, the endpoint is a dead local port, output goes to a temp dir.
# Usage: tests/run_tests.sh [-k]  (-k keeps the temp dir). SHOTS=DIR saves browser screenshots.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$HERE/../rds_backup_compliance_report.sh"
OUT="$(mktemp -d /tmp/rbc_tests.XXXXXX)"; KEEP=0; [[ "${1:-}" == -k ]] && KEEP=1
PASS=0; FAIL=0
export MOCK_LOG="$OUT/aws_calls.jsonl" PATH="$HERE/mock:$PATH"
unset AWS_REGION AWS_DEFAULT_REGION AWS_PROFILE MOCK_DEFAULT_REGION MOCK_SCENARIO
export AWS_ACCESS_KEY_ID=fake AWS_SECRET_ACCESS_KEY=fake AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null \
       AWS_EC2_METADATA_DISABLED=true AWS_ENDPOINT_URL=http://127.0.0.1:9 TMPDIR="$OUT"
if [[ "$(command -v aws)" != "$HERE/mock/aws" || "$(aws --version 2>&1)" != *.mock* ]]; then echo "GUARD: aws is not the mock"; exit 2; fi
BEFORE="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"
trap '(( KEEP )) && echo "kept $OUT" || rm -rf -- "$OUT"' EXIT
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
t() { local name="$1" exp="$2" scen="$3"; shift 3
      MOCK_SCENARIO="$scen" "$SCRIPT" "$@" >"$OUT/$name.out" 2>"$OUT/$name.err"; local rc=$?
      if [[ "$rc" == "$exp" ]]; then ok "$name (rc=$rc)"; else bad "$name: rc=$rc expected $exp"; tail -3 "$OUT/$name.err" | sed 's/^/       /'; fi; }
has()  { grep -qE -- "$3" "$OUT/$1.$2" && ok "$1 $2 has /$3/" || bad "$1 $2 lacks /$3/"; }
hasnt(){ grep -qE -- "$3" "$OUT/$1.$2" && bad "$1 $2 unexpectedly has /$3/" || ok "$1 $2 lacks /$3/"; }
chk()  { local d="$1"; shift; "$@" && ok "$d" || bad "$d"; }
jqt()  { jq -e "$2" "$3" >/dev/null 2>&1 && ok "$1: $2" || bad "$1: $2"; }
rowt() { jq -e --arg i "$2" ".rows[] | select(.identifier == \$i) | $3" "$OUT/$1.out" >/dev/null 2>&1 && ok "$1 $2: $3" \
           || bad "$1 $2: $3 (got $(jq -c --arg i "$2" '.rows[] | select(.identifier == $i) | {status, gaps, global_role}' "$OUT/$1.out" 2>/dev/null))"; }
ncalls() { wc -l <"$MOCK_LOG" 2>/dev/null | tr -d ' ' || echo 0; }

echo "== CLI"
t version 0 fleet --version; has version out '1\.4\.1'
t help 0 fleet --help; has help out 'list-recovery-points-by-backup-vault'; has help out 'weekly-days'
t badopt 1 fleet --nope
t multifmt 1 fleet -P prod -r us-east-1 -F csv,html
t badwd 1 fleet --weekly-days 70-60
t badint 1 fleet --weekly x
t badwd2 1 fleet --weekly-days 25-40 --monthly-days 30-400
t badtol 1 fleet --tolerance-days 4
t baddow 1 fleet --weekly-weekday saturday
t badrule 1 fleet --monthly-rule last-sun
t mergeP 1 fleet --merge x.json -P prod
t noregion 2 fleet -P prod

echo "== fleet (prod, two regions)"
t fleet 0 fleet -P prod -r us-east-1,us-west-2 -F json
rowt fleet orders-aurora-pg15 '.status == "COMPLIANT" and .global_role == "primary" and .global_cluster == "orders-global"'
rowt fleet orders-aurora-pg15 '.daily.have == 7 and .weekly.have == .weekly.need and (.weekly.need | . == 4 or . == 5) and .monthly.have == 12 and .monthly.need == 12 and .yearly.st == "OFF"'
rowt fleet orders-aurora-pg15 '.warnings == "retention doesn'"'"'t match: 2 recovery points (2555d, never expires) not counted" and .gaps == ""'
rowt fleet orders-aurora-pg15 '.settings.backup_window == "03:00-03:30" and .settings.copy_tags == false and .settings.weekly_retention == "35d" and .settings.monthly_retention == "365d"'
rowt fleet orders-aurora-pg15 '.settings.plans == "prod-rds-plan / monthly-first-sun, prod-rds-plan / weekly-sat" and (.settings.schedules | test("SAT"))'
rowt fleet orders-aurora-pg15 '.age_days == 1000 and (.created | test(" 00:00 UTC$"))'
rowt fleet legacy-mysql '.settings.copy_tags == false and .settings.backup_window == "04:00-04:30"'
rowt fleet reports-pg '.settings.copy_tags == true'
rowt fleet orders-aurora-pg15 '.automated == 7'          # the awsbackup-type snapshot is not counted as automated
rowt fleet orders-aurora-pg15 '.manual == 4'
rowt fleet legacy-mysql '.manual == 2'
rowt fleet billing-aurora-mysql '.status == "NON-COMPLIANT" and (.gaps | test("^weekly [34]/[45] missing Sat [0-9]{2} [A-Z][a-z]{2}$"))'
SAT1="$(jq -rn 'now / 86400 | floor | . - ((. + 4) % 7 - 6 + 7) % 7 | if (. * 86400 + 5 * 3600) > now then . - 7 else . end | . - 7 | . * 86400 | strftime("Sat %d %b")')"
rowt fleet billing-aurora-mysql ".weekly.st == \"FAIL\" and (.gaps | endswith(\"$SAT1\"))"
chk "billing weekly cell lists the missing Saturday" bash -c "jq -e '.rows[] | select(.identifier == \"billing-aurora-mysql\")' '$OUT/fleet.out' >/dev/null"
rowt fleet new-aurora-pg16 '.status == "NOT YET DUE" and .daily.st == "OK" and .weekly.st == "DUE" and .monthly.st == "DUE" and .gaps == "" and .age_days == 20'
rowt fleet new-aurora-pg16 '.weekly.have == .weekly.need and .weekly.need < .weekly.target and (.not_yet_due | test("^weekly full on [0-9]{2} [A-Z][a-z]{2} 20[0-9]{2}; monthly full on "))'
FULL7="$(date -u -d '+2 days' '+%d %b %Y')"; FULLW="$(date -u -d '+10 days' '+%d %b %Y')"
rowt fleet new-aurora-pg16 ".weekly.full_on == \"$FULLW\""
rowt fleet fresh-pg ".status == \"NOT YET DUE\" and .daily.st == \"DUE\" and .daily.target == 7 and .daily.have == .daily.need and (.daily.need | . == 4 or . == 5) and .daily.full_on == \"$FULL7\" and .age_days == 5"
rowt fleet fresh-pg '.monthly.need <= 1 and .monthly.target == 12 and .monthly.st == "DUE"'
rowt fleet reports-pg '.status == "NON-COMPLIANT" and (.gaps | test("retention 3d < 7d")) and .type == "instance"'
rowt fleet legacy-mysql '.status == "NON-COMPLIANT" and (.gaps | test("last automated 7[34](\\.[0-9])?h ago"))'
rowt fleet orders-dr-pg15 '.status == "COMPLIANT" and .global_role == "secondary" and .weekly.st == "N/A" and .yearly.st == "N/A"'
rowt fleet shop-dr-mysql '.status == "NON-COMPLIANT" and .global_cluster == "shop-global" and (.gaps | test("^daily"))'
jqt fleet '[.rows[].identifier] | index("docs-cluster") == null' "$OUT/fleet.out"
jqt fleet '[.rows[].identifier] | map(select(test("-1$"))) | length == 0' "$OUT/fleet.out"
jqt fleet '.totals == {resources: 8, compliant: 2, non_compliant: 4, not_yet_due: 2, unknown: 0, compliance: {compliant: 2, of: 6, not_yet_due: 2, pct: 33}}' "$OUT/fleet.out"
jqt fleet '.thresholds | .weekly_min_days == 25 and .weekly_max_days == 40 and .monthly_min_days == 300 and .monthly_max_days == 400 and .weekly == "auto" and .monthly == 12 and .yearly == 0 and .weekly_weekday == 6 and .monthly_weekday == 0 and .tolerance_days == 1' "$OUT/fleet.out"
has fleet err '^.*\[1/2\] us-east-1: 3 clusters, 3 instances, [0-9]+ snapshots, [0-9]+ recovery points, 4 without source \([0-9]+s\)$'
has fleet err '\[2/2\] us-west-2: 2 clusters, 0 instances, [0-9]+ snapshots, 0 recovery points'
jqt fleet '[.rows[] | keys[]] | unique | map(select(test("(^|_)arn$|^env|owner|^app|notes?$"))) | length == 0' "$OUT/fleet.out"
t fleettxt 0 fleet -P prod -r us-east-1
has fleettxt out '^RDS backup compliance - account 111111111111$'; has fleettxt out 'UTC / .* IST'
chk "text header has no region names" bash -c "head -4 '$OUT/fleettxt.out' | grep -qvE 'us-east-1' && ! head -4 '$OUT/fleettxt.out' | grep -q us-east-1"

echo "== read-only"
chk "only read-only AWS operations were called" bash -c "jq -r '[.[] | select(startswith(\"--\") | not)][1] // \"\"' '$MOCK_LOG' | sort -u | grep -vE '^(describe-|list-|get-caller-identity|get$|--version)' | grep -q . && exit 1 || exit 0"
n0="$(ncalls)"; t dry 0 fleet -P prod -r us-east-1 --dry-run
chk "dry-run calls nothing" test "$(ncalls)" == "$n0"; has dry out 'DRY-RUN: aws rds describe-db-clusters'

echo "== files (-A, csv/html/json/txt, save-data)"
mkdir -p "$OUT/o"
t files 0 fleet -P prod -A -F csv,html,json,text -o "$OUT/o" --save-data
for e in csv html json txt; do chk "file .$e with account in the name" compgen -G "$OUT/o/rds_backup_compliance_111111111111_*.$e" >/dev/null; done
chk "backups csv" compgen -G "$OUT/o/rds_backup_compliance_111111111111_*_backups.csv" >/dev/null
SD="$(ls "$OUT"/o/rds_backup_111111111111_*.json 2>/dev/null | head -1)"
chk "save-data rds_backup_<acct>_<date>.json" test -s "$SD"
jqt savedata '.schema == "rds_backup_compliance_data" and .schema_version == 1 and .accounts[0].account == "111111111111"' "$SD"
jqt savedata '[.regions[] | select(.status == "empty")] | length == 2' "$SD"
jqt savedata '[.regions[] | select(.status == "snapshots only") | .region] == ["ca-central-1"]' "$SD"
jqt savedata '[.orphans[] | .id] | sort == ["analytics-aurora-final", "crm-mysql-before-delete", "eu-app-copy", "orders-aurora-pg15-dr-copy", "reports-pg-west", "retired-oracle-final", "vendor-copy", "vendor-share-1"]' "$SD"
jqt savedata '[.orphans[] | select(.id == "analytics-aurora-final")][0] | .source_id == "analytics-aurora" and .engine == "aurora-postgresql" and .engine_version == "14.9" and .size_gb == 500 and .encrypted and (.kms_key | test("^arn:aws:kms:"))' "$SD"
jqt savedata '[.resources[] | has("arn")] | any | not' "$SD"
CSV="$(ls "$OUT"/o/rds_backup_compliance_111111111111_*[0-9].csv | head -1)"; BCSV="$(ls "$OUT"/o/*_backups.csv | head -1)"
HTML="$(ls "$OUT"/o/*.html | head -1)"; JSON="$(ls "$OUT"/o/rds_backup_compliance_*.json | head -1)"
HDR='"account_id","region","identifier","type","engine","engine_version","global_cluster","global_role","retention_days","created_utc","age_days","backup_window","copy_tags_to_snapshot","last_automated_utc","last_automated_ist"'
for k in daily weekly monthly; do HDR+=",\"${k}_status\",\"${k}_found\",\"${k}_expected\",\"${k}_target\",\"${k}_missing\",\"${k}_full_on\""; done
HDR+=',"status","not_yet_due","gaps","warnings","weekly_retention","monthly_retention","backup_plans"'
HDR+=',"retention_mismatch_count","retention_mismatch","excess_daily","excess_weekly","excess_monthly","excess","over_retention_count","over_retention","counted_in_compliance_pct"'
chk "csv header" grep -qxF "$HDR" "$CSV"
# v1.4.0 strict retention / excess / over-retention / compliance %
rowt fleet orders-aurora-pg15 '.retention_mismatch == "weekly point has 35d, expected 30d (x5)" and .retention_mismatch_count == 5 and .status == "COMPLIANT" and .weekly.have == 5'
rowt fleet orders-aurora-pg15 '[.recovery_points[] | select(.ret == 365 and .counted)] | length > 0 and all(.retention_mismatch == null and (.reason | test("retention 365d as expected$")))'
rowt fleet reports-pg '.excess == "weekly 9 (expected 4-5)" and .excess_counts == {daily: 0, weekly: 4, monthly: 0} and .weekly.st == "OK"'
rowt fleet legacy-mysql '(.over_retention | test("^holds 7 automated backups for 7d retention; 2 older than 7d, oldest rds:legacy-mysql-")) and .over_retention_count == 2'
rowt fleet new-aurora-pg16 '.over_retention_count == 13 and .status == "NOT YET DUE"'
rowt fleet orders-dr-pg15 '.excess_counts.weekly == null and .excess == "" and .over_retention == "" and .retention_mismatch == ""'
has fleettxt out '^Compliance: 25% \(1 of 4\), 2 not yet due not counted$'
chk "csv has 8 rows + header" test "$(wc -l <"$CSV")" -eq 9
chk "csv: no yearly column at yearly=0" bash -c "! head -1 '$CSV' | grep -q yearly"
chk "csv: not_yet_due + full on" bash -c "grep '\"fresh-pg\"' '$CSV' | grep -q 'daily full on'"
csvq() { python3 -c 'import csv,sys; rows=list(csv.DictReader(open(sys.argv[1], encoding="utf-8"))); sys.exit(0 if eval(sys.argv[2]) else 1)' "$@"; }
csvq "$CSV" 'all(r["counted_in_compliance_pct"] == ("no" if r["status"] == "NOT YET DUE" else "yes") for r in rows) and [r["excess_weekly"] for r in rows if r["identifier"] == "reports-pg"] == ["4"] and [r["excess_weekly"] for r in rows if r["identifier"] == "orders-dr-pg15"] == [""]' && ok "csv: excess / compliance columns" || bad "csv: excess / compliance columns"
csvq "$CSV" 'all(all(not __import__("re").match(r"^\d{1,4}[-/]\d{1,2}([-/]\d{1,4})?$", r[k]) for k in ("retention_mismatch_count","excess_daily","excess_weekly","excess_monthly","over_retention_count")) for r in rows)' && ok "csv: new count columns are plain numbers (no Excel dates)" || bad "csv: new count columns are plain numbers (no Excel dates)"
chk "csv: weekly numeric found/expected/target + missing Saturday ISO" csvq "$CSV" 'any(r["identifier"]=="billing-aurora-mysql" and r["weekly_status"]=="FAIL" and r["weekly_found"] in ("3","4") and int(r["weekly_expected"])==int(r["weekly_found"])+1 and r["weekly_target"]==r["weekly_expected"] and __import__("re").fullmatch(r"20\d\d-\d\d-\d\d Sat", r["weekly_missing"]) for r in rows)'
chk "csv: building up = found/expected < target 7, full_on ISO" csvq "$CSV" 'any(r["identifier"]=="fresh-pg" and r["daily_found"]==r["daily_expected"] and r["daily_expected"] in ("4","5") and r["daily_target"]=="7" and __import__("re").fullmatch(r"20\d\d-\d\d-\d\d [A-Z][a-z]{2}", r["daily_full_on"]) for r in rows)'
chk "csv: count columns are plain integers (or empty for N/A)" csvq "$CSV" 'all(__import__("re").fullmatch(r"\d*", r[k+"_"+c]) for r in rows for k in ("daily","weekly","monthly") for c in ("found","expected","target"))'
chk "csv: N/A periods keep status, empty numbers" csvq "$CSV" 'any(r["identifier"]=="orders-dr-pg15" and r["weekly_status"]=="N/A" and r["weekly_found"]=="" for r in rows)'
chk "csv: no cell Excel would read as a date" python3 -c 'import csv,re,sys
bad=re.compile(r"^\s*(\d{1,4}[/-]\d{1,2}([/-]\d{1,4})?|\d{1,2}[ -](Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*([ -]\d{2,4})?|(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*[ -]\d{1,4})\s*$")
cells=[c for row in csv.reader(open(sys.argv[1], encoding="utf-8")) for c in row]
hits=[c for c in cells if bad.match(c)]; hits and print(hits[:5], file=sys.stderr); sys.exit(1 if hits else 0)' "$CSV"
chk "text: no YEARLY column at yearly=0" bash -c "! grep -q YEARLY \"\$(ls '$OUT'/o/*.txt | head -1)\""
hasnt files err 'ap-south-1: \(empty\)'
has files err '\[[0-9]/5\] us-east-1: [0-9]+ clusters'
has files err '111111111111: 5 regions scanned, 2 empty: ap-south-1, eu-west-1$'
has files err "^Output \\([0-9]+ files\\):\$"
has files err "^  $OUT/o/rds_backup_compliance_111111111111_[0-9_]+\\.html\$"
has files err "^  $OUT/o/rds_backup_compliance_111111111111_[0-9_]+\\.csv\$"
has files err "^  $OUT/o/rds_backup_111111111111_[0-9]+\\.json\$"
chk "output block: every file line is an absolute path that exists" bash -c "sed -n '/^Output/,\$p' '$OUT/files.err' | tail -n +2 | while IFS= read -r l; do [[ \"\$l\" == '  /'* && -s \"\${l#  }\" ]] || exit 1; done"
t filesv 0 fleet -P prod -A -F json -v
has filesv err '\[[0-9]/5\] ap-south-1: \(empty\)$'
has filesv err '5 regions scanned, 2 empty'
t rpq 0 rpquirks -P prod -r us-east-1 -i orders-* -F json
rowt rpq orders-aurora-pg15 '.weekly.have == .weekly.need and .weekly.need >= 4 and .weekly.st == "OK"'
rowt rpq orders-aurora-pg15 '.weekly.have as $h | [.recovery_points[] | select(.class == "weekly" and .counted and .status == "AVAILABLE" and .ret == 35)] | length == $h'
rowt rpq orders-aurora-pg15 '[.recovery_points[] | select(.reason | test("^continuous backup")) | select(.counted | not)] | length == 1'
rowt fleet orders-aurora-pg15 '[.recovery_points[] | select(.ret == 35)] | all(.counted and (.reason | test("^weekly: counts for Sat [0-9]{2} [A-Z][a-z]{2}, but weekly point has 35d, expected 30d$")) and .retention_mismatch == "weekly point has 35d, expected 30d")'
rowt fleet orders-aurora-pg15 '.recovery_points | all(has("date") and has("ret") and has("class") and has("counted") and has("reason")) and (.[0].date | test("^20[0-9]{2}-[0-9]{2}-[0-9]{2} [A-Z][a-z]{2}$"))'
chk "output block: no // or ./ in paths" bash -c "! sed -n '/^Output/,\$p' '$OUT/files.err' | grep -qE '//|/\\./|~'"
mkdir -p "$OUT/o2/sub"; ( cd "$OUT/o2" && t relout 0 fleet -P prod -r us-east-1 -F csv -o ./sub//../sub/ )
has relout err "^Output \\(3 files\\):\$"
has relout err "^  $OUT/o2/sub/rds_backup_compliance_111111111111_[0-9_]+_backups\\.csv\$"
chk "csv has every status" bash -c "grep -q '\"COMPLIANT\"' '$CSV' && grep -q '\"NON-COMPLIANT\"' '$CSV' && grep -q '\"NOT YET DUE\"' '$CSV'"
chk "backups csv has manual, automated, backup kinds" bash -c "grep -q ',\"manual\",' '$BCSV' && grep -q ',\"automated\",' '$BCSV' && grep -q ',\"backup\",' '$BCSV'"
chk "backups csv has IST column and classes" bash -c "head -1 '$BCSV' | grep -q created_ist && grep -q '\"weekly\"' '$BCSV' && grep -q '\"monthly\"' '$BCSV' && grep -q '\"mismatch\"' '$BCSV'"
chk "backups csv header = in-page export order" bash -c "head -1 '$BCSV' | tr -d '\"\r' | grep -qx 'account_id,region,identifier,type,kind,snapshot_or_recovery_point,created_utc,created_ist,age_days,status,size_gb,rule,retention_days,expires_utc,vault,source_status'"
chk "backups csv: automated rule daily, manual rule empty, age_days numeric" bash -c "grep ',\"automated\",' '$BCSV' | head -1 | grep -q ',\"daily\",' && grep ',\"manual\",' '$BCSV' | head -1 | grep -qE ',\"[0-9]+\",\"available\",\"100\",\"\",\"\",'"
chk "backups csv: no EC2 recovery point" bash -c "! grep -q ami-0abc '$BCSV'"
chk "html: no empty region (ap-south-1)" bash -c "! grep -qE 'ap-south-1' '$HTML'"
chk "html: no region names above the tabs" bash -c "! sed -n '1,/class=\"tabs\"/p' '$HTML' | grep -qE '(us|eu|ap|ca)-[a-z]+-[0-9]'"
chk "html: account in title" grep -q '<title>RDS backup compliance - 111111111111</title>' "$HTML"
chk "html: no </script> breakout in data" bash -c "test \"\$(grep -c '</script>' '$HTML')\" -eq 2"
jqt filesjson '.regions | map(.region) == ["ca-central-1", "us-east-1", "us-west-2"]' "$JSON"
# orphaned manual snapshots
OCSV="$(ls "$OUT"/o/*_orphaned_snapshots.csv 2>/dev/null | head -1)"
chk "orphaned csv written with csv format" test -s "$OCSV"
chk "orphaned csv header" bash -c "head -1 '$OCSV' | tr -d '\"\r' | grep -qx 'account_id,region,snapshot_id,type,source_id,engine,engine_version,created_utc,created_ist,age_days,size_gb,est_monthly_usd,encrypted,kms_key'"
chk "orphaned csv: 4 orphans, oldest first" bash -c "tail -n +2 '$OCSV' | cut -d, -f3 | tr -d '\"' | paste -sd' ' | grep -qx 'retired-oracle-final analytics-aurora-final crm-mysql-before-delete reports-pg-west'"
chk "orphaned csv: same-name source in another region is orphaned" bash -c "grep -q '\"us-west-2\",\"reports-pg-west\",\"instance\",\"reports-pg\"' '$OCSV'"
chk "orphaned csv: deleted source row has size, estimate, kms" bash -c "grep -q '\"analytics-aurora-final\",\"cluster\",\"analytics-aurora\",\"aurora-postgresql\",\"14.9\",.*\"500\",\"10.5\",\"true\",\"arn:aws:kms:' '$OCSV'"
chk "orphaned csv: no shared / copy / awsbackup / automated / docdb" bash -c "! grep -qE 'vendor|eu-app|dr-copy|gone-db|docs-final' '$OCSV'"
jqt filesjson '.orphan_totals.summary == "4 orphaned snapshots, 1.8 TB, ~$38/month (estimate)" and .orphan_totals.shared == 2 and .orphan_totals.unverified == 1' "$JSON"
jqt filesjson '[.orphaned_snapshots[] | {key: .id, value: .source_status}] | from_entries | .["vendor-share-1"] == "SHARED" and .["vendor-copy"] == "SHARED" and .["orders-aurora-pg15-dr-copy"] == "EXISTING" and .["eu-app-copy"] == "UNVERIFIED" and .["analytics-aurora-final"] == "ORPHANED"' "$JSON"
chk "backups csv: orphaned flag rows" bash -c "grep -q '\"crm-mysql\",\"instance\",\"manual\",\"crm-mysql-before-delete\",.*\"ORPHANED\"$' '$BCSV' && grep -q '\"vendor-share-1\",.*\"SHARED\"$' '$BCSV'"
chk "describe-db-*-snapshots called with --include-shared" bash -c "grep 'describe-db-snapshots' '$MOCK_LOG' | tail -1 | grep -q include-shared"
chk "snapshots read in a region without databases (ca-central-1)" bash -c "grep 'describe-db-cluster-snapshots' '$MOCK_LOG' | grep -q ca-central-1"
has files err '4 orphaned snapshots, 1.8 TB, ~\$38/month \(estimate\)'
t price 0 fleet -P prod -r us-east-1 -F json --snapshot-price-per-gb 0.05
jqt price '[.orphaned_snapshots[] | select(.id == "analytics-aurora-final")][0].est_monthly_usd == 25 and .orphan_totals.price_per_gb_month == 0.05' "$OUT/price.out"
t pricebad 1 fleet -P prod -r us-east-1 --snapshot-price-per-gb cheap
printf 'snapshot_price_per_gb = 0.1\r\nregion=us-east-1\r\nformat=json\r\n' >"$OUT/price conf.conf"
t priceconf 0 fleet -P prod --config "$OUT/price conf.conf"
jqt priceconf '.orphan_totals.est_monthly_usd == 70' "$OUT/priceconf.out"

echo "== scenarios"
t bdeny 0 backupdeny -P prod -r us-east-1,us-west-2 -F json
rowt bdeny orders-aurora-pg15 '.status == "UNKNOWN" and .weekly.st == "UNKNOWN" and (.gaps | test("unreadable"))'
rowt bdeny orders-dr-pg15 '.status == "COMPLIANT"'
rowt bdeny billing-aurora-mysql '.status == "UNKNOWN"'
has bdeny err '\[1/2\] us-east-1: .* - ERROR: .*list-backup-vaults'
jqt bdeny '[.regions[] | select(.status == "error")] | length == 2' "$OUT/bdeny.out"
t gdeny 0 globaldeny -P prod -r us-west-2 -F json
rowt gdeny orders-dr-pg15 '.global_role == "unknown" and .weekly.st == "FAIL"'
has gdeny err 'describe-global-clusters: \(AccessDenied\)'
t sdeny 0 snapdeny -P prod -r us-east-1 -F json
rowt sdeny reports-pg '.daily.st == "UNKNOWN"'
rowt sdeny orders-aurora-pg15 '.status == "COMPLIANT"'
t empty 0 empty -P prod -A -F json
jqt empty '.rows == [] and .regions == []' "$OUT/empty.out"
t broken 2 fleet -P broken -r us-east-1
t mixed 0 fleet -P prod,broken -r us-east-1 -F json
jqt mixed '.accounts | length == 1' "$OUT/mixed.out"
t failnc 5 fleet -P prod -r us-east-1 --fail-on-noncompliant
t failok 0 fleet -P nonprod -r ap-south-1 -i hr-* --fail-on-noncompliant
t nconly 0 fleet -P prod -r us-east-1 -F json --non-compliant-only
jqt nconly '[.rows[].status] | unique == ["NON-COMPLIANT"]' "$OUT/nconly.out"
t eng 0 fleet -P prod -r us-east-1 -e 'aurora-*' -F json
jqt eng '[.orphaned_snapshots[] | .source_id] == ["analytics-aurora"]' "$OUT/eng.out"
jqt eng '[.rows[].engine] | all(startswith("aurora-"))' "$OUT/eng.out"
t ident 0 fleet -P prod -r us-east-1 -i 'REPORTS-*' -F json
jqt ident '[.rows[].identifier] == ["reports-pg"]' "$OUT/ident.out"
t defregion 2 fleet -P nonprod -F json; MOCK_DEFAULT_REGION=ap-south-1 t defregion2 0 fleet -P nonprod -F json
jqt defregion2 '.rows | length == 2' "$OUT/defregion2.out"

echo "== thresholds"
t wk6 0 fleet -P prod -r us-east-1 -i orders-* --weekly 6 -F json; rowt wk6 orders-aurora-pg15 '.weekly.have == 5 and .weekly.need == 6 and .weekly.st == "FAIL" and (.gaps | test("^weekly 5/6 missing Sat "))'
t wd40 0 fleet -P prod -r us-east-1 -i orders-* --weekly-days 40-60 -F json; rowt wd40 orders-aurora-pg15 '.weekly.have == 0 and (.warnings | test("35d"))'
t mmax 0 fleet -P prod -r us-east-1 -i orders-* --monthly-max-days 300 -F json; rowt mmax orders-aurora-pg15 '.monthly.have == 0 and (.warnings | test("365d"))'
t mdays 0 fleet -P prod -r us-east-1 -i orders-* --monthly-days 360-370 -F json; rowt mdays orders-aurora-pg15 '.monthly.have == 12 and .status == "COMPLIANT"'
t yearly1 0 fleet -P prod -r us-east-1 -i orders-* --yearly 1 -F csv; has yearly1 out '"monthly_full_on","yearly_status","yearly_found","yearly_expected","yearly_target","yearly_missing","yearly_full_on","status"'
t yearly1j 0 fleet -P prod -r us-east-1 -i orders-* --yearly 1 -F json; rowt yearly1j orders-aurora-pg15 '.yearly.have == 2 and .yearly.st == "OK" and .warnings == ""'
t yearly1t 0 fleet -P prod -r us-east-1 -i orders-* --yearly 1; has yearly1t out 'MONTHLY	YEARLY	STATUS'
t yearly1h 0 fleet -P prod -r us-east-1 -i orders-* --yearly 1 -F html -o "$OUT/y1"; chk "html: Yearly shown at yearly=1" bash -c "grep -q 'yearly x1' \"$OUT\"/y1/*.html"
# Saturday / first-Sunday matching with tolerance (hr-aurora-pg's 2nd weekly point ran on Sunday 07:00 UTC)
t tol1 0 fleet -P nonprod -r ap-south-1 -F json; rowt tol1 hr-aurora-pg '.status == "COMPLIANT" and .weekly.st == "OK"'
rowt tol1 payroll-sqlserver '.status == "NON-COMPLIANT" and (.gaps | test("^monthly 10/12 missing [A-Z][a-z]{2} 20[0-9]{2}, [A-Z][a-z]{2} 20[0-9]{2}$"))'
rowt tol1 payroll-sqlserver '.settings.plans == "1a2b3c4d-plan / rule-monthly-first-sun, 1a2b3c4d-plan / rule-weekly-sat" and .settings.schedules == ""'
M2="$(jq -rn '[now | gmtime | .[0] * 12 + .[1] | range(0; 14) as $k | (. - $k) as $mi | ([($mi / 12 | floor), ($mi % 12), 1, 0, 0, 0, 0, 0] | mktime) as $d1
       | ($d1 / 86400 | floor) as $dn | ($dn + ((0 - (($dn + 4) % 7) + 7) % 7)) | select(. * 86400 + 4 * 3600 <= now) | . * 86400 | strftime("%b %Y")] | "\(.[5]), \(.[2])"')"
rowt tol1 payroll-sqlserver ".gaps == \"monthly 10/12 missing $M2\""
t tol0 0 fleet -P nonprod -r ap-south-1 -F json --tolerance-days 0; rowt tol0 hr-aurora-pg '.status == "NON-COMPLIANT" and (.gaps | test("^weekly [34]/[45] missing Sat "))'
t wdsun 0 fleet -P nonprod -r ap-south-1 -F json --weekly-weekday sun --tolerance-days 0; rowt wdsun hr-aurora-pg '.weekly.have <= 1'
rowt wd40 orders-aurora-pg15 '[.recovery_points[] | select(.ret == 35) | .reason] | length > 0 and all(test("^retention 35d is outside the weekly range 40-60d \\(expected 30d\\) and the monthly range"))'
rowt wdsun hr-aurora-pg '[.recovery_points[] | select(.class == "weekly" and (.counted | not)) | .reason] | all(test("not within ±0d of a checked Sunday"))'
t daily14 0 fleet -P nonprod -r ap-south-1 --daily 14 -F json; rowt daily14 hr-aurora-pg '.daily.st == "OK"'; rowt daily14 payroll-sqlserver '.daily.st == "FAIL"'
t age 0 fleet -P prod -r us-east-1 -i legacy-* --daily-max-age 80 -F json; rowt age legacy-mysql '(.gaps | test("last automated") | not)'
printf 'weekly = 6\r\n# comment\r\nregion=us-east-1\r\nidentifier = orders-*\r\nformat=json\r\n' >"$OUT/my conf.conf"
t conf 0 fleet -P prod --config "$OUT/my conf.conf"; rowt conf orders-aurora-pg15 '.weekly.need == 6'
t confcli 0 fleet -P prod --config "$OUT/my conf.conf" --weekly 4; rowt confcli orders-aurora-pg15 '.weekly.need == 4'
# v1.4.0 strict retention settings (CLI + config, both key spellings)
t wret 0 fleet -P prod -r us-east-1 -i orders-* --weekly-retention-days 35 -F json; rowt wret orders-aurora-pg15 '.retention_mismatch == "" and .weekly.have == 5'
t wtol 0 fleet -P prod -r us-east-1 -i orders-* --retention-tolerance-days 5 -F json; rowt wtol orders-aurora-pg15 '.retention_mismatch == ""'
t mret 0 fleet -P prod -r us-east-1 -i orders-* --monthly-retention-days 400 -F json
rowt mret orders-aurora-pg15 '(.retention_mismatch | test("monthly point has 365d, expected 400d \\(x12\\)")) and .monthly.have == 12 and .status == "COMPLIANT"'
t dret 0 fleet -P prod -r us-east-1 -i reports-pg --daily-retention-days 2 -F json; rowt dret reports-pg '.retention_mismatch | test("^daily retention 3d, expected 2d")'
printf 'WEEKLY_RETENTION_DAYS=35\nmonthly_retention_days=365\nretention-tolerance-days=1\nregion=us-east-1\nidentifier=orders-*\nformat=json\n' >"$OUT/ret.conf"
t retconf 0 fleet -P prod --config "$OUT/ret.conf"; rowt retconf orders-aurora-pg15 '.retention_mismatch == ""'
t badret 1 fleet -P prod --weekly-retention-days x
printf 'bogus=1\n' >"$OUT/bad.conf"; t badconf 1 fleet --config "$OUT/bad.conf"
t tz 0 fleet -P prod -r us-east-1 --tz UTC -F csv; has tz out 'last_automated_utc"'
chk "jq: +05:30 timestamps parse to UTC" test "$(jq -n --slurpfile x /dev/null 'include "collect" {search: "'"$HERE"'/../lib"}; 1' 2>/dev/null; jq -rn '"2026-10-01T08:30:00.123000+05:30" | capture("^(?<d>[0-9-]+T[0-9:]+)") | .d + "Z" | fromdateiso8601 - 19800 | todate')" == "2026-10-01T03:00:00Z"

echo "== parallel regions"
t badpar 1 fleet --parallel 0
t badpar2 1 fleet --parallel x
NORM='del(.. | .collected_epoch?, .collected_at?, .generated_epoch?, .generated_at?, .generated_utc?, .generated_local?, .age_days?)'
MOCK_NOW="$(date -u +%s)"; export MOCK_NOW
MOCK_SLEEP=ap-south-1=1,ca-central-1=0.5 t par1 0 fleet -P prod -A --parallel 1 -F json
MOCK_SLEEP=ap-south-1=1,ca-central-1=0.5 t par4 0 fleet -P prod -A --parallel 4 -F json
MOCK_SLEEP=ap-south-1=1 RDS_BCR_NO_WAIT_N=1 t par2b 0 fleet -P prod -A --parallel 2 -F json
chk "parallel 4 output identical to sequential (slow first region finishes last)" cmp -s <(jq -S "$NORM" "$OUT/par1.out") <(jq -S "$NORM" "$OUT/par4.out")
chk "batch fallback (no wait -n) identical to sequential" cmp -s <(jq -S "$NORM" "$OUT/par1.out") <(jq -S "$NORM" "$OUT/par2b.out")
hasnt par1 err 'started|at a time|regions in order'
has par4 err 'scanning 5 regions, up to 4 at a time'
hasnt par4 err 'started|regions in order|\(empty\)'
has par4 err '111111111111: 5 regions scanned, 2 empty: ap-south-1, eu-west-1$'
chk "par: same summary line as sequential" bash -c "diff <(grep -o 'regions scanned.*' '$OUT/par1.err') <(grep -o 'regions scanned.*' '$OUT/par4.err')"
MOCK_SLEEP=ap-south-1=1,ca-central-1=0.5 t par4v 0 fleet -P prod -A --parallel 4 -F json -v
has par4v err '\[1/5\] ap-south-1: started'
has par4v err '\[5/5\] us-west-2: started'
has par4v err 'regions in order: ap-south-1: done \(0 resources\); ca-central-1: done \(0 resources\); eu-west-1: done \(0 resources\); us-east-1: done \(6 resources\); us-west-2: done \(2 resources\)$'
chk "par4v: slow ap-south-1 reports done after us-east-1" bash -c "grep -n 'us-east-1: 3 clusters' '$OUT/par4v.err' | cut -d: -f1 | { read a; b=\$(grep -n 'ap-south-1: (empty)' '$OUT/par4v.err' | cut -d: -f1); (( a < b )); }"
MOCK_SLEEP=ap-south-1=1 RDS_BCR_NO_WAIT_N=1 t par2bv 0 fleet -P prod -A --parallel 2 -F json -v
chk "par2bv: never more than 2 regions started before one finished" bash -c "awk '/: started\$/{r++; if(r>m)m=r} /: [0-9]+ clusters|\\(empty\\)/{r--} END{exit !(m==2)}' '$OUT/par2bv.err'"
t parconf 0 fleet --config <(printf 'profile = prod\nall-regions = yes\nparallel = 2\nformat = json\n')
has parconf err 'up to 2 at a time'
t parcrash 0 regioncrash -P prod -A -F json
jqt parcrash '.regions[] | select(.region == "us-west-2") | .status == "error" and (.errors[0] | startswith("region scan failed"))' "$OUT/parcrash.out"
jqt parcrash '[.rows[] | select(.region == "us-east-1")] | length == 6' "$OUT/parcrash.out"
rowt parcrash orders-aurora-pg15 '.status == "COMPLIANT"'
has parcrash err '\[ERROR\] \[5/5\] us-west-2: failed'
has parcrash err '5 regions scanned, 2 empty: ap-south-1, eu-west-1; 1 failed: us-west-2$'
has parcrash err '1 of 5 region\(s\) failed'
t parcrashnc 5 regioncrash -P prod -A -F json --fail-on-noncompliant
mkdir -p "$OUT/ptmp"; TMPDIR="$OUT/ptmp" MOCK_SCENARIO=regioncrash "$SCRIPT" -P prod -A -F json >/dev/null 2>&1
chk "parallel: temp work dir removed by the trap" bash -c "[[ -z \"\$(ls -A '$OUT/ptmp')\" ]]"
unset MOCK_NOW

echo "== merge (offline)"
M="$OUT/merge dir"; mkdir -p "$M"
MOCK_SCENARIO=fleet "$SCRIPT" -P prod -r us-east-1,us-west-2 --save-data "$M/prod.json" -F json >/dev/null 2>&1
MOCK_SCENARIO=fleet "$SCRIPT" -P nonprod -r ap-south-1 --save-data "$M/nonprod.json" -F json >/dev/null 2>&1
MOCK_SCENARIO=fleet "$SCRIPT" -P dev -r eu-west-1 --save-data "$M/dev.json" -F json >/dev/null 2>&1
jq '.collected_epoch -= 86400 | .accounts[0].collected_epoch -= 86400 | .resources |= .[:2]' "$M/prod.json" >"$OUT/prod_old.json"
n0="$(ncalls)"
t merge 0 fleet --merge "$M/prod.json" "$M/nonprod.json" "$M/dev.json" "$OUT/prod_old.json" -F json
chk "merge made zero AWS calls" test "$(ncalls)" == "$n0"
jqt merge '[.accounts[].account] | sort == ["111111111111", "222222222222", "333333333333"]' "$OUT/merge.out"
jqt merge '.rows | length == 11' "$OUT/merge.out"
jqt merge '.orphan_totals.orphaned == 5 and .orphan_totals.summary == "5 orphaned snapshots, 1.6 TB, ~$34/month (estimate)"' "$OUT/merge.out"
jqt merge '[.orphaned_snapshots[] | select(.source_status == "ORPHANED") | .account_id] | unique == ["111111111111", "222222222222", "333333333333"]' "$OUT/merge.out"
jqt merge '[.orphaned_snapshots[] | select(.id == "orders-aurora-pg15-dr-copy")][0].source_status == "EXISTING"' "$OUT/merge.out"
has merge err 'account 111111111111: an older collection was ignored'
rowt merge payroll-sqlserver '.status == "NON-COMPLIANT" and (.gaps | startswith("monthly 10/12 missing "))'
t mergeold 0 fleet --merge "$OUT/prod_old.json" "$M/nonprod.json" -F json
jqt mergeold '.rows | length == 4' "$OUT/mergeold.out"
# manual-snapshot audit CSV (live and from merged data); v1.0.0 save-data files still merge
mkdir -p "$OUT/mo"
t mold 0 fleet -P prod -r us-east-1 -F json -o "$OUT/mo" --manual-older-than 90
MO="$(ls "$OUT"/mo/*_manual_older_than_90d.csv 2>/dev/null | head -1)"
chk "manual-older-than: csv written" test -s "$MO"
chk "manual-older-than: header" bash -c "head -1 '$MO' | grep -q '^\"\?account_id\"\?,\"\?region\"\?,\"\?identifier\"\?,.*age_days'"
chk "manual-older-than: >90d manual incl. orphaned (5 + 2 in prod us-east-1)" test "$(tail -n +2 "$MO" | grep -c .)" == 7
chk "manual-older-than: orphaned rows flagged" bash -c "grep -q 'analytics-aurora-final.*\"ORPHANED\"' '$MO'"
chk "manual-older-than: oldest first, >12 months kept" bash -c "sed -n 2p '$MO' | grep -q 'legacy-mysql-manual-600d'"
t moldbad 1 fleet -P prod -r us-east-1 --manual-older-than abc
t moldmerge 0 fleet --merge "$M" -F json -o "$OUT/mo2" --manual-older-than 365
chk "manual-older-than on merge: >365d across accounts" bash -c "tail -n +2 \"$OUT\"/mo2/*_manual_older_than_365d.csv | cut -d, -f3 | sort -u | tr -d '\"' | paste -sd' ' | grep -qx 'analytics-aurora legacy-mysql orders-aurora-pg15 payroll-sqlserver'"
if git -C "$HERE/.." cat-file -e 602abe2 2>/dev/null; then
    V1="$OUT/v100"; mkdir -p "$V1/lib"
    for f in rds_backup_compliance_report.sh lib/collect.jq lib/backup.jq lib/merge.jq lib/backup_page.js; do git -C "$HERE/.." show "602abe2:$f" >"$V1/$f"; done
    chmod +x "$V1/rds_backup_compliance_report.sh"
    MOCK_SCENARIO=fleet "$V1/rds_backup_compliance_report.sh" -P dev -r eu-west-1 --save-data "$OUT/v100_dev.json" -F json >/dev/null 2>&1
    t mergev100 0 fleet --merge "$OUT/v100_dev.json" "$M/prod.json" -F json
    jqt mergev100 '[.accounts[].account] | sort == ["111111111111", "333333333333"]' "$OUT/mergev100.out"
    jqt mergev100 '.orphan_totals.orphaned == 3' "$OUT/mergev100.out"
fi
if git -C "$HERE/.." cat-file -e 61a6cd9 2>/dev/null; then   # v1.1.0 save-data (no orphans) still merges
    V11="$OUT/v110"; mkdir -p "$V11/lib"
    for f in rds_backup_compliance_report.sh lib/collect.jq lib/backup.jq lib/merge.jq lib/backup_page.js; do git -C "$HERE/.." show "61a6cd9:$f" >"$V11/$f"; done
    chmod +x "$V11/rds_backup_compliance_report.sh"
    MOCK_SCENARIO=fleet "$V11/rds_backup_compliance_report.sh" -P nonprod -r ap-south-1 --save-data "$OUT/v110_nonprod.json" -F json >/dev/null 2>&1
    jqt v110file 'has("orphans") | not' "$OUT/v110_nonprod.json"
    t mergev110 0 fleet --merge "$OUT/v110_nonprod.json" "$M/dev.json" -F csv,html -o "$OUT/m110"
    chk "v1.1.0 merge: html + orphaned csv (dev only)" bash -c "compgen -G '$OUT/m110/*.html' >/dev/null && test \"\$(tail -n +2 $OUT/m110/*_orphaned_snapshots.csv | cut -d, -f3 | tr -d '\"')\" == dev-scratch-final"
fi
if git -C "$HERE/.." cat-file -e b2f6c70 2>/dev/null; then   # v1.2.1 save-data (no settings / plan fields) still merges, new fields blank
    V12="$OUT/v121"; mkdir -p "$V12/lib"
    for f in rds_backup_compliance_report.sh lib/collect.jq lib/backup.jq lib/merge.jq lib/backup_page.js; do git -C "$HERE/.." show "b2f6c70:$f" >"$V12/$f"; done
    chmod +x "$V12/rds_backup_compliance_report.sh"
    MOCK_SCENARIO=fleet "$V12/rds_backup_compliance_report.sh" -P prod -r us-east-1 --save-data "$OUT/v121_prod.json" -F json >/dev/null 2>&1
    jqt v121file '.schema_version == 1 and ([.resources[] | has("backup_window")] | any | not)' "$OUT/v121_prod.json"
    t mergev121 0 fleet --merge "$OUT/v121_prod.json" "$M/dev.json" -F json
    rowt mergev121 orders-aurora-pg15 '.settings.backup_window == "" and .settings.copy_tags == "" and .settings.plans == "" and .settings.weekly_retention == "35d" and .status == "COMPLIANT"'
    rowt mergev121 dev-aurora-mysql '.settings.backup_window == "03:00-03:30" and (.warnings | test("14d"))'
    t mergev121h 0 fleet --merge "$OUT/v121_prod.json" "$M/dev.json" -F csv,html -o "$OUT/m121"
    chk "v1.2.1 merge: html + csv written" bash -c "compgen -G '$OUT/m121/*.html' >/dev/null && compgen -G '$OUT/m121/*[0-9].csv' >/dev/null"
fi
t mergedir 0 fleet --merge "$M" -o "$OUT/all accounts.html"
chk "merge -o FILE.html written" test -s "$OUT/all accounts.html"
# v1.4.1: same identifiers in a second account (one resource with no backups at all) for the cross-tab link checks
sed 's/111111111111/444444444444/g' "$M/prod.json" | jq '.resources[0].snapshots = []' >"$OUT/dup444.json"
t mergedup 0 fleet --merge "$M/prod.json" "$OUT/dup444.json" -o "$OUT/dup ids.html"
chk "merge with duplicate identifiers written" test -s "$OUT/dup ids.html"
chk "merged html lists 3 accounts in title" grep -q '<title>RDS backup compliance - 111111111111, 222222222222, 333333333333</title>' "$OUT/all accounts.html"
t mergecsv 0 fleet --merge "$M" -F csv,html -o "$OUT/mc"
chk "merged orphaned csv: 5 rows" test "$(tail -n +2 "$OUT"/mc/*_orphaned_snapshots.csv | grep -c .)" == 5
chk "merged csv name has all accounts" compgen -G "$OUT/mc/rds_backup_compliance_111111111111_222222222222_333333333333_*.csv" >/dev/null
echo '{"x":1}' >"$OUT/notdata.json"; t mergebad 3 fleet --merge "$OUT/notdata.json"
t mergemissing 3 fleet --merge "$OUT/nope.json"
echo 'not json' >"$OUT/garbage.json"; t mergegarbage 3 fleet --merge "$OUT/garbage.json"
# Git Bash: jq.exe writes CRLF
CR="$OUT/crjq"; mkdir -p "$CR"; REALJQ="$(command -v jq)"
printf '#!/usr/bin/env bash\n"%s" "$@" | sed "s/$/\\r/"\nexit "${PIPESTATUS[0]}"\n' "$REALJQ" >"$CR/jq"; chmod +x "$CR/jq"
PATH="$CR:$PATH" t crlf 0 fleet --merge "$M" -F json
jqt crlf '.rows | length == 11' <(tr -d '\r' <"$OUT/crlf.out")
PATH="$CR:$PATH" t crlfhtml 0 fleet --merge "$M" -o "$OUT/cr.html"
chk "CRLF jq: html written" grep -q 'orders-aurora-pg15' "$OUT/cr.html"

echo "== browser"
if command -v node >/dev/null && [[ -x "${CHROME:-/usr/bin/google-chrome}" ]] && node -e 'require("puppeteer-core")' 2>/dev/null; then
    LH=("$HTML" "$OUT/all accounts.html" "$OUT/dup ids.html"); i=0
    for h in "${LH[@]:0:2}"; do
        cmp=""; [[ "$h" == "$HTML" ]] && cmp="$CSV"
        res="$(CSV_CMP="$cmp" node "$HERE/browser_check.js" "$h" ${SHOTS:+"$SHOTS"} 2>&1)"; rc=$?
        [[ -n "$cmp" && $rc -eq 0 ]] && { grep -q '"checks":[0-9]' <<<"$res" && ok "browser: HTML CSV export compared with $(basename "$CSV")"; }
        if [[ $rc -eq 0 ]]; then ok "browser: $(basename "$h") $res"; else bad "browser: $(basename "$h") $res"; fi
        SHOTS="${SHOTS:+$SHOTS/merged}"
    done
    SHOTS="${SHOTS%%/merged*}"
    for h in "${LH[@]}"; do   # v1.4.1 cross-tab links, Back button, deep links, duplicate identifiers, empty state
        sd=""; [[ -n "$SHOTS" ]] && sd="$SHOTS/links_$i"; i=$((i + 1))
        res="$(node "$HERE/link_check.js" "$h" ${sd:+"$sd"} 2>&1)"; rc=$?
        if [[ $rc -eq 0 ]]; then ok "links: $(basename "$h") $res"; else bad "links: $(basename "$h") $res"; fi
    done
else echo "  skip browser check (node + puppeteer-core + Chrome not found)"; fi

echo "== v1.2.1: tampered --merge file cannot inject HTML/JS (M2)"
XP='"><img src=x data-xss=1 onerror="window.__xss=1">'
XD="$OUT/xss in"; mkdir -p "$XD"
jq --arg x "$XP" '.resources |= map(.snapshots |= map(.kind += $x))' "$M/prod.json" >"$XD/prod.json"
chk "xss: tampered file really carries the payload" grep -q 'data-xss' "$XD/prod.json"
t xss 0 fleet --merge "$XD/prod.json" -F html -o "$OUT/xss out"
XH="$(ls "$OUT/xss out"/*.html 2>/dev/null | head -1)"
chk "xss: report written" test -s "$XH"
if command -v node >/dev/null 2>&1 && [[ -x "${CHROME:-/usr/bin/google-chrome}" ]] && NODE_PATH="${NODE_PATH:-}" node -e 'require("puppeteer-core")' 2>/dev/null; then
    res="$(node "$HERE/xss_check.js" "$XH" 2>&1)"; rc=$?
    chk "xss: headless Chrome, no payload executed or injected ${res:0:300}" test "$rc" -eq 0
else echo "  skip xss browser check (node + puppeteer-core on NODE_PATH + Chrome not found)"; fi

AFTER="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"
chk "nothing written into the repo" test "$BEFORE" == "$AFTER"
echo; echo "passed $PASS, failed $FAIL"; (( FAIL == 0 ))
