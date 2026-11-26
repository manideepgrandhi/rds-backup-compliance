#!/usr/bin/env bash
#
# rds_backup_compliance_report.sh - backup compliance of Aurora clusters and standalone RDS instances, per account
# and region. READ-ONLY: rds describe-*, backup list-*, sts get-caller-identity, iam list-account-aliases, ec2 describe-regions.
#
# Rules (check-mode=schedule, the default; the values below are the shipped rds_backup_compliance_report.conf, all configurable):
#   daily   RDS automated backups: retention >= daily days, one backup on each of the last daily UTC days, the latest
#           <= daily-max-age hours old
#   weekly  AWS Backup point (retention in weekly-days counted) for every weekly-weekday of the last weekly-window-days
#           (follows weekly-retention-days unless set), +/- tolerance-days
#   monthly AWS Backup point (retention in monthly-days counted) for the monthly-rule day of each of the last monthly months
#   strict  expected retention daily-retention-days (RDS), weekly-retention-days, monthly-retention-days (+/- retention-
#           tolerance-days): a counted point with another retention is highlighted, not failed. Excess backups and
#           automated backups kept past retention: warnings.
#   yearly  yearly=N checks N points with retention over the monthly range; 0 = off
#   Dates before the resource was created are never expected. Points whose retention fits no class: warning only.
#   Aurora global database secondaries and read replicas: daily only (weekly / monthly / yearly N/A).
#   replica-exempt-engines: those Role=replica/secondary engines are always COMPLIANT (all schedules N/A).
# check-mode=counts (v1.8.0, off by default): no weekday placement. Same settings, counted instead:
#   daily   at least daily of the last daily closed UTC days have an RDS automated backup (retention and daily-max-age as above)
#   weekly  at least weekly points (auto = floor(weekly-window-days / 7), 4 for 30 days) with retention in weekly-days,
#           created in the last weekly-window-days days, on any weekday
#   monthly at least monthly points with retention in monthly-days created in the last monthly months (+7 days slack);
#           a catch-up point counts like a regular one
#   weekly-weekday, monthly-rule and tolerance-days are ignored. Gaps read like "weekly 3/4 in last 30d".
# Role (global_role column): replica | secondary (global DB member) | primary (everything else, v1.7.0; was none) | unknown (global clusters unreadable).
# Status: COMPLIANT | NON-COMPLIANT (gaps column) | NOT YET DUE (resource too young) | UNKNOWN (a call failed).
# Config (v1.7.1): every setting comes from ONE file, rds_backup_compliance_report.conf next to the script (required;
#   --config FILE uses another complete file instead). CLI options override it. There are no setting values in this
#   script or in lib/. --check-config validates the files and shows each setting's source.
# Exceptions (v1.6.0): compliance_exceptions.conf (or --exceptions FILE) lists servers that show COMPLIANT (EXCEPTION)
#   and count as compliant until their expiry date; the evaluated status stays in actual_status.
# Report retention (v1.7.1): keep-reports=N deletes this tool's report files older than N days from output-dir.
# E-mail (v1.7.1, HTML body unreleased): alert-email / alert-from / alert-on send a short HTML summary (text fallback) with sendmail;
#   attach-html / attach-csv attach the interactive HTML report and the compliance CSV (short names from attach-prefix). mail / mailx send the text only.
# Output: text | csv | json | html. Exit: 0 ok, 5 NON-COMPLIANT with --fail-on-noncompliant, 1 usage / config, 2 pre-check,
#         3 bad --merge input, 4 output error, 130 interrupted. Logic and rendering live in lib/*.jq.

# ---------------------------------------------------------------------------- setup and defaults
# Strict mode, constants (version, lib/ folder, --save-data schema) and the bash 4.4+ check.
# shellcheck disable=SC2016,SC2034  # jq programs are single-quoted on purpose; KEEP_WORKDIR is read in the EXIT trap
set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.7.2"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
LIBDIR="${RDS_BCR_LIB:-$SCRIPT_DIR/lib}"
readonly CONFIG_NAME="rds_backup_compliance_report.conf"   # loaded from $SCRIPT_DIR (required; --config FILE replaces it)
# Named constants: unit facts and fixed limits, not settings (settings live only in the conf file).
readonly SECONDS_PER_MINUTE=60 SECONDS_PER_HOUR=3600 MINUTES_PER_DAY=1440 DAYS_PER_WEEK=7
readonly IST_OFFSET_SECONDS=19800        # Asia/Kolkata = UTC+05:30; used where `date` has no zoneinfo (Git Bash)
readonly GLOBAL_API_REGION="us-east-1"   # region for account-wide calls (iam, ec2 describe-regions) when no region is set
readonly MAX_PARALLEL=32 MAX_TOLERANCE_DAYS=3 MAX_NAME_CHARS=64 MAX_ERR_CHARS=200
readonly REPORT_EXTS="html csv json txt"  # extensions keep-reports may delete (only files starting with the prefix)
# Every key the conf file must contain (a value may be empty where the conf says so). Order = --check-config order.
readonly -a REQUIRED_KEYS=(profile region all-regions engine identifier
    check-mode daily daily-max-age weekly-weekday weekly-retention-days monthly-rule monthly monthly-retention-days replica-exempt-engines
    format output-dir tz non-compliant-only log-file manual-older-than snapshot-price-per-gb keep-reports
    alert-email alert-from alert-on attach-html attach-csv attach-prefix exceptions
    weekly weekly-window-days weekly-days monthly-days tolerance-days daily-retention-days retention-tolerance-days yearly
    parallel prefix aws-timeout max-attempts mail-timeout fail-on-noncompliant save-data)
readonly DATA_SCHEMA="rds_backup_compliance_data" DATA_SCHEMA_VERSION=1

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "$SCRIPT_NAME: bash 4.4+ required (found $BASH_VERSION)" >&2; exit 2
fi

# Settings: empty on purpose. Every value comes from the conf file (set_opt); CLI options override it.
# Arrays hold the list settings. Run state below: background job pids, AWS call counters, the work dir, written files.
PROFILES=(); REGIONS=(); ENGINES=(); IDENTIFIERS=(); FORMATS=(); EXEMPT_ENGINES=(); ALERT_EMAILS=(); MERGE_ARGS=()
ALL_REGIONS=""; OUTPUT_DIR=""; OUT_FILE=""; MANUAL_OLDER=""; SNAP_PRICE=""; PREFIX=""; DISPLAY_TZ=""
CHECK_MODE=""; DAILY=""; DAILY_MAX_AGE_H=""; WEEKLY=""; MONTHLY=""; YEARLY=""
WEEKLY_MIN_DAYS=""; WEEKLY_MAX_DAYS=""; MONTHLY_MIN_DAYS=""; MONTHLY_MAX_DAYS=""
WEEKLY_WEEKDAY=""; MONTHLY_RULE=""; TOLERANCE_DAYS=""; WEEKLY_WINDOW_DAYS=""; PARALLEL=""
DAILY_RETENTION_DAYS=""; WEEKLY_RETENTION_DAYS=""; MONTHLY_RETENTION_DAYS=""; RET_TOLERANCE_DAYS=""
NC_ONLY=""; FAIL_ON_NC=""; SAVE_DATA=""; LOG_FILE=""; AWS_TIMEOUT=""; MAX_ATTEMPTS=""; KEEP_REPORTS=""
ALERT_FROM=""; ALERT_ON=""; MAIL_TIMEOUT=""; ATTACH_HTML=""; ATTACH_CSV=""; ATTACH_PREFIX=""
CONFIG_FILE=""; CONFIG_AUTO=0; CHECK_CONFIG=0; ALERT_TEST=0
BG_PIDS=(); SCAN_PAR=0; HAVE_WAIT_N=0
KEEP_WORKDIR=0; DRY_RUN=0; VERBOSE=0; SAVE_DATA_FILE=""; MERGE=0
WORK=""; NOW=0; STAMP=""; AWS_CALLS=0; AWS_FAILS=0
EXC_FILE=""; EXC_JSON="null"; EXC_PATH=""; EXC_ARGS=()   # compliance exceptions (v1.6.0)
declare -a WRITTEN=() DATA_FILES=()
declare -A ACCOUNT_NAMES=()   # config: 123456789012 = name (display only)
declare -A OPT_SRC=()         # setting name -> where its value came from (config file path or "CLI")
declare -A CLI_LIST_SET=()    # list settings already replaced by a CLI option (the first -P / -r / ... replaces the conf list)
CUR_SRC=""                    # source recorded by set_opt: the config file being read, "CLI" while parsing options

# ---------------------------------------------------------------------------- logging
# _log LEVEL MSG...: timestamped line to stderr, and to --log-file too (never during --dry-run or --check-config).
_log() { local l; l="$(date '+%Y-%m-%d %H:%M:%S') [$1] ${*:2}"; printf '%s\n' "$l" >&2
         if [[ -n "$LOG_FILE" && "$DRY_RUN" -eq 0 && "$CHECK_CONFIG" -eq 0 ]]; then printf '%s\n' "$l" 2>/dev/null >>"$LOG_FILE" || true; fi; }
# Level wrappers around _log (INFO / WARN / ERROR).
log_info() { _log INFO "$@"; }; log_warn() { _log WARN "$@"; }; log_error() { _log ERROR "$@"; }
# Debug line only with -v / --verbose; always returns 0 so it is safe under set -e.
log_debug() { [[ "$VERBOSE" -eq 1 ]] && _log DEBUG "$@"; return 0; }
# die CODE MSG...: log an ERROR and exit with CODE (see the exit codes in the header).
# While a config line is being read, ERR_CTX ("Config FILE:LINE: ") is put in front of the message, so a bad value names its line.
ERR_CTX=""
die() { local c="$1"; shift; log_error "$ERR_CTX$*"; exit "$c"; }

