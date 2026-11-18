# Examples

```bash
# Everything from rds_backup_compliance_report.conf (shipped: current login, every region, HTML + CSV into ./reports)
./rds_backup_compliance_report.sh

# Current login and region only, text summary on the screen (CLI overrides the file for this run)
./rds_backup_compliance_report.sh -r us-east-1 -F text -o ''

# Every region, HTML and CSV (compliance and backups), and save the data for merging
./rds_backup_compliance_report.sh -A -F html,csv --save-data -o ./out

# Only Aurora PostgreSQL, two regions, non-compliant rows only
./rds_backup_compliance_report.sh -r us-east-1,us-west-2 -e aurora-postgresql --non-compliant-only

# Stricter daily freshness and a different weekly window
./rds_backup_compliance_report.sh -A --daily-max-age 24 --weekly-days 20-45 -F html -o ./out

# Use it as a CI gate
./rds_backup_compliance_report.sh -A --fail-on-noncompliant -F json -o ./out || echo "exit $?"

# Another complete settings file instead of the one next to the script (see "The settings file" below)
./rds_backup_compliance_report.sh --config /home/cloudshell-user/configs/prod.conf

# Validate the settings and exceptions files without calling AWS
./rds_backup_compliance_report.sh --check-config

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
# or in rds_backup_compliance_report.conf (v1.7.1: change the existing lines; each key appears once)
#   weekly-retention-days=35
#   monthly-retention-days=365
#   retention-tolerance-days=1

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

## v1.5.4

`oracle-*` (or any non-Aurora glob) no longer blanks daily counts on Aurora global secondaries. Global DB members list together in every format (primary then secondary).

```bash
# Oracle replicas only: Aurora secondaries still show daily have/need
./rds_backup_compliance_report.sh -A --replica-exempt-engines oracle-* -F html,csv -o ./out
```

## v1.5.3

HTML Account filters and the Per-region / Backups Account columns show `name (number)` when an account name is set (same as the main table and TXT header). Search also matches the account name. No new conf keys.

## v1.5.2

```bash
# Oracle replicas and Aurora global secondaries: always COMPLIANT (no backup counts)
./rds_backup_compliance_report.sh -A --replica-exempt-engines oracle-*,aurora-* -F html,csv -o ./out

