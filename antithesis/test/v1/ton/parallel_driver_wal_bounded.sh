#!/usr/bin/env bash
source /opt/antithesis/test/v1/ton/helper_sdk.sh
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
PROPERTY="RocksDB WAL file count is bounded"
WAL_LIMIT=50

# Only check when healthy (all 3 ports up)
udp_up=false; console_up=false; lite_up=false
nc -z -w 1 -u "$VALIDATOR_HOST" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30002 2>/dev/null && console_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "Validator not fully healthy, skipping WAL check"
    exit 0
fi

WAL_COUNT=$(cat /shared/validator_wal_count 2>/dev/null || echo "")
if [[ -z "$WAL_COUNT" ]]; then
    echo "WAL count file not present yet, skipping"
    exit 0
fi

if ! [[ "$WAL_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid WAL count value: $WAL_COUNT, skipping"
    exit 0
fi

if [ "$WAL_COUNT" -lt "$WAL_LIMIT" ]; then
    sdk_always true "$PROPERTY" "WAL count $WAL_COUNT within bounds"
else
    sdk_always false "$PROPERTY" "WAL count $WAL_COUNT exceeds threshold $WAL_LIMIT"
fi
