#!/usr/bin/env bash
#
# rds_backup_compliance_report.sh - backup compliance of Aurora clusters and standalone RDS instances, per account
# and region. READ-ONLY: rds describe-*, backup list-*, sts get-caller-identity, ec2 describe-regions.
#
# Rules (defaults, all configurable):
#   daily   RDS automated backups: retention >= 7 days, >= 7 daily automated backups, the latest <= 26 h old
#   weekly  >= 4  AWS Backup recovery points in distinct weeks   (retention 11-60 days)
#   monthly >= 11 AWS Backup recovery points in distinct months  (retention 61-400 days)
#   yearly  >= 1  AWS Backup recovery point                      (retention over 400 days or never expires)
#   Aurora global database secondaries and read replicas: daily only (weekly / monthly / yearly N/A).
# Status: COMPLIANT | NON-COMPLIANT (gaps column) | NOT YET DUE (resource too young) | UNKNOWN (a call failed).
# Output: text | csv | json | html. Exit: 0 ok, 5 NON-COMPLIANT with --fail-on-noncompliant, 1 usage, 2 pre-check,
#         3 bad --merge input, 4 output error, 130 interrupted. Logic and rendering live in lib/*.jq.

# shellcheck disable=SC2016,SC2034  # jq programs are single-quoted on purpose; KEEP_WORKDIR is read in the EXIT trap
set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
LIBDIR="${RDS_BCR_LIB:-$SCRIPT_DIR/lib}"
readonly DATA_SCHEMA="rds_backup_compliance_data" DATA_SCHEMA_VERSION=1

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "$SCRIPT_NAME: bash 4.4+ required (found $BASH_VERSION)" >&2; exit 2
fi

PROFILES=(); REGIONS=(); ALL_REGIONS=0; ENGINES=(); IDENTIFIERS=(); FORMATS=(); MERGE_ARGS=()
OUTPUT_DIR=""; OUT_FILE=""; MANUAL_OLDER=""; PREFIX="rds_backup_compliance"; DISPLAY_TZ="Asia/Kolkata"
DAILY=7; DAILY_MAX_AGE_H=26; WEEKLY=4; MONTHLY=11; YEARLY=1
WEEKLY_MIN_DAYS=11; WEEKLY_MAX_DAYS=60; MONTHLY_MAX_DAYS=400
NC_ONLY=0; FAIL_ON_NC=0; LOG_FILE=""; CONFIG_FILE=""; AWS_TIMEOUT=30; MAX_ATTEMPTS=5
KEEP_WORKDIR=0; DRY_RUN=0; VERBOSE=0; SAVE_DATA=0; SAVE_DATA_FILE=""; MERGE=0
WORK=""; NOW=0; STAMP=""; AWS_CALLS=0; AWS_FAILS=0
declare -a WRITTEN=() DATA_FILES=()

_log() { local l; l="$(date '+%Y-%m-%d %H:%M:%S') [$1] ${*:2}"; printf '%s\n' "$l" >&2
         if [[ -n "$LOG_FILE" && "$DRY_RUN" -eq 0 ]]; then printf '%s\n' "$l" >>"$LOG_FILE" 2>/dev/null || true; fi; }
log_info() { _log INFO "$@"; }; log_warn() { _log WARN "$@"; }; log_error() { _log ERROR "$@"; }
log_debug() { [[ "$VERBOSE" -eq 1 ]] && _log DEBUG "$@"; return 0; }
die() { local c="$1"; shift; log_error "$@"; exit "$c"; }

