# Build the resources of one account + region from raw describe-* outputs (rds_backup_compliance_report.sh).
# Output: {resources: [...], orphans: [...], existing: {clusters: [ids], instances: [ids]}}.
# orphans = manual / shared snapshots (region-wide) not attached to a current cluster or instance of this account + region:
# deleted source, shared from / copied from another account, or cross-region copies. Classified later (backup.jq osrc).
# Args: $acct, $region, $clusters, $instances, $csnaps, $isnaps, $rps, $globals (slurped files), $csnap_ok, $isnap_ok, $backup_ok, $global_ok.
def ts: if . == null or . == "" then null elif type == "number" then floor
  else capture("^(?<d>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") as $m
    | ($m.d + "Z" | fromdateiso8601) as $e
    | if ($m.z // "Z") == "Z" then $e
      else ($m.z | capture("(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})")) as $o
        | (($o.h | tonumber) * 3600 + ($o.m | tonumber) * 60) as $sec | if $o.s == "+" then $e - $sec else $e + $sec end end end;
def skip_engine: test("^(docdb|neptune)");
def arnp: if type == "string" and startswith("arn:") then split(":") | {region: .[3], account: .[4], name: (.[6:] | join(":"))} else null end;
($globals[0].GlobalClusters // []) as $G
| ([ $G[] | .GlobalClusterIdentifier as $g | .GlobalClusterMembers[]? | {key: .DBClusterArn, value: {g: $g, w: (.IsWriter == true)}} ] | from_entries) as $GM
| ($rps[0] // []) as $RP
| def rps($arn): ($arn | ascii_downcase) as $la | [ $RP[] | select((.ResourceArn // "" | ascii_downcase) == $la)
      | {kind: "backup", id: (.RecoveryPointArn | split(":") | last), created_epoch: (.CreationDate | ts), status: .Status,
         size_gb: (if .BackupSizeInBytes == null then null else ((.BackupSizeInBytes / 1073741824 * 10 | round) / 10) end),
         expires_epoch: (.CalculatedLifecycle.DeleteAt | ts), vault: .BackupVaultName}
      + (if .Lifecycle.DeleteAfterDays != null then {ret_days: .Lifecycle.DeleteAfterDays} else {} end)
      + (if (.RecoveryPointArn // "" | test(":continuous:")) or .BackupType == "CONTINUOUS" then {continuous: true} else {} end)
      + ((.CreatedBy // {}) | {plan: (.BackupPlanName // .BackupPlanId // null), rule: (.BackupRuleName // .BackupRuleId // null),
                               cron: (.BackupRuleCron // null), rtz: (.BackupRuleTimezone // null)} | with_entries(select(.value != null))) ];
  def role($arn; $repl): if $global_ok | not then (if $repl then "replica" else "unknown" end)
      elif $GM[$arn] then (if $GM[$arn].w then "primary" else "secondary" end)
      elif $repl then "replica" else "none" end;
  ([ ($clusters[0].DBClusters // [])[].DBClusterIdentifier ] | unique) as $EC
| ([ ($instances[0].DBInstances // [])[].DBInstanceIdentifier ] | unique) as $EI
| def orphan($type; $sid; $src; $srcarn; $snaparn):
    ($srcarn | arnp) as $sa | ($snaparn | arnp) as $na
    | {account_id: $acct, region: $region, type: $type, id: (($sid | arnp).name // $sid), kind: (if .SnapshotType == "shared" then "shared" else "manual" end),
       source_id: $src, source_account: (if .SnapshotType == "shared" then ($na.account // null) else ($sa.account // null) end),
       source_region: (.SourceRegion // $sa.region // null), engine: .Engine, engine_version: .EngineVersion,
       created_epoch: (.SnapshotCreateTime | ts), status: .Status, size_gb: .AllocatedStorage,
       encrypted: (.StorageEncrypted // .Encrypted // false), kms_key: (.KmsKeyId // null)};
  { existing: {clusters: $EC, instances: $EI},
    orphans: ([ ($csnaps[0].DBClusterSnapshots // [])[] | select((.SnapshotType == "manual" or .SnapshotType == "shared") and ((.Engine // "") | skip_engine | not)
                  and (.SnapshotType == "shared" or ((.DBClusterIdentifier // "") as $s | $EC | index([$s]) | not)))
                | orphan("cluster"; .DBClusterSnapshotIdentifier; .DBClusterIdentifier; .SourceDBClusterSnapshotArn; .DBClusterSnapshotArn) ]
            + [ ($isnaps[0].DBSnapshots // [])[] | select((.SnapshotType == "manual" or .SnapshotType == "shared") and ((.Engine // "") | skip_engine | not)
                  and (.SnapshotType == "shared" or ((.DBInstanceIdentifier // "") as $s | $EI | index([$s]) | not)))
                | orphan("instance"; .DBSnapshotIdentifier; .DBInstanceIdentifier; .SourceDBSnapshotIdentifier; .DBSnapshotArn) ]),
    resources: (
  [ ($clusters[0].DBClusters // [])[] | select(.Engine | skip_engine | not) | . as $c
    | {account_id: $acct, region: $region, id: .DBClusterIdentifier, type: "cluster", engine: .Engine, engine_version: .EngineVersion,
       created_epoch: (.ClusterCreateTime | ts), retention: (.BackupRetentionPeriod // 0),
       backup_window: (.PreferredBackupWindow // null), copy_tags: (if .CopyTagsToSnapshot == null then null else .CopyTagsToSnapshot end),
       global_cluster: ($GM[.DBClusterArn].g // (if $global_ok then null else "unknown" end)),
       global_role: role(.DBClusterArn; ((.ReplicationSourceIdentifier // "") != "")),
       snap_ok: $csnap_ok, backup_ok: $backup_ok, arn: .DBClusterArn,
       snapshots: ([ ($csnaps[0].DBClusterSnapshots // [])[] | select(.DBClusterIdentifier == $c.DBClusterIdentifier and (.SnapshotType == "manual" or .SnapshotType == "automated"))
                     | {kind: .SnapshotType, id: .DBClusterSnapshotIdentifier, created_epoch: (.SnapshotCreateTime | ts), status: .Status,
                        size_gb: .AllocatedStorage, expires_epoch: null} ] + rps($c.DBClusterArn))} ]
  + [ ($instances[0].DBInstances // [])[] | select((.DBClusterIdentifier // "") == "" and (.Engine | skip_engine | not)) | . as $i
    | {account_id: $acct, region: $region, id: .DBInstanceIdentifier, type: "instance", engine: .Engine, engine_version: .EngineVersion,
       created_epoch: (.InstanceCreateTime | ts), retention: (.BackupRetentionPeriod // 0), global_cluster: null,
       backup_window: (.PreferredBackupWindow // null), copy_tags: (if .CopyTagsToSnapshot == null then null else .CopyTagsToSnapshot end),
       global_role: (if (.ReadReplicaSourceDBInstanceIdentifier // "") != "" then "replica" else "none" end),
       snap_ok: $isnap_ok, backup_ok: $backup_ok, arn: .DBInstanceArn,
       snapshots: ([ ($isnaps[0].DBSnapshots // [])[] | select(.DBInstanceIdentifier == $i.DBInstanceIdentifier and (.SnapshotType == "manual" or .SnapshotType == "automated"))
                     | {kind: .SnapshotType, id: .DBSnapshotIdentifier, created_epoch: (.SnapshotCreateTime | ts), status: .Status,
                        size_gb: .AllocatedStorage, expires_epoch: null} ] + rps($i.DBInstanceArn))} ])}
