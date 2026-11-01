# Examples

```bash
# Current login and region, console summary
./rds_backup_compliance_report.sh

# Every region, HTML and CSV (compliance and backups), and save the data for merging
./rds_backup_compliance_report.sh -A -F html,csv --save-data -o ./out

# Only Aurora PostgreSQL, two regions, non-compliant rows only
./rds_backup_compliance_report.sh -r us-east-1,us-west-2 -e aurora-postgresql --non-compliant-only

# Stricter daily freshness and a different weekly window
./rds_backup_compliance_report.sh -A --daily-max-age 24 --weekly-days 20-45 -F html -o ./out

# Use it as a CI gate
./rds_backup_compliance_report.sh -A --fail-on-noncompliant -F json -o ./out || echo "exit $?"

# Settings file (the CLI overrides it)
./rds_backup_compliance_report.sh --config rds_backup_compliance_report.conf.example -A

# See which calls would run, without calling anything
./rds_backup_compliance_report.sh -A --dry-run

# Audit manual snapshots older than 90 days (CSV, oldest first)
./rds_backup_compliance_report.sh -A --manual-older-than 90 -o ./out
./rds_backup_compliance_report.sh --merge ./saved -F html -o ./out --manual-older-than 180
# In the HTML: Backups tab -> "Old manual snapshots (> 90 days)", or pick Backup type and Age yourself

# Orphaned manual snapshots (source cluster/instance deleted), with a custom $/GB-month
./rds_backup_compliance_report.sh -A -F html,csv -o ./out --snapshot-price-per-gb 0.019
# -> *_orphaned_snapshots.csv; in the HTML: Backups tab -> "Orphaned snapshots"

# Offline merge (Git Bash on Windows works too)
./rds_backup_compliance_report.sh --merge rds_backup_111111111111_20261030.json rds_backup_222222222222_20261030.json -o all.html
./rds_backup_compliance_report.sh --merge "./saved data/" -F csv -o ./merged
```

Sample outputs from the mock fleet are in `samples/`, and screenshots are in `docs/`.

## v1.3.0

```bash
# Saturday weekly / first-Sunday monthly schedule (the defaults), stricter: no ±1 day tolerance
./rds_backup_compliance_report.sh -A --tolerance-days 0 -F html,csv -o ./out

# Weekly runs on Sunday, check the last 5 of them; monthly on the first Saturday
./rds_backup_compliance_report.sh -A --weekly-weekday sun --weekly 5 --monthly-rule first-sat

# You also keep yearly backups: turn the yearly check back on
./rds_backup_compliance_report.sh -A --yearly 1

# Scan up to 8 regions at once, or one at a time
./rds_backup_compliance_report.sh -A --parallel 8
./rds_backup_compliance_report.sh -A --parallel 1
```

The run ends with the output files:

```
[INFO] 111111111111: 17 regions scanned, 15 empty: ap-northeast-1, ap-northeast-2, ...
Output (4 files):
  /home/cloudshell-user/out/rds_backup_compliance_111111111111_20261031_144500.html
  /home/cloudshell-user/out/rds_backup_compliance_111111111111_20261031_144500.csv
  /home/cloudshell-user/out/rds_backup_compliance_111111111111_20261031_144500_backups.csv
  /home/cloudshell-user/out/rds_backup_compliance_111111111111_20261031_144500_orphaned_snapshots.csv
```

## v1.3.1

```bash
# Show every region line, empty regions included
./rds_backup_compliance_report.sh -A -v

# Why is weekly 0/4? List each AWS Backup recovery point and why it did or did not count
./rds_backup_compliance_report.sh -r us-east-1 -i orders-aurora-pg15 -F json \
  | jq -r '.rows[0].recovery_points[] | [.date, .ret, .class, .status, .counted, .reason] | @tsv'
```

```
2026-10-24 Sat  35   weekly    COMPLETED  true   weekly: counts for Sat 24 Oct, retention 35d in weekly window 25-40d
2026-10-21 Wed  2555 mismatch  COMPLETED  false  retention 2555d outside weekly window 25-40d and monthly window 300-400d
(v1.4.0 words these differently, see below)
```

The same table is in the HTML report: click a row to open it. CSV columns per check (`weekly_found`, `weekly_expected`, `weekly_missing`, ...) are plain numbers or `YYYY-MM-DD Day` text that Excel keeps as text.

## v1.4.0

```bash
# Strict retention is on by default (weekly 30d, monthly 365d, daily 7, ±1d). Your weekly plan keeps 35 days on purpose:
./rds_backup_compliance_report.sh -A --weekly-retention-days 35
# or in the conf file
#   WEEKLY_RETENTION_DAYS=35
#   MONTHLY_RETENTION_DAYS=365
#   RET_TOLERANCE_DAYS=1

# Which resources have the wrong retention, too many backups, or old automated backups?
./rds_backup_compliance_report.sh -A -F json \
  | jq -r '.rows[] | select(.retention_mismatch != "" or .excess != "" or .over_retention != "")
           | [.identifier, .retention_mismatch, .excess, .over_retention] | @tsv'

# Compliance percentage (not-yet-due resources are not counted)
./rds_backup_compliance_report.sh -A -F json | jq '.totals.compliance'
```

```
reports-pg      weekly point has 35d, expected 30d (x9)  weekly 9 (expected 4-5)
legacy-mysql    weekly point has 35d, expected 30d (x5)                           holds 7 automated backups for 7d retention; 2 older than 7d, oldest rds:legacy-mysql-2026-10-23-01-00 (9d)
{"compliant": 2, "of": 6, "not_yet_due": 2, "pct": 33}
```

Recovery-point reasons now read `weekly: counts for Sat 24 Oct, but weekly point has 35d, expected 30d` (or `..., retention 30d as expected`).
In the HTML: Compliance tab -> Show "Retention mismatch" / "Excess backups" / "Holds more than retention", or type in Search; Backups tab -> Account and Search work for one resource too, and Reset clears everything.


## v1.4.1

Cross-tab links: click a resource on the Backups tab to open its Compliance row (expanded and highlighted), or click `backups` on a Compliance row to see its backups. Browser Back returns to where you were. Bookmarkable: `report.html#view=comp&id=111111111111%7Cus-east-1%7Corders-aurora-pg15`.