usage() {
    cat <<USAGE
$SCRIPT_NAME v$SCRIPT_VERSION - backup compliance report for Aurora clusters and RDS instances (read-only)

Usage: $SCRIPT_NAME [options]

Scope:
  -P, --profile NAME        AWS CLI profile / account; repeatable or comma-separated (default: current login)
  -r, --region REGION       Region(s); repeatable or comma-separated (default: env / profile region)
  -A, --all-regions         Every enabled region (ec2 describe-regions); regions without databases are left out
  -e, --engine GLOB         aurora-postgresql, aurora-mysql, postgres, mysql, mariadb, 'sqlserver-*', 'oracle-*' [repeatable]
  -i, --identifier GLOB     Cluster / instance identifier                                               [repeatable]

Compliance (defaults in brackets):
      --daily N             RDS automated: retention >= N days and N daily backups               [7]
      --daily-max-age H     Latest automated backup at most H hours old                         [26]
      --weekly N            AWS Backup recovery points in N distinct weeks                       [4]
      --monthly N           ... in N distinct months                                             [11]
      --yearly N            ... in N distinct years                                              [1]
      --weekly-days MIN-MAX Retention (days) that classifies a recovery point as weekly         [11-60]
      --monthly-max-days N  Retention up to N days = monthly; above N or never expires = yearly [400]
      --non-compliant-only  Show only NON-COMPLIANT rows (totals still count everything)
      --fail-on-noncompliant  Exit 5 when a NON-COMPLIANT resource is found

Report:
  -F, --format LIST         text,csv,json,html (default: text; html with --merge). Several formats need -o.
                            csv writes the compliance CSV and, with -o, also <name>_backups.csv
  -o, --output-dir DIR      Write <prefix>_<account>_YYYYmmdd_HHMMSS.<ext> into DIR. With --merge, -o FILE.html names the file
      --manual-older-than N Also write <name>_manual_older_than_<N>d.csv: manual snapshots older than N days, oldest first
      --save-data [FILE]    Also write the raw data for --merge: rds_backup_<ACCOUNT>_<YYYYMMDD>.json per account
      --prefix NAME         File name prefix (default: rds_backup_compliance)
      --tz ZONE             Second time zone shown next to UTC (default: Asia/Kolkata = IST)
  -l, --log-file FILE       Append log lines to FILE

Merge (offline, no AWS calls, jq only - works in Git Bash on Windows):
      --merge FILE|DIR...   Combine --save-data files of several accounts. Same account twice: the newer collection
                            wins. Compliance is re-evaluated at merge time. e.g. --merge a.json b.json -o all.html

Behaviour:
      --config FILE         key=value settings (long option names, e.g. weekly=4; never sourced; CLI overrides)
      --aws-timeout SEC     AWS CLI connect/read timeout (default: 30)
      --max-attempts N      AWS CLI retry attempts (default: 5)
      --keep-workdir        Keep raw AWS responses for debugging
      --dry-run             Print the AWS calls that would run; call nothing
  -v, --verbose / -h, --help / -V, --version

AWS calls (all read-only): sts get-caller-identity; ec2 describe-regions (-A); rds describe-db-clusters,
describe-db-instances, describe-global-clusters (once per account), describe-db-cluster-snapshots,
describe-db-snapshots; backup list-backup-vaults, list-recovery-points-by-backup-vault (gives the retention
used to classify weekly / monthly / yearly; list-recovery-points-by-resource does not return it).
USAGE
}

add_list() { local -n _a="$1"; local _i; local -a _p; IFS=',' read -r -a _p <<<"$2"
             for _i in "${_p[@]}"; do _i="${_i//[[:space:]]/}"; [[ -n "$_i" ]] && _a+=("$_i"); done; return 0; }
is_true() { case "${1,,}" in 1|y|yes|true|on) return 0 ;; *) return 1 ;; esac; }
need_arg() { [[ "$2" -ge 2 ]] || die 1 "Option $1 requires a value (see --help)"; }
int_ok() { [[ "$2" =~ ^[0-9]+$ ]] || die 1 "$1 must be a whole number (got '$2')"; }
json_array() { if (( $# )); then printf '%s\n' "$@" | jq -R . | jq -cs . | tr -d '\r'; else printf '[]'; fi; }
jqv() { jq "$@" | tr -d '\r'; }       # jq.exe on Windows writes CRLF: strip for values and files

set_opt() {   # set_opt key value  (shared by CLI and --config)
    local k="$1" v="$2"
    case "$k" in
        profile) add_list PROFILES "$v" ;; region) add_list REGIONS "$v" ;; all-regions|all_regions) is_true "$v" && ALL_REGIONS=1 ;;
        engine) add_list ENGINES "$v" ;; identifier) add_list IDENTIFIERS "$v" ;;
        daily) int_ok --daily "$v"; DAILY="$v" ;; daily-max-age|daily_max_age) int_ok --daily-max-age "$v"; DAILY_MAX_AGE_H="$v" ;;
        weekly) int_ok --weekly "$v"; WEEKLY="$v" ;; monthly) int_ok --monthly "$v"; MONTHLY="$v" ;; yearly) int_ok --yearly "$v"; YEARLY="$v" ;;
        weekly-days|weekly_days) [[ "$v" =~ ^([0-9]+)-([0-9]+)$ ]] || die 1 "--weekly-days must be MIN-MAX (got '$v')"
            WEEKLY_MIN_DAYS="${BASH_REMATCH[1]}"; WEEKLY_MAX_DAYS="${BASH_REMATCH[2]}" ;;
        monthly-max-days|monthly_max_days) int_ok --monthly-max-days "$v"; MONTHLY_MAX_DAYS="$v" ;;
        format) add_list FORMATS "$v" ;; output-dir|output_dir) OUTPUT_DIR="$v" ;; prefix) PREFIX="$v" ;; tz) DISPLAY_TZ="$v" ;;
        log-file|log_file) LOG_FILE="$v" ;; aws-timeout|aws_timeout) int_ok --aws-timeout "$v"; AWS_TIMEOUT="$v" ;;
        max-attempts|max_attempts) int_ok --max-attempts "$v"; MAX_ATTEMPTS="$v" ;;
        non-compliant-only|non_compliant_only) is_true "$v" && NC_ONLY=1 ;; fail-on-noncompliant|fail_on_noncompliant) is_true "$v" && FAIL_ON_NC=1 ;;
        save-data|save_data) is_true "$v" && SAVE_DATA=1 ;;
        manual-older-than|manual_older_than) int_ok --manual-older-than "$v"; MANUAL_OLDER="$v" ;;
        *) return 1 ;;
    esac
    return 0
}

