#!/bin/bash
cd "$(dirname "$0")";
./img-backup.sh > ./Log/log 2>&1
retVal=$?

if [ $retVal -eq 0 ]; then
    result="SUCCESS"
else
    result="UNSUCCESSFUL"
fi

# Send results via Email
mail -s "$result: Backup Results for $(hostname)" mcollins1290@gmail.com < ./Log/log

exit