# Same via rds_backup_compliance_report.conf (shipped value since v1.7.1), with friendly account names
#   replica-exempt-engines=oracle-*,aurora-*
#   111111111111 = prod-core
#   222222222222 = nonprod-shared
./rds_backup_compliance_report.sh -A -F html,csv -o ./out
```

Account names show as `name (number)` when set (config wins over the IAM alias). The compliance CSV ends with an `account_name` column.


## Role column: `primary` instead of `none` (v1.7.0)

The `global_role` column (CSV, JSON, text and HTML) now says `primary` for every instance or cluster that is not a replica or a global-database secondary. Before, standalone instances, plain clusters and Oracle sources showed `none`. The column name is unchanged. Statuses, counts and filters are unchanged.

Before (v1.6.0 and older), compliance CSV, selected columns:

```text
account_id    identifier            type      engine              global_cluster  global_role  status
111111111111  billing-aurora-mysql  cluster   aurora-mysql        -               none         NON-COMPLIANT
111111111111  legacy-mysql          instance  mysql               -               none         NON-COMPLIANT
111111111111  orders-aurora-pg15    cluster   aurora-postgresql   orders-global   primary      COMPLIANT
111111111111  orders-dr-pg15        cluster   aurora-postgresql   orders-global   secondary    COMPLIANT
333333333333  erp-oracle            instance  oracle-ee           -               none         COMPLIANT
333333333333  erp-oracle-rr         instance  oracle-ee           -               replica      NON-COMPLIANT
```

After (v1.7.0), same data:

```text
account_id    identifier            type      engine              global_cluster  global_role  status
111111111111  billing-aurora-mysql  cluster   aurora-mysql        -               primary      NON-COMPLIANT
111111111111  legacy-mysql          instance  mysql               -               primary      NON-COMPLIANT
111111111111  orders-aurora-pg15    cluster   aurora-postgresql   orders-global   primary      COMPLIANT
111111111111  orders-dr-pg15        cluster   aurora-postgresql   orders-global   secondary    COMPLIANT
333333333333  erp-oracle            instance  oracle-ee           -               primary      COMPLIANT
333333333333  erp-oracle-rr         instance  oracle-ee           -               replica      NON-COMPLIANT
```

If a script or spreadsheet filtered on `global_role = none`, change it to `primary`. To find only members of an Aurora global database, filter on a non-empty `global_cluster`. Reports merged from older saved data (`--merge`) also show `primary` where that data says `none`. An instance that replicates from a Multi-AZ cluster now shows `replica`.

## The settings file (v1.7.1)

One file holds every setting: `rds_backup_compliance_report.conf`, in the **same folder as `rds_backup_compliance_report.sh`**. It comes in the zip with every value filled in, is loaded automatically, and is required.

### 1. Edit the shipped file

```bash
cd /home/cloudshell-user/rds-backup-compliance
cp rds_backup_compliance_report.conf rds_backup_compliance_report.conf.mine   # keep a copy for upgrades
vi rds_backup_compliance_report.conf
```

Only change values; keep every key. For example, three accounts, a 35-day weekly plan, e-mail to the DBA team (fake account numbers):

```text
## ============================== Accounts and regions ==============================
profile=prod,nonprod,dev
all-regions=yes
...
weekly-retention-days=35
...
## ============================== Email ==============================
alert-email=dba-team@example.com
alert-from=rds-reports@example.com
alert-on=noncompliant
## ============================== Account names (display only) ==============================
111111111111 = prod-payments
222222222222 = nonprod-shared
333333333333 = dev-sandbox
```

`weekly-window-days` is empty in the shipped file, so the weekly check now looks back 35 days too.

### 2. Check it (no AWS calls)

```bash
./rds_backup_compliance_report.sh --check-config
./rds_backup_compliance_report.sh --check-config --weekly 4 -P prod     # CLI values show source CLI
```

Sample (abridged; the full list has every setting):

```text
Config file:     /home/cloudshell-user/rds-backup-compliance/rds_backup_compliance_report.conf (next to the script)
Exceptions file: /home/cloudshell-user/rds-backup-compliance/compliance_exceptions.conf (auto-loaded from the script folder)
Script folder:   /home/cloudshell-user/rds-backup-compliance

Settings in effect (name, value, source: conf = the config file above, CLI = command line):
  profile                    prod                           CLI
  all-regions                yes                            conf
  daily                      7                              conf
  daily-max-age              26                             conf
  weekly-retention-days      35                             conf
  weekly                     4                              CLI
  weekly-window-days         = weekly-retention-days (35)   conf
  keep-reports               30 days                        conf
  alert-email                dba-team@example.com           conf

Account names (3):
  111111111111 = prod-payments
  222222222222 = nonprod-shared
  333333333333 = dev-sandbox

Exceptions (1); today is 2026-11-18 UTC:
  line 1: 111111111111 legacy-mysql scope=backup expires 2027-03-31 - Decommission in Q1

E-mail: to dba-team@example.com when NON-COMPLIANT or AWS errors
  mail command: /usr/sbin/sendmail (HTML report attached when html is a format)

OK: configuration is valid (no AWS calls made)
```

Errors stop with exit 1:

```text
[ERROR] Settings file not readable: /home/cloudshell-user/rds-backup-compliance/rds_backup_compliance_report.conf
    Every setting comes from rds_backup_compliance_report.conf. Put the shipped file next to the script (...),
    or point --config at a complete copy. A fresh copy is in the release zip.
