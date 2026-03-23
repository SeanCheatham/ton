#!/usr/bin/env bash
source /opt/antithesis/test/v1/ton/helper_sdk.sh
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
PROPERTY="RocksDB WAL-to-SST ratio is healthy when validator is running"
RATIO_LIMIT=10

# Only check when healthy (all 3 ports up)
udp_up=false; console_up=false; lite_up=false
nc -z -w 1 -u "$VALIDATOR_HOST" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30002 2>/dev/null && console_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "Validator not fully healthy, skipping WAL-to-SST ratio check"
    exit 0
fi

WAL_COUNT=$(cat /shared/validator_wal_count 2>/dev/null || echo "")
SST_COUNT=$(cat /shared/validator_sst_count 2>/dev/null || echo "")

if [[ -z "$WAL_COUNT" || -z "$SST_COUNT" ]]; then
    echo "WAL or SST count file not present yet, skipping"
    exit 0
fi

if ! [[ "$WAL_COUNT" =~ ^[0-9]+$ ]] || ! [[ "$SST_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid WAL ($WAL_COUNT) or SST ($SST_COUNT) count, skipping"
    exit 0
fi

# Skip if DB is not yet mature (no SST files yet)
if [ "$SST_COUNT" -eq 0 ]; then
    echo "SST count is 0 (DB not mature), skipping ratio check"
    exit 0
fi

# Compute ratio (integer division)
RATIO=$((WAL_COUNT / SST_COUNT))

if [ "$RATIO" -le "$RATIO_LIMIT" ]; then
    sdk_always true "$PROPERTY" "$(jq -cn --argjson wal "$WAL_COUNT" --argjson sst "$SST_COUNT" --argjson ratio "$RATIO" --argjson limit "$RATIO_LIMIT" '{wal_count: $wal, sst_count: $sst, ratio: $ratio, ratio_limit: $limit}')"
else
    sdk_always false "$PROPERTY" "$(jq -cn --argjson wal "$WAL_COUNT" --argjson sst "$SST_COUNT" --argjson ratio "$RATIO" --argjson limit "$RATIO_LIMIT" '{wal_count: $wal, sst_count: $sst, ratio: $ratio, ratio_limit: $limit}')"
fi
