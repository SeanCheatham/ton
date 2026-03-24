#!/usr/bin/env bash

# Parallel driver: RocksDB SST file count is non-decreasing when healthy
# Tracks SST file count trend. A sudden >50% drop when the validator is healthy
# could indicate data loss, catastrophic compaction, or corruption.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="RocksDB SST file count is non-decreasing when healthy"
HEARTBEAT_MAX_AGE=60

# Precondition: heartbeat must be fresh
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
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

# Read current SST count
SST_COUNT=$(cat /shared/validator_sst_count 2>/dev/null | tr -d '[:space:]')
if ! [[ "$SST_COUNT" =~ ^[0-9]+$ ]]; then
    echo "SST count metric not available or invalid, skipping"
    exit 0
fi

# Skip if SST_COUNT is 0 (DB not mature enough — no SST files yet)
if [ "$SST_COUNT" -eq 0 ]; then
    echo "SST count is 0 (DB not mature), skipping"
    exit 0
fi

# Read previous value
PREV_FILE="/shared/_prev_sst_count"
PREV_COUNT=$(cat "$PREV_FILE" 2>/dev/null | tr -d '[:space:]')

# Store current for next invocation
echo "$SST_COUNT" > "$PREV_FILE"

if ! [[ "$PREV_COUNT" =~ ^[0-9]+$ ]] || [ "$PREV_COUNT" -eq 0 ]; then
    echo "First valid observation: SST count=$SST_COUNT"
    sdk_always true "$ASSERTION_NAME" "$(jq -cn --argjson cur "$SST_COUNT" '{status:"first_observation", current_sst_count: $cur}')"
    exit 0
fi

# Check: current >= prev * 0.5 (allow up to 50% drop for legitimate compaction)
DETAILS=$(jq -cn --argjson current "$SST_COUNT" --argjson previous "$PREV_COUNT" '{current_sst_count: $current, previous_sst_count: $previous}')

if [ $((SST_COUNT * 2)) -ge "$PREV_COUNT" ]; then
    echo "PASS: SST count stable (current=$SST_COUNT, previous=$PREV_COUNT)"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Catastrophic SST loss detected (current=$SST_COUNT, previous=$PREV_COUNT)"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