[ERROR] Config .../rds_backup_compliance_report.conf is missing 3 required setting(s): daily, weekly-weekday, alert-on
[ERROR] Config .../rds_backup_compliance_report.conf:41: 'daily' is set twice (also on line 27); keep one line
[ERROR] Config .../rds_backup_compliance_report.conf:90: --weekly must be a whole number (got 'x')
```

### 3. Run

```bash
./rds_backup_compliance_report.sh                                   # everything from the file
./rds_backup_compliance_report.sh --daily 14 -P prod                 # CLI wins for this run
./rds_backup_compliance_report.sh -r us-east-1 -F text -o '' -l ''   # one region, text on the screen, no files
./rds_backup_compliance_report.sh --config /home/cloudshell-user/configs/prod.conf   # another complete file
```

A v1.7.0-style partial file (only a few keys) now stops with the list of missing keys: copy them from the shipped file. `--no-config` no longer exists.

### 4. Report retention

With `keep-reports=30`, each run ends by deleting this tool's report files older than 30 days from `output-dir`:

```text
[INFO] keep-reports: deleted rds_backup_compliance_111111111111_20251001_020000.html (older than 30 days)
[INFO] keep-reports: deleted rds_backup_compliance_111111111111_20251001_020000.csv (older than 30 days)
[INFO] keep-reports: 2 old report file(s) deleted from /home/cloudshell-user/rds-backup-compliance/reports (keeping 30 days)
```

Files with another name, sub-folders, `run.log` and `--save-data` files are never deleted. `keep-reports=0` keeps everything.

### 5. E-mail

```bash
./rds_backup_compliance_report.sh --alert-test                       # one test e-mail, no AWS calls
./rds_backup_compliance_report.sh --alert-on always                  # e-mail even when all compliant
```

Sample e-mail (fake accounts):

```text
Subject: [rds_backup_compliance] NON-COMPLIANT: 3 non-compliant of 6, 25% compliant

RDS backup compliance report from jumpbox-01 (rds_backup_compliance_report.sh v1.7.1)
Accounts: prod-payments (111111111111)

Resources: 6   Compliant: 1   Non-compliant: 3   Not yet due: 2   Unknown: 0
Compliance: 25% (1 of 4; not yet due not counted)

NON-COMPLIANT servers (3):
  - prod-payments (111111111111) us-east-1 billing-aurora-mysql (aurora-mysql): weekly 3/4 missing Sat 07 Nov
  - prod-payments (111111111111) us-east-1 legacy-mysql (mysql): daily: last automated 74h ago; daily 4/7 missing Sun 15 Nov, Mon 16 Nov, Tue 17 Nov
  - prod-payments (111111111111) us-east-1 reports-pg (postgres): daily: retention 3d < 7d; daily 3/7 missing Wed 11 Nov, Thu 12 Nov, Fri 13 Nov, Sat 14 Nov

Report files:
  /home/cloudshell-user/rds-backup-compliance/reports/rds_backup_compliance_111111111111_20261118_011013.html
  ...
Attachment (sendmail only): rds_backup_compliance_111111111111_20261118_011013.html
```

## Exceptions (v1.6.0)

Approved exceptions for servers you know are non-compliant. Same shared file as rds-patch-compliance and rds-compliance-report. Matched, unexpired entries (scope `backup` or `patch,backup`) show as **Compliant (exception)** / `COMPLIANT (EXCEPTION)`, count as compliant in every %, and appear in the pop-up as `compliant N (incl. X exceptions)`. The HTML gets an Exception column and an Exceptions quick filter (all / exceptions only / non-exceptions / expiring soon or no longer needed / expired). Flags: **expiring soon** (14 days or less), **no longer needed** (already compliant), **exception expired**. CSV columns at the end: `exception`, `exception_reason`, `exception_expires`, `exception_flag`, `actual_status`. With no file the reports are exactly as before. Applied when the report is built; `--save-data` files never change.

### 1. Set up the file

```bash
cp /home/cloudshell-user/rds-backup-compliance/compliance_exceptions.conf.example \
   /home/cloudshell-user/rds-backup-compliance/compliance_exceptions.conf
