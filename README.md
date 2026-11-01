# rds-backup-compliance

`rds_backup_compliance_report.sh` v1.3.0 checks whether Aurora clusters and standalone RDS instances keep the backups the policy asks for. It makes only read-only calls and needs Bash, jq and AWS CLI v2. It is built to run in AWS CloudShell, one account at a time. You can then merge the results offline, including in Git Bash on Windows with `jq.exe`.

## Install (CloudShell)

```bash
curl -fsSLO https://github.com/manideepgrandhi/rds-backup-compliance/releases/latest/download/rds-backup-compliance.zip && curl -fsSLO https://github.com/manideepgrandhi/rds-backup-compliance/releases/latest/download/rds-backup-compliance.zip.sha256
sha256sum -c rds-backup-compliance.zip.sha256 && unzip -oq rds-backup-compliance.zip && cd rds-backup-compliance
./rds_backup_compliance_report.sh -A -F html,csv --save-data -o ./out
```

`sha256sum -c` must print `rds-backup-compliance.zip: OK`. If it reports `FAILED`, the `&&` chain stops before `unzip`; delete the zip and do not run it. Releases from v1.2.1 on publish `rds-backup-compliance.zip.sha256` next to the zip.

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

- **Global cluster roles** come from `describe-global-clusters`. The writer is `primary` and the other members are `secondary`. Secondaries are checked for daily backups only, and their weekly, monthly and yearly checks show N/A.
- **Read replicas** (cross-region cluster replicas and instance read replicas) are checked for daily backups only.
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
  - **Old manual snapshots (> 90 days)** sets All + Manual + Older than 90 days in one click, for auditing leftover manual snapshots.
  - Manual snapshots of any age are kept in the data (nothing is trimmed to 12 months).

### Manual snapshot audit CSV

`--manual-older-than N` also writes `<prefix>_<account>_<stamp>_manual_older_than_<N>d.csv`. It lists every manual snapshot older than N days, oldest first, with account, region, identifier, type, engine, snapshot, created (UTC and IST), age_days, status and size_gb. It works for live scans and with `--merge`, and is written to `-o DIR` (or the current directory).

### Orphaned manual snapshots

A manual snapshot is **orphaned** when its source cluster or instance no longer exists in the same account and region. Each region's manual snapshots are read in full (with `--include-shared`), including regions that have no databases left; such regions show as `snapshots only`. With `--merge`, matching is still per account and region.

| Source status | Meaning |
|---|---|
| Existing | The source cluster/instance exists (a cross-region copy whose source exists in its scanned source region also counts) |
| Orphaned | The source is gone: counted in the summary and cost estimate |
| Shared | Shared with this account, or copied from another account: listed, never counted |
| Unverified | A cross-region copy whose source region was not scanned (use `-A` or add that region) |

AWS Backup recovery points, automated snapshots, `awsbackup:` snapshots and DocumentDB/Neptune snapshots are not part of the orphan logic.

- **Summary**, in the Compliance header and the Backups tab: e.g. `4 orphaned snapshots, 1.8 TB, ~$38/month (estimate)`. The estimate is size GB × `--snapshot-price-per-gb` (default 0.021, or `snapshot_price_per_gb` in the config file). It is a **rough upper estimate**: snapshot storage is billed incrementally, so the real cost is usually lower.
- **Backups tab, All clusters and instances:** a Source status filter (All, Existing, Orphaned, Shared, Unverified when present), Source and Est. $/month columns, an **Orphaned snapshots** button, and `(deleted) <id>` entries in the Resource dropdown.
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

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | Usage error |
| 2 | Pre-check failed (aws, jq, credentials or region) |
| 3 | Bad merge input |
| 4 | Output error |
| 5 | NON-COMPLIANT resource found, with `--fail-on-noncompliant` |
| 130 | Interrupted |

## Permissions (read-only)

- `sts:GetCallerIdentity`
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
