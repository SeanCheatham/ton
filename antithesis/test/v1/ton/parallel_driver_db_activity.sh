#!/usr/bin/env bash
source /opt/antithesis/test/v1/ton/helper_sdk.sh
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
PROPERTY="Validator is actively modifying database files"

# Check if validator is healthy (all 3 ports up)
udp_up=false; console_up=false; lite_up=false
nc -z -w 1 -u "$VALIDATOR_HOST" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30002 2>/dev/null && console_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "Validator not fully healthy, skipping activity check"
    exit 0
fi

DB_MTIME=$(cat /shared/validator_db_mtime 2>/dev/null || echo "-1")
NOW=$(date +%s)

if [[ "$DB_MTIME" == "-1" || -z "$DB_MTIME" ]]; then
    echo "No DB mtime available yet, skipping"
    exit 0
fi

AGE=$((NOW - DB_MTIME))
if [ "$AGE" -le 60 ]; then
    sdk_always true "$PROPERTY" "DB file modified ${AGE}s ago"
else
    sdk_always false "$PROPERTY" "DB file last modified ${AGE}s ago (limit: 60s)"
fi
