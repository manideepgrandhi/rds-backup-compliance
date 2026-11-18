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
if [[ -e "$HERE/../compliance_exceptions.conf" ]]; then   # auto-loaded from the script folder and would change results
    echo "GUARD: $HERE/../compliance_exceptions.conf exists; the tests would load it. Move it away and re-run."; exit 2; fi
SHIPPED="$HERE/../rds_backup_compliance_report.conf"   # v1.7.1: the one settings file, tracked and required
[[ -r "$SHIPPED" ]] || { echo "GUARD: $SHIPPED is missing (it ships with the script)"; exit 2; }
BEFORE="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"
trap '(( KEEP )) && echo "kept $OUT" || rm -rf -- "$OUT"' EXIT
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
# BASECONF: the shipped conf with the v1.7.0 behaviour for scope / output (no all-regions, text to the screen, no log,
# no manual audit, no retention, no exempt engines, no account names), so every older test keeps its meaning.
# Every run passes --config "$BASECONF" first; a test's own --config (given later) wins.
BASECONF="$OUT/base.conf"
sed -E 's/^all-regions=.*/all-regions=no/; s/^format=.*/format=text/; s/^output-dir=.*/output-dir=/; s/^log-file=.*/log-file=/;
        s/^manual-older-than=.*/manual-older-than=/; s/^keep-reports=.*/keep-reports=0/; s/^replica-exempt-engines=.*/replica-exempt-engines=/;
        /^[0-9]{12} *=/d' "$SHIPPED" >"$BASECONF"
