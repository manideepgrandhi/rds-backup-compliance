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
t version 0 fleet --version; has version out '1\.0\.0'
t help 0 fleet --help; has help out 'list-recovery-points-by-backup-vault'; has help out 'weekly-days'
t badopt 1 fleet --nope
t multifmt 1 fleet -P prod -r us-east-1 -F csv,html
t badwd 1 fleet --weekly-days 70-60
t badint 1 fleet --weekly x
t mergeP 1 fleet --merge x.json -P prod
t noregion 2 fleet -P prod

echo "== fleet (prod, two regions)"
t fleet 0 fleet -P prod -r us-east-1,us-west-2 -F json
rowt fleet orders-aurora-pg15 '.status == "COMPLIANT" and .global_role == "primary" and .global_cluster == "orders-global"'
rowt fleet orders-aurora-pg15 '.daily.have == 7 and .weekly.have == 5 and .monthly.have == 12 and .yearly.have == 2'
rowt fleet orders-aurora-pg15 '.automated == 7'          # the awsbackup-type snapshot is not counted as automated
rowt fleet orders-aurora-pg15 '.manual == 4'
rowt fleet legacy-mysql '.manual == 2'
rowt fleet billing-aurora-mysql '.status == "NON-COMPLIANT" and .gaps == "weekly 2/4; yearly 0/1"'
rowt fleet new-aurora-pg16 '.status == "NOT YET DUE" and .monthly.st == "DUE" and .yearly.st == "DUE" and .gaps == ""'
rowt fleet reports-pg '.status == "NON-COMPLIANT" and (.gaps | test("retention 3d < 7d")) and .type == "instance"'
rowt fleet legacy-mysql '.status == "NON-COMPLIANT" and (.gaps | test("last automated 7[34](\\.[0-9])?h ago"))'
rowt fleet orders-dr-pg15 '.status == "COMPLIANT" and .global_role == "secondary" and .weekly.st == "N/A" and .yearly.st == "N/A"'
rowt fleet shop-dr-mysql '.status == "NON-COMPLIANT" and .global_cluster == "shop-global" and (.gaps | test("^daily"))'
jqt fleet '[.rows[].identifier] | index("docs-cluster") == null' "$OUT/fleet.out"
jqt fleet '[.rows[].identifier] | map(select(test("-1$"))) | length == 0' "$OUT/fleet.out"
jqt fleet '.totals == {resources: 7, compliant: 2, non_compliant: 4, not_yet_due: 1, unknown: 0}' "$OUT/fleet.out"
jqt fleet '.thresholds.weekly_min_days == 11 and .thresholds.weekly_max_days == 60 and .thresholds.monthly_max_days == 400' "$OUT/fleet.out"
jqt fleet '[.rows[] | keys[]] | unique | map(select(test("arn|environment|owner|application|note"))) | length == 0' "$OUT/fleet.out"
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
jqt savedata '[.regions[] | select(.status == "empty")] | length == 3' "$SD"
jqt savedata '[.resources[] | has("arn")] | any | not' "$SD"
CSV="$(ls "$OUT"/o/rds_backup_compliance_111111111111_*[0-9].csv | head -1)"; BCSV="$(ls "$OUT"/o/*_backups.csv | head -1)"
HTML="$(ls "$OUT"/o/*.html | head -1)"; JSON="$(ls "$OUT"/o/rds_backup_compliance_*.json | head -1)"
chk "csv header" grep -qx '"account_id","region","identifier","type","engine","engine_version","global_cluster","global_role","retention_days","last_automated_utc","last_automated_ist","daily","weekly","monthly","yearly","status","gaps"' "$CSV"
chk "csv has 7 rows + header" test "$(wc -l <"$CSV")" -eq 8
chk "csv has every status" bash -c "grep -q '\"COMPLIANT\"' '$CSV' && grep -q '\"NON-COMPLIANT\"' '$CSV' && grep -q '\"NOT YET DUE\"' '$CSV'"
chk "backups csv has manual, automated, backup kinds" bash -c "grep -q ',\"manual\",' '$BCSV' && grep -q ',\"automated\",' '$BCSV' && grep -q ',\"backup\",' '$BCSV'"
chk "backups csv has IST column and classes" bash -c "head -1 '$BCSV' | grep -q created_ist && grep -q '\"weekly\"' '$BCSV' && grep -q '\"yearly\"' '$BCSV' && grep -q '\"short\"' '$BCSV'"
chk "backups csv: no EC2 recovery point" bash -c "! grep -q ami-0abc '$BCSV'"
chk "html: no empty region (ca-central-1, ap-south-1)" bash -c "! grep -qE 'ca-central-1|ap-south-1' '$HTML'"
chk "html: no region names above the tabs" bash -c "! sed -n '1,/class=\"tabs\"/p' '$HTML' | grep -qE '(us|eu|ap|ca)-[a-z]+-[0-9]'"
chk "html: account in title" grep -q '<title>RDS backup compliance - 111111111111</title>' "$HTML"
chk "html: no </script> breakout in data" bash -c "test \"\$(grep -c '</script>' '$HTML')\" -eq 2"
jqt filesjson '.regions | map(.region) == ["us-east-1", "us-west-2"]' "$JSON"