vi /home/cloudshell-user/rds-backup-compliance/compliance_exceptions.conf
```

One entry per line, all five fields required (`account_id | identifier | scope | expires | reason`). Sample:

```text
# account_id | identifier   | scope        | expires    | reason
111111111111 | legacy-mysql | backup       | 2027-03-31 | Decommission in Q1, CHG-1234 (owner: dba-team)
111111111111 | reports-pg   | patch,backup | 2027-03-31 | Vendor-pinned version, backups by vendor tool | INC-77
111111111111 | billing-pg   | patch        | 2026-12-31 | Patch-only waiver (not applied by the backup tool)
```

`expires` is mandatory `YYYY-MM-DD` (UTC), last day the exception applies. `#` comments and blank lines are ignored. The real `compliance_exceptions.conf` is in `.gitignore`.

### 2. Default run (file next to the script)

If `compliance_exceptions.conf` sits next to the script it is picked up automatically:

```bash
/home/cloudshell-user/rds-backup-compliance/rds_backup_compliance_report.sh -A -F html,csv \
  -o /home/cloudshell-user/out
```

### 3. Custom location

```bash
mkdir -p /home/cloudshell-user/configs
cp /home/cloudshell-user/rds-backup-compliance/compliance_exceptions.conf.example \
   /home/cloudshell-user/configs/compliance_exceptions.conf
# edit /home/cloudshell-user/configs/compliance_exceptions.conf, then:
/home/cloudshell-user/rds-backup-compliance/rds_backup_compliance_report.sh -A -F html,csv \
  -o /home/cloudshell-user/out \
  --exceptions /home/cloudshell-user/configs/compliance_exceptions.conf
```

Config file alternative: `exceptions = /home/cloudshell-user/configs/compliance_exceptions.conf` (CLI `--exceptions` wins).

### 4. Multi-account: `--save-data` then `--merge`

Exceptions are applied when the report is built. `--save-data` files are unchanged (with or without `--exceptions`).

```bash
# CloudShell, once per account (read-only) -> rds_backup_<ACCOUNT>_<YYYYMMDD>.json
/home/cloudshell-user/rds-backup-compliance/rds_backup_compliance_report.sh -A --save-data \
  -o /home/cloudshell-user/data

# Offline merge: exceptions applied here
/home/cloudshell-user/rds-backup-compliance/rds_backup_compliance_report.sh \
  --merge /home/cloudshell-user/data -F html,csv -o /home/cloudshell-user/out \
  --exceptions /home/cloudshell-user/configs/compliance_exceptions.conf
```

### 5. Validation error (run stops, exit 1, before any AWS call)

A missing field, a bad account / scope / date, or a duplicate account + identifier for the same scope stops the run with `file:line`. Real captured output:

Invalid date (2027 is not a leap year):

```text
2026-11-09 16:08:06 [ERROR] Exceptions /home/cloudshell-user/rds-backup-compliance/compliance_exceptions.conf:3: expires '2027-02-29' is not a valid date
```

Wrong date format:

```text
2026-11-09 16:08:06 [ERROR] Exceptions /home/cloudshell-user/rds-backup-compliance/compliance_exceptions.conf:3: expires must be a date YYYY-MM-DD (got '01-01-2027'); an expiry date is mandatory
```

Duplicate (case-insensitive identifier; `patch,backup` collides with an existing `backup` row):

```text
2026-11-09 16:08:06 [ERROR] Exceptions /home/cloudshell-user/rds-backup-compliance/compliance_exceptions.conf:3: duplicate entry for 111111111111 GOOD-db (backup), already on line 2
```

Fix: correct the date to a real `YYYY-MM-DD`, or remove / change the duplicate line so each account + identifier appears at most once per scope (`patch` and `backup` may both be listed, either as two lines or as `patch,backup`).

### 6. Turning exceptions off

```bash
# rename (keep for later)
mv /home/cloudshell-user/rds-backup-compliance/compliance_exceptions.conf \
   /home/cloudshell-user/rds-backup-compliance/compliance_exceptions.conf.off

# or remove
rm /home/cloudshell-user/rds-backup-compliance/compliance_exceptions.conf
```

With no file (and no `--exceptions`), the report matches the pre-exceptions behaviour.
