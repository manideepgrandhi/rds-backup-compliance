# Changelog

Plain-English features for each published release. The What's new page is built from this file.

## Unreleased
- The Issue filter "Not yet due" now shows only servers whose status is NOT YET DUE. A young server that is already missing a backup stays under NON-COMPLIANT (the Building up dates in the row detail are unchanged)
- The HTML report works on a phone: it has a viewport tag, the table scrolls sideways without stretching the filter bar, and the Status and Issue dropdowns stay on screen under 700px
- The Status column is wide enough that NOT YET DUE stays on one line

## 1.8.0
- New `check-mode` setting (and `--check-mode`): `schedule` (the default, exactly as before) or `counts`
- In `counts` mode a server is compliant when it has enough backups in a window, whatever weekday they ran on: daily = 7 of the last 7 days have an automated backup, weekly = 4 points (auto: the weeks that fit in `weekly-window-days`) in the last 30 days, monthly = 12 points in the last 12 months
- A backup you re-run late counts, so a missed Saturday that you re-run on Monday brings the weekly check back to 4/4. `weekly-weekday`, `monthly-rule` and `tolerance-days` are ignored in `counts` mode (they stay in the conf)
- Counts-mode gaps read `weekly 3/4 in last 30d`, `daily 6/7 in last 7d`, `monthly 11/12 in last 12 months`; retention checks, young servers (NOT YET DUE) and replica rules are unchanged
- With `check-mode=schedule` the reports are identical to 1.7.2 byte for byte, except the tool version is now 1.8.0
- The alert e-mail now has a short HTML body (status banner, counts, a table of NON-COMPLIANT / UNKNOWN / region-error servers only) and a plain-text fallback
- The interactive HTML report is still attached, and the compliance CSV is attached too (`attach-html` and `attach-csv`, both shipped yes)
- Attachment file names are short (`attach-prefix`, shipped `backup_compliance`, e.g. `backup_compliance_2026-11-26.html`); files on disk keep their full names
- The e-mail body does not list report file paths or attachments; full paths are still printed on the screen at the end of the run
- The jump-box hostname and script name moved to a small footer, so the body starts with the result
- `mail` / `mailx` still send the text only, with a log note to install sendmail for the HTML body and attachments
- Report files (HTML, CSV and the rest) are unchanged

## 1.7.2
- `--dry-run` now previews `keep-reports`: it lists each old report it would delete and a count, and deletes nothing
- With `--non-compliant-only`, the text summary (Compliance, Resources) counts every server, as `--help` says; the table and CSV still list only the failing rows
- With `-o ''` (screen only), `manual-older-than` no longer writes a CSV into the current folder; the old manual snapshots are listed on the screen instead
- Reports are otherwise identical to 1.7.1

## 1.7.1
- One settings file: `rds_backup_compliance_report.conf` now ships next to the script with every setting filled in, grouped under headings with `##` notes, and the script has no built-in values
- The settings file is required: a missing file, a missing setting or a setting listed twice stops the run with a clear message
- The weekly window follows `weekly-retention-days` unless you set `weekly-window-days`
- New `keep-reports` setting (shipped 30) deletes this tool's report files older than N days from the output folder
- New e-mail summary (`alert-email`, `alert-from`, `alert-on`, `--alert-test`) using mail, mailx or sendmail; sendmail attaches the HTML report
- `--check-config` shows each setting's source (conf or CLI) and the mail command; `--no-config` was removed
- With the same settings, reports are identical to 1.7.0

## 1.7.0
- A settings file named `rds_backup_compliance_report.conf` next to the script is now loaded automatically, so `--config` is no longer needed (`--config FILE` still overrides it, `--no-config` skips it)
- New `--check-config` checks the settings and exceptions files and shows where every setting comes from, without calling AWS
- Role column shows `primary` instead of `none` for standalone and source servers, including Oracle
- Instances that replicate from a Multi-AZ cluster now show `replica`
- Statuses, counts and filters are unchanged; without a settings file the script behaves exactly as before

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
