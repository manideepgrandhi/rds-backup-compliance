# rds-backup-compliance

`rds_backup_compliance_report.sh` v1.0.0 checks whether Aurora clusters and standalone RDS instances keep the backups the policy asks for. It makes only read-only calls and needs Bash, jq and AWS CLI v2. It is built to run in AWS CloudShell, one account at a time. You can then merge the results offline, including in Git Bash on Windows with `jq.exe`.

## Install (CloudShell)

```bash
curl -fsSLO https://github.com/<owner>/rds-backup-compliance/releases/latest/download/rds-backup-compliance.zip
unzip -oq rds-backup-compliance.zip && cd rds-backup-compliance
./rds_backup_compliance_report.sh -A -F html,csv --save-data -o ./out
```

## Policy

| Check | Source | Default rule | Applies to |
|---|---|---|---|
| Daily | RDS automated backups | Retention ≥ 7 days, 7 distinct days with an automated snapshot, and the latest one ≤ 26 h old | Every resource |
| Weekly | AWS Backup | ≥ 4 recovery points in distinct weeks (Monday start) | Primary clusters, non-global clusters, standalone instances |
| Monthly | AWS Backup | ≥ 11 in distinct months | Same as weekly |
| Yearly | AWS Backup | ≥ 1 in distinct years | Same as weekly |

AWS Backup recovery points are classified by their retention, which is CreationDate → CalculatedLifecycle.DeleteAt:

| Retention | Class |
|---|---|
| 11–60 days | Weekly |
| 61–400 days | Monthly |
| Over 400 days, or never expires | Yearly |
| Under 11 days | Short (listed, but not counted) |

You can change these with `--weekly-days MIN-MAX` and `--monthly-max-days N`.

How the role of each resource is decided:

- **Global cluster roles** come from `describe-global-clusters`. The writer is `primary` and the other members are `secondary`. Secondaries are checked for daily backups only, and their weekly, monthly and yearly checks show N/A.
- **Read replicas** (cross-region cluster replicas and instance read replicas) are checked for daily backups only.
- **Aurora cluster member instances** are not listed separately.
- **DocumentDB and Neptune** are excluded.

### Status

| Status | Meaning |
|---|---|
| COMPLIANT | All applicable checks pass. |
| NON-COMPLIANT | At least one check fails. The **Gaps** column says which, for example `weekly 2/4; yearly 0/1`. |
| NOT YET DUE | The resource is too new to have the full set yet, and it has every backup it could have had so far. A check counts as not yet due when age < N × period and have ≥ ⌊age/period⌋ − 1. The periods are 1 day, 7 days, 30.44 days and 365.25 days. |
| UNKNOWN | A needed call was denied or failed, for example `backup:ListRecoveryPointsByBackupVault`. |

## Outputs

All outputs show the account number, and every time is shown in UTC and IST (`--tz` changes the second zone). File names follow `<prefix>_<account>_<UTC stamp>.<ext>`. Regions with no databases are left out.

| Format | What you get |
|---|---|
| text | Console summary. |
| csv | Compliance CSV. With `-o`, you also get `<name>_backups.csv`, which lists every manual snapshot, automated backup and AWS Backup recovery point. |
| json | Rows and raw backups. |
| html | Two tabs, described below. |

The HTML report has two tabs:

- **Compliance tab:**
  - Total cards.
  - Filters for account, region, type, engine, role, global cluster, status and identifier.
  - Export CSV, which exports the filtered rows.
  - A per-region table with an "All regions" total, and the region errors.
- **Backups tab:**
  - Pick a cluster or instance, and a period: last 3, 6 or 12 months.
  - Three sections: manual snapshots, RDS automated backups, and AWS Backup recovery points (with class, retention, expiry and vault).
  - A CSV of what is shown.

### Several accounts

```bash
# CloudShell, once per account:
./rds_backup_compliance_report.sh -A --save-data -F html -o ./out      # writes rds_backup_<ACCOUNT>_<YYYYMMDD>.json
# Windows Git Bash, offline (CRLF files, spaces in paths and jq.exe are fine):
./rds_backup_compliance_report.sh --merge "/c/Users/me/RDS backups/" -o "/c/Users/me/RDS backups/all.html"
```

Compliance is re-evaluated at merge time, so threshold options also work with `--merge`. If the same account appears twice, the newer collection is used. The saved data contains no ARNs.

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
- **Weekly grouping does not match ISO weeks at year boundaries.** Weeks start on Monday and are counted from the Unix epoch, so they are not ISO week numbers. This keeps the tool portable to jq.exe.
- **`-A` calls every enabled region.**

## Tests

```bash
tests/run_tests.sh               # mock AWS CLI and headless browser checks (needs node + puppeteer-core for the browser part)
tests/validate_cli.py            # checks that every field read exists in the bundled AWS CLI service models
```