echo "== scenarios"
t bdeny 0 backupdeny -P prod -r us-east-1,us-west-2 -F json
rowt bdeny orders-aurora-pg15 '.status == "UNKNOWN" and .weekly.st == "UNKNOWN" and (.gaps | test("unreadable"))'
rowt bdeny orders-dr-pg15 '.status == "COMPLIANT"'
rowt bdeny billing-aurora-mysql '.status == "UNKNOWN"'
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
jqt eng '[.rows[].engine] | all(startswith("aurora-"))' "$OUT/eng.out"
t ident 0 fleet -P prod -r us-east-1 -i 'REPORTS-*' -F json
jqt ident '[.rows[].identifier] == ["reports-pg"]' "$OUT/ident.out"
t defregion 2 fleet -P nonprod -F json; MOCK_DEFAULT_REGION=ap-south-1 t defregion2 0 fleet -P nonprod -F json
jqt defregion2 '.rows | length == 2' "$OUT/defregion2.out"

echo "== thresholds"
t wk6 0 fleet -P prod -r us-east-1 -i orders-* --weekly 6 -F json; rowt wk6 orders-aurora-pg15 '.weekly == {have: 5, need: 6, st: "FAIL"}'
t wd40 0 fleet -P prod -r us-east-1 -i orders-* --weekly-days 40-60 -F json; rowt wd40 orders-aurora-pg15 '.weekly.have == 0'
t mmax 0 fleet -P prod -r us-east-1 -i orders-* --monthly-max-days 300 -F json; rowt mmax orders-aurora-pg15 '.monthly.have == 0 and .yearly.have >= 2'
t daily14 0 fleet -P nonprod -r ap-south-1 --daily 14 -F json; rowt daily14 hr-aurora-pg '.daily.st == "OK"'; rowt daily14 payroll-sqlserver '.daily.st == "FAIL"'
t age 0 fleet -P prod -r us-east-1 -i legacy-* --daily-max-age 80 -F json; rowt age legacy-mysql '(.gaps | test("last automated") | not)'
printf 'weekly = 6\r\n# comment\r\nregion=us-east-1\r\nidentifier = orders-*\r\nformat=json\r\n' >"$OUT/my conf.conf"
t conf 0 fleet -P prod --config "$OUT/my conf.conf"; rowt conf orders-aurora-pg15 '.weekly.need == 6'
t confcli 0 fleet -P prod --config "$OUT/my conf.conf" --weekly 4; rowt confcli orders-aurora-pg15 '.weekly.need == 4'
printf 'bogus=1\n' >"$OUT/bad.conf"; t badconf 1 fleet --config "$OUT/bad.conf"
t tz 0 fleet -P prod -r us-east-1 --tz UTC -F csv; has tz out 'last_automated_utc"'
chk "jq: +05:30 timestamps parse to UTC" test "$(jq -n --slurpfile x /dev/null 'include "collect" {search: "'"$HERE"'/../lib"}; 1' 2>/dev/null; jq -rn '"2026-10-01T08:30:00.123000+05:30" | capture("^(?<d>[0-9-]+T[0-9:]+)") | .d + "Z" | fromdateiso8601 - 19800 | todate')" == "2026-10-01T03:00:00Z"

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
jqt merge '.rows | length == 10' "$OUT/merge.out"
has merge err 'account 111111111111: an older collection was ignored'
rowt merge payroll-sqlserver '.status == "NON-COMPLIANT" and .gaps == "monthly 9/11"'
t mergeold 0 fleet --merge "$OUT/prod_old.json" "$M/nonprod.json" -F json
jqt mergeold '.rows | length == 4' "$OUT/mergeold.out"
# manual-snapshot audit CSV (live and from merged data); v1.0.0 save-data files still merge
mkdir -p "$OUT/mo"
t mold 0 fleet -P prod -r us-east-1 -F json -o "$OUT/mo" --manual-older-than 90
MO="$(ls "$OUT"/mo/*_manual_older_than_90d.csv 2>/dev/null | head -1)"
chk "manual-older-than: csv written" test -s "$MO"
chk "manual-older-than: header" bash -c "head -1 '$MO' | grep -q '^\"\?account_id\"\?,\"\?region\"\?,\"\?identifier\"\?,.*age_days'"
chk "manual-older-than: only >90d manual (5 in prod us-east-1)" test "$(tail -n +2 "$MO" | grep -c .)" == 5
chk "manual-older-than: oldest first, >12 months kept" bash -c "sed -n 2p '$MO' | grep -q 'legacy-mysql-manual-600d'"
t moldbad 1 fleet -P prod -r us-east-1 --manual-older-than abc
t moldmerge 0 fleet --merge "$M" -F json -o "$OUT/mo2" --manual-older-than 365
chk "manual-older-than on merge: >365d across accounts" bash -c "tail -n +2 \"$OUT\"/mo2/*_manual_older_than_365d.csv | cut -d, -f3 | sort -u | tr -d '\"' | paste -sd' ' | grep -qx 'legacy-mysql orders-aurora-pg15 payroll-sqlserver'"
if git -C "$HERE/.." cat-file -e 602abe2 2>/dev/null; then
    V1="$OUT/v100"; mkdir -p "$V1/lib"
    for f in rds_backup_compliance_report.sh lib/collect.jq lib/backup.jq lib/merge.jq lib/backup_page.js; do git -C "$HERE/.." show "602abe2:$f" >"$V1/$f"; done
    chmod +x "$V1/rds_backup_compliance_report.sh"
    MOCK_SCENARIO=fleet "$V1/rds_backup_compliance_report.sh" -P dev -r eu-west-1 --save-data "$OUT/v100_dev.json" -F json >/dev/null 2>&1
    t mergev100 0 fleet --merge "$OUT/v100_dev.json" "$M/prod.json" -F json
    jqt mergev100 '[.accounts[].account] | sort == ["111111111111", "333333333333"]' "$OUT/mergev100.out"