# mkconf FILE [crlf] LINE...: a complete settings file = BASECONF with each LINE (key=value in any key spelling, a
# comment, or an account line) replacing the base line of the same setting; crlf writes Windows line ends.
mkconf() { local f="$1" l k crlf=0; shift; [[ "${1:-}" == crlf ]] && { crlf=1; shift; }
           cp "$BASECONF" "$f"
           for l in "$@"; do
               if [[ "$l" =~ ^[[:space:]]*([A-Za-z_-]+)[[:space:]]*= ]]; then k="${BASH_REMATCH[1]//_/-}"; k="${k,,}"; sed -i "/^${k}=/d" "$f"; fi
               printf '%s\n' "$l" >>"$f"
           done
           (( crlf )) && sed -i 's/$/\r/' "$f"; return 0; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
t() { local name="$1" exp="$2" scen="$3"; shift 3
      MOCK_SCENARIO="$scen" "$SCRIPT" --config "$BASECONF" "$@" >"$OUT/$name.out" 2>"$OUT/$name.err"; local rc=$?
      if [[ "$rc" == "$exp" ]]; then ok "$name (rc=$rc)"; else bad "$name: rc=$rc expected $exp"; tail -3 "$OUT/$name.err" | sed 's/^/       /'; fi; }
has()  { grep -qE -- "$3" "$OUT/$1.$2" && ok "$1 $2 has /$3/" || bad "$1 $2 lacks /$3/"; }
hasnt(){ grep -qE -- "$3" "$OUT/$1.$2" && bad "$1 $2 unexpectedly has /$3/" || ok "$1 $2 lacks /$3/"; }
chk()  { local d="$1"; shift; "$@" && ok "$d" || bad "$d"; }
jqt()  { jq -e "$2" "$3" >/dev/null 2>&1 && ok "$1: $2" || bad "$1: $2"; }
rowt() { jq -e --arg i "$2" ".rows[] | select(.identifier == \$i) | $3" "$OUT/$1.out" >/dev/null 2>&1 && ok "$1 $2: $3" \
           || bad "$1 $2: $3 (got $(jq -c --arg i "$2" '.rows[] | select(.identifier == $i) | {status, gaps, global_role}' "$OUT/$1.out" 2>/dev/null))"; }
ncalls() { wc -l <"$MOCK_LOG" 2>/dev/null | tr -d ' ' || echo 0; }

echo "== CLI"
t version 0 fleet --version; has version out '1\.7\.2'
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
# the shipped conf itself (as --config): with the scope / output values overridden on the CLI, results match the base
( cd "$OUT" && t shipped 0 fleet -P prod -r us-east-1,us-west-2 -F json -o '' -l '' --manual-older-than '' --replica-exempt-engines '' --config "$SHIPPED" )
chk "shipped conf: same thresholds and statuses as the v1.7.0 defaults" bash -c "diff <(jq -S '{thresholds,totals,rows:[.rows[]|{identifier,status}]}' '$OUT/fleet.out') <(jq -S '{thresholds,totals,rows:[.rows[]|{identifier,status}]}' '$OUT/shipped.out')"
jqt shipped '.accounts[0].name == "prod-payments"' "$OUT/shipped.out"
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
has fleettxt out '^RDS backup compliance - account prod-core \(111111111111\)$'; has fleettxt out 'UTC / .* IST'
chk "text header has no region names" bash -c "head -4 '$OUT/fleettxt.out' | grep -qvE 'us-east-1' && ! head -4 '$OUT/fleettxt.out' | grep -q us-east-1"

echo "== read-only"
chk "only read-only AWS operations were called" bash -c "jq -r '[.[] | select(startswith(\"--\") | not)][1] // \"\"' '$MOCK_LOG' | sort -u | grep -vE '^(describe-|list-|get-caller-identity|get$|--version)' | grep -q . && exit 1 || exit 0"
n0="$(ncalls)"; t dry 0 fleet -P prod -r us-east-1 --dry-run
chk "dry-run calls nothing" test "$(ncalls)" == "$n0"; has dry out 'DRY-RUN: aws rds describe-db-clusters'; has dry out 'DRY-RUN: aws iam list-account-aliases'

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
HDR+=',"retention_mismatch_count","retention_mismatch","excess_daily","excess_weekly","excess_monthly","excess","over_retention_count","over_retention","counted_in_compliance_pct","pitr_enabled","pitr_since_utc","account_name"'
chk "csv header" grep -qxF "$HDR" "$CSV"
# v1.4.0 strict retention / excess / over-retention / compliance %
rowt fleet orders-aurora-pg15 '.weekly.have == .weekly.need and .weekly.have >= 4 and .retention_mismatch == "weekly point has 35d, expected 30d (x\(.weekly.have))" and .retention_mismatch_count == .weekly.have and .status == "COMPLIANT"'
rowt fleet orders-aurora-pg15 '[.recovery_points[] | select(.ret == 365 and .counted)] | length > 0 and all(.retention_mismatch == null and (.reason | test("retention 365d as expected$")))'
rowt fleet reports-pg '(.excess | startswith("weekly ")) and (.excess | endswith("expected 4-5)")) and (.excess_counts.weekly == 3 or .excess_counts.weekly == 4) and .excess_counts.daily == 0 and .excess_counts.monthly == 0 and .weekly.st == "OK"'
rowt fleet legacy-mysql '(.over_retention | test("^holds 7 automated backups for 7d retention; 2 older than 7d, oldest rds:legacy-mysql-")) and .over_retention_count == 2'
rowt fleet new-aurora-pg16 '.over_retention_count == 13 and .status == "NOT YET DUE"'
rowt fleet orders-dr-pg15 '.excess_counts.weekly == null and .excess == "" and .over_retention == "" and .retention_mismatch == ""'
has fleettxt out '^Compliance: 25% \(1 of 4\), 2 not yet due not counted$'
chk "csv has 8 rows + header" test "$(wc -l <"$CSV")" -eq 9
chk "csv: no yearly column at yearly=0" bash -c "! head -1 '$CSV' | grep -q yearly"
chk "csv: not_yet_due + full on" bash -c "grep '\"fresh-pg\"' '$CSV' | grep -q 'daily full on'"
csvq() { python3 -c 'import csv,sys; rows=list(csv.DictReader(open(sys.argv[1], encoding="utf-8"))); sys.exit(0 if eval(sys.argv[2]) else 1)' "$@"; }
csvq "$CSV" 'all(r["counted_in_compliance_pct"] == ("no" if r["status"] == "NOT YET DUE" else "yes") for r in rows) and [r["excess_weekly"] for r in rows if r["identifier"] == "reports-pg"][0] in ("3","4") and [r["excess_weekly"] for r in rows if r["identifier"] == "orders-dr-pg15"] == [""]' && ok "csv: excess / compliance columns" || bad "csv: excess / compliance columns"
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
rowt fleet orders-aurora-pg15 '.weekly.have as $w | ([.recovery_points[] | select(.ret == 35 and .counted)] | length) == $w and ([.recovery_points[] | select(.ret == 35 and (.reason | test("is not within ±1d of a checked Saturday") | not))] | all(.counted and (.reason | test("^weekly: counts for Sat [0-9]{2} [A-Z][a-z]{2}, but weekly point has 35d, expected 30d$")) and .retention_mismatch == "weekly point has 35d, expected 30d"))'
rowt fleet orders-aurora-pg15 '.recovery_points | all(has("date") and has("ret") and has("class") and has("counted") and has("reason")) and (.[0].date | test("^20[0-9]{2}-[0-9]{2}-[0-9]{2} [A-Z][a-z]{2}$"))'
chk "output block: no // or ./ in paths" bash -c "! sed -n '/^Output/,\$p' '$OUT/files.err' | grep -qE '//|/\\./|~'"
mkdir -p "$OUT/o2/sub"; ( cd "$OUT/o2" && t relout 0 fleet -P prod -r us-east-1 -F csv -o ./sub//../sub/ )
has relout err "^Output \\(3 files\\):\$"
has relout err "^  $OUT/o2/sub/rds_backup_compliance_111111111111_[0-9_]+_backups\\.csv\$"
chk "csv has every status" bash -c "grep -q '\"COMPLIANT\"' '$CSV' && grep -q '\"NON-COMPLIANT\"' '$CSV' && grep -q '\"NOT YET DUE\"' '$CSV'"
chk "backups csv has manual, automated, backup kinds" bash -c "grep -q ',\"manual\",' '$BCSV' && grep -q ',\"automated\",' '$BCSV' && grep -q ',\"backup\",' '$BCSV'"
chk "backups csv has IST column and classes" bash -c "head -1 '$BCSV' | grep -q created_ist && grep -q '\"weekly\"' '$BCSV' && grep -q '\"monthly\"' '$BCSV' && grep -q '\"mismatch\"' '$BCSV'"
chk "backups csv header = in-page export order" bash -c "head -1 '$BCSV' | tr -d '\"\r' | grep -qx 'account_id,region,identifier,type,kind,snapshot_or_recovery_point,created_utc,created_ist,age_days,status,size_gb,rule,retention_days,expires_utc,vault,source_status,backup_type,schedule'"
chk "backups csv: automated rule daily, manual rule empty, age_days numeric" bash -c "grep ',\"automated\",' '$BCSV' | head -1 | grep -q ',\"daily\",' && grep ',\"manual\",' '$BCSV' | head -1 | grep -qE ',\"[0-9]+\",\"available\",\"100\",\"\",\"\",'"
chk "backups csv: no EC2 recovery point" bash -c "! grep -q ami-0abc '$BCSV'"
chk "html: no empty region (ap-south-1)" bash -c "! grep -qE 'ap-south-1' '$HTML'"
chk "html: no region names above the tabs" bash -c "! sed -n '1,/class=\"tabs\"/p' '$HTML' | grep -qE '(us|eu|ap|ca)-[a-z]+-[0-9]'"
chk "html: account in title" grep -qE '<title>RDS backup compliance - (prod-core \(111111111111\)|111111111111)</title>' "$HTML"
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
chk "backups csv: orphaned flag rows" bash -c "grep -q '\"crm-mysql\",\"instance\",\"manual\",\"crm-mysql-before-delete\",.*\"ORPHANED\",\"manual\",\"not_counted\"$' '$BCSV' && grep -q '\"vendor-share-1\",.*\"SHARED\",\"manual\",\"not_counted\"$' '$BCSV'"
chk "describe-db-*-snapshots called with --include-shared" bash -c "grep 'describe-db-snapshots' '$MOCK_LOG' | tail -1 | grep -q include-shared"
chk "snapshots read in a region without databases (ca-central-1)" bash -c "grep 'describe-db-cluster-snapshots' '$MOCK_LOG' | grep -q ca-central-1"
has files err '4 orphaned snapshots, 1.8 TB, ~\$38/month \(estimate\)'
t price 0 fleet -P prod -r us-east-1 -F json --snapshot-price-per-gb 0.05
jqt price '[.orphaned_snapshots[] | select(.id == "analytics-aurora-final")][0].est_monthly_usd == 25 and .orphan_totals.price_per_gb_month == 0.05' "$OUT/price.out"
t pricebad 1 fleet -P prod -r us-east-1 --snapshot-price-per-gb cheap
mkconf "$OUT/price conf.conf" crlf 'snapshot_price_per_gb = 0.1' 'region=us-east-1' 'format=json'
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
# v1.6.1: with global clusters unreadable a plain cluster stays unknown (not primary); instances are never global, so primary
t gdeny2 0 globaldeny -P prod -r us-east-1 -F json
rowt gdeny2 billing-aurora-mysql '.global_role == "unknown"'
rowt gdeny2 legacy-mysql '.global_role == "primary"'
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
t yearly1h 0 fleet -P prod -r us-east-1 -i orders-* --yearly 1 -F html -o "$OUT/y1"; chk "html: Yearly shown at yearly=1" bash -c "grep -q 'Yearly: last 1<' \"$OUT\"/y1/*.html"
t hdrcfg 0 fleet -P prod -r us-east-1 --daily 9 --weekly 3 --weekly-retention-days 33 --monthly 6 --monthly-rule first-mon -F html -o "$OUT/hc"; chk "html header bullets follow a changed config" bash -c "f=\$(ls \"$OUT\"/hc/*.html); grep -q \">Daily: last 9 days, newest within [0-9]*h, retention [0-9]*d<\" \"\$f\" && grep -q \">Weekly: every Saturday, last 3, retention 33d \" \"\$f\" && grep -q \">Monthly: first Monday, last 6 months, retention \" \"\$f\" && ! grep -q h-yearly \"\$f\""
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
mkconf "$OUT/my conf.conf" crlf 'weekly = 6' '# comment' 'region=us-east-1' 'identifier = orders-*' 'format=json'
t conf 0 fleet -P prod --config "$OUT/my conf.conf"; rowt conf orders-aurora-pg15 '.weekly.need == 6'
t confcli 0 fleet -P prod --config "$OUT/my conf.conf" --weekly 4; rowt confcli orders-aurora-pg15 '.weekly.need == 4'
# v1.4.0 strict retention settings (CLI + config, both key spellings)
t wret 0 fleet -P prod -r us-east-1 -i orders-* --weekly-retention-days 35 -F json; rowt wret orders-aurora-pg15 '.retention_mismatch == "" and .weekly.have == .weekly.need and .weekly.have >= 4'
t wtol 0 fleet -P prod -r us-east-1 -i orders-* --retention-tolerance-days 5 -F json; rowt wtol orders-aurora-pg15 '.retention_mismatch == ""'
t mret 0 fleet -P prod -r us-east-1 -i orders-* --monthly-retention-days 400 -F json
rowt mret orders-aurora-pg15 '(.retention_mismatch | test("monthly point has 365d, expected 400d \\(x12\\)")) and .monthly.have == 12 and .status == "COMPLIANT"'
t dret 0 fleet -P prod -r us-east-1 -i reports-pg --daily-retention-days 2 -F json; rowt dret reports-pg '.retention_mismatch | test("^daily retention 3d, expected 2d")'
mkconf "$OUT/ret.conf" 'WEEKLY_RETENTION_DAYS=35' 'monthly_retention_days=365' 'retention-tolerance-days=1' 'region=us-east-1' 'identifier=orders-*' 'format=json'
t retconf 0 fleet -P prod --config "$OUT/ret.conf"; rowt retconf orders-aurora-pg15 '.retention_mismatch == ""'
t badret 1 fleet -P prod --weekly-retention-days x
mkconf "$OUT/bad.conf" 'bogus=1'; t badconf 1 fleet --config "$OUT/bad.conf"
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
mkconf "$OUT/par.conf" 'profile = prod' 'all-regions = yes' 'parallel = 2' 'format = json'; t parconf 0 fleet --config "$OUT/par.conf"
has parconf err 'up to 2 at a time'
t parcrash 0 regioncrash -P prod -A -F json
jqt parcrash '.regions[] | select(.region == "us-west-2") | .status == "error" and (.errors[0] | startswith("region scan failed"))' "$OUT/parcrash.out"
jqt parcrash '[.rows[] | select(.region == "us-east-1")] | length == 6' "$OUT/parcrash.out"
rowt parcrash orders-aurora-pg15 '.status == "COMPLIANT"'
has parcrash err '\[ERROR\] \[5/5\] us-west-2: failed'
has parcrash err '5 regions scanned, 2 empty: ap-south-1, eu-west-1; 1 failed: us-west-2$'
has parcrash err '1 of 5 region\(s\) failed'
t parcrashnc 5 regioncrash -P prod -A -F json --fail-on-noncompliant
mkdir -p "$OUT/ptmp"; TMPDIR="$OUT/ptmp" MOCK_SCENARIO=regioncrash "$SCRIPT" --config "$BASECONF" -P prod -A -F json >/dev/null 2>&1
chk "parallel: temp work dir removed by the trap" bash -c "[[ -z \"\$(ls -A '$OUT/ptmp')\" ]]"
unset MOCK_NOW

echo "== merge (offline)"
M="$OUT/merge dir"; mkdir -p "$M"
MOCK_SCENARIO=fleet "$SCRIPT" --config "$BASECONF" -P prod -r us-east-1,us-west-2 --save-data "$M/prod.json" -F json >/dev/null 2>&1
MOCK_SCENARIO=fleet "$SCRIPT" --config "$BASECONF" -P nonprod -r ap-south-1 --save-data "$M/nonprod.json" -F json >/dev/null 2>&1
MOCK_SCENARIO=fleet "$SCRIPT" --config "$BASECONF" -P dev -r eu-west-1 --save-data "$M/dev.json" -F json >/dev/null 2>&1
jq '.collected_epoch -= 86400 | .accounts[0].collected_epoch -= 86400 | .resources |= .[:2]' "$M/prod.json" >"$OUT/prod_old.json"
n0="$(ncalls)"
t merge 0 fleet --merge "$M/prod.json" "$M/nonprod.json" "$M/dev.json" "$OUT/prod_old.json" -F json
chk "merge made zero AWS calls" test "$(ncalls)" == "$n0"
jqt merge '[.accounts[].account] | sort == ["111111111111", "222222222222", "333333333333"]' "$OUT/merge.out"
jqt merge '.rows | length == 13' "$OUT/merge.out"
rowt merge erp-oracle '.pitr.on == true and (.pitr.since | test("^20[0-9]{2}-")) and .global_role == "primary"'
rowt merge payroll-sqlserver '.pitr.on == false'
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
chk "merged html lists 3 accounts in title" grep -qE '<title>RDS backup compliance - (prod-core \(111111111111\)|111111111111), 222222222222, 333333333333</title>' "$OUT/all accounts.html"
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
jqt crlf '.rows | length == 13' <(tr -d '\r' <"$OUT/crlf.out")
PATH="$CR:$PATH" t crlfhtml 0 fleet --merge "$M" -o "$OUT/cr.html"
chk "CRLF jq: html written" grep -q 'orders-aurora-pg15' "$OUT/cr.html"

echo "== v1.5.2: replica-exempt-engines + account names"
# Oracle replica without exemption: daily fails
t orex0 0 fleet -P dev -r eu-west-1 -F json
rowt orex0 erp-oracle-rr '.global_role == "replica" and .status == "NON-COMPLIANT" and .weekly.st == "N/A" and (.gaps | test("daily"))'
rowt orex0 erp-oracle '.global_role == "primary" and .status == "COMPLIANT"'
# v1.6.1: standalone / source instances show primary (never none); a replica of a Multi-AZ cluster is a replica
jqt orex0 '[.rows[] | select(.type == "instance")] | length > 0 and all(.global_role == "primary" or .global_role == "replica")' "$OUT/orex0.out"
jqt orex0 '[.rows[] | select(.global_role == "none")] | length == 0' "$OUT/orex0.out"
MOCK_REPLICA_OF_CLUSTER=1 t orexc 0 fleet -P dev -r eu-west-1 -F json
rowt orexc erp-oracle-rr '.global_role == "replica" and .status == "NON-COMPLIANT" and (.gaps | test("daily"))'
rowt orexc erp-oracle '.global_role == "primary" and .status == "COMPLIANT"'
MOCK_REPLICA_OF_CLUSTER=1 t orexc1 0 fleet -P dev -r eu-west-1 -F json --replica-exempt-engines 'oracle-*'
rowt orexc1 erp-oracle-rr '.global_role == "replica" and .status == "COMPLIANT" and .weekly.st == "N/A"'
# plain (non-global) Aurora cluster is primary, with no global cluster; statuses unchanged
t plainclu 0 fleet -P prod -r us-east-1 -F json
rowt plainclu billing-aurora-mysql '.type == "cluster" and .global_role == "primary" and .global_cluster == "" and .status == "NON-COMPLIANT"'
rowt plainclu legacy-mysql '.type == "instance" and .global_role == "primary" and .status == "NON-COMPLIANT"'
# older saved data (global_role "none") is shown as primary at merge time; a saved unknown stays unknown
jq '.resources |= map(if .id == "legacy-mysql" then .global_role = "none" elif .id == "billing-aurora-mysql" then .global_role = "unknown" else . end)' "$M/prod.json" >"$OUT/prod_none.json"
t oldnone 0 fleet --merge "$OUT/prod_none.json" -F json
rowt oldnone legacy-mysql '.global_role == "primary" and .status == "NON-COMPLIANT"'
rowt oldnone billing-aurora-mysql '.global_role == "unknown"'
# oracle-* exempts the replica only
t orex1 0 fleet -P dev -r eu-west-1 -F json --replica-exempt-engines 'oracle-*'
rowt orex1 erp-oracle-rr '.status == "COMPLIANT" and .daily.st == "N/A" and .weekly.st == "N/A" and .monthly.st == "N/A" and .gaps == ""'
rowt orex1 erp-oracle '.status == "COMPLIANT" and .daily.st == "OK"'
# aurora-* exempts shop-dr secondary; orders-dr already compliant; primary untouched
t aex 0 fleet -P prod -r us-east-1,us-west-2 -F json --replica-exempt-engines 'aurora-*'
rowt aex shop-dr-mysql '.status == "COMPLIANT" and .global_role == "secondary" and .daily.st == "N/A" and .weekly.st == "N/A" and .gaps == ""'
rowt aex orders-dr-pg15 '.status == "COMPLIANT" and .daily.st == "N/A"'
rowt aex orders-aurora-pg15 '.status == "COMPLIANT" and .global_role == "primary" and .daily.st == "OK"'
# without setting, shop-dr still fails daily (existing behaviour)
rowt fleet shop-dr-mysql '.status == "NON-COMPLIANT" and (.gaps | test("^daily"))'
# both globs via conf
mkconf "$OUT/ex.conf" 'replica-exempt-engines=oracle-*,aurora-*'
t exconf 0 fleet -P prod -P dev -r us-west-2,eu-west-1 -F json --config "$OUT/ex.conf"
rowt exconf shop-dr-mysql '.status == "COMPLIANT" and .daily.st == "N/A"'
rowt exconf erp-oracle-rr '.status == "COMPLIANT" and .daily.st == "N/A"'
# account names: alias for prod, denied for nonprod, empty for dev
AN="$OUT/an"; mkdir -p "$AN/a" "$AN/c" "$AN/d"
t an_alias 0 fleet -P prod -P nonprod -r us-east-1,ap-south-1 -F csv,json,text -o "$AN/a"
chk "alias: prod gets its alias, nonprod (AccessDenied) falls back silently" jq -e '[.accounts[] | {account, name}] | sort_by(.account) == [{account: "111111111111", name: "prod-core"}, {account: "222222222222", name: ""}]' "$AN"/a/*.json
hasnt an_alias err 'AccessDenied|list-account-aliases'
chk "alias: account_name is the last CSV column and filled" python3 -c 'import csv,sys,glob; fs=[f for f in glob.glob(sys.argv[1]+"/*.csv") if "_backups" not in f and "_orphaned" not in f and "_manual" not in f]; r=list(csv.reader(open(fs[0],encoding="utf-8-sig"))); h=r[0]; i=h.index("account_name"); assert i==len(h)-1; assert ("111111111111","prod-core") in {(x[0],x[i]) for x in r[1:]}, {(x[0],x[i]) for x in r[1:]}' "$AN/a"
chk "alias: json rows carry account_name" jq -e 'all(.rows[]; has("account_name")) and ([.rows[] | select(.account_id == "111111111111") | .account_name] | unique) == ["prod-core"]' "$AN"/a/*.json
chk "alias: text file shows name (number)" grep -q 'prod-core (111111111111)' "$AN"/a/*.txt
mkconf "$AN/n.conf" '111111111111 = prod-payments   # comment' '222222222222 = "np x"'
t an_cfg 0 fleet -P prod -P nonprod -r us-east-1,ap-south-1 -F json,html,text -o "$AN/c" --config "$AN/n.conf"
chk "config map wins over the alias" jq -e '[.accounts[] | .name] | sort == ["np x", "prod-payments"]' "$AN"/c/*.json
chk "html shows name (number)" grep -q 'prod-payments (111111111111)' "$AN"/c/*.html
MOCK_ALIAS_DENY=1 t an_deny 0 fleet -P prod -r us-east-1 -F json -o "$AN/d"
chk "alias denied: number only, no warning" jq -e '.accounts[0].name == ""' "$AN"/d/*.json
hasnt an_deny err 'AccessDenied|list-account-aliases'
# save-data carries name
jqt savedata '.accounts[0].name == "prod-core"' "$SD"

echo "== v1.5.3: HTML account filter / per-region / backups labels"
# Ensure embedded page JS builds name (number) labels (static string + runtime via browser_check when Chrome is present)
chk "page js: alabel helper present" grep -qF 'var alabel = function' "$HERE/../lib/backup_page.js"
chk "page js: f-acct uses alabel" grep -qE "opt\('f-acct', 'Account'.*alabel" "$HERE/../lib/backup_page.js"
chk "page js: b-acct uses alabel" grep -qE "bopt\('b-acct', 'Account'.*alabel" "$HERE/../lib/backup_page.js"
chk "page js: hay includes account_name" grep -qF 'r.account_name, ST(r).plans' "$HERE/../lib/backup_page.js"
chk "page js: per-region uses alabel" grep -qF 'line(esc(alabel(p[0]))' "$HERE/../lib/backup_page.js"
chk "page js: backups Account column uses alab" grep -qF 'esc(alab(x.r))' "$HERE/../lib/backup_page.js"

echo "== v1.5.4: eng_exempt engine match + global members sorted together"
# oracle-* must NOT blank Aurora secondary daily (the v1.5.2 jq bug)
t orex_aurora 0 fleet -P prod -r us-east-1,us-west-2 -F json --replica-exempt-engines 'oracle-*'
rowt orex_aurora shop-dr-mysql '.status == "NON-COMPLIANT" and .global_role == "secondary" and .daily.st == "FAIL" and (.gaps | test("daily"))'
rowt orex_aurora orders-dr-pg15 '.status == "COMPLIANT" and .global_role == "secondary" and .daily.st == "OK" and .daily.st != "N/A" and .weekly.st == "N/A"'
rowt orex_aurora orders-aurora-pg15 '.status == "COMPLIANT" and .global_role == "primary" and .daily.st == "OK"'
# oracle-* still exempts Oracle replica (eu-west-1), and Aurora secondary in same run stays evaluated
t orex_both 0 fleet -P prod -P dev -r us-west-2,eu-west-1 -F json --replica-exempt-engines 'oracle-*'
rowt orex_both erp-oracle-rr '.status == "COMPLIANT" and .daily.st == "N/A" and .weekly.st == "N/A"'
rowt orex_both shop-dr-mysql '.status == "NON-COMPLIANT" and .daily.st != "N/A" and (.gaps | test("daily"))'
rowt orex_both orders-dr-pg15 '.daily.st == "OK" and .daily.st != "N/A"'
# no exempt: secondary daily behaviour unchanged (already covered on fleet; re-assert)
rowt fleet orders-dr-pg15 '.daily.st == "OK" and .weekly.st == "N/A"'
rowt fleet shop-dr-mysql '.daily.st == "FAIL" or (.gaps | test("daily"))'
# aurora-* and combined globs still exempt (covered above as aex/exconf); re-run sanity
rowt aex shop-dr-mysql '.daily.st == "N/A"'
rowt exconf shop-dr-mysql '.daily.st == "N/A"'
rowt exconf erp-oracle-rr '.daily.st == "N/A"'
# Sort: orders-global primary immediately followed by its secondary; shop-dr after its global key
jqt fleet '([.rows[] | .identifier] | index("orders-aurora-pg15")) as $p | ([.rows[] | .identifier] | index("orders-dr-pg15")) as $s | $p != null and $s == ($p + 1)' "$OUT/fleet.out"
jqt fleet '[.rows[] | select(.account_id == "111111111111") | {id: .identifier, g: .global_cluster, role: .global_role, region}] | . as $r | ([range(0; length-1)] | all( . as $i | ($r[$i].g == "orders-global" and $r[$i].role == "primary" and $r[$i+1].g == "orders-global" and $r[$i+1].role == "secondary") or ($r[$i].g != "orders-global") or ($r[$i].role != "primary") ))' "$OUT/fleet.out"
# CSV / HTML use the same rows sort: primary then secondary for orders-global
t gsort 0 fleet -P prod -r us-east-1,us-west-2 -F csv,html -o "$OUT/gsort"
chk "csv: orders primary then secondary consecutive" python3 -c 'import csv,glob,sys; fs=[f for f in glob.glob(sys.argv[1]+"/*.csv") if "_backups" not in f and "_orphaned" not in f and "_manual" not in f]; r=list(csv.DictReader(open(fs[0],encoding="utf-8-sig"))); ids=[x["identifier"] for x in r]; i=ids.index("orders-aurora-pg15"); assert ids[i+1]=="orders-dr-pg15", ids; assert r[i]["global_role"]=="primary" and r[i+1]["global_role"]=="secondary"' "$OUT/gsort"
chk "html: orders primary row before secondary" python3 -c 'import glob,sys; h=open(glob.glob(sys.argv[1]+"/*.html")[0],encoding="utf-8").read(); assert h.find("orders-aurora-pg15") < h.find("orders-dr-pg15") and "orders-aurora-pg15" in h and "orders-dr-pg15" in h' "$OUT/gsort"
chk "version is 1.7.2" grep -qF 'SCRIPT_VERSION="1.7.2"' "$SCRIPT"

echo "== v1.6.0: compliance exceptions (--exceptions FILE / compliance_exceptions.conf)"
EX="$OUT/exc"; mkdir -p "$EX"; export RDS_BCR_EXC_NOW=1791000000   # "today" for the expiry dates only = 2026-10-03 UTC
cat >"$EX/ok.conf" <<'CONF'
# account_id | identifier | scope | expires | reason
111111111111 | legacy-mysql | backup | 2027-03-31 | Decommission in Q1 (CHG-1234)

111111111111 | reports-pg   | patch,backup | 2026-10-03 | Vendor app freeze | ticket A|B
  111111111111|Orders-Aurora-PG15|BACKUP|2027-01-01|<b>Old</b> migration window
111111111111 | shop-dr-mysql | backup | 2026-10-02 | =DR rebuild
111111111111 | gone-db | backup | 2027-01-01 | Retired server
111111111111 | billing-aurora-mysql | patch | 2027-01-01 | Patch-only exception (not applied by the backup tool)
CONF
t exc_base 0 fleet -P prod -A -F json
t exc_on 0 fleet -P prod -A -F json --exceptions "$EX/ok.conf"
EJ="$OUT/exc_on.out"; BJ="$OUT/exc_base.out"
jqt exc_base '.totals | .compliant == 2 and .non_compliant == 4 and .not_yet_due == 2 and .compliance.pct == 33 and (has("exceptions") | not)' "$BJ"
jqt exc_base 'all(.rows[]; has("exception") | not)' "$BJ"
jqt exc_on '.totals | .compliant == 4 and .non_compliant == 2 and .not_yet_due == 2 and .compliance.compliant == 4 and .compliance.of == 6 and .compliance.pct == 67' "$EJ"
jqt exc_on '[.rows[] | select(.exception == "yes") | [.identifier, .status, .actual_status]] | sort == [["legacy-mysql","COMPLIANT","NON-COMPLIANT"],["orders-aurora-pg15","COMPLIANT","COMPLIANT"],["reports-pg","COMPLIANT","NON-COMPLIANT"]]' "$EJ"
jqt exc_on '([.rows[] | select(.exception != "no") | {(.identifier): .exception_flag}] | add) == {"legacy-mysql": "", "orders-aurora-pg15": "no longer needed", "reports-pg": "expiring soon", "shop-dr-mysql": "exception expired"}' "$EJ"
jqt exc_on '.rows[] | select(.identifier == "shop-dr-mysql") | .exception == "expired" and .status == "NON-COMPLIANT"' "$EJ"
jqt exc_on '.rows[] | select(.identifier == "billing-aurora-mysql") | .exception == "no" and .status == "NON-COMPLIANT"' "$EJ"
jqt exc_on '.rows[] | select(.identifier == "reports-pg") | .exception_reason == "Vendor app freeze | ticket A|B" and .exception_expires == "2026-10-03"' "$EJ"
jqt exc_on '.totals.exceptions | .entries == 5 and .applied == 3 and .attention == 2 and .expiring_soon == 1 and .no_longer_needed == 1 and .expired == 1 and .unmatched == [{line: 7, account: "111111111111", identifier: "gone-db"}]' "$EJ"
chk "exc: other rows unchanged vs no-file run" bash -c "diff <(jq -S '[.rows[] | select(.exception == \"no\") | del(.exception, .exception_reason, .exception_expires, .exception_flag, .actual_status)]' '$EJ') <(jq -S '[.rows[] | select(.identifier | IN(\"legacy-mysql\",\"orders-aurora-pg15\",\"reports-pg\",\"shop-dr-mysql\") | not)]' '$BJ')"
has exc_on err 'ok\.conf:7 \(111111111111 gone-db\) matched no server'
has exc_on err 'shop-dr-mysql expired on 2026-10-02'
has exc_on err 'Exceptions \(backup\): 3 applied \(counted as COMPLIANT\), 2 expiring soon or no longer needed, 1 expired, 1 unmatched'
has exc_on err 'non-compliant: 2$'
t exc_files 0 fleet -P prod -A -F csv,html,txt --exceptions "$EX/ok.conf" -o "$EX/on"
EC="$(ls "$EX"/on/rds_backup_compliance_*[0-9].csv)"
chk "exc csv: 5 new columns at the end" bash -c "head -1 '$EC' | grep -q ',\"account_name\",\"exception\",\"exception_reason\",\"exception_expires\",\"exception_flag\",\"actual_status\"\$'"
chk "exc csv: status COMPLIANT (EXCEPTION) on 3 rows" test "$(grep -c '"COMPLIANT (EXCEPTION)"' "$EC")" -eq 3
chk "exc csv: expired row + formula guard" grep -q '"expired","'"'"'=DR rebuild","2026-10-02","exception expired","NON-COMPLIANT"$' "$EC"
chk "exc csv: counted_in_compliance_pct yes for excepted rows" python3 -c 'import csv,sys; r=[x for x in csv.DictReader(open(sys.argv[1],encoding="utf-8-sig")) if x["exception"]=="yes"]; assert len(r)==3 and all(x["counted_in_compliance_pct"]=="yes" for x in r)' "$EC"
ET="$(ls "$EX"/on/*.txt)"
chk "exc text: summary + Exceptions section" bash -c "grep -q 'compliant 4 (incl. 3 exceptions), non-compliant 2' '$ET' && grep -q '^Exceptions: 3 applied (counted as compliant); expiring soon or no longer needed: 2; expired: 1' '$ET' && grep -q 'line 7: 111111111111 gone-db matched no server' '$ET' && grep -q 'COMPLIANT (EXCEPTION)' '$ET'"
EH="$(ls "$EX"/on/*.html)"
chk "exc html: exceptions in page data, reason escaped" bash -c "grep -q '\"exc\":{\"entries\":5' '$EH' && ! grep -q '<b>Old</b>' '$EH'"
t exc_nc 0 fleet -P prod -A -F json --non-compliant-only --exceptions "$EX/ok.conf"
jqt exc_nc '[.rows[].identifier] | sort == ["billing-aurora-mysql","shop-dr-mysql"]' "$OUT/exc_nc.out"
jqt exc_nc '.totals.exceptions.unmatched | map(.identifier) == ["gone-db"]' "$OUT/exc_nc.out"
jq -r '.rows[] | select(.status == "NON-COMPLIANT") | "\(.account_id) | \(.identifier) | backup | 2027-01-01 | all non-compliant"' "$BJ" >"$EX/all.conf"
t exc_fail 0 fleet -P prod -A -F json --fail-on-noncompliant --exceptions "$EX/all.conf"
jqt exc_fail '.totals.non_compliant == 0 and .totals.exceptions.applied == 4' "$OUT/exc_fail.out"
t exc_fail5 5 fleet -P prod -A -F json --fail-on-noncompliant --exceptions "$EX/ok.conf"
# validation: every bad line stops the run with file:line, before any AWS call
xbad() { local name="$1" want="$2" line="$3"; printf '# header\n111111111111 | good-db | backup | 2027-01-01 | ok\n%s\n' "$line" >"$EX/$name.conf"
         : >"$MOCK_LOG"; t "$name" 1 fleet -P prod -r us-east-1 --exceptions "$EX/$name.conf"
         has "$name" err "Exceptions .*$name\\.conf:3: .*$want"; chk "$name: no AWS call made" test ! -s "$MOCK_LOG"; }
xbad exc_missing 'missing field' '111111111111 | db1 | backup |  | r'
xbad exc_fields 'expected 5 fields' '111111111111 | db1 | backup | 2027-01-01'
xbad exc_acct 'account_id must be 12 digits' '1111111111x1 | db1 | backup | 2027-01-01 | r'
xbad exc_scope 'scope must be patch, backup or patch,backup' '111111111111 | db1 | backups | 2027-01-01 | r'
xbad exc_date 'is not a valid date' '111111111111 | db1 | backup | 2027-02-29 | r'
xbad exc_date2 'expires must be a date YYYY-MM-DD' '111111111111 | db1 | backup | 01-01-2027 | r'
xbad exc_glob 'is not a DB instance / cluster identifier' '111111111111 | * | backup | 2027-01-01 | r'
xbad exc_dup 'duplicate entry for 111111111111 GOOD-db \(backup\), already on line 2' '111111111111 | GOOD-db | patch,backup | 2027-01-01 | r'
printf '111111111111 | db1 | backup | 2028-02-29 | leap day ok\n111111111111 | db1 | patch | 2027-01-01 | other scope, not a duplicate\n' >"$EX/nodup.conf"
t exc_nodup 0 fleet -P prod -r us-east-1 -F json --exceptions "$EX/nodup.conf"
t exc_nofile 1 fleet -P prod -r us-east-1 --exceptions "$EX/does-not-exist.conf"; has exc_nofile err 'Exceptions file not readable'
# default: compliance_exceptions.conf next to the script (a copy of the tool), absent = off; config key exceptions =
TC="$OUT/toolcopy"; mkdir -p "$TC"; cp -r "$HERE/../rds_backup_compliance_report.sh" "$HERE/../lib" "$TC/"; cp "$BASECONF" "$TC/rds_backup_compliance_report.conf"
MOCK_SCENARIO=fleet "$TC/rds_backup_compliance_report.sh" -P prod -A -F json >"$EX/def0.json" 2>/dev/null
jqt exc_def0 '.totals | has("exceptions") | not' "$EX/def0.json"
cp "$EX/ok.conf" "$TC/compliance_exceptions.conf"
MOCK_SCENARIO=fleet "$TC/rds_backup_compliance_report.sh" -P prod -A -F json >"$EX/def1.json" 2>"$EX/def1.err"
jqt exc_def1 '.totals.exceptions.applied == 3' "$EX/def1.json"
mkconf "$EX/c.conf" "exceptions = $EX/all.conf"
t exc_conf 0 fleet -P prod -A -F json --config "$EX/c.conf"
jqt exc_conf '.totals.non_compliant == 0 and .totals.exceptions.applied == 4' "$OUT/exc_conf.out"
# --save-data file is the same with and without exceptions; --merge applies them at report time
MOCK_NOW="$(date -u +%s)"; export MOCK_NOW
MOCK_SCENARIO=fleet "$SCRIPT" --config "$BASECONF" -P prod -A --save-data "$EX/sd0.json" -F json >/dev/null 2>&1
MOCK_SCENARIO=fleet "$SCRIPT" --config "$BASECONF" -P prod -A --save-data "$EX/sd1.json" -F json --exceptions "$EX/ok.conf" >/dev/null 2>&1
unset MOCK_NOW
chk "exc: --save-data file identical with and without exceptions" bash -c "diff <(jq -S 'del(.collected_epoch, .collected_at, .accounts[].collected_epoch)' '$EX/sd0.json') <(jq -S 'del(.collected_epoch, .collected_at, .accounts[].collected_epoch)' '$EX/sd1.json')"
chk "exc: --save-data file has no exception fields" bash -c "! grep -qi exception '$EX/sd1.json'"
n0="$(ncalls)"; t exc_merge 0 fleet --merge "$EX/sd0.json" -F json --exceptions "$EX/ok.conf"
chk "exc merge: zero AWS calls" test "$(ncalls)" == "$n0"
jqt exc_merge '.totals.compliant == 4 and .totals.exceptions.applied == 3' "$OUT/exc_merge.out"
if command -v node >/dev/null 2>&1 && [[ -x "${CHROME:-/usr/bin/google-chrome}" ]] && NODE_PATH="${NODE_PATH:-}" node -e 'require("puppeteer-core")' 2>/dev/null; then
    res="$(node "$HERE/browser_exceptions.js" "$EH" ${SHOTS:+"$SHOTS/exceptions"} 2>&1)"; rc=$?
    chk "browser: exception column, quick filter with other filters, pop-up, CSV ($(jq -r '.checks' <<<"$res" 2>/dev/null) checks) ${res:0:400}" test "$rc" -eq 0
    res="$(node "$HERE/browser_check.js" "$EH" 2>&1)"; rc=$?
    chk "browser: existing checks still pass on a report with exceptions ${res:0:300}" test "$rc" -eq 0
else echo "  skip exceptions browser check (node + puppeteer-core on NODE_PATH + Chrome not found)"; fi
unset RDS_BCR_EXC_NOW

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

echo "== v1.7.1: one settings file (required, complete, each key once) and --check-config"
# every case runs a COPY of the tool in a temp folder (cwd = that folder, so ./reports lands there, never in the repo)
AC="$OUT/autoconf"; mkdir -p "$AC"; cp -r "$HERE/../rds_backup_compliance_report.sh" "$HERE/../lib" "$AC/"
ACS="$AC/rds_backup_compliance_report.sh"; ACF="$AC/rds_backup_compliance_report.conf"
act() { local name="$1" exp="$2"; shift 2   # like t, but runs the temp copy (fleet scenario) from its own folder
        ( cd "$AC" && MOCK_SCENARIO="${SCEN:-fleet}" "$ACS" "$@" >"$OUT/$name.out" 2>"$OUT/$name.err" ); local rc=$?
        if [[ "$rc" == "$exp" ]]; then ok "$name (rc=$rc)"; else bad "$name: rc=$rc expected $exp"; tail -3 "$OUT/$name.err" | sed 's/^/       /'; fi; }
# the shipped file: notes start with ##, settings are key=value, each key once, keys = the script's required keys
chk "shipped conf: no single-# lines (notes use ##, settings are plain key=value)" bash -c "! grep -qE '^#([^#]|$)' '$SHIPPED'"
chk "shipped conf: every line is a ## note, blank, key=value or an account line" bash -c "! grep -vE '^(##.*|[a-z-]+=.*|[0-9]{12} = [a-z-]+)?$' '$SHIPPED' | grep -q ."
chk "shipped conf: every setting key listed once" bash -c "! grep -E '^[a-z-]+=' '$SHIPPED' | cut -d= -f1 | sort | uniq -d | grep -q ."
REQ="$(sed -n '/^readonly -a REQUIRED_KEYS=(/,/)$/p' "$SCRIPT" | sed 's/.*(//; s/)//' | tr -s ' \n' '\n' | grep -v '^$' | sort)"
chk "shipped conf: keys are exactly the script's REQUIRED_KEYS ($(wc -l <<<"$REQ") keys)" test "$(grep -E '^[a-z-]+=' "$SHIPPED" | cut -d= -f1 | sort)" == "$REQ"
chk "shipped conf: headings in the agreed order" test "$(grep -oE '^## =+ [A-Z][^=]+' "$SHIPPED" | sed -E 's/^## =+ //; s/ +$//' | paste -sd'|')" == "Accounts and regions|Schedule|Output|Snapshot audit|Report retention|Email|Account names (display only)|Advanced (rarely changed)"
chk "shipped conf: main values as agreed" bash -c "for kv in profile= all-regions=yes daily=7 daily-max-age=26 weekly-weekday=sat weekly-retention-days=30 monthly-rule=first-sun monthly=12 monthly-retention-days=365 'replica-exempt-engines=oracle-*,aurora-*' format=html,csv output-dir=./reports tz=Asia/Kolkata non-compliant-only=no log-file=./reports/run.log manual-older-than=90 snapshot-price-per-gb=0.021 keep-reports=30 alert-email= alert-on=noncompliant weekly-window-days= daily-retention-days=; do grep -qxF \"\$kv\" '$SHIPPED' || { echo \"missing \$kv\"; exit 1; }; done"
chk "shipped conf: only fake account numbers" bash -c "! grep -E '^[0-9]{12} ' '$SHIPPED' | grep -vqE '^(111111111111|222222222222|333333333333) '"
chk "repo: the .example file is gone and the conf is not git-ignored" bash -c "[[ ! -e '$HERE/../rds_backup_compliance_report.conf.example' ]] && ! git -C '$HERE/..' check-ignore -q rds_backup_compliance_report.conf 2>/dev/null"
# --check-config with the shipped file next to the script: every setting from "conf", no AWS call
cp "$SHIPPED" "$ACF"; : >"$MOCK_LOG"
act cc_ship 0 --check-config
has cc_ship out '^Config file: +.*autoconf/rds_backup_compliance_report\.conf \(next to the script\)$'
has cc_ship out '^  daily +7 +conf$'; has cc_ship out '^  weekly-window-days += weekly-retention-days \(30\) +conf$'
has cc_ship out '^  daily-retention-days += daily \(7\) +conf$'; has cc_ship out '^  keep-reports +30 days +conf$'
has cc_ship out '^  alert-email +\(empty = off\) +conf$'; has cc_ship out '^  111111111111 = prod-payments$'
has cc_ship out '^E-mail: off \(alert-email is empty\)$'; has cc_ship out '^OK: configuration is valid \(no AWS calls made\)$'
chk "check-config writes nothing (no ./reports, no run.log)" test ! -e "$AC/reports"
chk "check-config lists every required key once" test "$(grep -cE '^  [a-z-]+ ' "$OUT/cc_ship.out" | tr -d ' ')" -ge "$(wc -l <<<"$REQ")"
act cc_cli 0 --check-config --daily 9 -P prod --alert-email dba@example.com
has cc_cli out '^  daily +9 +CLI$'; has cc_cli out '^  profile +prod +CLI$'; has cc_cli out '^E-mail: to dba@example.com when NON-COMPLIANT or AWS errors$'
if ! command -v mail mailx sendmail >/dev/null 2>&1 && [[ ! -x /usr/sbin/sendmail ]]; then has cc_cli out 'mail command: none found'; fi
chk "check-config: zero AWS calls" test "$(ncalls)" -eq 0
chk "check-config: works without the aws CLI" bash -c "PATH='$(dirname "$(command -v jq)")':/usr/bin:/bin; command -v aws >/dev/null 2>&1 && exit 0; '$ACS' --check-config >/dev/null 2>&1"
# missing file: clear message, exit 1, even for --check-config; --help / --version still work
rm -f "$ACF"
act noconf 1 -P prod; has noconf err 'Settings file not readable: .*autoconf/rds_backup_compliance_report\.conf'; has noconf err 'Put the shipped file next to the script'
act noconf_cc 1 --check-config; has noconf_cc err 'Settings file not readable'
act noconf_help 0 --help; has noconf_help out 'settings file not loaded'; act noconf_ver 0 --version; has noconf_ver out '1\.7\.2'
chk "missing conf: no AWS calls" test "$(ncalls)" -eq 0
# missing keys (e.g. a v1.7.0 partial conf): exit 1 listing every missing key
grep -vE '^(daily|weekly-weekday|alert-on)=' "$SHIPPED" >"$ACF"
act misskey 1 --check-config; has misskey err 'rds_backup_compliance_report\.conf is missing 3 required setting\(s\): daily, weekly-weekday, alert-on$'
printf 'daily = 9\nweekly = 4\n' >"$AC/old170.conf"
act partial 1 -P prod --config "$AC/old170.conf"; has partial err 'old170\.conf is missing [0-9]+ required setting\(s\): profile, region, all-regions'
grep -vE '^daily=' "$SHIPPED" >"$AC/nodaily.conf"   # log-file=./reports/run.log, but ./reports does not exist: no shell noise
act partial2 1 -P prod --config "$AC/nodaily.conf"; hasnt partial2 err 'No such file or directory'; has partial2 err 'missing 1 required setting\(s\): daily$'
# each key once (any spelling), each account once; bad lines name file:line
{ cat "$SHIPPED"; echo 'daily=8'; } >"$ACF"; act dupkey 1 --check-config; has dupkey err 'conf:[0-9]+: .daily. is set twice \(also on line [0-9]+\); keep one line$'
{ cat "$SHIPPED"; echo 'DAILY_MAX_AGE = 20'; } >"$ACF"; act dupkey2 1 --check-config; has dupkey2 err '.daily-max-age. is set twice'
{ cat "$SHIPPED"; echo '111111111111 = again'; } >"$ACF"; act dupacct 1 --check-config; has dupacct err 'account 111111111111 is listed twice'
sed 's/^weekly=auto$/weekly=x/' "$SHIPPED" >"$ACF"; act badval 1 --check-config; has badval err 'Config .*autoconf/rds_backup_compliance_report\.conf:[0-9]+: --weekly must be a whole number'
{ cat "$SHIPPED"; echo 'bogus = 1'; } >"$ACF"; act badkey 1 --check-config; has badkey err 'Config .*\.conf:[0-9]+: unknown key .bogus.'
sed 's/^all-regions=yes$/all-regions=maybe/' "$SHIPPED" >"$ACF"; act badbool 1 --check-config; has badbool err '--all-regions must be yes or no'
sed 's/^alert-email=$/alert-email=dba@example.com,bad address/' "$SHIPPED" >"$ACF"; act bademail 1 --check-config; has bademail err 'conf:[0-9]+: Invalid --alert-email address: bad'
sed 's/^keep-reports=30$/keep-reports=-1/' "$SHIPPED" >"$ACF"; act badkeep 1 --check-config; has badkeep err '--keep-reports must be a whole number'
sed 's/^format=html,csv$/format=/' "$SHIPPED" >"$ACF"; act emptyfmt 1 --check-config; has emptyfmt err 'format is empty'
# --no-config was removed (the file is required now)
cp "$SHIPPED" "$ACF"
act nocfgflag 1 --check-config --no-config; has nocfgflag err '--no-config was removed in v1.7.1'
# --config FILE replaces the shipped file (no mixing); CLI overrides both
mkconf "$AC/other.conf" 'weekly=5' 'region=us-east-1' 'identifier=orders-*' 'format=json'
act cfgother 0 -P prod --config "$AC/other.conf"; rowt cfgother orders-aurora-pg15 '.weekly.need == 5'
jqt cfgother '.accounts[0].name == "prod-core"' "$OUT/cfgother.out"
act cfgother_cli 0 -P prod --config "$AC/other.conf" --weekly 4; rowt cfgother_cli orders-aurora-pg15 '.weekly.need == 4'
act cc_other 0 --check-config --config "$AC/other.conf"; has cc_other out '\(--config\)$'; has cc_other out '^  weekly +5 +conf$'
# the shipped file as is: all regions, html + csv + manual audit into ./reports, a run log, account names
act shiprun 0 -P prod
chk "shipped run: html, csv, backups csv, orphaned csv, manual audit csv in ./reports" bash -c "cd '$AC/reports' && compgen -G 'rds_backup_compliance_111111111111_*[0-9].html' && compgen -G 'rds_backup_compliance_111111111111_*[0-9].csv' && compgen -G '*_backups.csv' && compgen -G '*_orphaned_snapshots.csv' && compgen -G '*_manual_older_than_90d.csv'" >/dev/null
chk "shipped run: log-file ./reports/run.log written" grep -q 'resources: 8, non-compliant: [0-9]' "$AC/reports/run.log"
has shiprun err '5 regions scanned'; has shiprun err 'keep-reports: 0 old report file\(s\) deleted'
chk "shipped run: HTML uses the conf account name" grep -q 'prod-payments (111111111111)' "$(ls "$AC"/reports/*.html | head -1)"
# -r on the CLI replaces all-regions from the conf; -o '' / -l '' turn the conf output off for one run
rm -rf "$AC/reports"; act rcli 0 -P prod -r us-east-1 -F json -o '' -l ''
jqt rcli '.regions | map(.region) == ["us-east-1"]' "$OUT/rcli.out"; chk "rcli: nothing written (-o '' -l '')" test ! -e "$AC/reports"
# list settings: the first CLI use replaces the conf list
mkconf "$AC/plist.conf" 'profile=prod' 'region=us-east-1,ap-south-1' 'format=json'
act plist 0 --config "$AC/plist.conf" -P nonprod; jqt plist '[.accounts[].account] == ["222222222222"]' "$OUT/plist.out"
act plist2 0 --config "$AC/plist.conf" -P nonprod -P prod; jqt plist2 '[.accounts[].account] | sort == ["111111111111", "222222222222"]' "$OUT/plist2.out"
# --merge ignores the conf scope (all-regions=yes) and still works offline
n0="$(ncalls)"; act shipmerge 0 --merge "$M/prod.json" -F json -o '' -l ''; chk "merge with the shipped conf: zero AWS calls" test "$(ncalls)" == "$n0"
jqt shipmerge '.totals.resources == 8' "$OUT/shipmerge.out"
act shipmergeA 1 --merge "$M/prod.json" -A; has shipmergeA err 'do not combine it with -P / -r / -A'
t cc_help 0 fleet --help; has cc_help out '--check-config'; has cc_help out '--keep-reports'; has cc_help out '--alert-email'; hasnt cc_help out '--no-config'
has cc_help out '--daily N .*\[7\]$'; has cc_help out '--weekly-retention-days N .*\[30\]$'

echo "== v1.7.1: no setting values in the code (all from the conf)"
LIBD="$HERE/../lib"
chk "jq: no \$cfg fallbacks (\$cfg.x // value)" bash -c "! grep -nE '\\\$cfg\\.[a-z_]+\\)? *//' '$LIBD'/*.jq"
chk "page js: no cfg fallbacks (cfg.x || value)" bash -c "! grep -nE 'cfg\\.[a-z_]+ *\\|\\|' '$LIBD/backup_page.js'"
chk "jq / js: unit numbers only inside named constants" bash -c "! grep -nE '(^|[^0-9.])(86400|3600|1073741824|365\\.25)([^0-9]|$)' '$LIBD'/*.jq '$LIBD'/*.js | grep -vE ':def [A-Z_]+: |var SECONDS_PER_DAY = '"
chk "page js: no default price / retention literals" bash -c "! grep -nE '0\\.021|\\|\\| *(30|365)\\b' '$LIBD/backup_page.js'"
SETBLK="$(sed -n '/^# Settings: empty on purpose/,/^CONFIG_FILE=/p' "$SCRIPT")"
chk "shell: the settings block assigns no values" bash -c "! grep -vE '^#|^CONFIG_FILE=' <<<'$SETBLK' | grep -qE '[A-Z_]+=(\"[^\"]+\"|[^\"(; ][^;]*)'"
CODE="$(sed -e '/cat <<USAGE/,/^USAGE$/d' "$SCRIPT" | grep -vE '^[[:space:]]*#|^readonly ')"
chk "shell: no shipped default values outside comments, --help and named constants" bash -c "! grep -nE '(^|[^0-9.a-z_-])(7|26|30|365|0\\.021|25-40|300-400)([^0-9.]|$)|Asia/Kolkata|first-sun|=sat\\b|=auto\\b|timeout 60|\"rds_backup_compliance\"' <<<\"\$1\" | grep -vE '\\\$\\{?[A-Za-z_]+|% 100|% 4 |% 400|[0-9]{4}|dim=|3[01]\\b ;;|y >= 2000'" _ "$CODE"
chk "shell: the old built-in defaults are gone" bash -c "! grep -qE '^(DAILY=7|SNAP_PRICE=\"0\\.021\"|.*DISPLAY_TZ=\"Asia/Kolkata\"|.*WEEKLY_RETENTION_DAYS=30)' '$SCRIPT'"
chk "shellcheck clean" bash -c "command -v shellcheck >/dev/null || exit 0; shellcheck '$SCRIPT'"

echo "== v1.7.1: results identical to v1.7.0 (same settings, frozen clock)"
if git -C "$HERE/.." rev-parse -q --verify 'v1.7.0^{commit}' >/dev/null 2>&1; then
    V170="$OUT/v170"; FD="$OUT/fakedate"; mkdir -p "$V170" "$FD" "$OUT/idcwd"; git -C "$HERE/.." archive v1.7.0 | tar -x -C "$V170"
    # date shim: "now" frozen at FAKE_NOW for date calls without -d, so both versions evaluate the same instant
    printf '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in -d|-d*|--date*) exec /bin/date "$@" ;; esac; done\nexec /bin/date -d "@$FAKE_NOW" "$@"\n' >"$FD/date"; chmod +x "$FD/date"
    FN="$(( $(date -u +%s) / 3600 * 3600 + 1234 ))"
    same() { local name="$1" scen="$2" fmt="$3"; shift 3; local o="$OUT/id_$name"
        cd "$OUT/idcwd" || return   # --manual-older-than without -o writes into the current folder
        PATH="$FD:$PATH" FAKE_NOW="$FN" MOCK_NOW="$FN" MOCK_SCENARIO="$scen" "$V170/rds_backup_compliance_report.sh" "$@" -F "$fmt" >"$o.old" 2>/dev/null
        PATH="$FD:$PATH" FAKE_NOW="$FN" MOCK_NOW="$FN" MOCK_SCENARIO="$scen" "$SCRIPT" --config "$BASECONF" "$@" -F "$fmt" >"$o.new" 2>/dev/null
        if [[ "$fmt" == json ]]; then
            chk "same as v1.7.0: $name" cmp -s <(jq -S 'walk(if type == "object" then del(.version, .tool_version) else . end)' "$o.old") <(jq -S 'walk(if type == "object" then del(.version, .tool_version) else . end)' "$o.new")
        else chk "same as v1.7.0: $name" cmp -s <(sed 's/1\.7\.0/1.7.x/g' "$o.old") <(sed 's/1\.7\.2/1.7.x/g' "$o.new"); fi
        [[ -s "$o.new" ]] || bad "same as v1.7.0: $name produced no output"; cd "$HERE" || return; }
    same fleet_2r fleet json -P prod -r us-east-1,us-west-2
    same fleet_all fleet json -P prod,nonprod,dev -A
    same fleet_csv fleet csv -P prod -r us-east-1
    same fleet_txt fleet text -P prod -r us-east-1,us-west-2
    same backupdeny backupdeny json -P prod -r us-east-1,us-west-2
    same globaldeny globaldeny json -P prod -r us-east-1,us-west-2
    same snapdeny snapdeny json -P prod -r us-east-1
    same empty empty json -P prod -A
    same rpquirks rpquirks json -P prod -r us-east-1
    same weekly6_yearly1 fleet json -P prod -r us-east-1 --weekly 6 --yearly 1 --tolerance-days 0
    same retention fleet json -P prod -r us-east-1 --weekly-retention-days 35 --weekly-window-days 30 --monthly-retention-days 400 --daily-retention-days 2
    same window fleet json -P nonprod -r ap-south-1 --weekly-window-days 45 --weekly-weekday sun --monthly-rule first-mon
    same exempt fleet json -P prod,dev -r us-west-2,eu-west-1 --replica-exempt-engines 'oracle-*,aurora-*'
    same manual_price fleet json -P prod -A --manual-older-than 90 --snapshot-price-per-gb 0.05
    same nconly fleet json -P prod -r us-east-1 --non-compliant-only
    same tz_utc fleet csv -P prod -r us-east-1 --tz UTC
    same exceptions fleet json -P prod -A --exceptions "$EX/ok.conf"
    same merge fleet json --merge "$M"
    # weekly-window-days empty = weekly-retention-days: the same as v1.7.0 with an explicit window of that size
    PATH="$FD:$PATH" FAKE_NOW="$FN" MOCK_NOW="$FN" MOCK_SCENARIO=fleet "$V170/rds_backup_compliance_report.sh" -P prod -r us-east-1 --weekly-retention-days 42 --weekly-window-days 42 -F json >"$OUT/id_follow.old" 2>/dev/null
    PATH="$FD:$PATH" FAKE_NOW="$FN" MOCK_NOW="$FN" MOCK_SCENARIO=fleet "$SCRIPT" --config "$BASECONF" -P prod -r us-east-1 --weekly-retention-days 42 -F json >"$OUT/id_follow.new" 2>/dev/null
    chk "weekly window follows weekly-retention-days (42 = v1.7.0 with window 42)" cmp -s <(jq -S 'walk(if type == "object" then del(.version, .tool_version) else . end)' "$OUT/id_follow.old") <(jq -S 'walk(if type == "object" then del(.version, .tool_version) else . end)' "$OUT/id_follow.new")
    jqt id_follow '.thresholds.weekly_window_days == 42' "$OUT/id_follow.new"
else echo "  skip v1.7.0 comparison (no git tag v1.7.0 here)"; fi

echo "== v1.7.1: keep-reports (report retention)"
KR="$OUT/kr"; mkdir -p "$KR/o/sub" "$KR/o/rds_backup_compliance_dir_20200101.html"
OLDF=(rds_backup_compliance_111111111111_20250101_000000.html rds_backup_compliance_111111111111_20250101_000000.csv
      rds_backup_compliance_111111111111_20250101_000000_backups.csv rds_backup_compliance_111111111111_20250101_000000.json
      rds_backup_compliance_111111111111_20250101_000000.txt)
KEEPF=(other_report.html rds_backup_compliance_old.log rds_backup_111111111111_20250101.json run.log sub/rds_backup_compliance_old.html)
for f in "${OLDF[@]}" "${KEEPF[@]}"; do : >"$KR/o/$f"; touch -d '40 days ago' "$KR/o/$f"; done
touch -d '40 days ago' "$KR/o/rds_backup_compliance_dir_20200101.html"
: >"$KR/o/rds_backup_compliance_young.html"; touch -d '29 days ago' "$KR/o/rds_backup_compliance_young.html"
t kr 0 fleet -P prod -r us-east-1 -F html,csv -o "$KR/o" --keep-reports 30
chk "keep-reports: the 5 old prefixed report files are deleted" bash -c "for f in ${OLDF[*]}; do [[ ! -e '$KR/o/'\$f ]] || exit 1; done"
chk "keep-reports: other names, other extensions, sub folders, folders, young files and the log are kept" bash -c "for f in ${KEEPF[*]} rds_backup_compliance_young.html; do [[ -e '$KR/o/'\$f ]] || { echo \$f; exit 1; }; done; [[ -d '$KR/o/rds_backup_compliance_dir_20200101.html' ]]"
chk "keep-reports: this run's reports are kept" compgen -G "$KR/o/rds_backup_compliance_111111111111_2*[0-9].html" >/dev/null
has kr err 'keep-reports: deleted rds_backup_compliance_111111111111_20250101_000000\.html \(older than 30 days\)$'
has kr err 'keep-reports: 5 old report file\(s\) deleted from .*/kr/o \(keeping 30 days\)$'
cp "$OUT/kr.err" "$OUT/keep_reports_log.txt"   # for screenshots
for f in "${OLDF[@]}"; do : >"$KR/o/$f"; touch -d '40 days ago' "$KR/o/$f"; done
t kr0 0 fleet -P prod -r us-east-1 -F json -o "$KR/o" --keep-reports 0
chk "keep-reports 0: nothing deleted" bash -c "for f in ${OLDF[*]}; do [[ -e '$KR/o/'\$f ]] || exit 1; done"; hasnt kr0 err 'keep-reports'
t krpfx 0 fleet -P prod -r us-east-1 -F json -o "$KR/o" --keep-reports 30 --prefix myrep
chk "keep-reports: only the configured prefix (myrep_*) is pruned" bash -c "for f in ${OLDF[*]}; do [[ -e '$KR/o/'\$f ]] || exit 1; done"
( cd "$KR/o" && t krstdout 0 fleet -P prod -r us-east-1 -F json -o '' --keep-reports 1 )
chk "keep-reports without output-dir: nothing deleted" bash -c "for f in ${OLDF[*]}; do [[ -e '$KR/o/'\$f ]] || exit 1; done"
t krdry 0 fleet -P prod -r us-east-1 -o "$KR/o" -F json --keep-reports 1 --dry-run
chk "keep-reports with --dry-run: nothing deleted" bash -c "for f in ${OLDF[*]}; do [[ -e '$KR/o/'\$f ]] || exit 1; done"

echo "== v1.7.1: e-mail (alert-email / alert-on / --alert-test) with fake mail commands"
FM="$OUT/fakemail"; mkdir -p "$FM/mailx" "$FM/sendmail" "$FM/both" "$FM/slow"
FAKE='#!/usr/bin/env bash
# fake mail command for the tests: records its name, arguments and stdin; sends nothing
{ printf "%s\n" "${0##*/}"; printf "%s\n" "$@"; } >"$MAIL_CAPTURE.args"; cat >"$MAIL_CAPTURE.body"'
printf '%s\n' "$FAKE" >"$FM/mailx/mailx"; printf '%s\n' "$FAKE" >"$FM/sendmail/sendmail"
printf '%s\n' "$FAKE" >"$FM/both/mail"; printf '%s\n' "$FAKE" >"$FM/both/sendmail"
printf '#!/usr/bin/env bash\nsleep 5\n' >"$FM/slow/sendmail"; chmod +x "$FM"/*/*
SYSMAIL=0; { command -v mail || command -v mailx || command -v sendmail || [[ -x /usr/sbin/sendmail ]]; } >/dev/null 2>&1 && SYSMAIL=1
EMO="$OUT/em"; mkdir -p "$EMO"
em() { local name="$1" fake="$2"; shift 2; rm -f "$OUT/$name.cap".*   # t with a fake mailer dir first on PATH
       PATH="$FM/$fake:$PATH" MAIL_CAPTURE="$OUT/$name.cap" t "$name" "$@"; }
A2=(--alert-email "dba@example.com,oncall@example.com" --alert-from rds-reports@example.com)
# alert-on=noncompliant: everything compliant -> nothing sent; always -> sent
em em_ok_nc mailx 0 fleet -P nonprod -r ap-south-1 -i 'hr-*' -F json "${A2[@]}"
chk "noncompliant + all compliant: no e-mail" test ! -e "$OUT/em_ok_nc.cap.args"; has em_ok_nc err 'E-mail: not sent \(alert-on=noncompliant'
em em_ok_always mailx 0 fleet -P nonprod -r ap-south-1 -i 'hr-*' -F json "${A2[@]}" --alert-on always
has em_ok_always.cap args '^\[rds_backup_compliance\] COMPLIANT: 0 non-compliant of 1, 100% compliant$'
# mailx: text only, -r from, -s subject, -- recipients
em em_mailx mailx 0 fleet -P prod -r us-east-1 -F html,csv -o "$EMO/x" "${A2[@]}"
chk "mailx: argv = mailx -r FROM -s SUBJECT -- TO..." bash -c "diff <(sed -n '1,4p;6,8p' '$OUT/em_mailx.cap.args') <(printf 'mailx\n-r\nrds-reports@example.com\n-s\n--\ndba@example.com\noncall@example.com\n')"
has em_mailx.cap args '^\[rds_backup_compliance\] NON-COMPLIANT: 3 non-compliant of 6, [0-9]+% compliant$'
has em_mailx.cap body '^Resources: 6   Compliant: [0-9]+   Non-compliant: 3   Not yet due: [0-9]+   Unknown: 0$'
has em_mailx.cap body '^NON-COMPLIANT servers \(3\):$'; has em_mailx.cap body '^  - prod-core \(111111111111\) us-east-1 billing-aurora-mysql \(aurora-mysql\): weekly [0-9]/[0-9] missing Sat '
has em_mailx.cap body '^  - prod-core \(111111111111\) us-east-1 reports-pg \(postgres\): .*retention 3d < 7d'
has em_mailx.cap body '^Report files:$'; has em_mailx.cap body '\.html$'; hasnt em_mailx.cap body 'Content-Type|^--rds_bcr'
has em_mailx err 'mailx cannot attach the HTML report'; has em_mailx err 'E-mail sent to dba@example.com oncall@example.com: \[rds_backup_compliance\] NON-COMPLIANT'
# sendmail: MIME multipart with the written HTML report attached (base64 decodes to the same file)
em em_sm sendmail 0 fleet -P prod -r us-east-1 -F html,csv -o "$EMO/s" "${A2[@]}"
chk "sendmail: argv = sendmail -t -oi" test "$(paste -sd' ' "$OUT/em_sm.cap.args")" == "sendmail -t -oi"
has em_sm.cap body '^From: rds-reports@example.com$'; has em_sm.cap body '^To: dba@example.com,oncall@example.com$'
has em_sm.cap body '^Subject: \[rds_backup_compliance\] NON-COMPLIANT: 3 non-compliant of 6'
has em_sm.cap body '^MIME-Version: 1\.0$'; has em_sm.cap body '^Content-Type: multipart/mixed; boundary="rds_bcr_[0-9]+_[0-9]+"$'
has em_sm.cap body '^Content-Disposition: attachment; filename="rds_backup_compliance_111111111111_[0-9_]+\.html"$'
has em_sm.cap body '^NON-COMPLIANT servers \(3\):$'
chk "sendmail: the attachment decodes to the written HTML report" bash -c "b=\$(sed -n 's/^Content-Type: multipart.*boundary=\"\\(.*\\)\"/\\1/p' '$OUT/em_sm.cap.body'); awk -v b=\"--\$b\" 'f==2 && \$0==b\"--\"{exit} f==2{print} f==1 && \$0==\"\"{f=2} /^Content-Disposition: attachment/{f=1}' '$OUT/em_sm.cap.body' | base64 -d | cmp -s - \"\$(ls '$EMO'/s/*.html)\""
em em_smtxt sendmail 0 fleet -P prod -r us-east-1 -F json -o "$EMO/t" "${A2[@]}"
has em_smtxt.cap body '^Content-Type: text/plain; charset=UTF-8$'; hasnt em_smtxt.cap body 'multipart|attachment'
# mail + sendmail: sendmail when the HTML is attached, mail for text only
em em_both both 0 fleet -P prod -r us-east-1 -F html -o "$EMO/b" "${A2[@]}"; has em_both.cap args '^sendmail$'
em em_both2 both 0 fleet -P prod -r us-east-1 -F json "${A2[@]}"; has em_both2.cap args '^mail$'
# html printed to the screen: the report is rendered for the e-mail
em em_stdout sendmail 0 fleet -P prod -r us-east-1 -F html "${A2[@]}"; has em_stdout.cap body 'filename="rds_backup_compliance_report\.html"'
# exceptions that cover every NON-COMPLIANT server count as compliant: no e-mail with alert-on=noncompliant
em em_exc mailx 0 fleet -P prod -A -F json --exceptions "$EX/all.conf" "${A2[@]}"; chk "exceptions applied: no e-mail" test ! -e "$OUT/em_exc.cap.args"
# AWS errors (UNKNOWN rows / failed regions) send even with 0 NON-COMPLIANT
em em_err mailx 0 backupdeny -P prod -r us-east-1 -i orders-aurora-pg15 -F json "${A2[@]}"
has em_err.cap args '^\[rds_backup_compliance\] ERRORS: 0 non-compliant of 1'; has em_err.cap body '^UNKNOWN \(an AWS call failed\) \(1\):$'; has em_err.cap body '^Region errors \(1\):$'
# merge (offline) e-mails too
em em_merge mailx 0 fleet --merge "$M" -F json "${A2[@]}"; has em_merge.cap body '^Accounts: '
# --alert-test: one test e-mail, no AWS calls
n0="$(ncalls)"; em em_test sendmail 0 fleet "${A2[@]}" --alert-test
chk "--alert-test: zero AWS calls" test "$(ncalls)" == "$n0"
has em_test.cap body '^Subject: \[rds_backup_compliance\] TEST e-mail from '; has em_test.cap body '^Test e-mail from rds_backup_compliance_report\.sh v1\.7\.2 '
t em_test_noaddr 1 fleet --alert-test; has em_test_noaddr err '--alert-test needs alert-email'
# no mail command: warning, the run still succeeds and the report is written
if (( ! SYSMAIL )); then
    t em_none 0 fleet -P prod -r us-east-1 -F html -o "$EMO/n" "${A2[@]}"
    has em_none err 'E-mail: no mail, mailx or sendmail found; e-mail not sent'; chk "no mail command: report still written" compgen -G "$EMO/n/*.html" >/dev/null
else echo "  skip no-mailer case (this machine has a mail command)"; fi
# a hung mail command is stopped after mail-timeout seconds; the run still succeeds
SECONDS=0; em em_slow slow 0 fleet -P prod -r us-east-1 -F json "${A2[@]}" --mail-timeout 1
chk "mail-timeout 1: stopped quickly ($SECONDS s)" test "$SECONDS" -lt 5; has em_slow err 'E-mail to .* failed or was not sent'
# validation
t em_bad 1 fleet --alert-email 'not-an-address'; has em_bad err 'Invalid --alert-email address: not-an-address'
t em_bad2 1 fleet --alert-email 'a@b.c;rm'; t em_badon 1 fleet --alert-on sometimes; has em_badon err '--alert-on must be noncompliant or always'
t em_badfrom 1 fleet --alert-from 'x y@z'; t em_badtmo 1 fleet --mail-timeout 0

echo "== v1.7.2: --dry-run previews keep-reports"
D2="$OUT/dry2"; mkdir -p "$D2/o"
OLD2=(rds_backup_compliance_111111111111_20250101_000000.html rds_backup_compliance_111111111111_20250101_000000.csv rds_backup_compliance_111111111111_20250101_000000.json)
for f in "${OLD2[@]}" other_report.html; do : >"$D2/o/$f"; touch -d '40 days ago' "$D2/o/$f"; done
: >"$D2/o/rds_backup_compliance_young.html"; touch -d '5 days ago' "$D2/o/rds_backup_compliance_young.html"
n0="$(ncalls)"; t dry2 0 fleet -P prod -r us-east-1 -o "$D2/o" -F json --keep-reports 30 --dry-run
chk "dry-run keep-reports: zero AWS calls" test "$(ncalls)" == "$n0"
for f in "${OLD2[@]}"; do has dry2 err "keep-reports: would delete $f\$"; done
has dry2 err 'keep-reports: 3 old report file\(s\) would be deleted from .*/dry2/o \(keeping 30 days\); nothing was deleted$'
hasnt dry2 err 'would delete (other_report|rds_backup_compliance_young)'
chk "dry-run keep-reports: every file is still there" bash -c "for f in ${OLD2[*]} other_report.html rds_backup_compliance_young.html; do [[ -e '$D2/o/'\$f ]] || exit 1; done"
t dry2_off 0 fleet -P prod -r us-east-1 -o "$D2/o" -F json --keep-reports 0 --dry-run; hasnt dry2_off err 'keep-reports'
t dry2_scr 0 fleet -P prod -r us-east-1 -o '' -F json --keep-reports 30 --dry-run; hasnt dry2_scr err 'keep-reports'
t dry2_real 0 fleet -P prod -r us-east-1 -o "$D2/o" -F json --keep-reports 30
chk "same run without --dry-run deletes exactly the files that were previewed" bash -c "for f in ${OLD2[*]}; do [[ ! -e '$D2/o/'\$f ]] || exit 1; done; [[ -e '$D2/o/other_report.html' && -e '$D2/o/rds_backup_compliance_young.html' ]]"

echo "== v1.7.2: --non-compliant-only text summary counts every server"
t nc_all 0 fleet -P prod -r us-east-1 -F text; t nc_only 0 fleet -P prod -r us-east-1 -F text --non-compliant-only
chk "nc-only text: Compliance and Resources lines equal the full run" bash -c "diff <(grep -E '^(Compliance|Resources) ' '$OUT/nc_all.out') <(grep -E '^(Compliance|Resources) ' '$OUT/nc_only.out')"
has nc_only out '^Resources 6: compliant [0-9]+, non-compliant 3,'
chk "nc-only text: only the 3 failing rows are listed" bash -c "test \"\$(grep -c 'NON-COMPLIANT' '$OUT/nc_only.out')\" == 3 && ! grep -E '	COMPLIANT	' '$OUT/nc_only.out'"
chk "nc-only text: the full run lists all 6 servers" bash -c "test \"\$(grep -cE '	(COMPLIANT|NON-COMPLIANT|NOT YET DUE|UNKNOWN)	' '$OUT/nc_all.out')\" == 6"
t nc_csv 0 fleet -P prod -r us-east-1 -F csv --non-compliant-only
chk "nc-only csv: only the failing rows" bash -c "test \"\$(tail -n +2 '$OUT/nc_csv.out' | grep -c .)\" == 3"
t nc_exc 0 fleet -P prod -A -F text --non-compliant-only --exceptions "$EX/ok.conf"
has nc_exc out '^Exceptions: [0-9]+ applied'; has nc_exc out 'line 7: 111111111111 gone-db matched no server'

echo "== v1.7.2: -o '' writes no manual-snapshot CSV"
SC="$OUT/scr2"; mkdir -p "$SC"
( cd "$SC" && t scr2 0 fleet -P prod -r us-east-1 -F text -o '' --manual-older-than 90 )
chk "screen only: no file in the current folder" bash -c "test -z \"\$(ls -A '$SC')\""
has scr2 err 'manual snapshots older than 90 days: 7 \(screen only, no file written\)'
has scr2 err '^"?account_id"?,.*age_days'; has scr2 err 'legacy-mysql-manual-600d'
chk "screen only: the report on stdout is untouched (no CSV rows)" bash -c "! grep -q 'legacy-mysql-manual-600d' '$OUT/scr2.out'"
( cd "$SC" && t scr2_json 0 fleet -P prod -r us-east-1 -F json -o '' --manual-older-than 90 ); jqt scr2_json '.rows | length == 6' "$OUT/scr2_json.out"
chk "screen only (json): stdout stays valid JSON, folder still empty" bash -c "test -z \"\$(ls -A '$SC')\""
t scr2_dir 0 fleet -P prod -r us-east-1 -F json -o "$SC/d" --manual-older-than 90
chk "with -o DIR the CSV is still written there" compgen -G "$SC/d/*_manual_older_than_90d.csv" >/dev/null
hasnt scr2_dir err 'screen only'

AFTER="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"
chk "nothing written into the repo" test "$BEFORE" == "$AFTER"
echo; echo "passed $PASS, failed $FAIL"; (( FAIL == 0 ))