load_config() {
    local f="$1" line n=0
    [[ -r "$f" ]] || die 1 "Config file not readable: $f"
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1)); line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_-]+)[[:space:]]*=[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]] || die 1 "Config $f:$n: expected key=value"
        set_opt "${BASH_REMATCH[1],,}" "${BASH_REMATCH[2]:-}" || die 1 "Config $f:$n: unknown key '${BASH_REMATCH[1]}'"
    done <"$f"
}

parse_args() {
    local a; for ((a = 1; a <= $#; a++)); do if [[ "${!a}" == --config ]]; then local b=$((a + 1)); [[ $b -le $# ]] || die 1 "--config needs a file"; CONFIG_FILE="${!b}"; fi; done
    [[ -n "$CONFIG_FILE" ]] && load_config "$CONFIG_FILE"
    local cli_formats=()
    while (( $# )); do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -V|--version) echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            -P|--profile) need_arg "$1" $#; add_list PROFILES "$2"; shift ;;
            -r|--region) need_arg "$1" $#; add_list REGIONS "$2"; shift ;;
            -A|--all-regions) ALL_REGIONS=1 ;;
            -e|--engine) need_arg "$1" $#; add_list ENGINES "$2"; shift ;;
            -i|--identifier) need_arg "$1" $#; add_list IDENTIFIERS "$2"; shift ;;
            -F|--format) need_arg "$1" $#; add_list cli_formats "$2"; shift ;;
            -o|--output-dir) need_arg "$1" $#; OUTPUT_DIR="$2"; shift ;;
            -l|--log-file) need_arg "$1" $#; LOG_FILE="$2"; shift ;;
            --config) shift ;;
            --non-compliant-only) NC_ONLY=1 ;; --fail-on-noncompliant) FAIL_ON_NC=1 ;;
            --keep-workdir) KEEP_WORKDIR=1 ;; --dry-run) DRY_RUN=1 ;; -v|--verbose) VERBOSE=1 ;;
            --save-data) SAVE_DATA=1; if [[ $# -ge 2 && "$2" != -* ]]; then SAVE_DATA_FILE="$2"; shift; fi ;;
            --merge) MERGE=1; while [[ $# -ge 2 && "$2" != -* ]]; do MERGE_ARGS+=("$2"); shift; done ;;
            --daily|--daily-max-age|--weekly|--monthly|--yearly|--weekly-days|--monthly-max-days|--prefix|--tz|--aws-timeout|--max-attempts|--manual-older-than)
                need_arg "$1" $#; set_opt "${1#--}" "$2"; shift ;;
            --*=*) set_opt "${1%%=*}" "${1#*=}" 2>/dev/null || die 1 "Unknown option: $1"; ;;
            *) die 1 "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done
    (( ${#cli_formats[@]} )) && FORMATS=("${cli_formats[@]}")
    local f; for f in "${FORMATS[@]}"; do case "$f" in text|txt|csv|json|html) ;; *) die 1 "Unknown format '$f' (text,csv,json,html)" ;; esac; done
    (( ${#FORMATS[@]} )) || { if (( MERGE )); then FORMATS=(html); else FORMATS=(text); fi; }
    (( WEEKLY_MIN_DAYS <= WEEKLY_MAX_DAYS && WEEKLY_MAX_DAYS < MONTHLY_MAX_DAYS )) || die 1 "Need weekly-days MIN <= MAX < monthly-max-days"
    if (( MERGE )); then
        (( ${#MERGE_ARGS[@]} )) || die 1 "--merge needs at least one FILE or DIR"
        (( ${#PROFILES[@]} || ${#REGIONS[@]} || ALL_REGIONS )) && die 1 "--merge works offline: do not combine it with -P / -r / -A"
        (( SAVE_DATA )) && die 1 "--save-data cannot be combined with --merge"
    fi
    if [[ -n "$OUTPUT_DIR" && "$OUTPUT_DIR" == *.html && MERGE -eq 1 ]]; then OUT_FILE="$OUTPUT_DIR"; OUTPUT_DIR="$(dirname -- "$OUT_FILE")"; FORMATS=(html); fi
    if (( ${#FORMATS[@]} > 1 )) && [[ -z "$OUTPUT_DIR" ]]; then die 1 "Several formats need -o DIR"; fi
    return 0
}

tz_setup() {   # offset seconds + label of the second time zone (Git Bash date may lack zoneinfo: fallback for IST)
    local z; z="$(TZ="$DISPLAY_TZ" date +%z 2>/dev/null || echo +0000)"
    [[ "$z" =~ ^([+-])([0-9]{2})([0-9]{2})$ ]] || z="+0000"
    [[ "$z" =~ ^([+-])([0-9]{2})([0-9]{2})$ ]]
    TZ_OFFSET=$(( 10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60 )); [[ "${BASH_REMATCH[1]}" == - ]] && TZ_OFFSET=$(( -TZ_OFFSET ))
    case "$DISPLAY_TZ" in Asia/Kolkata|Asia/Calcutta|IST) TZ_LABEL=IST; TZ_OFFSET=19800 ;;
        *) TZ_LABEL="$(TZ="$DISPLAY_TZ" date +%Z 2>/dev/null || echo "$DISPLAY_TZ")"; [[ "$TZ_LABEL" =~ ^[+-] ]] && TZ_LABEL="UTC$TZ_LABEL" ;; esac
    return 0
}

cfg_json() {
    jq -cn --argjson d "$DAILY" --argjson h "$DAILY_MAX_AGE_H" --argjson w "$WEEKLY" --argjson m "$MONTHLY" --argjson y "$YEARLY" \
        --argjson wmin "$WEEKLY_MIN_DAYS" --argjson wmax "$WEEKLY_MAX_DAYS" --argjson mmax "$MONTHLY_MAX_DAYS" \
        --argjson off "$TZ_OFFSET" --arg lab "$TZ_LABEL" --argjson mo "${MANUAL_OLDER:-null}" \
        '{manual_older_than: $mo, daily: $d, daily_max_age_h: $h, weekly: $w, monthly: $m, yearly: $y, weekly_min_days: $wmin, weekly_max_days: $wmax,
          monthly_max_days: $mmax, tz_offset: $off, tz_label: $lab}' | tr -d '\r'
}

# ---------------------------------------------------------------------------- AWS (read-only)
awsc() {   # awsc <out-file> <profile> <region> <service> <operation> [args...]; stderr -> <out-file>.err
    local out="$1" prof="$2" reg="$3"; shift 3
    local -a cmd=(aws "$@" --output json --cli-connect-timeout "$AWS_TIMEOUT" --cli-read-timeout "$AWS_TIMEOUT")
    [[ -n "$reg" ]] && cmd+=(--region "$reg"); [[ -n "$prof" ]] && cmd+=(--profile "$prof")
    if (( DRY_RUN )); then printf 'DRY-RUN: %s\n' "${cmd[*]}"; echo '{}' >"$out"; return 0; fi
    AWS_CALLS=$((AWS_CALLS + 1)); log_debug "${cmd[*]}"
    if AWS_MAX_ATTEMPTS="$MAX_ATTEMPTS" AWS_RETRY_MODE=standard AWS_PAGER="" "${cmd[@]}" >"$out" 2>"$out.err"; then return 0; fi
    AWS_FAILS=$((AWS_FAILS + 1)); return 1
}
err_of() { tr -d '\r' <"$1.err" | grep -v '^[[:space:]]*$' | sed -E 's/^aws: \[ERROR\]: //; s/An error occurred //' | head -1 | cut -c1-200; }

# shellcheck disable=SC2053  # the right-hand side is a glob on purpose
glob_match() { local v="${1,,}" g; shift; (( $# )) || return 0; for g in "$@"; do [[ "$v" == ${g,,} ]] && return 0; done; return 1; }

scan_region() {   # scan_region <profile> <account> <region> <dir>  -> <dir>/resources.json, <dir>/region.json
    local prof="$1" acct="$2" reg="$3" d="$4" e; local -a errs=()
    local csnap_ok=true isnap_ok=true backup_ok=true
    echo '{}' >"$d/c.json"; echo '{}' >"$d/i.json"; echo '{}' >"$d/cs.json"; echo '{}' >"$d/is.json"; echo '[]' >"$d/rp.json"
    awsc "$d/c.json" "$prof" "$reg" rds describe-db-clusters || { errs+=("describe-db-clusters: $(err_of "$d/c.json")"); echo '{}' >"$d/c.json"; }
    awsc "$d/i.json" "$prof" "$reg" rds describe-db-instances || { errs+=("describe-db-instances: $(err_of "$d/i.json")"); echo '{}' >"$d/i.json"; }
    local nc ni
    nc="$(jqv '[.DBClusters[]? | select(.Engine | test("^(docdb|neptune)") | not)] | length' "$d/c.json")"
    ni="$(jqv '[.DBInstances[]? | select((.DBClusterIdentifier // "") == "" and (.Engine | test("^(docdb|neptune)") | not))] | length' "$d/i.json")"
    if (( DRY_RUN )); then nc=1; ni=1; fi
    if (( nc + ni > 0 )); then
        if (( nc > 0 )); then
            awsc "$d/cs.json" "$prof" "$reg" rds describe-db-cluster-snapshots || { csnap_ok=false; errs+=("describe-db-cluster-snapshots: $(err_of "$d/cs.json")"); echo '{}' >"$d/cs.json"; }
            if (( ! GLOBAL_DONE )); then GLOBAL_DONE=1
                if awsc "$WORK/$acct.globals.json" "$prof" "$reg" rds describe-global-clusters; then GLOBAL_OK=true
                else GLOBAL_OK=false; errs+=("describe-global-clusters: $(err_of "$WORK/$acct.globals.json")"); echo '{}' >"$WORK/$acct.globals.json"; fi
            fi
        fi
        if (( ni > 0 )); then
            awsc "$d/is.json" "$prof" "$reg" rds describe-db-snapshots || { isnap_ok=false; errs+=("describe-db-snapshots: $(err_of "$d/is.json")"); echo '{}' >"$d/is.json"; }
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
    [[ -s "$WORK/$acct.globals.json" ]] || echo '{}' >"$WORK/$acct.globals.json"   # (re)fetched only once: GLOBAL_DONE
    jqv -n --arg acct "$acct" --arg region "$reg" --slurpfile clusters "$d/c.json" --slurpfile instances "$d/i.json" \
        --slurpfile csnaps "$d/cs.json" --slurpfile isnaps "$d/is.json" --slurpfile rps "$d/rp.json" --slurpfile globals "$WORK/$acct.globals.json" \
        --argjson csnap_ok "$csnap_ok" --argjson isnap_ok "$isnap_ok" --argjson backup_ok "$backup_ok" --argjson global_ok "${GLOBAL_OK:-true}" -f "$LIBDIR/collect.jq" >"$d/all.json"
    # engine / identifier filters
    local keep='[]' id en
    local -a ks=()
    while IFS=$'\t' read -r id en; do
        [[ -n "$id" ]] || continue
        glob_match "$id" "${IDENTIFIERS[@]}" && glob_match "$en" "${ENGINES[@]}" && ks+=("$id")
    done < <(jqv -r '.[] | [.id, .engine] | @tsv' "$d/all.json")
    keep="$(json_array "${ks[@]}")"
    jqv --argjson k "$keep" '[ .[] | select(.id as $i | $k | index([$i])) ]' "$d/all.json" >"$d/resources.json"
    local n status; n="$(jqv length "$d/resources.json")"
    if (( ${#errs[@]} )); then status=error; elif (( n > 0 )); then status="with databases"; else status=empty; fi
    for e in "${errs[@]}"; do log_warn "$acct $reg: $e"; done
    jqv -n --arg a "$acct" --arg r "$reg" --arg s "$status" --argjson n "$n" --argjson e "$(json_array "${errs[@]}")" \
        '{account: $a, region: $r, status: $s, resources: $n, errors: $e}' >"$d/region.json"
}

scan_profile() {   # scan_profile <profile>  -> $WORK/data_<account>.json
    local prof="$1" acct reg idf="$WORK/id_${1:-default}.json"; local -a regs=()
    if (( DRY_RUN )); then acct="ACCOUNT"; awsc "$idf" "$prof" "" sts get-caller-identity
    else
        awsc "$idf" "$prof" "" sts get-caller-identity || { log_error "profile '${prof:-default}': no valid credentials ($(err_of "$idf"))"; return 1; }
        acct="$(jqv -r '.Account // empty' "$idf")"; [[ -n "$acct" ]] || { log_error "profile '${prof:-default}': no account id"; return 1; }
    fi
    GLOBAL_OK=true; GLOBAL_DONE=0; rm -f "$WORK/$acct.globals.json"
    if (( ALL_REGIONS )); then
        if (( DRY_RUN )); then awsc "$WORK/regs.json" "$prof" "${REGIONS[0]:-us-east-1}" ec2 describe-regions; regs=("<each-enabled-region>")
        else
            awsc "$WORK/regs.json" "$prof" "${REGIONS[0]:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}" ec2 describe-regions --filters Name=opt-in-status,Values=opt-in-not-required,opted-in \
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
    local i=0
    for reg in "${regs[@]}"; do
        i=$((i + 1)); local d="$WORK/$acct/$i"; mkdir -p "$d"
        scan_region "$prof" "$acct" "$reg" "$d"
    done
    (( DRY_RUN )) && return 0
    jqv -n --arg s "$DATA_SCHEMA" --argjson v "$DATA_SCHEMA_VERSION" --arg tool "$SCRIPT_VERSION" --arg a "$acct" --arg p "${prof:-default}" --argjson now "$NOW" \
        '{schema: $s, schema_version: $v, tool_version: $tool, collected_epoch: $now, collected_at: ($now | todate),
          accounts: [{account: $a, profile: $p, collected_epoch: $now}],
          regions: [ inputs | select(type == "object") ], resources: []}' "$WORK/$acct"/*/region.json >"$WORK/hdr_$acct.json"
    jqv -s '.[0] + {resources: [ .[1:][][] | del(.arn) ]}' "$WORK/hdr_$acct.json" "$WORK/$acct"/*/resources.json >"$WORK/data_$acct.json"
    DATA_FILES+=("$WORK/data_$acct.json")
}

# ---------------------------------------------------------------------------- merge input
winpath() { local p="$1"; [[ -e "$p" ]] && { printf '%s' "$p"; return; }
            command -v cygpath >/dev/null 2>&1 && { cygpath -u -- "$p" 2>/dev/null | tr -d '\r'; return; }; printf '%s' "$p"; }
is_data_file() { [[ "$(jq -r --arg s "$DATA_SCHEMA" 'if type == "object" and .schema == $s then "y" else "n" end' -- "$1" 2>/dev/null | tr -d '\r')" == y ]]; }
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
    for f in "${files[@]}"; do i=$((i + 1)); jqv -c --argjson i "$i" '{i: $i, d: .}' -- "$f" >"$WORK/m$i.json"; parts+=("$WORK/m$i.json"); done
    jqv -s -f "$LIBDIR/merge.jq" "${parts[@]}" >"$WORK/data.json"
    local r; while IFS= read -r r; do [[ -n "$r" ]] && log_warn "account $r: an older collection was ignored (newer file wins)"; done < <(jqv -r '.replaced[] | .account' "$WORK/data.json")
    log_info "merged ${#files[@]} file(s): $(jqv -r '[.accounts[].account] | join(", ")' "$WORK/data.json")"
}

# ---------------------------------------------------------------------------- output
render() {   # render <mode> <data> -> stdout
    jqv -r --arg mode "$1" --argjson now "$NOW" --argjson cfg "$CFG" --arg tool "$SCRIPT_VERSION" --rawfile page "$LIBDIR/backup_page.js" -f "$LIBDIR/backup.jq" "$2"
}
write_out() { local f="$1"; shift; "$@" >"$f" || die 4 "Cannot write $f"; WRITTEN+=("$f"); }

main() {
    parse_args "$@"
    command -v jq >/dev/null 2>&1 || die 2 "jq not found"
    for f in backup.jq backup_page.js collect.jq merge.jq; do [[ -r "$LIBDIR/$f" ]] || die 2 "Missing $LIBDIR/$f - keep the lib/ folder next to the script"; done
    (( MERGE )) || (( DRY_RUN )) || command -v aws >/dev/null 2>&1 || die 2 "aws CLI not found"
    NOW="$(date -u +%s)"; STAMP="$(date -u +%Y%m%d_%H%M%S)"; tz_setup; CFG="$(cfg_json)"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/rds_bcr.XXXXXX")"
    trap '(( KEEP_WORKDIR )) && echo "workdir kept: $WORK" >&2 || rm -rf -- "$WORK"' EXIT
    trap 'exit 130' INT TERM
    [[ -n "$OUTPUT_DIR" ]] && { mkdir -p -- "$OUTPUT_DIR" 2>/dev/null || die 4 "Cannot create $OUTPUT_DIR"; }

    if (( MERGE )); then collect_merge_inputs
    else
        (( ${#PROFILES[@]} )) || PROFILES=("")
        local p ok=0; for p in "${PROFILES[@]}"; do scan_profile "$p" && ok=$((ok + 1)); done
        (( DRY_RUN )) && exit 0
        (( ok )) || die 2 "No profile could be scanned"
        jqv -s --arg s "$DATA_SCHEMA" --argjson v "$DATA_SCHEMA_VERSION" --argjson now "$NOW" \
            '{schema: $s, schema_version: $v, collected_epoch: $now, accounts: [.[].accounts[]], regions: [.[].regions[]], resources: [.[].resources[]]}' \
            "${DATA_FILES[@]}" >"$WORK/data.json"
        log_info "AWS calls: $AWS_CALLS ($AWS_FAILS failed)"
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
    if (( NC_ONLY )); then
        render rows "$data" | jqv -c '[.[] | select(.status == "NON-COMPLIANT") | "\(.account_id)|\(.region)|\(.identifier)"]' >"$WORK/nc.json"
        jqv --slurpfile k "$WORK/nc.json" '.resources |= [ .[] | select("\(.account_id)|\(.region)|\(.id)" as $x | $k[0] | index([$x])) ]' "$data" >"$WORK/data_nc.json"
        data="$WORK/data_nc.json"
    fi
    accts="$(jqv -r '[.accounts[].account] | unique | join("_")' "$WORK/data.json")"
    tag="$accts"; [[ "$(jqv '.accounts | length' "$WORK/data.json")" -gt 3 ]] && tag="merged_$(jqv '.accounts | length' "$WORK/data.json")_accounts"
    local f ext base
    for f in "${FORMATS[@]}"; do
        case "$f" in text|txt) ext=txt; f=txt ;; *) ext="$f" ;; esac
        if [[ -n "$OUTPUT_DIR" ]]; then
            base="$OUTPUT_DIR/${PREFIX}_${tag}_${STAMP}"
            if [[ -n "$OUT_FILE" ]]; then write_out "$OUT_FILE" render html "$data"; continue; fi
            write_out "$base.$ext" render "$f" "$data"
            [[ "$f" == csv ]] && write_out "${base}_backups.csv" render bcsv "$data"
        else render "$f" "$data" || die 4 "render failed"; fi
    done
    if [[ -n "$MANUAL_OLDER" ]]; then   # manual-snapshot audit (all resources, ignores --non-compliant-only)
        write_out "${OUTPUT_DIR:-.}/${PREFIX}_${tag}_${STAMP}_manual_older_than_${MANUAL_OLDER}d.csv" render mcsv "$WORK/data.json"
        log_info "manual snapshots older than ${MANUAL_OLDER} days: $(render mcsv "$WORK/data.json" | tail -n +2 | grep -c . || true)"
    fi
    for f in "${WRITTEN[@]}"; do log_info "wrote $f"; done
    local nc; nc="$(render rows "$WORK/data.json" | jqv '[.[] | select(.status == "NON-COMPLIANT")] | length')"
    log_info "resources: $(jqv '.resources | length' "$WORK/data.json"), non-compliant: $nc"
    if (( FAIL_ON_NC && nc > 0 )); then exit 5; fi
    exit 0
}

main "$@"
