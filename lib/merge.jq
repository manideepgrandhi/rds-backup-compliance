# --merge: input [{i, d}] of --save-data documents. Per account the newest collection wins (same time: later file).
[ .[] | . as $f | $f.d.accounts[] | . + {i: $f.i} ] as $ALL
| ([ $ALL | group_by(.account)[] | sort_by(.collected_epoch, .i) | last ]) as $KEEP
| def kept($a; $i): any($KEEP[]; .account == $a and .i == $i);
  { schema: "rds_backup_compliance_data", schema_version: 1,
    collected_epoch: ([ $KEEP[].collected_epoch ] | max),
    accounts: [ $KEEP[] | del(.i) ],
    replaced: [ $ALL[] | . as $x | select(kept($x.account; $x.i) | not) | {account, collected_epoch} ],
    regions: [ .[] | .i as $i | .d.regions[] | select(kept(.account; $i)) ],
    resources: [ .[] | .i as $i | .d.resources[] | select(kept(.account_id; $i)) ] }
