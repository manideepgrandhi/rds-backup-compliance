# rds-backup-compliance: full reference

This is the long version of the [README](README.md): every rule, setting, output and note in one place. Plain-English release notes are in [CHANGELOG.md](CHANGELOG.md) and on the [What's new](https://manideepgrandhi.github.io/rds-backup-compliance/) page. The technical version notes are at the end of this file.

`rds_backup_compliance_report.sh` v1.7.2 checks whether Aurora clusters and standalone RDS instances keep the backups the policy asks for. It makes only read-only calls and needs Bash, jq and AWS CLI v2. It is built to run in AWS CloudShell, one account at a time. You can then merge the results offline, including in Git Bash on Windows with `jq.exe`.

## Contents

- [Install (CloudShell)](#install-cloudshell)
- [Quick start](#quick-start)
- [Policy](#policy)
  - [Strict retention (v1.4.0)](#strict-retention-v140)
  - [Status](#status)
- [Outputs](#outputs)
  - [Manual snapshot audit CSV](#manual-snapshot-audit-csv)
  - [Orphaned manual snapshots](#orphaned-manual-snapshots)
  - [Several accounts](#several-accounts)
- [Scanning regions in parallel](#scanning-regions-in-parallel)
- [The settings file (v1.7.1)](#the-settings-file-v171)
  - [`--check-config`](#--check-config)
- [Report retention: `keep-reports` (v1.7.1)](#report-retention-keep-reports-v171)
- [E-mail: `alert-email` (v1.7.1)](#e-mail-alert-email-v171)
- [Compliance exceptions (v1.6.0)](#compliance-exceptions-v160)
- [Exit codes](#exit-codes)
- [Permissions (read-only)](#permissions-read-only)
- [Limitations](#limitations)
- [Tests](#tests)
- [Changelog](#changelog)

## Install (CloudShell)

```bash
curl -fsSLO https://github.com/manideepgrandhi/rds-backup-compliance/releases/latest/download/rds-backup-compliance.zip && curl -fsSLO https://github.com/manideepgrandhi/rds-backup-compliance/releases/latest/download/rds-backup-compliance.zip.sha256
sha256sum -c rds-backup-compliance.zip.sha256 && unzip -oq rds-backup-compliance.zip && cd rds-backup-compliance
./rds_backup_compliance_report.sh -A -F html,csv --save-data -o ./out
```

All settings come from [rds_backup_compliance_report.conf](rds_backup_compliance_report.conf), which is in the zip next to the script. With the shipped values, `./rds_backup_compliance_report.sh` on its own scans every region of the current login and writes HTML and CSV into `./reports`. Edit the file once (see [The settings file](#the-settings-file-v171)) and check it with `--check-config`.

`sha256sum -c` must print `rds-backup-compliance.zip: OK`. If it reports `FAILED`, the `&&` chain stops before `unzip`; delete the zip and do not run it. Releases from v1.2.1 on publish `rds-backup-compliance.zip.sha256` next to the zip.

## Quick start

```bash
cd rds-backup-compliance
vi rds_backup_compliance_report.conf                       # profile, region / all-regions, alert-email ...
./rds_backup_compliance_report.sh --check-config           # validate it, no AWS calls
./rds_backup_compliance_report.sh                          # HTML + CSV into ./reports
./rds_backup_compliance_report.sh -F text -o '' --non-compliant-only   # quick look on the screen
./rds_backup_compliance_report.sh --alert-test             # test the e-mail settings
```

More, with sample output for each: [Usage examples](EXAMPLES.md#usage-examples-v172). They cover the first run, several accounts, scheduled jobs and exit codes, one-off overrides, `--config`, e-mail, `keep-reports`, the manual snapshot audit, a cron job and the exceptions file.

## Policy

The default rules follow this schedule: RDS automated backups daily (7-day retention), AWS Backup every Saturday (kept about a month) and on the first Sunday of each month (kept a year). There are no yearly backups, so the yearly check is off.

| Check | Source | Default rule | Applies to |
|---|---|---|---|
| Daily | RDS automated backups | Retention ≥ 7 days, an automated snapshot on each of the last 7 UTC days, and the latest one ≤ 26 h old | Every resource |
| Weekly | AWS Backup | A recovery point for every Saturday in the last 30 days (`--weekly auto`), or for the last N Saturdays (`--weekly N`) | Primary clusters, non-global clusters, standalone instances |
| Monthly | AWS Backup | A recovery point for the first Sunday of each of the last 12 months | Same as weekly |
| Yearly | AWS Backup | Off (`yearly=0`). `--yearly N` turns it on: N points in distinct years with retention over the monthly range | Same as weekly |

- **Scheduled dates.** A point counts for a scheduled date when it was taken that UTC day, or up to `--tolerance-days` (default 1) before or after. A scheduled day that has not ended yet and has no point is not expected yet.
- **Creation date.** Dates on or before the day a resource was created are never expected. A resource that is still building up shows `3/3 so far (target 5)` and `weekly full on 10 Nov 2026`.
- **Missing dates.** Failing checks list the dates they miss, for example `weekly 4/5 missing Sat 24 Oct` or `monthly 10/12 missing May 2026, Aug 2026`.

AWS Backup recovery points are classified by their retention, which is CreationDate → CalculatedLifecycle.DeleteAt:

| Retention | Class |
|---|---|
| 25–40 days | Weekly |
| 300–400 days | Monthly |
| Over 400 days, or never expires | Yearly, only when `yearly` > 0 |
| Anything else | Mismatch: not counted, and the resource gets a yellow warning such as `retention doesn't match: 2 recovery points (2555d, never expires) not counted` |

### Check mode: counts (v1.8.0)

`check-mode=schedule` (the default) is the policy above: a point for every scheduled day. `check-mode=counts` (or `--check-mode counts`) drops the calendar and counts backups in a window instead, whatever weekday they ran on. A backup you re-run late counts like the original, so a missed Saturday that you re-run on Monday brings the weekly check back to 4/4.

| Check | Rule in `counts` mode | Numbers come from |
|---|---|---|
| Daily | At least `daily` of the last `daily` UTC days have an RDS automated backup (the same day count as schedule mode, which never used tolerance). Retention ≥ `daily` and newest ≤ `daily-max-age` hours stay as they are | `daily`, `daily-max-age` |
| Weekly | At least N AWS Backup points with retention in `weekly-days`, created in the last `weekly-window-days` days (default `weekly-retention-days`, 30), on any weekday. N = `weekly`; `auto` = floor(window / 7), 4 for 30 days | `weekly`, `weekly-window-days`, `weekly-days` |
| Monthly | At least `monthly` AWS Backup points with retention in `monthly-days`, created in the last `monthly` months counted back from today's date, plus 7 days of slack. A catch-up point counts like a regular one, so this is a total, not one per month | `monthly`, `monthly-days` |
| Yearly | Unchanged | `yearly` |

- **Ignored in `counts` mode:** `weekly-weekday`, `monthly-rule` and `tolerance-days`. They stay required in the conf so one file works in both modes.
- **Unchanged in `counts` mode:** the retention checks (`retention mismatch`, excess backups, holds more than retention, points outside `weekly-days` / `monthly-days` not counted), replica and global-secondary rules, `replica-exempt-engines`, exceptions, `--merge` (the mode is applied when the report is made, so saved data works in either mode) and the e-mail summary.
- **Young servers stay NOT YET DUE.** A server expects only what its age allows: whole closed days for daily, whole weeks since creation for weekly (at most the target) and whole months since the month it was created, not counting the current one, for monthly. A server that has all of that but not the full target shows `2/2 so far (target 4)` and `weekly full on 20 Dec 2026`; one that is missing some of it is NON-COMPLIANT.
- **Gaps** name the window instead of dates: `weekly 3/4 in last 30d`, `daily 6/7 in last 7d`, `monthly 11/12 in last 12 months`. The CSV and JSON `missing` fields are empty in `counts` mode.
- **Weekly window.** Days are UTC dates, today included; 30 days always holds at least four Saturdays, so a healthy Saturday job reads 4/4 on any day.
- **Monthly caveat.** The retention of the monthly point limits what can be counted: with `monthly=12` and a 365-day retention, the point of 12 months ago expires a few days before a first-Sunday that moved later in the calendar is due, so a healthy server can read `11/12` for a few days a year (for example 3 Feb 2027). Schedule mode shows the same thing on those days. Keep monthly points a little longer than a year, or use `monthly=11`.
- **Output.** The text rule line, the HTML header and the JSON `thresholds` say `counts` (JSON gets `check_mode`; in `schedule` mode the key is absent so the output stays identical to 1.7.2).

### Strict retention (v1.4.0)

The ranges above decide whether a point **counts**. On top of that, each counted point is compared with the retention the schedule expects:

| Backup | Expected retention | Option / conf key |
|---|---|---|
| Daily (RDS) | `BackupRetentionPeriod` = 7 (the `daily` value) | `--daily-retention-days N` / `DAILY_RETENTION_DAYS` |
| Weekly (AWS Backup) | 30 days | `--weekly-retention-days N` / `WEEKLY_RETENTION_DAYS` |
| Monthly (AWS Backup) | 365 days | `--monthly-retention-days N` / `MONTHLY_RETENTION_DAYS` |
| Allowed difference | ±1 day | `--retention-tolerance-days N` / `RET_TOLERANCE_DAYS` |

A point with another retention (say a 35-day weekly point) **still counts**, so the status does not change, but it is highlighted in yellow: `retention mismatch: weekly point has 35d, expected 30d (x5)`. A daily retention above 7 is flagged the same way (below 7 is already a gap). The diagnostics reason says so too: `weekly: counts for Sat 24 Oct, but weekly point has 35d, expected 30d`.

Two more yellow warnings, also without changing the status:

- **Excess backups:** more points than the schedule makes, for example `weekly 9 (expected 4-5)`. The expected count is daily 7 (+1 for the backup in progress), weekly 4–5 (the Saturdays that fit in 30 days) and monthly 12. Likely causes: two backup plans or rules select the resource, or an on-demand job ran.
- **Holds more than retention:** more automated RDS backups than the retention allows, for example `holds 21 automated backups for 7d retention; 13 older than 7d, oldest rds:db-2026-10-12-00-00 (20d)`. Likely causes: backups stopped so old ones are not replaced, the retention was lowered recently, the instance is stopped, or a snapshot is in use (copy, export or restore).

You can change these with `--weekly-days MIN-MAX`, `--monthly-days MIN-MAX`, `--weekly-weekday sat`, `--monthly-rule first-sun`, `--tolerance-days N` (0–3) and `--weekly-window-days N`.

How the role of each resource is decided:

- **Role column** (`global_role`, "Global role" in the page): every cluster and instance gets a role.
  - **Instances** are `replica` when RDS reports a replication source (`ReadReplicaSourceDBInstanceIdentifier`, or `ReadReplicaSourceDBClusterIdentifier` for a replica of a Multi-AZ cluster). All other instances are `primary`: standalone and source instances of every engine, including Oracle (v1.7.0; older versions showed `none`).
  - **Clusters:** the writer of an Aurora global database is `primary` and its other members are `secondary`. A cluster that replicates from another cluster is `replica`. Any other cluster is `primary`. If `describe-global-clusters` is denied, clusters show `unknown` (replicas still show `replica`).
  - The role does not change a status. `primary`, `unknown` and (in older saved data) `none` all get the full checks. Only a `primary` that belongs to an Aurora global database counts as global: the Aurora global DB and Global role filters in the page ignore standalone primaries.
- **Global cluster roles** come from `describe-global-clusters`. Secondaries are checked for daily backups only, and their weekly, monthly and yearly checks show N/A.
- **Read replicas** (cross-region cluster replicas and instance read replicas) are checked for daily backups only.
- **`replica-exempt-engines`** (v1.5.2): engines matching these globs with Role=`replica` or Role=`secondary` skip every backup check and are COMPLIANT. Use for Oracle replicas or Aurora global secondaries that keep no local backups on purpose.
- **Aurora cluster member instances** are not listed separately.
- **DocumentDB and Neptune** are excluded.

### Status

| Status | Meaning |
|---|---|
| COMPLIANT | All applicable checks pass. |
| NON-COMPLIANT | At least one check fails. The **Gaps** column says which and lists the missing dates, for example `weekly 4/5 missing Sat 24 Oct`. |
| NOT YET DUE | The resource is too new to have the full set, and it has a backup for every scheduled date since it was created. The `not_yet_due` column says when each check will be full, for example `daily full on 02 Nov 2026`. |
| UNKNOWN | A needed call was denied or failed, for example `backup:ListRecoveryPointsByBackupVault`. |

## Outputs

All outputs show the account number, and every time is shown in UTC and IST (`--tz` changes the second zone). File names follow `<prefix>_<account>_<UTC stamp>.<ext>`. Regions with no databases are left out.

| Format | What you get |
|---|---|
| text | Console summary, with a `Compliance: 33% (2 of 6), 2 not yet due not counted` line and the yellow warnings in the WARNINGS column. |
| csv | Compliance CSV with numeric columns per check: `<check>_status`, `_found`, `_expected`, `_target`, `_missing` (`2026-10-24 Sat; ...`) and `_full_on`, then (v1.4.0) `retention_mismatch_count`, `retention_mismatch`, `excess_daily`, `excess_weekly`, `excess_monthly` (number over the expected maximum, blank when the check is N/A), `excess`, `over_retention_count`, `over_retention` and `counted_in_compliance_pct` (`yes`, or `no` for not yet due). No cell is a value Excel turns into a date. With `-o`, you also get `<name>_backups.csv`, which lists every manual snapshot, automated backup and AWS Backup recovery point. |
| json | Rows and raw backups. |
| html | Two tabs, described below. |

The HTML report has two tabs:

- **Compliance tab:**
  - Cards: **NN% compliant (x of y)** first (not-yet-due resources are left out of the denominator and shown under it), then the totals. Cards follow the filters.
  - Filters for account, region, type, engine, role, global cluster and status, a **Search** box (identifier, engine, region, account, AWS Backup vault or plan), and **Show:** Not yet due / Points not counted (retention) / Retention mismatch / Excess backups / Holds more than retention.
  - The **Per region** table (with a % compliant column and an "All regions" total) sits right under the filters and follows them.
  - Yellow tags in the Gaps cell for retention mismatch, excess backups and holds more than retention; the detail row gives the full text and likely causes, and mismatched recovery points are yellow rows.
  - A Created column (date and age in days). Yearly shows only when `yearly` > 0.
  - Compact count cells (`4/5` with a red `1 missing` tag; hover for the dates) and a one-line Gaps summary. Fixed column widths that wrap; on a phone the table scrolls sideways.
  - Click a row (or its ▶ caret, or Enter on it) to open its detail row: full gaps, not-yet-due and warnings, a per-check table, and every AWS Backup recovery point with created date, retention, class, status, whether it counted and why.
  - Export CSV, which exports the filtered rows with exactly the same columns and quoting as the script's CSV.
  - Region errors, if any.
- **Backups tab:**
  - **Resource:** "All clusters and instances" (the first option) or one cluster or instance.
  - **Backup type:** All types, Manual, Automated or AWS Backup.
  - **Age:** Last 3, 6 or 12 months (newest first); Older than 30, 90, 180 or 365 days (oldest first); or Any age.
  - **Account** works in every mode: in single view it narrows the Resource list (a resource in another account switches to All).
  - **Search:** resource identifier, engine, region, account, AWS Backup vault or plan, or snapshot / recovery point id.
  - Yellow rows: AWS Backup points with an unexpected retention and automated backups older than the retention (hover for the reason).
  - **Reset** puts every dropdown back (Resource to All clusters and instances), clears the search and restores newest-first order.
  - **Single resource:** a Retention settings section, then three sections (manual, RDS automated, AWS Backup with class, retention, expiry and vault). Backup type shows only the chosen section.
  - **All clusters and instances:** one combined table with Account, Region, Resource, Resource type, Backup type, Created (UTC and IST), Age (days), Status, Size GB, Rule (daily for automated; weekly, monthly, mismatch, or yearly when it is on, for AWS Backup), Retention and Vault. The Account, Region and Engine filters narrow it.
  - A count and total GB of the matching rows, and **Export CSV** of exactly what is shown (all filters applied).
  - To audit leftover manual snapshots, set Backup type = Snapshot: manual and Age = Older than 90 days.
  - Manual snapshots of any age are kept in the data (nothing is trimmed to 12 months).

### Manual snapshot audit CSV

`--manual-older-than N` also writes `<prefix>_<account>_<stamp>_manual_older_than_<N>d.csv`. It lists every manual snapshot older than N days, oldest first, with account, region, identifier, type, engine, snapshot, created (UTC and IST), age_days, status and size_gb. It works for live scans and with `--merge`, and is written to `-o DIR`. With `-o ''` (screen only, v1.7.2) no file is written: the rows are printed on the screen (stderr) instead.

### Orphaned manual snapshots

A manual snapshot is **orphaned** when its source cluster or instance no longer exists in the same account and region. Each region's manual snapshots are read in full (with `--include-shared`), including regions that have no databases left; such regions show as `snapshots only`. With `--merge`, matching is still per account and region.

| Source status | Meaning |
|---|---|
| Existing | The source cluster/instance exists (a cross-region copy whose source exists in its scanned source region also counts) |
| Orphaned | The source is gone: counted in the summary and cost estimate |
| Shared | Shared with this account, or copied from another account: listed, never counted |
| Unverified | A cross-region copy whose source region was not scanned (use `-A` or add that region) |

AWS Backup recovery points, automated snapshots, `awsbackup:` snapshots and DocumentDB/Neptune snapshots are not part of the orphan logic.

- **Summary**, in the Compliance header and the Backups tab: e.g. `4 orphaned snapshots, 1.8 TB, ~$38/month (estimate)`. The estimate is size GB × `--snapshot-price-per-gb` (`snapshot-price-per-gb` in the settings file, shipped 0.021). It is a **rough upper estimate**: snapshot storage is billed incrementally, so the real cost is usually lower.
- **Backups tab, All clusters and instances:** a Source status filter (All, Existing, Orphaned, Shared, Unverified when present), Source and Est. $/month columns, a clickable orphaned count in the orphan summary line, and `(deleted) <id>` entries in the Resource dropdown.
- **CSV:** with `csv` in `-F`, `<prefix>_<account>_<stamp>_orphaned_snapshots.csv` (oldest first: account_id, region, snapshot_id, type, source_id, engine, engine_version, created_utc, created_ist, age_days, size_gb, est_monthly_usd, encrypted, kms_key), for live scans and `--merge`. `_backups.csv` and the in-page export gain a `source_status` column.
- Data saved by v1.0.0 and v1.1.0 still merges; those accounts simply have no orphan data.

### Several accounts

```bash
# CloudShell, once per account:
./rds_backup_compliance_report.sh -A --save-data -F html -o ./out      # writes rds_backup_<ACCOUNT>_<YYYYMMDD>.json
# Windows Git Bash, offline (CRLF files, spaces in paths and jq.exe are fine):
./rds_backup_compliance_report.sh --merge "/c/Users/me/RDS backups/" -o "/c/Users/me/RDS backups/all.html"
```

Compliance is re-evaluated at merge time, so threshold options also work with `--merge`. If the same account appears twice, the newer collection is used. The saved data contains no ARNs.

## Scanning regions in parallel

With several regions (`-r a,b,c` or `-A`), up to `--parallel N` regions of an account are scanned at once (default 4, conf key `parallel`). `--parallel 1` scans one region at a time, as before. Each region runs as a background job that writes only to its own temp folder. The results are then combined in region order, so the report is the same whatever order the regions finish in.

```
[INFO] [3/17] us-east-1: 4 clusters, 2 instances, 61 snapshots, 80 recovery points (6s)
[ERROR] [9/17] eu-west-3: failed (exit 1)
[INFO] 111111111111: 17 regions scanned, 14 empty: ap-northeast-1, ap-northeast-2, ...; 1 failed: eu-west-3
```

Only regions with databases, and errors, get their own line; empty regions are folded into the summary line. `-v` / `--verbose` prints every region line (`started`, `(empty)`) and the `regions in order` line, as in v1.3.0.

If one region fails, the other regions still finish. The failed region is listed under Region errors in the report, and the exit code follows the usual rules. Bash 4.3+ uses `wait -n`. Without it the tool waits for each batch to finish. The temp folder is removed on exit, including Ctrl-C. In parallel mode each region that has clusters calls `describe-global-clusters` itself, so there are a few more calls than with `--parallel 1`.

## The settings file (v1.7.1)

Every setting lives in **one file**, [rds_backup_compliance_report.conf](rds_backup_compliance_report.conf). It ships in the zip next to the script and is loaded automatically. The script and `lib/` hold no setting values of their own, so the file is the single reference for what a run does.

* **Easy to read:** settings are grouped under headings (Accounts and regions, Schedule, Output, Snapshot audit, Report retention, Email, Account names, Advanced). Notes start with `##`. Every other line is a setting, `key=value`, and each key appears once. There are no commented-out settings to confuse with real ones.
* **Required:** if the file is missing, the run stops (exit 1) and says where to put it. Every setting must be in the file; a missing one stops the run with the list of missing keys. A value may be empty where its note says so, for example `profile=` (current login) or `alert-email=` (no e-mail).
* **Checked:** a bad value, an unknown key or a key listed twice stops the run with `file:line`.
* **Command line wins for one run:** `--daily 14`, `-P prod`, `-o ''` (print to the screen), `-l ''` (no log file). `-r REGION` replaces `all-regions` from the file. A list option given on the command line (`-P`, `-r`, `-e`, `-i`, `-F`, `--alert-email`, `--replica-exempt-engines`) replaces the list in the file.
* **`--config FILE`:** use another complete copy instead of the file next to the script (it must also have every setting). Nothing is mixed between the two files.
* **`--no-config` was removed** (it existed in v1.7.0 only); it now stops with a message, because the file is required.
* **Relative paths** such as `output-dir=./reports` start from the folder you run the script in. Use full paths when a scheduler runs it.
* **Upgrades:** the zip contains the shipped file, so keep a copy of your edited file before you unzip a new release over it, then compare the two.

The main settings, as shipped:

```text
## ============================== Accounts and regions ==============================
profile=
all-regions=yes
region=
engine=
identifier=
## ============================== Schedule ==============================
check-mode=schedule
daily=7
daily-max-age=26
weekly-weekday=sat
weekly-retention-days=30
monthly-rule=first-sun
monthly=12
monthly-retention-days=365
replica-exempt-engines=oracle-*,aurora-*
## ============================== Output ==============================
format=html,csv
output-dir=./reports
tz=Asia/Kolkata
non-compliant-only=no
log-file=./reports/run.log
## ============================== Snapshot audit ==============================
manual-older-than=90
snapshot-price-per-gb=0.021
## ============================== Report retention ==============================
keep-reports=30
## ============================== Email ==============================
alert-email=
alert-from=
alert-on=noncompliant
attach-html=yes
attach-csv=yes
attach-prefix=backup_compliance
## ============================== Account names (display only) ==============================
111111111111 = prod-payments
222222222222 = nonprod-shared
```

The real file also has a short `##` note above each setting. Notes always sit on their own line: a setting line holds only `key=value`. `profile=` empty means the current login; for several accounts list one AWS CLI profile per account, e.g. `profile=prod,nonprod,dev`.

**Advanced (rarely changed)**, at the bottom of the same file:

| Key | Shipped value | Meaning |
|---|---|---|
| `check-mode` | `schedule` | `schedule` = a point for every scheduled day; `counts` = at least N points in a window, any weekday (`weekly-weekday`, `monthly-rule` and `tolerance-days` are then ignored) |
| `weekly` | `auto` | `auto` = every weekly-weekday in the weekly window (counts mode: floor(window / 7)); `N` = the last N (counts mode: N points in the window) |
| `weekly-window-days` | empty | Weekly window in days; empty = `weekly-retention-days` |
| `weekly-days` / `monthly-days` | `25-40` / `300-400` | Retention ranges that make a recovery point weekly / monthly |
| `tolerance-days` | `1` | A point counts for a scheduled day if taken up to N days before or after (0-3). Ignored when `check-mode=counts` |
| `daily-retention-days` | empty | Expected RDS backup retention; empty = `daily` |
| `retention-tolerance-days` | `1` | Allowed difference from the expected retention |
| `yearly` | `0` | Yearly points expected; 0 = off |
| `parallel` | `4` | Regions of one account scanned at the same time |
| `prefix` | `rds_backup_compliance` | Start of every report file name |
| `aws-timeout` / `max-attempts` | `30` / `5` | AWS CLI timeout (seconds) and retries |
| `mail-timeout` | `60` | Seconds the mail command may take |
| `fail-on-noncompliant` / `save-data` | `no` / `no` | Exit 5 on NON-COMPLIANT / also write `--save-data` files |
| `exceptions` | empty | Exceptions file; empty = `compliance_exceptions.conf` next to the script, if present |

`weekly-window-days` now follows `weekly-retention-days`: with the shipped 30/30 nothing changes, but if you set `weekly-retention-days=35` the weekly window becomes 35 days too (set `weekly-window-days=30` to keep the old window).

### `--check-config`

Validates the settings and exceptions files and prints every setting with its source (`conf` or `CLI`), the account names, the exceptions and the mail command it would use. No AWS calls, no credentials needed. Exit 0 when OK, 1 with `file:line` (or the list of missing keys) on an error.

```text
$ ./rds_backup_compliance_report.sh --check-config --daily 9
Config file:     /home/cloudshell-user/rds-backup-compliance/rds_backup_compliance_report.conf (next to the script)
Exceptions file: none (no exceptions in effect)
Script folder:   /home/cloudshell-user/rds-backup-compliance

Settings in effect (name, value, source: conf = the config file above, CLI = command line):
  profile                    (empty)                        conf
  all-regions                yes                            conf
  daily                      9                              CLI
  daily-max-age              26                             conf
  weekly-retention-days      30                             conf
  ...
  weekly-window-days         = weekly-retention-days (30)   conf
  keep-reports               30 days                        conf
  alert-email                (empty = off)                  conf

Account names (2):
  111111111111 = prod-payments
  222222222222 = nonprod-shared

Exceptions: none

E-mail: off (alert-email is empty)

OK: configuration is valid (no AWS calls made)
```

Where the files go (fake account numbers; walk-through in [EXAMPLES.md](EXAMPLES.md#the-settings-file-v171)):

```text
rds-backup-compliance/                       <- the folder that holds the script
  rds_backup_compliance_report.sh
  rds_backup_compliance_report.conf          <- every setting + account names (required, shipped)
  compliance_exceptions.conf                 <- exceptions (optional), auto-loaded
  lib/
```

The script folder is the real folder of the script (symlinks resolved), not the folder you run it from. `compliance_exceptions.conf` stays in `.gitignore`; the settings file is tracked.

## Report retention: `keep-reports` (v1.7.1)

`keep-reports=30` (shipped) deletes this tool's old report files after each run, so `output-dir` does not fill up.

* Only files directly in `output-dir` whose name starts with `prefix` + `_` and ends in `.html`, `.csv`, `.json` or `.txt`, and that are older than N days. Other files, sub-folders, the run log and `--save-data` files (`rds_backup_<account>_<date>.json`) are never touched.
* Every deleted file is logged: `keep-reports: deleted rds_backup_compliance_111111111111_20250101_000000.html (older than 30 days)`, then a count.
* `keep-reports=0` keeps everything (as before v1.7.1). No `output-dir` (`-o ''`): nothing is deleted.
* `--dry-run` previews it (v1.7.2): one `keep-reports: would delete <file>` line per file and a count, and nothing is deleted.

## E-mail: `alert-email` (v1.7.1; HTML body unreleased)

The same e-mail settings as rds-patch-compliance, sent with the machine's own mail command (no AWS service):

```text
alert-email=dba-team@example.com,oncall@example.com
alert-from=rds-reports@example.com
alert-on=noncompliant
attach-html=yes
attach-csv=yes
attach-prefix=backup_compliance
```

* **When:** `alert-on=noncompliant` sends only when a server is NON-COMPLIANT or an AWS call failed (UNKNOWN rows or failed regions). Servers with an applied exception count as compliant. `alert-on=always` sends after every run, including `--merge`.
* **What:** the subject is `[rds_backup_compliance] NON-COMPLIANT: 3 non-compliant of 6, 25% compliant`. The body is a short HTML summary (status banner, accounts, counts, and a table of NON-COMPLIANT servers, UNKNOWN servers and region errors only: account, server, region, engine, what's missing) plus a plain-text fallback with the same facts. The jump-box hostname and script name sit in a small footer. Report file paths are printed on the screen, not in the e-mail. A COMPLIANT e-mail (`alert-on=always`) uses a green banner and has no failures table.
* **How:** `sendmail` is preferred. The message is `multipart/mixed` with a `multipart/alternative` text+HTML body, then the interactive HTML report (`attach-html=yes`) and the compliance CSV (`attach-csv=yes`). Attachment names use `attach-prefix` and the UTC date only, e.g. `backup_compliance_2026-11-26.html`; the files in `output-dir` keep their full names. The attachments are rendered into the work dir when those formats were not written to `output-dir`. With only `mail` / `mailx`, the text summary is sent and the log notes that sendmail is needed for the HTML body and attachments. The mail command may take `mail-timeout` seconds (60).
* **No mail command:** the run logs a warning and still finishes with its normal exit code. E-mail never changes the exit code.
* **Test it:** `./rds_backup_compliance_report.sh --alert-test` sends one test e-mail and exits, with no AWS calls. `--check-config` shows which mail command would be used.
* Addresses are validated (one plain address each, no spaces or shell characters). The CLI options are `--alert-email`, `--alert-from`, `--alert-on`, `--attach-html`, `--attach-csv`, `--attach-prefix`, `--alert-test`, `--mail-timeout`.

## Compliance exceptions (v1.6.0)

Approved exceptions for servers you know are non-compliant (decommission planned, vendor-pinned version, and so on). They come from one shared file, `compliance_exceptions.conf`. rds-patch-compliance, rds-backup-compliance and rds-compliance-report all use the same file and format.

```text
# account_id | identifier | scope | expires | reason
111111111111 | legacy-aurora-pg12 | patch        | 2026-12-31 | Decommission in December, CHG-1234
111111111111 | reports-pg         | patch,backup | 2027-03-31 | Vendor-pinned version | INC-77
```

* **File:** `--exceptions FILE` (config `exceptions=FILE`). The default (loaded automatically; check it with `--check-config`) is `compliance_exceptions.conf` next to the script, if present. With no file the feature is off and the reports are exactly as before. Start from [compliance_exceptions.conf.example](compliance_exceptions.conf.example). The real file is in `.gitignore`.
* **Format:** all five fields are required. account_id is 12 digits. The identifier is exact and case-insensitive, with no wildcards and no region. scope is `patch`, `backup` or `patch,backup`. expires is a mandatory `YYYY-MM-DD` (UTC) and is the last day the exception applies. `#` comments and blank lines are ignored.
* **Validation:** strict. A missing field, a bad account, scope or date, or a duplicate account + identifier for the same scope stops the run (exit 1) with `file:line`.
* **Matched, not expired:** shown as **Compliant (exception)** and counted as compliant in every %. The evaluated status is kept in `actual_status`. Flags: **expiring soon** (14 days or less) and **no longer needed** (the server is compliant anyway).
* **Expired:** the server is evaluated normally and flagged **exception expired**. The log warns about expired entries and about entries that match no server.
* **When applied:** only when the report is built. `--save-data` files never change.
* **Outputs:**
  * Summary: `compliant N (incl. X exceptions)`. The COMPLIANT card pop-up shows Compliant, Non-compliant and "Exceptions expiring soon or no longer needed" (that line only when the count is above 0).
  * HTML: an Exception column (reason, expiry, flag badge) and an **Exceptions** quick filter: all, exceptions only, non-exceptions, expiring soon or no longer needed, expired. The filter combines with the other filters, and the counts, tables and CSV export follow it.
  * CSV / JSON: the CSV status column shows `COMPLIANT (EXCEPTION)`, and JSON keeps `COMPLIANT` with `"exception": "yes"`. Both get five fields at the end: `exception` (yes/no/expired), `exception_reason`, `exception_expires`, `exception_flag`, `actual_status`.
  * Text: an Exceptions section.
* `--fail-on-noncompliant` and `--non-compliant-only` treat an excepted resource as compliant.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | Usage or settings error (missing settings file, missing or bad setting) |
| 2 | Pre-check failed (aws, jq, credentials or region) |
| 3 | Bad merge input |
| 4 | Output error |
| 5 | NON-COMPLIANT resource found, with `--fail-on-noncompliant` |
| 130 | Interrupted |

## Permissions (read-only)

- `sts:GetCallerIdentity`
- `iam:ListAccountAliases` (optional; for the account name on reports)
- `ec2:DescribeRegions`
- `rds:DescribeDBClusters`
- `rds:DescribeDBInstances`
- `rds:DescribeGlobalClusters`
- `rds:DescribeDBClusterSnapshots`
- `rds:DescribeDBSnapshots`
- `backup:ListBackupVaults`
- `backup:ListRecoveryPointsByBackupVault`

## Limitations

- **Recovery points are read vault by vault.** `list-recovery-points-by-resource` does not return the lifecycle or DeleteAt that classification needs, so the tool uses `list-recovery-points-by-backup-vault`. It only sees vaults in the scanned account and region. Copies held in another account or region (for example a central backup account) are not counted.
- **Daily backups are counted from automated snapshots.** RDS keeps one automated snapshot per day, and continuous backup/PITR between snapshots is not inspected.
- **Unknown global roles get the full checks.** If `describe-global-clusters` is denied, roles show as `unknown` and the full checks are applied.
- **Scheduled days are UTC dates.** A Saturday backup that runs late on Friday or early on Sunday UTC still counts with the default ±1 day tolerance. With `--tolerance-days 0` it does not.
- **Plan and rule names** come from each recovery point's `CreatedBy`. When the CLI returns only IDs, the IDs are shown.
- **`-A` calls every enabled region.** Both snapshot calls now run in every scanned region, even ones without databases (2 extra calls per empty region).
- **The orphan cost is an upper estimate.** It uses the snapshot's allocated size, not the incremental billed bytes.
- **Orphans are matched by identifier within one account and region.** If a new resource reuses the old name, its old snapshots count as Existing. A cross-region copy is Unverified unless its source region was scanned.

## Tests

```bash
tests/run_tests.sh               # mock AWS CLI and headless browser checks (needs node + puppeteer-core for the browser part)
tests/validate_cli.py            # checks that every field read exists in the bundled AWS CLI service models
```

## Changelog

Technical notes for each version, kept as they were in the README. The plain-English version of the same releases is in [CHANGELOG.md](CHANGELOG.md).

- **Unreleased**
  - New setting `check-mode` (`schedule` default | `counts`) and `--check-mode`. `counts` replaces the date-by-date checks with window counts (daily N of the last N days, weekly N points in `weekly-window-days`, monthly N points in the last N months + 7 days); `weekly-weekday`, `monthly-rule` and `tolerance-days` are then ignored. Counts-mode gaps: `weekly 3/4 in last 30d`. JSON `thresholds` gets `check_mode` only in `counts` mode, so `schedule` output is byte-identical to 1.7.2.
- **1.7.2**
  - `--dry-run` previews `keep-reports` (a `would delete` line per file and a count) and deletes nothing.
  - With `--non-compliant-only`, the text summary counts every server; the table and CSV still list only the failing rows.
  - With `-o ''`, `manual-older-than` lists the old manual snapshots on the screen and writes no CSV into the current folder.
- **1.7.1**
  - One settings file: `rds_backup_compliance_report.conf` ships next to the script with every setting filled in, under headings, with `##` notes. It is required (clear message when missing), every key must be present and listed once, and the script and `lib/` no longer contain setting values. `--config FILE` uses another complete file; `--no-config` was removed. See [The settings file](#the-settings-file-v171).
  - `weekly-window-days` follows `weekly-retention-days` unless set.
  - New `keep-reports` (shipped 30): old report files in `output-dir` are deleted after each run, only this tool's own files.
  - New e-mail summary (`alert-email`, `alert-from`, `alert-on`, `--alert-test`, `mail-timeout`) with mail / mailx / sendmail; sendmail attaches the HTML report.
  - `--check-config` shows each setting's source as `conf` or `CLI`, the mail command, and reports missing keys.
  - With the same settings, reports are identical to v1.7.0. `-r` on the command line replaces `all-regions` from the file, and a list option on the command line replaces the list in the file.
- **1.7.0**
  - `rds_backup_compliance_report.conf` next to the script is loaded automatically (`--config FILE` overrides, `--no-config` skips). New `--check-config` validates the settings and exceptions files and shows each setting's source, with no AWS calls. See [The settings file](#the-settings-file-v171) (v1.7.1 replaced the optional file with one required file).
  - The role column (`global_role`) shows `primary` for every instance and cluster that is not a replica or a global-database secondary, instead of `none` (Oracle sources and standalone instances included). Instances that replicate from a Multi-AZ cluster (`ReadReplicaSourceDBClusterIdentifier`) now show `replica`.
  - Statuses, gaps, counts and filters are unchanged. Reports merged from older saved data show `primary` where that data says `none`. CSV and JSON keep the column name `global_role`; the value `none` no longer appears, so anything that filtered on it must use `primary`.
- **1.6.0**
  - Compliance exceptions (`--exceptions FILE` / `compliance_exceptions.conf`, see [Compliance exceptions](#compliance-exceptions-v160)), backup scope. Applied when the report is built (scan or `--merge`); `--save-data` is unchanged.
  - Excepted resources are COMPLIANT (EXCEPTION) and counted as compliant, and the evaluated status is kept. Flags: expiring soon, no longer needed, expired.
  - HTML: Exception column, Exceptions quick filter and the COMPLIANT card pop-up. CSV / JSON: 5 columns at the end. Text: Exceptions section. With no file the outputs are unchanged.
- **1.5.4**
  - Fix `replica-exempt-engines`: engine globs are matched against each configured pattern (v1.5.2 incorrectly treated every Role=replica/secondary as exempt whenever the list was non-empty). `oracle-*` now leaves Aurora secondaries on daily-only evaluation; `aurora-*` / `oracle-*,aurora-*` still exempt as documented.
  - Sort: within an account, members of the same Aurora global database sit together (primary, then secondary), then region and identifier. Standalone resources keep alphabetical order among themselves.
- **1.5.3**
  - HTML Account filter (`f-acct` / `b-acct`): option labels show `name (number)` from the report's accounts (fallback `number (profile)` when no name, else the number). The filter **value** stays the account id, so filtering is unchanged.
  - Per-region table Account column and Backups-tab Account column use the same `name (number)` label.
  - Compliance search also matches `account_name`.
- **1.5.2**
  - `replica-exempt-engines` (conf / `--replica-exempt-engines`): comma-separated engine globs. Role=`replica` or Role=`secondary` matching those engines is always COMPLIANT (daily/weekly/monthly/yearly all N/A). Empty = today's daily-only for those roles. Example: `oracle-*,aurora-*`.
  - Account names on reports: config `123456789012 = friendly-name` (wins), else IAM account alias (`iam:ListAccountAliases`), else the number. Shown as `name (number)` in the header, TXT, HTML; CSV gains an `account_name` column at the end. No name set = number only. Optional permission; AccessDenied is silent.
- **1.5.1**
  - No "More filters" toggle: every filter is on one row that wraps on narrow screens. The Backups order is Account, Region, Resource, Engine, Backup type, Schedule, Age, Source status. The Compliance order is Account, Region, Type, Engine, Aurora global DB, Global role (only when a global cluster exists), Status, Issue.
  - Resource is a type-to-filter box. It matches identifier, engine, account or region, offers "All clusters and instances", and supports arrows + Enter. Cross-tab links and deep links still select the right resource.
  - CSV column picker: Download, Cancel, All and None sit in a sticky header, and the column list scrolls under it.
  - The "Old manual snapshots (> 90 days)" and "Orphaned snapshots" buttons are removed. The orphaned count in the orphan summary line now opens Source status = Orphaned (all resources, any age).
  - Header: "RDS backup compliance · N accounts" (account ids in the tooltip), then bullets built from the config: Generated, Daily, Weekly, Monthly, Yearly (only when on) and Global secondaries (only when present). Tolerances, counted ranges and the UTC note are in ⓘ tips.
- **1.5.0**
  - PITR: a `PITR` badge on Backups-tab continuous recovery points and a PITR column (with "since" date) on Compliance. The compliance CSV gains `pitr_enabled`, `pitr_since_utc`, and the backups CSV gains `backup_type` (pitr / aws_backup / automated / manual) and `schedule` (daily / weekly / monthly / yearly / not_counted). The new columns are added at the end.
  - Backups tab: new Backup type options (PITR, automated, manual, AWS Backup), a Schedule filter, and "More filters" (account, region, engine, source) with a count of active hidden filters.
  - Compliance tab: the main row is Status, Issue (was "Show") and Engine. Account, Region, Type, Aurora global DB (All / All global databases / None / each name) and Global role (Primary / Secondary) are under More filters. The global filters appear only when a global cluster exists, and non-Aurora engines are never counted as global.
  - Status cards filter by status when clicked. ⓘ tips explain each filter using the configured thresholds.
  - CSV export from the page opens a column picker, and the chosen columns are remembered per tab. Filters are remembered in localStorage, and a `#view=` deep link still wins.
  - Every baseline value in `rds_backup_compliance_report.conf.example` is now commented out, so the example leaves the script defaults unchanged.
- **1.4.1**
  - Cross-tab links. On the Backups tab, a resource identifier opens the Compliance tab showing only that resource (account and region filters set, other filters cleared, a `× clear` chip), with its row expanded, highlighted and scrolled into view. On the Compliance tab, each row has a small `backups` link (the identifier still works too) that opens the Backups tab on that resource. Snapshots whose source is gone (`(deleted) ...`) keep opening their own snapshot list.
  - Links are keyed by account + region + identifier, so merged reports with the same identifier in several accounts or regions go to the right row. A resource with no backups shows a "No backups found" message.
  - The page address records the view (`#view=comp&id=<account|region|identifier>` or `#view=bk&res=...`): the browser Back and Forward buttons return to the previous view and filters, and such links can be bookmarked or shared. Links work with the keyboard (Tab, Enter).
  - HTML only: CSV, JSON, console output and AWS calls are unchanged.

- **1.4.0**
  - Strict retention: daily `BackupRetentionPeriod` 7, weekly points 30 days, monthly points 365 days (±1 day). New options and conf keys `--daily-retention-days` / `DAILY_RETENTION_DAYS`, `--weekly-retention-days` / `WEEKLY_RETENTION_DAYS=30`, `--monthly-retention-days` / `MONTHLY_RETENTION_DAYS=365`, `--retention-tolerance-days` / `RET_TOLERANCE_DAYS=1`. A point with another retention still counts (a 35-day point is still weekly) and is highlighted yellow: `weekly point has 35d, expected 30d`. Diagnostics reasons say so.
  - New yellow warnings (status unchanged): **excess backups** (`weekly 9 (expected 4-5)`) and **holds more than retention** (names the oldest automated backup; likely causes in the detail).
  - Compliance card `NN% compliant (x of y)`, with not-yet-due resources left out and shown separately; it follows the filters. Also in the console (`Compliance: ...`), the JSON totals (`totals.compliance`) and the per-region table (% compliant).
  - Compliance tab: search box (identifier, engine, region, account, vault, plan), Show options for the new warnings, per-region table moved under the filters.
  - Backups tab: Account dropdown in every mode, search box, yellow rows, and Reset now resets every dropdown (Resource to All), the search and the order.
  - CSV: `retention_mismatch_count`, `retention_mismatch`, `excess_daily`, `excess_weekly`, `excess_monthly`, `excess`, `over_retention_count`, `over_retention`, `counted_in_compliance_pct`. Counts are plain numbers.
  - No new AWS calls or permissions. Saved data from v1.2.1 and v1.3.x still merges and gets the new checks.

- **1.3.1**
  - CSV: the `x/y` text cells are replaced by numeric columns per check (`daily_status`, `daily_found`, `daily_expected`, `daily_target`, `daily_missing`, `daily_full_on`, then weekly, monthly, and yearly when on). Dates are written as `2026-10-24 Sat`, so Excel never turns a cell into a date. The HTML Export CSV produces the identical file.
  - HTML: compact count cells with a red `N missing` tag and tooltip, a one-line Gaps summary, and an expandable detail row (click the row or caret). Fixed column widths that wrap on desktop and mobile.
  - Recovery-point diagnostics: every AWS Backup recovery point of a resource is listed (date, retention, class, counted or not, and why) in the detail row and in the JSON (`recovery_points`).
  - Weekly fixes: recovery points without `CalculatedLifecycle` now use `Lifecycle.DeleteAfterDays`; status `AVAILABLE` counts like `COMPLETED`; continuous (PITR) recovery points are never counted as snapshots; resource ARNs match case-insensitively.
  - Console: one line per region with databases (and errors), then `N regions scanned, M empty: a, b`. `--verbose` prints every region line. Scanning stays parallel.
  - The `Output (N files):` block lists each file by its full absolute path.
  - No new AWS calls or permissions. Saved data from v1.2.1 and v1.3.0 still merges.

- **1.3.0**
  - Schedule-aware checks: daily for each of the last 7 UTC days, weekly for every Saturday in the last 30 days, monthly for the first Sunday of each of the last 12 months, with ±1 day tolerance. Yearly is off by default and hidden in all outputs.
  - The creation date counts: dates before a resource existed are not expected. Building-up checks show `x/y so far (target z)` and `full on <date>`. Failing checks list the missing dates.
  - Recovery points whose retention fits no class get a warning and are not counted.
  - Created/age column, a "Show: Not yet due / Retention warnings" filter, and `not_yet_due` and `warnings` CSV columns.
  - Backups tab: a Reset button, and a Retention settings section for one resource (retention, backup window, copy tags, AWS Backup retention seen, plan / rule, schedule). It uses data the tool already reads, so there are no new AWS calls or permissions.
  - Regions are scanned in parallel (`--parallel N`, default 4). One progress line per region (`[3/17] us-east-1: 4 clusters, ... (6s)`, `(empty)`, errors on the same line). A failing region does not stop the others.
  - The run ends with an `Output (N files) in /absolute/dir:` block, one file per line.
  - New options and conf keys: `weekly` (auto or N), `monthly-days`, `weekly-weekday`, `monthly-rule`, `tolerance-days`, `weekly-window-days`, `parallel`. Defaults are now weekly-days 25-40, monthly-days 300-400, monthly 12, yearly 0.
  - Saved data stays at schema_version 1. Files from v1.2.1 still merge, and the new fields show blank.

- **1.2.1**
  - Security fix: the Backups tab now HTML-escapes snapshot `kind`, `rd`, status and label values that come from the data file, so a tampered `--merge` file can no longer inject markup or script (stored XSS). The regression test renders a poisoned merge file in headless Chrome.
  - Releases publish `rds-backup-compliance.zip.sha256`, and the install verifies it with `sha256sum -c` before unzipping. The release workflow pins `actions/checkout` to a commit SHA and is read-only except for the publish job.

- **1.2.0**
  - Orphaned manual snapshots: snapshots whose source cluster/instance is gone from the account + region, with Shared and Unverified handling, summary and cost estimate (`--snapshot-price-per-gb`).
  - Backups tab: Source status filter, Orphaned snapshots button, `(deleted) <id>` resources, Source and Est. $/month columns.
  - `_orphaned_snapshots.csv`; `source_status` column in `_backups.csv` and the in-page export.

- **1.1.0**
  - Backups tab: Backup type filter (All, Manual, Automated, AWS Backup) and an Age filter (last 3/6/12 months, older than 30/90/180/365 days, any age).
  - "All clusters and instances" shows every backup type in one table, with Age (days), Rule, a count and total GB. Rule, Retention and Vault columns hide when empty.
  - "Old manual snapshots (> 90 days)" one-click audit, and the `--manual-older-than N` audit CSV.
  - `_backups.csv` gains age_days and rule, in the same column order as the in-page export.
- **1.0.0** First release.
