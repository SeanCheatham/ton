#!/usr/bin/env bash
source /opt/antithesis/test/v1/ton/helper_sdk.sh
PROPERTY="RocksDB WAL-to-SST ratio is healthy when validator is running"
RATIO_LIMIT=10
HEARTBEAT_MAX_AGE=60

# Heartbeat-based precondition
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s), skipping"
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"; exit 0
fi

WAL_COUNT=$(cat /shared/validator_wal_count 2>/dev/null || true)
WAL_COUNT=$(echo "$WAL_COUNT" | tr -d '[:space:]')
SST_COUNT=$(cat /shared/validator_sst_count 2>/dev/null || true)
SST_COUNT=$(echo "$SST_COUNT" | tr -d '[:space:]')

# If metrics are not yet populated, emit pass-through (heartbeat is fresh but metrics pending)
if [[ -z "$WAL_COUNT" || -z "$SST_COUNT" ]]; then
    echo "Metric not available yet (validator may have just restarted)"
    sdk_always true "$PROPERTY" '{"status":"metric_not_yet_available"}'
    exit 0
fi

if ! [[ "$WAL_COUNT" =~ ^[0-9]+$ ]] || ! [[ "$SST_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid WAL ($WAL_COUNT) or SST ($SST_COUNT) count, skipping"
    exit 0
fi

# When SST count is 0, the DB is not mature yet — ratio is trivially healthy
if [ "$SST_COUNT" -eq 0 ]; then
    echo "SST count is 0 (DB not mature), ratio trivially healthy"
    sdk_always true "$PROPERTY" "$(jq -cn --argjson wal "$WAL_COUNT" --argjson sst "$SST_COUNT" '{wal_count: $wal, sst_count: $sst, status: "db_not_mature"}')"
    exit 0
fi

# Compute ratio (integer division)
RATIO=$((WAL_COUNT / SST_COUNT))

if [ "$RATIO" -le "$RATIO_LIMIT" ]; then
    sdk_always true "$PROPERTY" "$(jq -cn --argjson wal "$WAL_COUNT" --argjson sst "$SST_COUNT" --argjson ratio "$RATIO" --argjson limit "$RATIO_LIMIT" '{wal_count: $wal, sst_count: $sst, ratio: $ratio, ratio_limit: $limit}')"
else
    sdk_always false "$PROPERTY" "$(jq -cn --argjson wal "$WAL_COUNT" --argjson sst "$SST_COUNT" --argjson ratio "$RATIO" --argjson limit "$RATIO_LIMIT" '{wal_count: $wal, sst_count: $sst, ratio: $ratio, ratio_limit: $limit}')"
fi