# ---------------------------------------------------------------------------- usage
# Print --help: every option, with its current value from the conf file in brackets, and the read-only AWS calls.
usage() {
    local src="(settings file not loaded: no values shown)" j=","
    [[ -n "$CONFIG_FILE" ]] && src="from $CONFIG_FILE"
    cat <<USAGE
$SCRIPT_NAME v$SCRIPT_VERSION - backup compliance report for Aurora clusters and RDS instances (read-only)

Usage: $SCRIPT_NAME [options]

Settings come from ONE file, $CONFIG_NAME next to the script (required). Every option below can also
be a line in it (long name without --, e.g. weekly-retention-days=30). Values in [brackets] are the current
settings $src. CLI options override the file for one run.

Scope:
  -P, --profile NAME        AWS CLI profile / account; repeatable or comma-separated; empty = current login  [$(IFS=$j; echo "${PROFILES[*]}")]
  -r, --region REGION       Region(s); repeatable or comma-separated (empty = env / profile region). Replaces
                            all-regions from the conf for this run                                         [$(IFS=$j; echo "${REGIONS[*]}")]
  -A, --all-regions         Every enabled region (ec2 describe-regions); regions without databases are left out [$(yn "$ALL_REGIONS")]
  -e, --engine GLOB         aurora-postgresql, aurora-mysql, postgres, mysql, mariadb, 'sqlserver-*', 'oracle-*' [$(IFS=$j; echo "${ENGINES[*]}")]
  -i, --identifier GLOB     Cluster / instance identifier                                               [$(IFS=$j; echo "${IDENTIFIERS[*]}")]

Compliance:
      --check-mode MODE     schedule = a point on each scheduled day (weekday, monthly-rule, +/- tolerance-days);
                            counts = at least N points in a window, any weekday (those three are then ignored) [$CHECK_MODE]
      --daily N             RDS automated: retention >= N days, a backup on each of the last N days     [$DAILY]
      --daily-max-age H     Latest automated backup at most H hours old                                 [$DAILY_MAX_AGE_H]
      --weekly-weekday DAY  Day the weekly backup runs (sun..sat)                                       [$WEEKLY_WEEKDAY]
      --weekly-retention-days N   Expected retention of a weekly point (highlight if not)               [$WEEKLY_RETENTION_DAYS]
      --monthly-rule RULE   first-sun (first Sunday of the month), first-mon, ... first-sat             [$MONTHLY_RULE]
      --monthly N           First-<day> points expected, one per month for the last N months            [$MONTHLY]
      --monthly-retention-days N  Expected retention of a monthly point (highlight if not)              [$MONTHLY_RETENTION_DAYS]
      --replica-exempt-engines LIST  Engine globs (comma-separated). Role=replica/secondary matching
                            these are always COMPLIANT (all schedules N/A). Empty = daily only          [$(IFS=$j; echo "${EXEMPT_ENGINES[*]}")]
      --non-compliant-only  Show only NON-COMPLIANT rows (totals still count everything)                [$(yn "$NC_ONLY")]
      --fail-on-noncompliant  Exit 5 when a NON-COMPLIANT resource is found                             [$(yn "$FAIL_ON_NC")]
      --exceptions FILE     Compliance exceptions (v1.6.0): lines "account_id | identifier | scope | expires | reason";
                            listed servers (scope backup) show COMPLIANT (EXCEPTION) and count as compliant until the
                            expiry date. Empty = compliance_exceptions.conf next to the script, if present (none = off).
                            Any malformed line stops the run. See compliance_exceptions.conf.example
 Advanced (rarely changed):
      --weekly auto|N       Weekly points expected: auto = every scheduled weekday in the
                            weekly-window-days window (4 or 5); N = the last N scheduled days           [$WEEKLY]
      --weekly-window-days N  Window for --weekly auto; empty = weekly-retention-days                   [${WEEKLY_WINDOW_DAYS}]
      --weekly-days MIN-MAX Retention (days) that classifies a recovery point as weekly                 [${WEEKLY_MIN_DAYS:+$WEEKLY_MIN_DAYS-$WEEKLY_MAX_DAYS}]
      --monthly-days MIN-MAX Retention (days) that classifies a recovery point as monthly               [${MONTHLY_MIN_DAYS:+$MONTHLY_MIN_DAYS-$MONTHLY_MAX_DAYS}]
      --monthly-max-days N  Same as the MAX of --monthly-days (kept for older configs)
      --tolerance-days N    A point counts for a scheduled day if taken up to N days before/after       [$TOLERANCE_DAYS]
      --daily-retention-days N    Expected RDS BackupRetentionPeriod; empty = daily                     [$DAILY_RETENTION_DAYS]
      --retention-tolerance-days N  Allowed difference from the expected retention                      [$RET_TOLERANCE_DAYS]
      --yearly N            AWS Backup points with retention above the monthly range; 0 = off           [$YEARLY]
      --parallel N          Scan up to N regions of an account at the same time; 1 = one by one         [$PARALLEL]

Report:
  -F, --format LIST         text,csv,json,html. Several formats need an output dir                    [$(IFS=$j; echo "${FORMATS[*]}")]
                            csv writes the compliance CSV and, with -o, also <name>_backups.csv and <name>_orphaned_snapshots.csv
  -o, --output-dir DIR      Write <prefix>_<account>_YYYYmmdd_HHMMSS.<ext> into DIR; -o '' = print to the screen.
                            With --merge, -o FILE.html names the file                                  [$OUTPUT_DIR]
      --tz ZONE             Second time zone shown next to UTC                                          [$DISPLAY_TZ]
  -l, --log-file FILE       Append log lines to FILE; empty = no log file                               [$LOG_FILE]
      --manual-older-than N Also write <name>_manual_older_than_<N>d.csv: manual snapshots older than N days;
                            with -o '' they are listed on the screen, no file; empty = off              [$MANUAL_OLDER]
      --snapshot-price-per-gb USD  Price per GB-month for the orphaned-snapshot cost estimate           [$SNAP_PRICE]
      --keep-reports N      After the run, delete <prefix>_* report files (.html .csv .json .txt) older than
                            N days from the output dir; 0 = keep everything                             [$KEEP_REPORTS]
      --save-data [FILE]    Also write the raw data for --merge: rds_backup_<ACCOUNT>_<YYYYMMDD>.json per account
      --prefix NAME         File name prefix                                                            [$PREFIX]

E-mail (sendmail preferred: HTML body, text fallback, optional attachments; mail / mailx send the text only):
      --alert-email ADDR    E-mail the summary to ADDR; repeatable or comma-separated; empty = off      [$(IFS=$j; echo "${ALERT_EMAILS[*]}")]
      --alert-from ADDR     From address                                                                [$ALERT_FROM]
      --alert-on WHEN       noncompliant (NON-COMPLIANT found or AWS errors) | always                   [$ALERT_ON]
      --attach-html YES|NO  Attach the interactive HTML report (sendmail)                               [$(yn "$ATTACH_HTML")]
      --attach-csv YES|NO   Attach the compliance CSV (sendmail)                                        [$(yn "$ATTACH_CSV")]
      --attach-prefix NAME  Short attachment names: NAME_YYYY-MM-DD.html / .csv (sendmail). Files on disk keep their full names  [$ATTACH_PREFIX]
      --alert-test          Send a test e-mail and exit (no AWS calls)
      --mail-timeout SEC    Seconds the mail command may take                                           [$MAIL_TIMEOUT]

Merge (offline, no AWS calls, jq only - works in Git Bash on Windows):
      --merge FILE|DIR...   Combine --save-data files of several accounts. Same account twice: the newer collection
                            wins. Compliance is re-evaluated at merge time. e.g. --merge a.json b.json -o all.html

Behaviour:
      --config FILE         Use FILE instead of $CONFIG_NAME next to the script. FILE must
                            contain every setting (copy the shipped file); never sourced
      --check-config        Validate the settings and exceptions files, print every setting with its source
                            (config file / CLI), the account names, the exceptions and the mail command; no AWS calls.
                            Exit 0 when OK, 1 with file:line on an error
      --aws-timeout SEC     AWS CLI connect/read timeout                                                [$AWS_TIMEOUT]
      --max-attempts N      AWS CLI retry attempts                                                      [$MAX_ATTEMPTS]
      --keep-workdir        Keep raw AWS responses for debugging
      --dry-run             Print the AWS calls that would run and the reports keep-reports would delete; do neither
  -v, --verbose             Print every region line (empty regions too) and debug logs
  -h, --help / -V, --version

AWS calls (all read-only): sts get-caller-identity; iam list-account-aliases (optional, for the account
name); ec2 describe-regions (-A); rds describe-db-clusters, describe-db-instances, describe-global-clusters
(once per account), describe-db-cluster-snapshots and describe-db-snapshots (--include-shared, every region,
for orphaned snapshots); backup list-backup-vaults, list-recovery-points-by-backup-vault (gives the retention
used to classify weekly / monthly / yearly; list-recovery-points-by-resource does not return it).
The conf may also set 123456789012 = friendly-name (shown as "name (number)"; else the IAM alias; else the number).
USAGE
}

# ---------------------------------------------------------------------------- helpers
# add_list ARRAY VALUE: split VALUE on commas, drop spaces and empty items, append to the named array.
add_list() { local -n _a="$1"; local _i; local -a _p; IFS=',' read -r -a _p <<<"$2"
             for _i in "${_p[@]}"; do _i="${_i//[[:space:]]/}"; [[ -n "$_i" ]] && _a+=("$_i"); done; return 0; }
# bool_set VAR OPTION VALUE: yes / no style value -> VAR=1 or 0 (1 y yes true on / 0 n no false off, any case).
bool_set() { local -n _b="$1"; case "${3,,}" in 1|y|yes|true|on) _b=1 ;; 0|n|no|false|off) _b=0 ;;
             *) die 1 "$2 must be yes or no (got '$3')" ;; esac; }
