# Build the resources of one account + region from raw describe-* outputs (rds_backup_compliance_report.sh).
# Args: $acct, $region, $clusters, $instances, $csnaps, $isnaps, $rps, $globals (slurped files), $csnap_ok, $isnap_ok, $backup_ok, $global_ok.
def ts: if . == null or . == "" then null elif type == "number" then floor
  else capture("^(?<d>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") as $m
    | ($m.d + "Z" | fromdateiso8601) as $e
    | if ($m.z // "Z") == "Z" then $e
      else ($m.z | capture("(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})")) as $o
        | (($o.h | tonumber) * 3600 + ($o.m | tonumber) * 60) as $sec | if $o.s == "+" then $e - $sec else $e + $sec end end end;
def skip_engine: test("^(docdb|neptune)");
($globals[0].GlobalClusters // []) as $G
| ([ $G[] | .GlobalClusterIdentifier as $g | .GlobalClusterMembers[]? | {key: .DBClusterArn, value: {g: $g, w: (.IsWriter == true)}} ] | from_entries) as $GM
| ($rps[0] // []) as $RP
| def rps($arn): [ $RP[] | select(.ResourceArn == $arn)
      | {kind: "backup", id: (.RecoveryPointArn | split(":") | last), created_epoch: (.CreationDate | ts), status: .Status,
         size_gb: (if .BackupSizeInBytes == null then null else ((.BackupSizeInBytes / 1073741824 * 10 | round) / 10) end),
         expires_epoch: (.CalculatedLifecycle.DeleteAt | ts), vault: .BackupVaultName} ];
  def role($arn; $repl): if $global_ok | not then (if $repl then "replica" else "unknown" end)
      elif $GM[$arn] then (if $GM[$arn].w then "primary" else "secondary" end)
      elif $repl then "replica" else "none" end;
  [ ($clusters[0].DBClusters // [])[] | select(.Engine | skip_engine | not) | . as $c
    | {account_id: $acct, region: $region, id: .DBClusterIdentifier, type: "cluster", engine: .Engine, engine_version: .EngineVersion,
       created_epoch: (.ClusterCreateTime | ts), retention: (.BackupRetentionPeriod // 0),
       global_cluster: ($GM[.DBClusterArn].g // (if $global_ok then null else "unknown" end)),
       global_role: role(.DBClusterArn; ((.ReplicationSourceIdentifier // "") != "")),
       snap_ok: $csnap_ok, backup_ok: $backup_ok, arn: .DBClusterArn,
       snapshots: ([ ($csnaps[0].DBClusterSnapshots // [])[] | select(.DBClusterIdentifier == $c.DBClusterIdentifier and (.SnapshotType == "manual" or .SnapshotType == "automated"))
                     | {kind: .SnapshotType, id: .DBClusterSnapshotIdentifier, created_epoch: (.SnapshotCreateTime | ts), status: .Status,
                        size_gb: .AllocatedStorage, expires_epoch: null} ] + rps($c.DBClusterArn))} ]
  + [ ($instances[0].DBInstances // [])[] | select((.DBClusterIdentifier // "") == "" and (.Engine | skip_engine | not)) | . as $i
    | {account_id: $acct, region: $region, id: .DBInstanceIdentifier, type: "instance", engine: .Engine, engine_version: .EngineVersion,
       created_epoch: (.InstanceCreateTime | ts), retention: (.BackupRetentionPeriod // 0), global_cluster: null,
       global_role: (if (.ReadReplicaSourceDBInstanceIdentifier // "") != "" then "replica" else "none" end),
       snap_ok: $isnap_ok, backup_ok: $backup_ok, arn: .DBInstanceArn,
       snapshots: ([ ($isnaps[0].DBSnapshots // [])[] | select(.DBInstanceIdentifier == $i.DBInstanceIdentifier and (.SnapshotType == "manual" or .SnapshotType == "automated"))
                     | {kind: .SnapshotType, id: .DBSnapshotIdentifier, created_epoch: (.SnapshotCreateTime | ts), status: .Status,
                        size_gb: .AllocatedStorage, expires_epoch: null} ] + rps($i.DBInstanceArn))} ]
