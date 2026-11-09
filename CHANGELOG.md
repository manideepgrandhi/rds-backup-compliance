# Changelog

Plain-English features for each published release. The What's new page is built from this file.

## 1.6.0
- Mark chosen servers as always compliant with a simple exceptions file (expiry date required)
- Excepted servers count as compliant, with warnings when an exception is expiring soon, expired, or no longer needed
- Exception column, quick filter, and "incl. N exceptions" on the compliant card pop-up
- CSV and JSON gain exception columns; without an exceptions file the report matches earlier versions

## 1.5.4
- Fixed replica-exempt engines so only the engines you list are treated as exempt
- Aurora global database members (primary, then secondary) are grouped together when sorting

## 1.5.3
- Account filter labels show `name (number)` instead of only the account id
- Per-region and Backups account columns use the same friendly label
- Compliance search also matches the account name

## 1.5.2
- Optional `replica-exempt-engines` setting to treat matching replicas or secondaries as always compliant
- Account names on reports from config or the IAM account alias, shown as `name (number)`
- CSV gains an `account_name` column

## 1.5.1
- All filters sit on one wrapping row (no "More filters" toggle)
- Resource picker type-to-filter box with keyboard support
- CSV column picker keeps Download and Cancel sticky while the list scrolls
- Cleaner header with config-based bullets and tip icons

## 1.5.0
- PITR badge on continuous recovery points and a PITR column on Compliance
- New Backup type and Schedule filters on the Backups tab
- Status cards filter the table when clicked; CSV column picker remembered per tab
- Filters remembered in the browser; deep links still win

## 1.4.1
- Cross-tab links between Compliance and Backups for the same resource
- Browser Back and Forward restore the previous view and filters
- Bookmarkable `#view=` links; keyboard accessible

## 1.4.0
- Strict retention checks for daily, weekly and monthly points, with a one-day tolerance
- Yellow warnings for retention mismatches, excess backups, and points held past retention
- Compliance percentage leaves not-yet-due resources out and follows the filters
- Search box and richer Show options on the Compliance tab

## 1.3.1
- CSV uses separate numeric columns per check so Excel keeps numbers and dates clean
- Expandable detail rows with recovery-point diagnostics
- Continuous (PITR) recovery points are never counted as snapshots
- Output block lists every file by its full absolute path

## 1.3.0
- Schedule-aware daily, weekly and monthly checks with missing-date lists
- Building-up resources show progress toward the full target date
- Regions scanned in parallel with a one-line progress update each
- Backups tab Reset button and a Retention settings section per resource

## 1.2.1
- Security fix: Backups tab HTML-escapes snapshot fields (stored XSS via a tampered merge file)
- Releases publish a `.sha256` checksum verified before unzip
- Release workflow pins Actions to commit SHAs with least-privilege permissions

## 1.2.0
- Orphaned manual snapshots when the source cluster or instance is gone
- Source status filter and cost estimate on the Backups tab
- New orphaned-snapshots CSV and a `source_status` column on backups CSV

## 1.1.0
- Backup type and Age filters on the Backups tab
- "All clusters and instances" combined view with size totals
- One-click audit for old manual snapshots and a `--manual-older-than` CSV

## 1.0.0
- First release: backup compliance HTML, CSV and text for Aurora clusters and RDS instances
