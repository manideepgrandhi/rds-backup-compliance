#!/usr/bin/env python3
"""Check every field the tool reads against the AWS CLI's bundled service models (no AWS call).
--generate-cli-skeleton truncates optional members, so the models are read directly.
Usage: tests/validate_cli.py [path-to-awscli-botocore-data]"""
import glob, json, os, shutil, sys
root = sys.argv[1] if len(sys.argv) > 1 else None
if not root:
    aws = os.path.realpath(shutil.which("aws") or "")
    c = glob.glob(os.path.join(os.path.dirname(aws), "**/botocore/data"), recursive=True) + glob.glob("/usr/local/aws-cli/**/botocore/data", recursive=True)
    root = c[0] if c else sys.exit("botocore data dir not found; pass it as argument")
def model(svc):
    d = sorted(glob.glob(f"{root}/{svc}/*/service-2.json"))[-1]; return json.load(open(d))
CHECKS = [
 ("rds","DescribeDBClusters",["DBClusters"],"DBClusterIdentifier DBClusterArn Engine EngineVersion ClusterCreateTime BackupRetentionPeriod ReplicationSourceIdentifier GlobalClusterIdentifier"),
 ("rds","DescribeDBInstances",["DBInstances"],"DBInstanceIdentifier DBInstanceArn Engine EngineVersion InstanceCreateTime BackupRetentionPeriod DBClusterIdentifier ReadReplicaSourceDBInstanceIdentifier"),
 ("rds","DescribeGlobalClusters",["GlobalClusters"],"GlobalClusterIdentifier GlobalClusterMembers"),
 ("rds","DescribeGlobalClusters",["GlobalClusters","GlobalClusterMembers"],"DBClusterArn IsWriter"),
 ("rds","DescribeDBClusterSnapshots",["DBClusterSnapshots"],"DBClusterIdentifier DBClusterSnapshotIdentifier SnapshotType SnapshotCreateTime Status AllocatedStorage DBClusterSnapshotArn SourceDBClusterSnapshotArn Engine EngineVersion StorageEncrypted KmsKeyId"),
 ("rds","DescribeDBSnapshots",["DBSnapshots"],"DBInstanceIdentifier DBSnapshotIdentifier SnapshotType SnapshotCreateTime Status AllocatedStorage DBSnapshotArn SourceDBSnapshotIdentifier SourceRegion Engine EngineVersion Encrypted KmsKeyId"),
 ("backup","ListBackupVaults",["BackupVaultList"],"BackupVaultName"),
 ("backup","ListRecoveryPointsByBackupVault",["RecoveryPoints"],"RecoveryPointArn ResourceArn ResourceType CreationDate Status BackupSizeInBytes CalculatedLifecycle BackupVaultName"),
 ("backup","ListRecoveryPointsByBackupVault",["RecoveryPoints","CalculatedLifecycle"],"DeleteAt"),
]
fail = 0
for op in ("DescribeDBClusterSnapshots", "DescribeDBSnapshots"):   # --include-shared
    m = model("rds"); inp = m["shapes"][m["operations"][op]["input"]["shape"]]["members"]
    if "IncludeShared" not in inp: print(f"MISSING rds {op} input IncludeShared"); fail += 1
for svc, op, path, fields in CHECKS:
    m = model(svc); sh = m["shapes"]; s = sh[m["operations"][op]["output"]["shape"]]
    for p in path:
        s = sh[s["members"][p]["shape"]]
        while s["type"] == "list": s = sh[s["member"]["shape"]]
    for f in fields.split():
        if f not in s.get("members", {}): print(f"MISSING {svc} {op} {'.'.join(path)}.{f}"); fail = 1
print("FAIL" if fail else f"PASS ({root})"); sys.exit(fail)
