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
Output (4 files) in /home/cloudshell-user/out:
  rds_backup_compliance_111111111111_20261031_144500.html
  rds_backup_compliance_111111111111_20261031_144500.csv
  rds_backup_compliance_111111111111_20261031_144500_backups.csv
  rds_backup_compliance_111111111111_20261031_144500_orphaned_snapshots.csv
```