# yn VALUE: 1 -> yes, 0 -> no (for --help and --check-config).
yn() { case "$1" in 1) echo yes ;; 0) echo no ;; *) echo "$1" ;; esac; }
# email_ok ADDR: one plain address, no spaces or shell characters (same rule as rds-patch-compliance).
email_ok() { [[ "$1" =~ ^[^[:space:]@\;\|\&\$\`]+@[^[:space:]@\;\|\&\$\`]+$ ]]; }
# need_arg OPTION "$#": stop with exit 1 when OPTION is the last argument (its value is missing).
need_arg() { [[ "$2" -ge 2 ]] || die 1 "Option $1 requires a value (see --help)"; }
# dow_ok OPTION VALUE: VALUE must be a weekday name sun..sat (exit 1 otherwise).
dow_ok() { [[ "${2,,}" =~ ^(sun|mon|tue|wed|thu|fri|sat)$ ]] || die 1 "$1 must be sun, mon, tue, wed, thu, fri or sat (got '$2')"; }
# dow_num DAY: weekday name -> number, 0 = Sunday .. 6 = Saturday (the numbering backup.jq uses).
dow_num() { case "$1" in sun) echo 0 ;; mon) echo 1 ;; tue) echo 2 ;; wed) echo 3 ;; thu) echo 4 ;; fri) echo 5 ;; *) echo 6 ;; esac; }
# int_ok OPTION VALUE: VALUE must be a whole number >= 0 (exit 1 otherwise).
int_ok() { [[ "$2" =~ ^[0-9]+$ ]] || die 1 "$1 must be a whole number (got '$2')"; }
# int_or_empty OPTION VALUE: like int_ok, but an empty value is allowed (it means "off" / "follow another setting").
int_or_empty() { [[ -z "$2" ]] || int_ok "$1" "$2"; }
# json_array ARGS...: print the arguments as a compact JSON array of strings ([] when none).
json_array() { if (( $# )); then printf '%s\n' "$@" | jq -R . | jq -cs . | tr -d '\r'; else printf '[]'; fi; }
# Account names from --config (12-digit = name lines) as one JSON object {account: name}.
account_names_json() {   # config names as JSON object (wins over IAM aliases and saved names)
    local k; { for k in "${!ACCOUNT_NAMES[@]}"; do printf '%s\t%s\n' "$k" "${ACCOUNT_NAMES[$k]}"; done; } \
        | jq -Rcs 'split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: (.[1:] | join(" "))}) | from_entries' | tr -d '\r'
}
# jq wrapper used for every value and file: removes the CR that jq.exe adds on Windows.
jqv() { jq "$@" | tr -d '\r'; }       # jq.exe on Windows writes CRLF: strip for values and files

# ---------------------------------------------------------------------------- config (options and --config values)
# set_opt KEY VALUE: validate one setting, store it in its global and note its source. Shared by the CLI and
# the conf file; returns 1 for an unknown key so each caller can word its own error.
set_opt() {   # set_opt key value  (shared by CLI and the conf file)
    local k="$1" v="$2"
    set_opt_apply "$k" "$v" || return 1
    src_note "$k"
}
# key_name KEY: canonical setting name (lower case, hyphens): weekly_retention_days / WEEKLY_RETENTION_DAYS -> weekly-retention-days.
key_name() { local k="${1//_/-}"; printf '%s' "${k,,}"; }
# src_note KEY: remember that setting KEY was last set by CUR_SRC (config file path or CLI).
src_note() {
    local k; k="$(key_name "$1")"
    [[ "$k" == monthly-max-days ]] && k=monthly-days
    OPT_SRC["$k"]="$CUR_SRC"
}
# set_list ARRAY KEY VALUE: list settings. In the conf the line is the whole list; on the CLI the first use of an
# option replaces the conf list and later uses add to it (-P a -P b).
set_list() {
    local -n _l="$1"
    if [[ "$CUR_SRC" != CLI || -z "${CLI_LIST_SET[$2]:-}" ]]; then _l=(); fi
    [[ "$CUR_SRC" == CLI ]] && CLI_LIST_SET["$2"]=1
    add_list "$1" "$3"
}
# set_opt_apply KEY VALUE: the validation and assignment behind set_opt (one case per setting).
set_opt_apply() {
    local k v="$2" e; k="$(key_name "$1")"
    case "$k" in
        profile) set_list PROFILES profile "$v" ;; region) set_list REGIONS region "$v" ;;
        all-regions) bool_set ALL_REGIONS --all-regions "$v" ;;
        engine) set_list ENGINES engine "$v" ;; identifier) set_list IDENTIFIERS identifier "$v" ;;
        check-mode) case "${v,,}" in schedule|counts) CHECK_MODE="${v,,}" ;; *) die 1 "--check-mode must be schedule or counts (got '$v')" ;; esac ;;
        daily) int_ok --daily "$v"; DAILY="$v" ;; daily-max-age) int_ok --daily-max-age "$v"; DAILY_MAX_AGE_H="$v" ;;
        weekly) [[ "$v" == auto ]] || int_ok --weekly "$v"; WEEKLY="$v" ;; monthly) int_ok --monthly "$v"; MONTHLY="$v" ;; yearly) int_ok --yearly "$v"; YEARLY="$v" ;;
        weekly-days) [[ "$v" =~ ^([0-9]+)-([0-9]+)$ ]] || die 1 "--weekly-days must be MIN-MAX (got '$v')"
            WEEKLY_MIN_DAYS="${BASH_REMATCH[1]}"; WEEKLY_MAX_DAYS="${BASH_REMATCH[2]}" ;;
        monthly-max-days) int_ok --monthly-max-days "$v"; MONTHLY_MAX_DAYS="$v" ;;
        monthly-days) [[ "$v" =~ ^([0-9]+)-([0-9]+)$ ]] || die 1 "--monthly-days must be MIN-MAX (got '$v')"
            MONTHLY_MIN_DAYS="${BASH_REMATCH[1]}"; MONTHLY_MAX_DAYS="${BASH_REMATCH[2]}" ;;
        weekly-weekday) dow_ok --weekly-weekday "$v"; WEEKLY_WEEKDAY="${v,,}" ;;
        monthly-rule) [[ "${v,,}" =~ ^first-(sun|mon|tue|wed|thu|fri|sat)$ ]] || die 1 "--monthly-rule must be first-sun .. first-sat (got '$v')"; MONTHLY_RULE="${v,,}" ;;
        parallel) int_ok --parallel "$v"; (( v >= 1 && v <= MAX_PARALLEL )) || die 1 "--parallel must be 1-$MAX_PARALLEL (got '$v')"; PARALLEL="$v" ;;
        daily-retention-days) int_or_empty --daily-retention-days "$v"; DAILY_RETENTION_DAYS="$v" ;;
        weekly-retention-days) int_ok --weekly-retention-days "$v"; WEEKLY_RETENTION_DAYS="$v" ;;
        monthly-retention-days) int_ok --monthly-retention-days "$v"; MONTHLY_RETENTION_DAYS="$v" ;;
        retention-tolerance-days) int_ok --retention-tolerance-days "$v"; RET_TOLERANCE_DAYS="$v" ;;
        tolerance-days) int_ok --tolerance-days "$v"; (( v <= MAX_TOLERANCE_DAYS )) || die 1 "--tolerance-days must be 0-$MAX_TOLERANCE_DAYS (got '$v')"; TOLERANCE_DAYS="$v" ;;
        weekly-window-days) int_or_empty --weekly-window-days "$v"
            [[ -z "$v" ]] || (( v >= DAYS_PER_WEEK )) || die 1 "--weekly-window-days must be at least $DAYS_PER_WEEK (or empty = weekly-retention-days)"; WEEKLY_WINDOW_DAYS="$v" ;;
        format) set_list FORMATS format "$v" ;; output-dir) OUTPUT_DIR="$v" ;;
        prefix) [[ -n "$v" ]] || die 1 "--prefix must not be empty"; PREFIX="$v" ;;
        tz) [[ -n "$v" ]] || die 1 "--tz must not be empty (e.g. Asia/Kolkata or UTC)"; DISPLAY_TZ="$v" ;;
        log-file) LOG_FILE="$v" ;; aws-timeout) int_ok --aws-timeout "$v"; AWS_TIMEOUT="$v" ;;
        max-attempts) int_ok --max-attempts "$v"; MAX_ATTEMPTS="$v" ;;
        non-compliant-only) bool_set NC_ONLY --non-compliant-only "$v" ;; fail-on-noncompliant) bool_set FAIL_ON_NC --fail-on-noncompliant "$v" ;;
        save-data) bool_set SAVE_DATA --save-data "$v" ;;
        snapshot-price-per-gb) [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die 1 "--snapshot-price-per-gb must be a number like 0.021 (got '$v')"; SNAP_PRICE="$v" ;;
        manual-older-than) int_or_empty --manual-older-than "$v"; MANUAL_OLDER="$v" ;;
        keep-reports) int_ok --keep-reports "$v"; KEEP_REPORTS="$v" ;;
        replica-exempt-engines) set_list EXEMPT_ENGINES replica-exempt-engines "$v" ;;
        exceptions) EXC_FILE="${v/#\~/$HOME}" ;;
        alert-email|alert-emails) set_list ALERT_EMAILS alert-email "$v"
            for e in "${ALERT_EMAILS[@]}"; do email_ok "$e" || die 1 "Invalid --alert-email address: $e"; done ;;
        alert-from) [[ -z "$v" ]] || email_ok "$v" || die 1 "Invalid --alert-from address: $v"; ALERT_FROM="$v" ;;
        alert-on) case "${v,,}" in noncompliant|always) ALERT_ON="${v,,}" ;; *) die 1 "--alert-on must be noncompliant or always (got '$v')" ;; esac ;;
        attach-html) bool_set ATTACH_HTML --attach-html "$v" ;;
        attach-csv) bool_set ATTACH_CSV --attach-csv "$v" ;;
        attach-prefix) [[ -n "$v" && "$v" =~ ^[A-Za-z0-9._-]+$ ]] || die 1 "--attach-prefix must be a non-empty name of letters, digits, dot, underscore or hyphen (got '$v')"; ATTACH_PREFIX="$v" ;;
        mail-timeout) int_ok --mail-timeout "$v"; (( v >= 1 )) || die 1 "--mail-timeout must be at least 1 second"; MAIL_TIMEOUT="$v" ;;
        *) return 1 ;;
    esac
    return 0
}

# load_config FILE: read key=value lines (# comments, blank lines skipped) through set_opt;
# "123456789012 = name" lines set display names for accounts. Any bad line, a key listed twice, or a missing
# required key stops the run naming the file (and line).
load_config() {
    local f="$1" line n=0 key val k
    local -A seen=()
    [[ -f "$f" || -p "$f" || -c "$f" ]] && [[ -r "$f" ]] || die 1 "Settings file not readable: $f
    Every setting comes from $CONFIG_NAME. Put the shipped file next to the script ($SCRIPT_DIR/$CONFIG_NAME),
    or point --config at a complete copy. A fresh copy is in the release zip."
    CUR_SRC="$f"
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1)); line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        ERR_CTX="Config $f:$n: "
        # account name line: strip a trailing # comment, control characters and quotes; at most MAX_NAME_CHARS
        if [[ "$line" =~ ^[[:space:]]*([0-9]{12})[[:space:]]*=[[:space:]]*(.*)$ ]]; then   # account name (display only)
            key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
            [[ "$val" =~ ^(.*[^[:space:]])?[[:space:]]+#.*$ ]] && val="${BASH_REMATCH[1]}"
            val="${val%"${val##*[![:space:]]}"}"; val="${val//[$'\001'-$'\037']/}"
            [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]] && val="${BASH_REMATCH[1]}"
            [[ -n "${seen[$key]:-}" ]] && die 1 "account $key is listed twice (also on line ${seen[$key]})"
            seen[$key]=$n; ACCOUNT_NAMES["$key"]="${val:0:$MAX_NAME_CHARS}"; continue
        fi
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_-]+)[[:space:]]*=[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]] || die 1 "expected key=value"
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]:-}"; k="$(key_name "$key")"
        [[ -n "${seen[$k]:-}" ]] && die 1 "'$k' is set twice (also on line ${seen[$k]}); keep one line"
        seen[$k]=$n
        [[ "$k" == no-config ]] && die 1 "unknown key '$key'"
        set_opt "$key" "$val" || die 1 "unknown key '$key'"
    done <"$f"
    ERR_CTX=""
    local -a miss=()
    for k in "${REQUIRED_KEYS[@]}"; do [[ -n "${seen[$k]:-}" ]] || miss+=("$k"); done
    local list; printf -v list '%s, ' "${miss[@]}"
    (( ${#miss[@]} )) && die 1 "Config $f is missing ${#miss[@]} required setting(s): ${list%, }
    Every setting must be in the file (a value may be empty where the shipped $CONFIG_NAME says so).
    Copy the missing lines from the shipped $CONFIG_NAME."
    return 0
}


# ---------------------------------------------------------------------------- args
# parse_args "$@": load the conf file first (so CLI options override it), then read the CLI options, then
# validate the combination. Sets the globals; exits 0 for --help / --version, 1 on a usage or config error.
parse_args() {
    # the conf: --config FILE, else rds_backup_compliance_report.conf next to the script (required either way).
    # Never sourced: load_config parses key=value lines. --help / --version work without it.
    local a help=0; for ((a = 1; a <= $#; a++)); do
        case "${!a}" in
            --config) local b=$((a + 1)); [[ $b -le $# ]] || die 1 "--config needs a file"; CONFIG_FILE="${!b}" ;;
            --no-config) die 1 "--no-config was removed in v1.7.1: every setting now comes from $CONFIG_NAME. Use --config FILE for another complete file, or CLI options to change single values" ;;
            -V|--version) echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            -h|--help) help=1 ;;
        esac
    done
    if [[ -z "$CONFIG_FILE" ]]; then CONFIG_FILE="$SCRIPT_DIR/$CONFIG_NAME"; CONFIG_AUTO=1; fi
    if (( help )); then   # show the current values when the file loads cleanly, else the help without values
        if ( load_config "$CONFIG_FILE" ) >/dev/null 2>&1; then load_config "$CONFIG_FILE"; else CONFIG_FILE=""; fi
        usage; exit 0
    fi
    load_config "$CONFIG_FILE"
    CUR_SRC="CLI"
    while (( $# )); do
        case "$1" in
            -P|--profile) need_arg "$1" $#; set_opt profile "$2"; shift ;;
            -r|--region) need_arg "$1" $#; set_opt region "$2"; shift ;;
            -A|--all-regions) set_opt all-regions yes ;;
            -e|--engine) need_arg "$1" $#; set_opt engine "$2"; shift ;;
            -i|--identifier) need_arg "$1" $#; set_opt identifier "$2"; shift ;;
            -F|--format) need_arg "$1" $#; set_opt format "$2"; shift ;;
            -o|--output-dir) need_arg "$1" $#; set_opt output-dir "$2"; shift ;;
            -l|--log-file) need_arg "$1" $#; set_opt log-file "$2"; shift ;;
            --config) shift ;;
            --check-config) CHECK_CONFIG=1 ;;
            --alert-test) ALERT_TEST=1 ;;
            --non-compliant-only) set_opt non-compliant-only yes ;; --fail-on-noncompliant) set_opt fail-on-noncompliant yes ;;
            --keep-workdir) KEEP_WORKDIR=1 ;; --dry-run) DRY_RUN=1 ;; -v|--verbose) VERBOSE=1 ;;
            --save-data) set_opt save-data yes; if [[ $# -ge 2 && "$2" != -* ]]; then SAVE_DATA_FILE="$2"; shift; fi ;;
            --merge) MERGE=1; while [[ $# -ge 2 && "$2" != -* ]]; do MERGE_ARGS+=("$2"); shift; done ;;
            --check-mode|--daily|--daily-max-age|--weekly|--monthly|--yearly|--weekly-days|--monthly-max-days|--monthly-days|--daily-retention-days|--weekly-retention-days|--monthly-retention-days|--retention-tolerance-days|--weekly-weekday|--monthly-rule|--tolerance-days|--parallel|--weekly-window-days|--prefix|--tz|--aws-timeout|--max-attempts|--manual-older-than|--snapshot-price-per-gb|--replica-exempt-engines|--exceptions|--keep-reports|--alert-email|--alert-from|--alert-on|--attach-html|--attach-csv|--attach-prefix|--mail-timeout)
                need_arg "$1" $#; set_opt "${1#--}" "$2"; shift ;;
            --*=*) set_opt "${1%%=*}" "${1#*=}" 2>/dev/null || die 1 "Unknown option: $1"; ;;
            *) die 1 "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done
    # validation: -r on the CLI replaces all-regions from the conf; formats; weekly / monthly ranges; --merge rules
    if [[ "${OPT_SRC[region]:-}" == CLI && "${OPT_SRC[all-regions]:-}" != CLI ]]; then ALL_REGIONS=0; fi
    local f; for f in "${FORMATS[@]}"; do case "$f" in text|txt|csv|json|html) ;; *) die 1 "Unknown format '$f' (text,csv,json,html)" ;; esac; done
    (( ${#FORMATS[@]} )) || die 1 "format is empty: set format= in $CONFIG_NAME (text, csv, json, html) or use -F"
    (( WEEKLY_MIN_DAYS <= WEEKLY_MAX_DAYS && WEEKLY_MAX_DAYS < MONTHLY_MIN_DAYS && MONTHLY_MIN_DAYS <= MONTHLY_MAX_DAYS )) \
        || die 1 "Need weekly-days MIN <= MAX < monthly-days MIN <= MAX (got weekly $WEEKLY_MIN_DAYS-$WEEKLY_MAX_DAYS, monthly $MONTHLY_MIN_DAYS-$MONTHLY_MAX_DAYS)"
    if (( MERGE )); then
        (( ${#MERGE_ARGS[@]} )) || die 1 "--merge needs at least one FILE or DIR"
        [[ "${OPT_SRC[profile]:-}" == CLI || "${OPT_SRC[region]:-}" == CLI || "${OPT_SRC[all-regions]:-}" == CLI ]] \
            && die 1 "--merge works offline: do not combine it with -P / -r / -A"
        [[ "${OPT_SRC[save-data]:-}" == CLI ]] && die 1 "--save-data cannot be combined with --merge"
        (( ALERT_TEST )) && die 1 "--alert-test cannot be combined with --merge"
        PROFILES=(); REGIONS=(); ALL_REGIONS=0; SAVE_DATA=0   # scope settings from the conf do not apply offline
    fi
    if [[ -n "$OUTPUT_DIR" && "$OUTPUT_DIR" == *.html && MERGE -eq 1 ]]; then OUT_FILE="$OUTPUT_DIR"; OUTPUT_DIR="$(dirname -- "$OUT_FILE")"; FORMATS=(html); fi
    if (( ${#FORMATS[@]} > 1 )) && [[ -z "$OUTPUT_DIR" ]]; then die 1 "Several formats need -o DIR (or output-dir in $CONFIG_NAME)"; fi
    return 0
}

# ---------------------------------------------------------------------------- evaluation settings (passed to lib/backup.jq as $cfg)
# tz_setup: TZ_OFFSET (seconds) and TZ_LABEL for the second time zone shown next to UTC (--tz).
tz_setup() {   # offset seconds + label of the second time zone (Git Bash date may lack zoneinfo: fallback for IST)
    local z; z="$(TZ="$DISPLAY_TZ" date +%z 2>/dev/null || echo +0000)"
    [[ "$z" =~ ^([+-])([0-9]{2})([0-9]{2})$ ]] || z="+0000"
    [[ "$z" =~ ^([+-])([0-9]{2})([0-9]{2})$ ]]
    TZ_OFFSET=$(( 10#${BASH_REMATCH[2]} * SECONDS_PER_HOUR + 10#${BASH_REMATCH[3]} * SECONDS_PER_MINUTE )); [[ "${BASH_REMATCH[1]}" == - ]] && TZ_OFFSET=$(( -TZ_OFFSET ))
    case "$DISPLAY_TZ" in Asia/Kolkata|Asia/Calcutta|IST) TZ_LABEL=IST; TZ_OFFSET=$IST_OFFSET_SECONDS ;;
        *) TZ_LABEL="$(TZ="$DISPLAY_TZ" date +%Z 2>/dev/null || echo "$DISPLAY_TZ")"; [[ "$TZ_LABEL" =~ ^[+-] ]] && TZ_LABEL="UTC$TZ_LABEL" ;; esac
    return 0
}

# cfg_json: every threshold as one JSON object ($cfg in backup.jq; jq has no fallbacks, so every key is passed).
# Weekday names become numbers (0 = Sunday); an empty daily-retention-days follows daily and an empty
# weekly-window-days follows weekly-retention-days; weekly "auto" stays a string. check_mode is added only in counts
# mode, so the settings embedded in the json / html reports of the default schedule mode stay exactly as before.
cfg_json() {
    local w="$WEEKLY"; [[ "$w" == auto ]] && w='"auto"'
    jq -cn --argjson d "$DAILY" --argjson h "$DAILY_MAX_AGE_H" --argjson w "$w" --argjson m "$MONTHLY" --argjson y "$YEARLY" \
        --argjson wmin "$WEEKLY_MIN_DAYS" --argjson wmax "$WEEKLY_MAX_DAYS" --argjson mmin "$MONTHLY_MIN_DAYS" --argjson mmax "$MONTHLY_MAX_DAYS" \
        --argjson wd "$(dow_num "$WEEKLY_WEEKDAY")" --argjson md "$(dow_num "${MONTHLY_RULE#first-}")" --argjson tol "$TOLERANCE_DAYS" --argjson ww "${WEEKLY_WINDOW_DAYS:-$WEEKLY_RETENTION_DAYS}" \
        --argjson dr "${DAILY_RETENTION_DAYS:-$DAILY}" --argjson wr "$WEEKLY_RETENTION_DAYS" --argjson mr "$MONTHLY_RETENTION_DAYS" --argjson rt "$RET_TOLERANCE_DAYS" \
        --argjson off "$TZ_OFFSET" --arg lab "$TZ_LABEL" --argjson mo "${MANUAL_OLDER:-null}" --argjson sp "$SNAP_PRICE" \
        --argjson ex "$(json_array "${EXEMPT_ENGINES[@]}")" --arg cm "$CHECK_MODE" \
        '{manual_older_than: $mo, snapshot_price_per_gb: $sp, daily: $d, daily_max_age_h: $h, weekly: $w, monthly: $m, yearly: $y, weekly_min_days: $wmin, weekly_max_days: $wmax,
          monthly_min_days: $mmin, monthly_max_days: $mmax, weekly_weekday: $wd, monthly_weekday: $md, tolerance_days: $tol, weekly_window_days: $ww,
          daily_retention_days: $dr, weekly_retention_days: $wr, monthly_retention_days: $mr, ret_tolerance_days: $rt,
          replica_exempt_engines: $ex, tz_offset: $off, tz_label: $lab} + (if $cm == "counts" then {check_mode: $cm} else {} end)' | tr -d '\r'
}


# ---------------------------------------------------------------------------- compliance exceptions (shared by
# rds-patch-compliance, rds-backup-compliance and rds-compliance-report; same file format in all three)
# compliance_exceptions.conf, one entry per line:  account_id | identifier | scope | expires | reason
#   all five required; scope patch, backup or patch,backup; expires YYYY-MM-DD (UTC, last valid day); # comments
# Strict: any bad line stops the run (exit 1) naming file:line. Applied at report time only (saved data is unchanged).
# exc_trim VAR: trim leading and trailing whitespace of the named variable in place.
exc_trim() { local -n _v="$1"; _v="${_v#"${_v%%[![:space:]]*}"}"; _v="${_v%"${_v##*[![:space:]]}"}"; }
# load_exceptions: read and validate the exceptions file (--exceptions, else compliance_exceptions.conf
# next to the script; no file = feature off). Sets EXC_JSON (entries as JSON, or null) and EXC_PATH.
load_exceptions() {   # -> EXC_JSON: "null" (feature off: no file) or a JSON array of entries; EXC_PATH = the file used
    local f="$EXC_FILE" line n=0 acct id scope exp reason s y m d dim k tsv=""
    local -a sc=()
    local -A seen=()
    if [[ -z "$f" ]]; then f="$SCRIPT_DIR/compliance_exceptions.conf"; [[ -f "$f" ]] || return 0; fi
    [[ -f "$f" && -r "$f" ]] || die 1 "Exceptions file not readable: $f"
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1)); line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" == *'|'*'|'*'|'*'|'* ]] || die 1 "Exceptions $f:$n: expected 5 fields 'account_id | identifier | scope | expires | reason'"
        IFS='|' read -r acct id scope exp reason <<<"$line"
        exc_trim acct; exc_trim id; exc_trim scope; exc_trim exp; reason="${reason//[$'\001'-$'\037']/ }"; exc_trim reason
        [[ -n "$acct" && -n "$id" && -n "$scope" && -n "$exp" && -n "$reason" ]] \
            || die 1 "Exceptions $f:$n: missing field (all of account_id, identifier, scope, expires, reason are required)"
        [[ "$acct" =~ ^[0-9]{12}$ ]] || die 1 "Exceptions $f:$n: account_id must be 12 digits (got '$acct')"
        [[ "$id" =~ ^[A-Za-z][A-Za-z0-9-]{0,62}$ ]] \
            || die 1 "Exceptions $f:$n: identifier '$id' is not a DB instance / cluster identifier (letters, digits, hyphens; no wildcards)"
        # scope: lower case, no spaces, only patch / backup, each at most once
        scope="${scope,,}"; scope="${scope//[[:space:]]/}"; IFS=',' read -r -a sc <<<"$scope"
        (( ${#sc[@]} )) || die 1 "Exceptions $f:$n: scope must be patch, backup or patch,backup"
        k=""; for s in "${sc[@]}"; do
            [[ "$s" == patch || "$s" == backup ]] || die 1 "Exceptions $f:$n: scope must be patch, backup or patch,backup (got '$scope')"
            [[ ",$k," == *",$s,"* ]] && die 1 "Exceptions $f:$n: scope lists '$s' twice"
            k+="${k:+,}$s"
        done
        scope="$k"
        # expires: mandatory YYYY-MM-DD that is a real calendar date (leap years checked)
        [[ "$exp" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || die 1 "Exceptions $f:$n: expires must be a date YYYY-MM-DD (got '$exp'); an expiry date is mandatory"
        y=$((10#${BASH_REMATCH[1]})); m=$((10#${BASH_REMATCH[2]})); d=$((10#${BASH_REMATCH[3]}))
        case "$m" in 1|3|5|7|8|10|12) dim=31 ;; 4|6|9|11) dim=30 ;;
            2) if (( (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 )); then dim=29; else dim=28; fi ;; *) dim=0 ;; esac
        (( m >= 1 && m <= 12 && d >= 1 && d <= dim && y >= 2000 )) || die 1 "Exceptions $f:$n: expires '$exp' is not a valid date"
        # the same account + identifier (any case) may appear only once per scope
        for s in "${sc[@]}"; do
            k="$acct|${id,,}|$s"
            [[ -n "${seen[$k]:-}" ]] && die 1 "Exceptions $f:$n: duplicate entry for $acct $id ($s), already on line ${seen[$k]}"
            seen[$k]=$n
        done
        tsv+="$n"$'\t'"$acct"$'\t'"$id"$'\t'"$scope"$'\t'"$exp"$'\t'"$reason"$'\n'
    done <"$f"
    EXC_PATH="$f"
    # tab-separated lines -> JSON array [{line, account, identifier, scopes, expires, reason}]
    EXC_JSON="$(printf '%s' "$tsv" | jq -Rcs 'split("\n") | map(select(. != "") | split("\t")
        | {line: (.[0] | tonumber), account: .[1], identifier: .[2], scopes: (.[3] | split(",")), expires: .[4], reason: (.[5:] | join(" "))})' | tr -d '\r')" \
        || die 1 "Exceptions $f: cannot convert the entries (jq)"
    return 0
}

# ---------------------------------------------------------------------------- --check-config
# setting_line NAME VALUE: one "name  value  source" row; the source is "conf" (the settings file) or "CLI".
setting_line() {
    local src="${OPT_SRC[$1]:-}"
    if [[ -z "$src" ]]; then src="-"; elif [[ "$src" == "$CONFIG_FILE" ]]; then src="conf"; elif [[ "$src" != CLI ]]; then src="config $src"; fi
    printf '  %-26s %-30s %s\n' "$1" "${2:-(empty)}" "$src"
}
# setting_value NAME: the effective value of one setting as text (lists comma-separated, booleans yes / no).
setting_value() {
    case "$1" in
        profile) (IFS=,; echo "${PROFILES[*]}") ;; region) (IFS=,; echo "${REGIONS[*]}") ;; all-regions) yn "$ALL_REGIONS" ;;
        engine) (IFS=,; echo "${ENGINES[*]}") ;; identifier) (IFS=,; echo "${IDENTIFIERS[*]}") ;;
        check-mode) echo "$CHECK_MODE" ;; daily) echo "$DAILY" ;; daily-max-age) echo "$DAILY_MAX_AGE_H" ;; weekly-weekday) echo "$WEEKLY_WEEKDAY" ;;
        weekly-retention-days) echo "$WEEKLY_RETENTION_DAYS" ;; monthly-rule) echo "$MONTHLY_RULE" ;; monthly) echo "$MONTHLY" ;;
        monthly-retention-days) echo "$MONTHLY_RETENTION_DAYS" ;; replica-exempt-engines) (IFS=,; echo "${EXEMPT_ENGINES[*]}") ;;
        format) (IFS=,; echo "${FORMATS[*]}") ;; output-dir) echo "$OUTPUT_DIR" ;; tz) echo "$DISPLAY_TZ" ;;
        non-compliant-only) yn "$NC_ONLY" ;; log-file) echo "$LOG_FILE" ;; manual-older-than) echo "${MANUAL_OLDER:-(empty = off)}" ;;
        snapshot-price-per-gb) echo "$SNAP_PRICE" ;; keep-reports) if (( KEEP_REPORTS )); then echo "$KEEP_REPORTS days"; else echo "0 = keep all"; fi ;;
        alert-email) (IFS=,; echo "${ALERT_EMAILS[*]:-(empty = off)}") ;; alert-from) echo "$ALERT_FROM" ;; alert-on) echo "$ALERT_ON" ;;
        attach-html) yn "$ATTACH_HTML" ;; attach-csv) yn "$ATTACH_CSV" ;; attach-prefix) echo "$ATTACH_PREFIX" ;;
        exceptions) echo "$EXC_FILE" ;; weekly) echo "$WEEKLY" ;;
        weekly-window-days) echo "${WEEKLY_WINDOW_DAYS:-= weekly-retention-days ($WEEKLY_RETENTION_DAYS)}" ;;
        weekly-days) echo "$WEEKLY_MIN_DAYS-$WEEKLY_MAX_DAYS" ;; monthly-days) echo "$MONTHLY_MIN_DAYS-$MONTHLY_MAX_DAYS" ;;
        tolerance-days) echo "$TOLERANCE_DAYS" ;; daily-retention-days) echo "${DAILY_RETENTION_DAYS:-= daily ($DAILY)}" ;;
        retention-tolerance-days) echo "$RET_TOLERANCE_DAYS" ;; yearly) echo "$YEARLY" ;; parallel) echo "$PARALLEL" ;;
        prefix) echo "$PREFIX" ;; aws-timeout) echo "$AWS_TIMEOUT" ;; max-attempts) echo "$MAX_ATTEMPTS" ;; mail-timeout) echo "$MAIL_TIMEOUT" ;;
        fail-on-noncompliant) yn "$FAIL_ON_NC" ;; save-data) yn "$SAVE_DATA" ;;
    esac
}
# check_config: print the files in use, every effective setting with its source, the account names, the exceptions
# and the mail command. Runs after parse_args and load_exceptions (both stop the run, exit 1 with file:line, on a
# bad line or a missing setting), so reaching it means the files are valid. Makes no AWS call.
check_config() {
    local cfg_note exc_note a k today mailer
    if (( CONFIG_AUTO )); then cfg_note="$CONFIG_FILE (next to the script)"; else cfg_note="$CONFIG_FILE (--config)"; fi
    if [[ -n "$EXC_FILE" ]]; then
        if [[ "${OPT_SRC[exceptions]:-}" == CLI ]]; then exc_note="$EXC_PATH (--exceptions)"; else exc_note="$EXC_PATH (exceptions key in config)"; fi
    elif [[ -n "$EXC_PATH" ]]; then exc_note="$EXC_PATH (auto-loaded from the script folder)"
    else exc_note="none (no exceptions in effect)"; fi
    echo "Config file:     $cfg_note"
    echo "Exceptions file: $exc_note"
    echo "Script folder:   $SCRIPT_DIR"
    echo; echo "Settings in effect (name, value, source: conf = the config file above, CLI = command line):"
    for k in "${REQUIRED_KEYS[@]}"; do setting_line "$k" "$(setting_value "$k")"; done
    echo; echo "Account names (${#ACCOUNT_NAMES[@]}):"
    if (( ${#ACCOUNT_NAMES[@]} )); then for a in $(printf '%s\n' "${!ACCOUNT_NAMES[@]}" | sort); do printf '  %s = %s\n' "$a" "${ACCOUNT_NAMES[$a]}"; done
    else echo "  none (IAM account alias, else the number, is shown)"; fi
    today="$(date -u +%F)"; [[ "${RDS_BCR_EXC_NOW:-}" =~ ^[0-9]+$ ]] && today="$(date -u -d "@$RDS_BCR_EXC_NOW" +%F)"
    echo; if [[ "$EXC_JSON" == null ]]; then echo "Exceptions: none"
    else
        echo "Exceptions ($(jqv -r 'length' <<<"$EXC_JSON")); today is $today UTC:"
        jqv -r --arg today "$today" '.[] | "  line \(.line): \(.account) \(.identifier) scope=\(.scopes | join(",")) expires \(.expires)"
              + (if .expires < $today then " EXPIRED" else "" end)
              + (if (.scopes | index("backup")) then "" else " (patch only: not applied by this script)" end)
              + " - \(.reason)"' <<<"$EXC_JSON"
    fi
    echo; if (( ${#ALERT_EMAILS[@]} )); then
        mailer="$(find_mailer)"
        echo "E-mail: to ${ALERT_EMAILS[*]} when $( [[ "$ALERT_ON" == always ]] && echo "every run" || echo "NON-COMPLIANT or AWS errors")"
        case "$mailer" in
            "") echo "  mail command: none found (mail, mailx, sendmail): the run would only log a warning" ;;
            *sendmail)
                local att=()
                (( ATTACH_HTML )) && att+=("the HTML report")
                (( ATTACH_CSV )) && att+=("the compliance CSV")
                if (( ${#att[@]} )); then
                    local joined; joined="$(printf '%s and ' "${att[@]}")"; joined="${joined% and }"
                    echo "  mail command: $mailer (HTML body with a text fallback; attaches $joined)"
                else
                    echo "  mail command: $mailer (HTML body with a text fallback; no attachments)"
                fi ;;
            *) echo "  mail command: $mailer (text summary only; install sendmail for the HTML body and attachments)" ;;
        esac
    else echo "E-mail: off (alert-email is empty)"; fi
    echo; echo "OK: configuration is valid (no AWS calls made)"
}

# ---------------------------------------------------------------------------- report retention (keep-reports)
# prune_reports: delete files in the output dir older than keep-reports days whose names start with the prefix and
# end in a report extension. Never touches other files or folders; logs every deletion; 0 = keep all.
# --dry-run only previews: one "would delete" line per file and a count, nothing is removed.
prune_reports() {
    (( KEEP_REPORTS > 0 )) && [[ -n "$OUTPUT_DIR" && -d "$OUTPUT_DIR" ]] || return 0
    local f e n=0; local -a names=()
    for e in $REPORT_EXTS; do names+=(-o -name "${PREFIX}_*.$e"); done
    while IFS= read -r -d '' f; do
        if (( DRY_RUN )); then n=$((n + 1)); log_info "keep-reports: would delete ${f##*/}"; continue; fi
        if rm -f -- "$f"; then n=$((n + 1)); log_info "keep-reports: deleted ${f##*/} (older than $KEEP_REPORTS days)"
        else log_warn "keep-reports: cannot delete $f"; fi
    done < <(find "$OUTPUT_DIR" -maxdepth 1 -type f \( "${names[@]:1}" \) -mmin +$(( KEEP_REPORTS * MINUTES_PER_DAY )) -print0 2>/dev/null)
    if (( DRY_RUN )); then log_info "keep-reports: $n old report file(s) would be deleted from $OUTPUT_DIR (keeping $KEEP_REPORTS days); nothing was deleted"
    else log_info "keep-reports: $n old report file(s) deleted from $OUTPUT_DIR (keeping $KEEP_REPORTS days)"; fi
}

# ---------------------------------------------------------------------------- e-mail (alert-email)
# find_mailer: prefer sendmail (needed for MIME: HTML body + attachments). Else mail, then mailx.
# Prints nothing when none exists.
find_mailer() {
    local c
    command -v sendmail 2>/dev/null && return 0
    [[ -x /usr/sbin/sendmail ]] && { echo /usr/sbin/sendmail; return 0; }
    for c in mail mailx; do command -v "$c" 2>/dev/null && return 0; done
    return 0
}
# attach_mime_name FILE: short name used only in the MIME headers (the file on disk keeps its name).
# Shape is <attach-prefix>_YYYY-MM-DD.<ext>, with the UTC date of this run.
attach_mime_name() {
    local ext="${1##*.}" day
    if [[ "$NOW" =~ ^[1-9][0-9]*$ ]]; then day="$(date -u -d "@$NOW" +%Y-%m-%d)"
    else day="$(date -u +%Y-%m-%d)"; fi
    printf '%s_%s.%s' "$ATTACH_PREFIX" "$day" "$ext"
}
# mime_attach BOUNDARY FILE [NAME]: one MIME attachment part (base64). NAME defaults to the short attach-prefix name.
mime_attach() {
    local bnd="$1" f="$2" name="${3:-}" ctype
    [[ -n "$name" ]] || name="$(attach_mime_name "$f")"
    case "${f##*.}" in
        html|htm) ctype="text/html; charset=UTF-8" ;;
        csv) ctype="text/csv; charset=UTF-8" ;;
        *) ctype="application/octet-stream" ;;
    esac
    printf -- '\n--%s\nContent-Type: %s; name="%s"\nContent-Disposition: attachment; filename="%s"\nContent-Transfer-Encoding: base64\n\n' \
        "$bnd" "$ctype" "$name" "$name"
    base64 <"$f"
}
# send_email SUBJECT TEXT_FILE HTML_FILE [ATTACH ...]: send with sendmail (multipart/alternative text+HTML,
# plus any attachments in multipart/mixed) or mail / mailx (text only). The mail command may take at most
# mail-timeout seconds. Returns 1 when no command exists.
send_email() {
    local subject="$1" text="$2" html="$3" mailer to mixed alt
    shift 3
    local -a atts=("$@") tmo=()
    command -v timeout >/dev/null 2>&1 && tmo=(timeout "$MAIL_TIMEOUT")
    mailer="$(find_mailer)"
    [[ -n "$mailer" ]] || { log_warn "E-mail: no mail, mailx or sendmail found; e-mail not sent (the report is still written)"; return 1; }
    if [[ "${mailer##*/}" != sendmail ]]; then
        local -a from=(); [[ -n "$ALERT_FROM" ]] && from=(-r "$ALERT_FROM")
        log_info "E-mail: ${mailer##*/} cannot send the HTML body or attachments; sending the text summary only. Install sendmail for the HTML body and attachments"
        "${tmo[@]}" "$mailer" "${from[@]}" -s "$subject" -- "${ALERT_EMAILS[@]}" <"$text"; return
    fi
    to="$(IFS=,; printf '%s' "${ALERT_EMAILS[*]}")"
    mixed="rds_bcr_$(date +%s)_$$"
    alt="rds_bcr_alt_$(date +%s)_$$"
    {
        [[ -n "$ALERT_FROM" ]] && printf 'From: %s\n' "$ALERT_FROM"
        printf 'To: %s\nSubject: %s\nMIME-Version: 1.0\n' "$to" "$subject"
        if (( ${#atts[@]} )); then
            printf 'Content-Type: multipart/mixed; boundary="%s"\n\nThis is a MIME message.\n\n' "$mixed"
            printf -- '--%s\nContent-Type: multipart/alternative; boundary="%s"\n\n' "$mixed" "$alt"
        else
            printf 'Content-Type: multipart/alternative; boundary="%s"\n\n' "$alt"
        fi
        printf -- '--%s\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n' "$alt"
        cat -- "$text"
        printf -- '\n--%s\nContent-Type: text/html; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n' "$alt"
        cat -- "$html"
        printf -- '\n--%s--\n' "$alt"
        if (( ${#atts[@]} )); then
            local a; for a in "${atts[@]}"; do mime_attach "$mixed" "$a"; done
            printf -- '\n--%s--\n' "$mixed"
        fi
    } | "${tmo[@]}" "$mailer" -t -oi
}
# is_compliance_csv FILE: the per-server compliance CSV, not the backups / orphans / manual-older sidecars.
is_compliance_csv() {
    local b="${1##*/}"
    [[ "$b" == *.csv ]] || return 1
    [[ "$b" != *_backups.csv && "$b" != *_orphaned_snapshots.csv && "$b" != *_manual_older_than_*csv ]]
}
# alert_bodies DATA HOST WHEN TEXT_OUT HTML_OUT: write the text and HTML e-mail bodies
# with lib/alert_email.jq. DATA is the render-json document. Returns 1 if either file cannot be built.
alert_bodies() {
    local data="$1" host="$2" when="$3" text_out="$4" html_out="$5" tool
    tool="$SCRIPT_NAME v$SCRIPT_VERSION"
    render json "$data" | jqv -r -f "$LIBDIR/alert_email.jq" --arg mode text --arg host "$host" \
        --arg tool "$tool" --arg when "$when" >"$text_out" || return 1
    render json "$data" | jqv -r -f "$LIBDIR/alert_email.jq" --arg mode html --arg host "$host" \
        --arg tool "$tool" --arg when "$when" >"$html_out" || return 1
    return 0
}
# send_alerts [test]: build the HTML+text summary and e-mail it to alert-email. With
# alert-on=noncompliant it only sends when a NON-COMPLIANT server or an AWS error (failed region, UNKNOWN row) was
# found; servers with an applied exception count as compliant. Never changes the exit code.
send_alerts() {
    local mode="${1:-}" subject text="$WORK/alert_body.txt" html="$WORK/alert_body.html" sum host when
    local -a atts=()
    (( ${#ALERT_EMAILS[@]} )) || return 0
    host="$(hostname 2>/dev/null || echo unknown)"
    when="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    if [[ "$mode" == test ]]; then
        subject="[$PREFIX] TEST e-mail from $host"
        printf 'Test e-mail from %s on %s at %s. No AWS calls were made.\n' "$SCRIPT_NAME v$SCRIPT_VERSION" "$host" "$when" >"$text"
        printf '%s\n' \
            '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>TEST e-mail</title></head>' \
            '<body style="margin:0;padding:0;font-family:Arial,Helvetica,sans-serif;color:#1d2939;">' \
            '<table role="presentation" width="680" cellspacing="0" cellpadding="0" style="max-width:680px;border:1px solid #d0d5dd;">' \
            '<tr><td style="padding:16px 20px;background:#1f5fa8;color:#ffffff;"><div style="font-size:11px;letter-spacing:.04em;text-transform:uppercase;opacity:.9;">RDS backup compliance</div>' \
            '<div style="font-size:20px;font-weight:700;margin-top:4px;">TEST</div></td></tr>' \
            "<tr><td style=\"padding:16px 20px;font-size:14px;line-height:1.5;\">Test e-mail from $(printf '%s' "$SCRIPT_NAME v$SCRIPT_VERSION" | jqv -Rr @html) on $(printf '%s' "$host" | jqv -Rr @html) at $(printf '%s' "$when" | jqv -Rr @html). No AWS calls were made.</td></tr>" \
            "<tr><td style=\"padding:12px 20px;border-top:1px solid #e4e7ec;font-size:11px;color:#667085;\">$(printf '%s' "$SCRIPT_NAME v$SCRIPT_VERSION · $host · $when" | jqv -Rr @html)</td></tr>" \
            '</table></body></html>' >"$html"
    else
        sum="$(render json "$WORK/data.json" | jqv -c --argjson aws_fails "$AWS_FAILS" '
            ([.regions[]? | select(.status == "error")] | length) as $re | ([.rows[] | select(.status == "UNKNOWN")] | length) as $un
            | {t: .totals, nc: .totals.non_compliant, err: ($re + $un), re: $re, un: $un}')" || { log_warn "E-mail: building the summary failed"; return 0; }
        if [[ "$ALERT_ON" == noncompliant && "$(jqv -r '.nc + .err' <<<"$sum")" == 0 ]]; then
            log_info "E-mail: not sent (alert-on=noncompliant and everything is compliant)"; return 0
        fi
        subject="[$PREFIX] $(jqv -r 'if .nc > 0 then "NON-COMPLIANT" elif .err > 0 then "ERRORS" else "COMPLIANT" end
            + ": \(.nc) non-compliant of \(.t.resources), \(.t.compliance.pct // 0)% compliant"' <<<"$sum")"
        alert_bodies "$WORK/data.json" "$host" "$when" "$text" "$html" \
            || { log_warn "E-mail: building the summary failed"; return 0; }
        # attachments: use a report already written, else render one into the work dir (not listed as a report file)
        if (( ATTACH_HTML )); then
            local hf="" w
            for w in "${WRITTEN[@]}"; do [[ "$w" == *.html ]] && hf="$w"; done
            if [[ -z "$hf" ]]; then
                hf="$WORK/${PREFIX}_report.html"
                render html "$WORK/data.json" >"$hf" || hf=""
            fi
            [[ -n "$hf" && -s "$hf" ]] && atts+=("$hf")
        fi
        if (( ATTACH_CSV )); then
            local cf="" w
            for w in "${WRITTEN[@]}"; do is_compliance_csv "$w" && cf="$w"; done
            if [[ -z "$cf" ]]; then
                cf="$WORK/${PREFIX}_report.csv"
                render csv "$WORK/data.json" >"$cf" || cf=""
            fi
            [[ -n "$cf" && -s "$cf" ]] && atts+=("$cf")
        fi
    fi
    if send_email "$subject" "$text" "$html" "${atts[@]}"; then log_info "E-mail sent to ${ALERT_EMAILS[*]}: $subject"
    else log_warn "E-mail to ${ALERT_EMAILS[*]} failed or was not sent"; fi
    return 0
}

# ---------------------------------------------------------------------------- AWS (read-only)
# awsc OUT PROFILE REGION SERVICE OPERATION [ARGS]: run one read-only AWS CLI call, JSON to OUT, stderr to
# OUT.err. Counts calls / failures; CLI retries in standard mode. --dry-run prints the command instead. Returns the CLI status.
awsc() {   # awsc <out-file> <profile> <region> <service> <operation> [args...]; stderr -> <out-file>.err
    local out="$1" prof="$2" reg="$3"; shift 3
    local -a cmd=(aws "$@" --output json --cli-connect-timeout "$AWS_TIMEOUT" --cli-read-timeout "$AWS_TIMEOUT")
    [[ -n "$reg" ]] && cmd+=(--region "$reg"); [[ -n "$prof" ]] && cmd+=(--profile "$prof")
    if (( DRY_RUN )); then printf 'DRY-RUN: %s\n' "${cmd[*]}"; echo '{}' >"$out"; return 0; fi
    AWS_CALLS=$((AWS_CALLS + 1)); log_debug "${cmd[*]}"
    if AWS_MAX_ATTEMPTS="$MAX_ATTEMPTS" AWS_RETRY_MODE=standard AWS_PAGER="" "${cmd[@]}" >"$out" 2>"$out.err"; then return 0; fi
    AWS_FAILS=$((AWS_FAILS + 1)); return 1
}
# err_of OUT: first readable line of OUT.err (the AWS error text), at most 200 characters.
err_of() { tr -d '\r' <"$1.err" | grep -v '^[[:space:]]*$' | sed -E 's/^aws: \[ERROR\]: //; s/An error occurred //' | head -1 | cut -c1-"$MAX_ERR_CHARS"; }

# glob_match VALUE GLOB...: case-insensitive match against any glob; no globs = match (no -e / -i filter).
# shellcheck disable=SC2053  # the right-hand side is a glob on purpose
glob_match() { local v="${1,,}" g; shift; (( $# )) || return 0; for g in "$@"; do [[ "$v" == ${g,,} ]] && return 0; done; return 1; }

# ---------------------------------------------------------------------------- collection (one account + region)
# scan_region PROFILE ACCOUNT REGION DIR: read one region (RDS, snapshots, AWS Backup), build its resources
# with lib/collect.jq, apply the -e / -i filters. Writes DIR/resources.json, orphans.json, region.json, stats.
scan_region() {   # scan_region <profile> <account> <region> <dir>  -> <dir>/resources.json, <dir>/region.json
    local prof="$1" acct="$2" reg="$3" d="$4" e; local -a errs=()
    local c0=$AWS_CALLS f0=$AWS_FAILS gf="$WORK/$acct.globals.json"
    # a background job cannot update the parent's GLOBAL_DONE, so in parallel mode each region reads global clusters itself
    (( SCAN_PAR )) && { gf="$d/globals.json"; GLOBAL_DONE=0; GLOBAL_OK=true; }   # parallel: each region job has its own copy
    local csnap_ok=true isnap_ok=true backup_ok=true
    echo '{}' >"$d/c.json"; echo '{}' >"$d/i.json"; echo '{}' >"$d/cs.json"; echo '{}' >"$d/is.json"; echo '[]' >"$d/rp.json"
    awsc "$d/c.json" "$prof" "$reg" rds describe-db-clusters || { errs+=("describe-db-clusters: $(err_of "$d/c.json")"); echo '{}' >"$d/c.json"; }
    awsc "$d/i.json" "$prof" "$reg" rds describe-db-instances || { errs+=("describe-db-instances: $(err_of "$d/i.json")"); echo '{}' >"$d/i.json"; }
    local nc ni
    nc="$(jqv '[.DBClusters[]? | select(.Engine | test("^(docdb|neptune)") | not)] | length' "$d/c.json")"
    ni="$(jqv '[.DBInstances[]? | select((.DBClusterIdentifier // "") == "" and (.Engine | test("^(docdb|neptune)") | not))] | length' "$d/i.json")"
    if (( DRY_RUN )); then nc=1; ni=1; fi
    # snapshots: region-wide in every region (manual snapshots outlive their source; --include-shared adds shared ones)
    awsc "$d/cs.json" "$prof" "$reg" rds describe-db-cluster-snapshots --include-shared || { csnap_ok=false; errs+=("describe-db-cluster-snapshots: $(err_of "$d/cs.json")"); echo '{}' >"$d/cs.json"; }
    awsc "$d/is.json" "$prof" "$reg" rds describe-db-snapshots --include-shared || { isnap_ok=false; errs+=("describe-db-snapshots: $(err_of "$d/is.json")"); echo '{}' >"$d/is.json"; }
    # global clusters and AWS Backup recovery points are read only when the region has a database
    if (( nc + ni > 0 )); then
        if (( nc > 0 && ! GLOBAL_DONE )); then GLOBAL_DONE=1
            if awsc "$gf" "$prof" "$reg" rds describe-global-clusters; then GLOBAL_OK=true
            else GLOBAL_OK=false; errs+=("describe-global-clusters: $(err_of "$gf")"); echo '{}' >"$gf"; fi
        fi
        if awsc "$d/v.json" "$prof" "$reg" backup list-backup-vaults; then
            local v k=0
            while IFS= read -r v; do
                [[ -n "$v" ]] || continue; k=$((k + 1))
                if awsc "$d/rp$k.json" "$prof" "$reg" backup list-recovery-points-by-backup-vault --backup-vault-name "$v"; then :
                else backup_ok=false; errs+=("list-recovery-points-by-backup-vault $v: $(err_of "$d/rp$k.json")"); echo '{}' >"$d/rp$k.json"; fi
            done < <(jqv -r '.BackupVaultList[]?.BackupVaultName' "$d/v.json")
            if (( k )); then jqv -s '[ .[].RecoveryPoints[]? | select(.ResourceType == "Aurora" or .ResourceType == "RDS" or (.ResourceArn // "" | test(":rds:"))) ]' "$d"/rp[0-9]*.json >"$d/rp.json"; fi
        else backup_ok=false; errs+=("list-backup-vaults: $(err_of "$d/v.json")"); fi
    fi
    [[ -s "$gf" ]] || echo '{}' >"$gf"   # (re)fetched only once: GLOBAL_DONE
    # lib/collect.jq: raw describe-* outputs -> {resources, orphans, existing}
    jqv -n --arg acct "$acct" --arg region "$reg" --slurpfile clusters "$d/c.json" --slurpfile instances "$d/i.json" \
        --slurpfile csnaps "$d/cs.json" --slurpfile isnaps "$d/is.json" --slurpfile rps "$d/rp.json" --slurpfile globals "$gf" \
        --argjson csnap_ok "$csnap_ok" --argjson isnap_ok "$isnap_ok" --argjson backup_ok "$backup_ok" --argjson global_ok "${GLOBAL_OK:-true}" -f "$LIBDIR/collect.jq" >"$d/coll.json"
    jqv '.resources' "$d/coll.json" >"$d/all.json"
    # engine / identifier filters
    local keep='[]' id en
    local -a ks=()
    while IFS=$'\t' read -r id en; do
        [[ -n "$id" ]] || continue
        glob_match "$id" "${IDENTIFIERS[@]}" && glob_match "$en" "${ENGINES[@]}" && ks+=("$id")
    done < <(jqv -r '.[] | [.id, .engine] | @tsv' "$d/all.json")
    keep="$(json_array "${ks[@]}")"
    jqv --argjson k "$keep" '[ .[] | select(.id as $i | $k | index([$i])) ]' "$d/all.json" >"$d/resources.json"
    local -a ko=(); local k=0   # same filters on orphan candidates (source identifier + engine)
    while IFS=$'\t' read -r id en; do
        glob_match "$id" "${IDENTIFIERS[@]}" && glob_match "$en" "${ENGINES[@]}" && ko+=("$k"); k=$((k + 1))
    done < <(jqv -r '.orphans[] | [(.source_id // ""), (.engine // "")] | @tsv' "$d/coll.json")
    jqv --argjson k "$(json_array "${ko[@]}")" '[ .orphans | to_entries[] | select(.key | tostring as $x | $k | index([$x])) | .value ]' "$d/coll.json" >"$d/orphans.json"
    local n no status; n="$(jqv length "$d/resources.json")"; no="$(jqv length "$d/orphans.json")"
    # region status: error > with databases > snapshots only > empty
    if (( ${#errs[@]} )); then status=error; elif (( n > 0 )); then status="with databases"; elif (( no > 0 )); then status="snapshots only"; else status=empty; fi
    for e in "${errs[@]}"; do log_warn "$acct $reg: $e"; done
    region_progress "$reg" "$d/resources.json" "$no" "${errs[@]}"
    jqv -n --arg a "$acct" --arg r "$reg" --arg s "$status" --argjson n "$n" --argjson e "$(json_array "${errs[@]}")" \
        --argjson snapok "$( [[ $csnap_ok == true && $isnap_ok == true ]] && echo true || echo false)" --slurpfile c "$d/coll.json" \
        '{account: $a, region: $r, status: $s, resources: $n, errors: $e, snapshot_scan: $snapok, existing: $c[0].existing}' >"$d/region.json"
    echo "$((AWS_CALLS - c0)) $((AWS_FAILS - f0))" >"$d/stats"
}

# ---------------------------------------------------------------------------- region jobs (parallel scan)
# region_job ARGS: background job wrapper. Runs scan_region in a subshell with its own error handling and writes
# its exit code to DIR/rc; a missing rc file means the job was killed.
# shellcheck disable=SC2030,SC2031  # REG_T0 is per job on purpose
region_job() {   # background job: scan_region in a subshell; <dir>/rc marks a normal finish
    local d="$4"
    trap - EXIT INT TERM; set +e
    ( set -e; shopt -s inherit_errexit 2>/dev/null || true; REG_T0=$SECONDS; scan_region "$@" ); echo $? >"$d/rc"
}

# region_failed ACCOUNT REGION DIR WHY: write empty results and an "error" region.json for a failed job,
# so the other regions still report and the failure shows under Region errors.
region_failed() {   # region_failed <account> <region> <dir> <why>: placeholder result so other regions still report
    local a="$1" r="$2" d="$3" why="$4"
    echo '[]' >"$d/resources.json"; echo '[]' >"$d/orphans.json"
    jqv -n --arg a "$a" --arg r "$r" --arg e "region scan failed: $why" \
        '{account: $a, region: $r, status: "error", resources: 0, errors: [$e], snapshot_scan: false, existing: []}' >"$d/region.json"
}

# region_progress REGION RESOURCES_FILE ORPHANS [ERRORS]: log one progress line for the region (counts, seconds,
# errors). Empty regions are logged only with -v; they appear in region_summary.
region_progress() {   # one line per region with resources (all regions with -v): [i/N] region: counts (seconds); errors always shown
    local reg="$1" res="$2" no="$3"; shift 3
    # shellcheck disable=SC2031  # REG_T0 is set per region inside that region's own (sub)shell on purpose
    local line secs=$(( SECONDS - ${REG_T0:-$SECONDS} ))
    line="$(jqv -r --argjson no "$no" '([.[] | select(.type == "cluster")] | length) as $c | ([.[] | select(.type == "instance")] | length) as $i
        | ([.[].snapshots[]? | select(.kind != "backup")] | length) as $s | ([.[].snapshots[]? | select(.kind == "backup")] | length) as $b
        | if $c + $i == 0 and $no == 0 then "(empty)"
          else "\($c) cluster\(if $c == 1 then "" else "s" end), \($i) instance\(if $i == 1 then "" else "s" end), \($s) snapshot\(if $s == 1 then "" else "s" end), \($b) recovery point\(if $b == 1 then "" else "s" end)"
               + (if $no > 0 then ", \($no) without source" else "" end) end' "$res")"
    [[ -n "$line" ]] || line="failed: unreadable AWS output"
    [[ "$line" == "(empty)" && $# -eq 0 && "$VERBOSE" != 1 ]] && return 0   # empty regions: listed in the summary line
    [[ "$line" == "(empty)" ]] || line+=" (${secs}s)"
    if (( $# )); then line+=" - ERROR: $(IFS='; '; echo "$*")"; [[ "$line" == *"(empty)"* ]] && line="${line/(empty)/(no data)}"; fi
    log_info "[$REG_I/$REG_N] $reg: $line"
}

# region_summary ACCOUNT: one log line with regions scanned, the empty ones and the failed ones.
region_summary() {   # one line per account: "8 regions scanned, 5 empty: a, b, c" (+ failed regions)
    log_info "$1: $(jqv -rs '(map(select(.status == "empty") | .region)) as $e | (map(select(.status == "error") | .region)) as $f
        | "\(length) region\(if length == 1 then "" else "s" end) scanned, \($e | length) empty\(if ($e | length) > 0 then ": " + ($e | join(", ")) else "" end)"
          + (if ($f | length) > 0 then "; \($f | length) failed: \($f | join(", "))" else "" end)' "$WORK/$1"/*/region.json)"
}

# ---------------------------------------------------------------------------- collection (one account: its regions, serial or parallel)
# scan_profile PROFILE: account id (sts), display name (config or IAM alias), region list (-r, -A or default),
# then every region. Writes $WORK/data_<account>.json and adds it to DATA_FILES; returns 1 if the account cannot be read.
scan_profile() {   # scan_profile <profile>  -> $WORK/data_<account>.json
    local prof="$1" acct reg idf="$WORK/id_${1:-default}.json" aname=""; local -a regs=()
    if (( DRY_RUN )); then acct="ACCOUNT"; awsc "$idf" "$prof" "" sts get-caller-identity
    else
        awsc "$idf" "$prof" "" sts get-caller-identity || { log_error "profile '${prof:-default}': no valid credentials ($(err_of "$idf"))"; return 1; }
        acct="$(jqv -r '.Account // empty' "$idf")"; [[ -n "$acct" ]] || { log_error "profile '${prof:-default}': no account id"; return 1; }
    fi
    aname="${ACCOUNT_NAMES[$acct]:-}"
    local alias_reg="${REGIONS[0]:-${AWS_REGION:-${AWS_DEFAULT_REGION:-$GLOBAL_API_REGION}}}"
    if [[ -z "$aname" ]]; then   # IAM account alias: optional, read-only; denied / none = number only
        local fails0=$AWS_FAILS
        if awsc "$WORK/$acct.alias.json" "$prof" "$alias_reg" iam list-account-aliases; then
            aname="$(jqv -r '(.AccountAliases // [])[0] // "" | explode | map(select(. >= 32)) | implode | .[0:$max]' --argjson max "$MAX_NAME_CHARS" "$WORK/$acct.alias.json")"
        else
            AWS_FAILS=$fails0
            log_debug "Account alias for $acct not available (iam:ListAccountAliases)"
        fi
    fi
    # describe-global-clusters is account-wide: serial scans read it once (first region with a cluster)
    GLOBAL_OK=true; GLOBAL_DONE=0; rm -f "$WORK/$acct.globals.json"
    if (( ALL_REGIONS )); then
        if (( DRY_RUN )); then awsc "$WORK/regs.json" "$prof" "${REGIONS[0]:-$GLOBAL_API_REGION}" ec2 describe-regions; regs=("<each-enabled-region>")
        else
            awsc "$WORK/regs.json" "$prof" "${REGIONS[0]:-${AWS_REGION:-${AWS_DEFAULT_REGION:-$GLOBAL_API_REGION}}}" ec2 describe-regions --filters Name=opt-in-status,Values=opt-in-not-required,opted-in \
                || { log_error "$acct: ec2 describe-regions failed ($(err_of "$WORK/regs.json"))"; return 1; }
            mapfile -t regs < <(jqv -r '.Regions[].RegionName' "$WORK/regs.json" | sort)
        fi
    elif (( ${#REGIONS[@]} )); then regs=("${REGIONS[@]}")
    else
        reg="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
        [[ -n "$reg" ]] || reg="$(aws configure get region ${prof:+--profile "$prof"} 2>/dev/null | tr -d '\r' || true)"
        [[ -n "$reg" ]] || { log_error "$acct: no region (use -r REGION or -A)"; return 1; }
        regs=("$reg")
    fi
    log_info "account $acct (profile ${prof:-default}): ${#regs[@]} region(s)"
    # parallel region jobs: at most $par at a time. With wait -n a new job starts as soon as one ends;
    # without it (bash < 4.3 or RDS_BCR_NO_WAIT_N) each batch must finish first. Each job writes only its own dir.
    local i=0 d n=${#regs[@]} par=$PARALLEL running=0 st
    (( DRY_RUN || n < 2 )) && par=1
    SCAN_PAR=$(( par > 1 ))
    (( SCAN_PAR )) && log_info "$acct: scanning $n regions, up to $par at a time"
    for reg in "${regs[@]}"; do   # dirs are zero-padded so the glob below keeps region order (10+ regions)
        i=$((i + 1)); printf -v d '%s/%s/%04d' "$WORK" "$acct" "$i"; mkdir -p "$d"; REG_I=$i; REG_N=$n; REG_T0=$SECONDS
        if (( ! SCAN_PAR )); then scan_region "$prof" "$acct" "$reg" "$d"; continue; fi
        if (( running >= par )); then
            if (( HAVE_WAIT_N )); then wait -n || true; running=$((running - 1))
            else wait || true; running=0; fi   # no wait -n: finish the batch first
        fi
        (( VERBOSE )) && log_info "[$i/$n] $reg: started"
        region_job "$prof" "$acct" "$reg" "$d" & BG_PIDS+=("$!"); running=$((running + 1))
    done
    # after all jobs: check each rc / result in region order, replace failures with placeholders, add the call counters
    if (( SCAN_PAR )); then
        wait || true; BG_PIDS=()
        i=0; local fails=0 summ=()
        for reg in "${regs[@]}"; do   # combine in region order: per-region files only, no shared writes
            i=$((i + 1)); printf -v d '%s/%s/%04d' "$WORK" "$acct" "$i"
            st="$(cat "$d/rc" 2>/dev/null || echo killed)"
            if [[ "$st" != 0 || ! -s "$d/region.json" || ! -s "$d/resources.json" ]]; then
                [[ "$st" == 0 ]] && st="0, incomplete result"
                fails=$((fails + 1)); log_error "[$i/$n] $reg: failed (exit $st)"; region_failed "$acct" "$reg" "$d" "exit $st"
            fi
            if [[ -s "$d/stats" ]]; then local c f; read -r c f <"$d/stats"; AWS_CALLS=$((AWS_CALLS + c)); AWS_FAILS=$((AWS_FAILS + f)); fi
            summ+=("$(jqv -r '"\(.region): \(if .status == "error" then "failed" else "done" end) (\(.resources) resource\(if .resources == 1 then "" else "s" end))"' "$d/region.json")")
        done
        if (( VERBOSE )); then local joined; printf -v joined '%s; ' "${summ[@]}"; log_info "$acct regions in order: ${joined%; }"; fi
        (( fails )) && log_warn "$acct: $fails of $n region(s) failed; see Region errors in the report"
    fi
    (( DRY_RUN )) && return 0
    region_summary "$acct"
    # account data document: header + regions, then resources (ARNs removed) and orphan snapshots in region order
    jqv -n --arg s "$DATA_SCHEMA" --argjson v "$DATA_SCHEMA_VERSION" --arg tool "$SCRIPT_VERSION" --arg a "$acct" --arg p "${prof:-default}" --arg n "$aname" --argjson now "$NOW" \
        '{schema: $s, schema_version: $v, tool_version: $tool, collected_epoch: $now, collected_at: ($now | todate),
          accounts: [{account: $a, profile: $p, name: $n, collected_epoch: $now}],
          regions: [ inputs | select(type == "object") ], resources: [], orphans: []}' "$WORK/$acct"/*/region.json >"$WORK/hdr_$acct.json"
    jqv -s '.[0] + {resources: [ .[1:][][] | del(.arn) ]}' "$WORK/hdr_$acct.json" "$WORK/$acct"/*/resources.json >"$WORK/res_$acct.json"
    jqv -s '.[0] + {orphans: [ .[1:][][] ]}' "$WORK/res_$acct.json" "$WORK/$acct"/*/orphans.json >"$WORK/data_$acct.json"
    DATA_FILES+=("$WORK/data_$acct.json")
}

# ---------------------------------------------------------------------------- merge input
# winpath PATH: PATH as given if it exists, else converted with cygpath (Git Bash C:\ paths).
winpath() { local p="$1"; [[ -e "$p" ]] && { printf '%s' "$p"; return; }
            command -v cygpath >/dev/null 2>&1 && { cygpath -u -- "$p" 2>/dev/null | tr -d '\r'; return; }; printf '%s' "$p"; }
# is_data_file FILE: true when FILE is JSON with the --save-data schema name.
is_data_file() { [[ "$(jq -r --arg s "$DATA_SCHEMA" 'if type == "object" and .schema == $s then "y" else "n" end' -- "$1" 2>/dev/null | tr -d '\r')" == y ]]; }
# collect_merge_inputs: expand the --merge FILE / DIR arguments into --save-data files, merge them with
# lib/merge.jq into $WORK/data.json (newest collection per account wins) and log ignored older collections.
collect_merge_inputs() {
    local a p f; local -a files=()
    for a in "${MERGE_ARGS[@]}"; do
        p="$(winpath "$a")"
        if [[ -d "$p" ]]; then
            local found=0
            for f in "$p"/*.json; do [[ -e "$f" ]] || continue; if is_data_file "$f"; then files+=("$f"); found=1; else log_warn "skipping $f (not a --save-data file)"; fi; done
            (( found )) || die 3 "No --save-data files in directory: $a"
        elif [[ -f "$p" ]]; then is_data_file "$p" || die 3 "Not a $SCRIPT_NAME --save-data file (or unreadable JSON): $a"; files+=("$p")
        else die 3 "Merge input not found: $a"; fi
    done
    local i=0 parts=()
    # number each file in argument order: merge.jq uses it to break ties between equal collection times
    for f in "${files[@]}"; do i=$((i + 1)); jqv -c --argjson i "$i" '{i: $i, d: .}' -- "$f" >"$WORK/m$i.json"; parts+=("$WORK/m$i.json"); done
    jqv -s -f "$LIBDIR/merge.jq" "${parts[@]}" >"$WORK/data.json"
    local r; while IFS= read -r r; do [[ -n "$r" ]] && log_warn "account $r: an older collection was ignored (newer file wins)"; done < <(jqv -r '.replaced[] | .account' "$WORK/data.json")
    log_info "merged ${#files[@]} file(s): $(jqv -r '[.accounts[].account] | join(", ")' "$WORK/data.json")"
}

# ---------------------------------------------------------------------------- output
# abs_dir DIR: absolute path with ~, ., .. and // resolved, without touching the disk.
abs_dir() {   # absolute, normalised directory (no //, ./, ..; ~ expanded) - CloudShell and Git Bash
    local p="$1" out="" part; local -a parts=() keep=()
    [[ "$p" == "~" || "$p" == \~/* ]] && p="$HOME${p#\~}"
    [[ "$p" == /* ]] || p="$PWD/$p"
    IFS='/' read -r -a parts <<<"$p"
    for part in "${parts[@]}"; do
        case "$part" in ''|.) ;; ..) (( ${#keep[@]} )) && unset 'keep[${#keep[@]}-1]' ;; *) keep+=("$part") ;; esac
    done
    for part in "${keep[@]}"; do out+="/$part"; done
    printf '%s' "${out:-/}"
}
# output_block: list every written file with its full path on stderr (and in --log-file).
output_block() {   # Output (N files): then one complete absolute path per line
    (( ${#WRITTEN[@]} )) || return 0
    local f n=${#WRITTEN[@]}
    printf 'Output (%d file%s):\n' "$n" "$( (( n == 1 )) || echo s)" >&2
    for f in "${WRITTEN[@]}"; do printf '  %s/%s\n' "$(abs_dir "$(dirname -- "$f")")" "${f##*/}" >&2; done
    if [[ -n "$LOG_FILE" ]]; then printf 'wrote %s\n' "${WRITTEN[@]}" 2>/dev/null >>"$LOG_FILE" || true; fi
}
# ---------------------------------------------------------------------------- evaluation and render (lib/backup.jq)
# render MODE DATA: evaluate compliance and print one output mode (rows, json, csv, bcsv, mcsv, ocsv, osum, exclog,
# txt, html). Compliance is computed here, at render time, so saved data is evaluated again with today's rules.
render() {   # render <mode> <data> -> stdout
    jqv -r --arg mode "$1" --argjson now "$NOW" --argjson cfg "$CFG" --arg tool "$SCRIPT_VERSION" \
        --argjson acct_names "$(account_names_json)" --rawfile page "$LIBDIR/backup_page.js" "${EXC_ARGS[@]}" -f "$LIBDIR/backup.jq" "$2"
}
# exc_ready: write the validated exceptions to $WORK/exceptions.json and set EXC_ARGS for render (no-op when off).
exc_ready() {   # write the validated entries next to the work files once; jq reads them as $ARGS.named.exc
    [[ "$EXC_JSON" != null && -n "$WORK" ]] || return 0
    printf '%s' "$EXC_JSON" >"$WORK/exceptions.json"; EXC_ARGS=(--slurpfile exc "$WORK/exceptions.json")
    [[ "${RDS_BCR_EXC_NOW:-}" =~ ^[0-9]+$ ]] && EXC_ARGS+=(--argjson exc_now "$RDS_BCR_EXC_NOW")   # tests: fixed "today" for expiry dates only
    return 0
}

# ---------------------------------------------------------------------------- outputs
# write_out FILE CMD...: run CMD into FILE (exit 4 if it cannot be written) and remember FILE for output_block.
write_out() { local f="$1"; shift; "$@" >"$f" || die 4 "Cannot write $f"; WRITTEN+=("$f"); }

# ---------------------------------------------------------------------------- main
# main "$@": pre-checks, exceptions, scan or merge, optional --save-data, render every format, summary log, exit code.
# E-mail (alert-email) is sent after the reports are written; --fail-on-noncompliant (exit 5) is the hook for schedulers / CI.
main() {
    parse_args "$@"
    if [[ -n "$LOG_FILE" ]] && (( ! DRY_RUN && ! CHECK_CONFIG )); then mkdir -p -- "$(dirname -- "$LOG_FILE")" 2>/dev/null || true; fi
    # pre-checks: jq, the lib/ files and the aws CLI (not needed for --merge / --dry-run / --check-config)
    command -v jq >/dev/null 2>&1 || die 2 "jq not found"
    for f in backup.jq backup_page.js collect.jq merge.jq alert_email.jq; do [[ -r "$LIBDIR/$f" ]] || die 2 "Missing $LIBDIR/$f - keep the lib/ folder next to the script"; done
    (( MERGE )) || (( DRY_RUN )) || (( CHECK_CONFIG )) || (( ALERT_TEST )) || command -v aws >/dev/null 2>&1 || die 2 "aws CLI not found"
    load_exceptions   # before any AWS call: a bad line stops the run now, not after the scan
    if (( CHECK_CONFIG )); then check_config; exit 0; fi   # --check-config: files validated above, nothing else runs
    if (( ALERT_TEST )); then   # --alert-test: one test e-mail, no AWS calls
        (( ${#ALERT_EMAILS[@]} )) || die 1 "--alert-test needs alert-email (in $CONFIG_NAME or --alert-email ADDR)"
        WORK="$(mktemp -d "${TMPDIR:-/tmp}/rds_bcr.XXXXXX")"; trap 'rm -rf -- "$WORK"' EXIT
        send_alerts test; exit 0
    fi
    [[ "$EXC_JSON" != null ]] && log_info "Exceptions file $EXC_PATH: $(jqv -r 'length' <<<"$EXC_JSON") entries"
    # one clock for the whole run: every evaluation and file name uses NOW / STAMP
    NOW="$(date -u +%s)"; STAMP="$(date -u +%Y%m%d_%H%M%S)"; tz_setup; CFG="$(cfg_json)"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/rds_bcr.XXXXXX")"
    exc_ready
    trap '(( KEEP_WORKDIR )) && echo "workdir kept: $WORK" >&2 || rm -rf -- "$WORK"' EXIT
    trap '(( ${#BG_PIDS[@]} )) && kill "${BG_PIDS[@]}" 2>/dev/null; exit 130' INT TERM
    HAVE_WAIT_N=0; [[ -z "${RDS_BCR_NO_WAIT_N:-}" ]] && (( BASH_VERSINFO[0] > 4 || BASH_VERSINFO[1] >= 3 )) && HAVE_WAIT_N=1
    [[ -n "$OUTPUT_DIR" ]] && { mkdir -p -- "$OUTPUT_DIR" 2>/dev/null || die 4 "Cannot create $OUTPUT_DIR"; }

    # data: merge saved files offline, or scan every profile and combine the account documents
    if (( MERGE )); then collect_merge_inputs
    else
        (( ${#PROFILES[@]} )) || PROFILES=("")
        local p ok=0; for p in "${PROFILES[@]}"; do scan_profile "$p" && ok=$((ok + 1)); done
        if (( DRY_RUN )); then prune_reports; exit 0; fi   # preview of keep-reports, then stop
        (( ok )) || die 2 "No profile could be scanned"
        jqv -s --arg s "$DATA_SCHEMA" --argjson v "$DATA_SCHEMA_VERSION" --argjson now "$NOW" \
            '{schema: $s, schema_version: $v, collected_epoch: $now, accounts: [.[].accounts[]], regions: [.[].regions[]], resources: [.[].resources[]], orphans: [.[].orphans[]]}' \
            "${DATA_FILES[@]}" >"$WORK/data.json"
        log_info "AWS calls: $AWS_CALLS ($AWS_FAILS failed)"
        # --save-data: one raw file per account (rds_backup_<account>_<date>.json) for a later --merge
        if (( SAVE_DATA )); then
            local df a
            for df in "${DATA_FILES[@]}"; do
                a="$(jqv -r '.accounts[0].account' "$df")"
                local target; target="${OUTPUT_DIR:-.}/rds_backup_${a}_$(date -u +%Y%m%d).json"
                if [[ -n "$SAVE_DATA_FILE" ]]; then target="$SAVE_DATA_FILE"; (( ${#DATA_FILES[@]} > 1 )) && target="${SAVE_DATA_FILE%.json}_$a.json"; fi
                write_out "$target" jqv . "$df"
            done
        fi
    fi
    local data="$WORK/data.json" accts tag
    # --non-compliant-only: keep only NON-COMPLIANT resources (rows evaluated once to find them)
    if (( NC_ONLY )); then
        render rows "$data" | jqv -c '[.[] | select(.status == "NON-COMPLIANT") | "\(.account_id)|\(.region)|\(.identifier)"]' >"$WORK/nc.json"
        # exc_ids: every scanned server, so an exception is not reported as unmatched only because its server is hidden
        jqv --slurpfile k "$WORK/nc.json" '.exc_ids = [ .resources[] | {account_id, identifier: .id} ]
            | .resources |= [ .[] | select("\(.account_id)|\(.region)|\(.id)" as $x | $k[0] | index([$x])) ]' "$data" >"$WORK/data_nc.json"
        # all_totals: the text summary counts every scanned server, not only the rows listed
        render totals "$WORK/data.json" | jqv -c . >"$WORK/all_totals.json"
        jqv --slurpfile t "$WORK/all_totals.json" '.all_totals = $t[0]' "$WORK/data_nc.json" >"$WORK/data_nc2.json" && mv -- "$WORK/data_nc2.json" "$WORK/data_nc.json"
        data="$WORK/data_nc.json"
    fi
    # file name tag: account numbers, or merged_<N>_accounts for more than 3 accounts
    accts="$(jqv -r '[.accounts[].account] | unique | join("_")' "$WORK/data.json")"
    tag="$accts"; [[ "$(jqv '.accounts | length' "$WORK/data.json")" -gt 3 ]] && tag="merged_$(jqv '.accounts | length' "$WORK/data.json")_accounts"
    local f ext base
    # outputs: one file per format; csv also writes the backups and orphaned snapshot CSVs
    for f in "${FORMATS[@]}"; do
        case "$f" in text|txt) ext=txt; f=txt ;; *) ext="$f" ;; esac
        if [[ -n "$OUTPUT_DIR" ]]; then
            base="$OUTPUT_DIR/${PREFIX}_${tag}_${STAMP}"
            if [[ -n "$OUT_FILE" ]]; then write_out "$OUT_FILE" render html "$data"; continue; fi
            write_out "$base.$ext" render "$f" "$data"
            if [[ "$f" == csv ]]; then write_out "${base}_backups.csv" render bcsv "$data"
                write_out "${base}_orphaned_snapshots.csv" render ocsv "$WORK/data.json"; fi
        else render "$f" "$data" || die 4 "render failed"; fi
    done
    if [[ -n "$MANUAL_OLDER" ]]; then   # manual-snapshot audit (all resources, ignores --non-compliant-only)
        if [[ -n "$OUTPUT_DIR" ]]; then   # file in the output dir; screen-only runs (-o '') write no file
            write_out "$OUTPUT_DIR/${PREFIX}_${tag}_${STAMP}_manual_older_than_${MANUAL_OLDER}d.csv" render mcsv "$WORK/data.json"
            log_info "manual snapshots older than ${MANUAL_OLDER} days: $(render mcsv "$WORK/data.json" | tail -n +2 | grep -c . || true)"
        else
            render mcsv "$WORK/data.json" >"$WORK/manual.csv"
            log_info "manual snapshots older than ${MANUAL_OLDER} days: $(tail -n +2 "$WORK/manual.csv" | grep -c . || true) (screen only, no file written)"
            cat -- "$WORK/manual.csv" >&2
        fi
    fi
    # summary: counts and exception notes in the log, then the exit code (5 only with --fail-on-noncompliant)
    local nc; nc="$(render rows "$WORK/data.json" | jqv '[.[] | select(.status == "NON-COMPLIANT")] | length')"
    log_info "resources: $(jqv '.resources | length' "$WORK/data.json"), non-compliant: $nc"
    if [[ "$EXC_JSON" != null ]]; then
        local l; while IFS=$'\t' read -r f l; do [[ -n "$l" ]] && if [[ "$f" == W ]]; then log_warn "$l"; else log_info "$l"; fi; done < <(render exclog "$WORK/data.json" | sed "s|@FILE@|${EXC_PATH##*/}|")
    fi
    log_info "$(render osum "$WORK/data.json")"
    prune_reports
    send_alerts
    output_block
    if (( FAIL_ON_NC && nc > 0 )); then exit 5; fi
    exit 0
}

main "$@"