fi
t mergedir 0 fleet --merge "$M" -o "$OUT/all accounts.html"
chk "merge -o FILE.html written" test -s "$OUT/all accounts.html"
chk "merged html lists 3 accounts in title" grep -q '<title>RDS backup compliance - 111111111111, 222222222222, 333333333333</title>' "$OUT/all accounts.html"
t mergecsv 0 fleet --merge "$M" -F csv,html -o "$OUT/mc"
chk "merged csv name has all accounts" compgen -G "$OUT/mc/rds_backup_compliance_111111111111_222222222222_333333333333_*.csv" >/dev/null
echo '{"x":1}' >"$OUT/notdata.json"; t mergebad 3 fleet --merge "$OUT/notdata.json"
t mergemissing 3 fleet --merge "$OUT/nope.json"
echo 'not json' >"$OUT/garbage.json"; t mergegarbage 3 fleet --merge "$OUT/garbage.json"
# Git Bash: jq.exe writes CRLF
CR="$OUT/crjq"; mkdir -p "$CR"; REALJQ="$(command -v jq)"
printf '#!/usr/bin/env bash\n"%s" "$@" | sed "s/$/\\r/"\nexit "${PIPESTATUS[0]}"\n' "$REALJQ" >"$CR/jq"; chmod +x "$CR/jq"
PATH="$CR:$PATH" t crlf 0 fleet --merge "$M" -F json
jqt crlf '.rows | length == 10' <(tr -d '\r' <"$OUT/crlf.out")
PATH="$CR:$PATH" t crlfhtml 0 fleet --merge "$M" -o "$OUT/cr.html"
chk "CRLF jq: html written" grep -q 'orders-aurora-pg15' "$OUT/cr.html"

echo "== browser"
if command -v node >/dev/null && [[ -x "${CHROME:-/usr/bin/google-chrome}" ]] && node -e 'require("puppeteer-core")' 2>/dev/null; then
    for h in "$HTML" "$OUT/all accounts.html"; do
        res="$(node "$HERE/browser_check.js" "$h" ${SHOTS:+"$SHOTS"} 2>&1)"; rc=$?
        if [[ $rc -eq 0 ]]; then ok "browser: $(basename "$h") $res"; else bad "browser: $(basename "$h") $res"; fi
        SHOTS="${SHOTS:+$SHOTS/merged}"
    done
else echo "  skip browser check (node + puppeteer-core + Chrome not found)"; fi

AFTER="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"
chk "nothing written into the repo" test "$BEFORE" == "$AFTER"
echo; echo "passed $PASS, failed $FAIL"; (( FAIL == 0 ))
