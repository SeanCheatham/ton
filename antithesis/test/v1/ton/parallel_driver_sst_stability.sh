#!/usr/bin/env bash
set -euo pipefail

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
            sleep 10
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"
        sleep 10
        exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"
    sleep 10
    exit 0
fi

# Read current SST count
if [ ! -f /shared/validator_sst_count ]; then
    echo "SST count metric not available yet, skipping"
    sleep 10
    exit 0
fi

SST_COUNT=$(cat /shared/validator_sst_count 2>/dev/null | tr -d '[:space:]')
if ! [[ "$SST_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid SST count value: $SST_COUNT, skipping"
    sleep 10
    exit 0
fi

# Skip if SST_COUNT is 0 (DB not mature enough)
if [ "$SST_COUNT" -eq 0 ]; then
    echo "SST count is 0 (DB not mature), skipping"
    sleep 10
    exit 0
fi

# Read previous value
PREV_FILE="/shared/_prev_sst_count"
if [ ! -f "$PREV_FILE" ]; then
    echo "First observation, storing SST count: $SST_COUNT"
    echo "$SST_COUNT" > "$PREV_FILE"
    sleep 10
    exit 0
fi

PREV_COUNT=$(cat "$PREV_FILE" 2>/dev/null | tr -d '[:space:]')
if ! [[ "$PREV_COUNT" =~ ^[0-9]+$ ]] || [ "$PREV_COUNT" -eq 0 ]; then
    echo "Previous count invalid or zero, resetting to current: $SST_COUNT"
    echo "$SST_COUNT" > "$PREV_FILE"
    sleep 10
    exit 0
fi

# Check: current >= prev * 0.5 (allow up to 50% drop for legitimate compaction)
# Using integer arithmetic: current * 2 >= prev
DETAILS=$(jq -cn --argjson current "$SST_COUNT" --argjson previous "$PREV_COUNT" '{current_sst_count: $current, previous_sst_count: $previous}')

if [ $((SST_COUNT * 2)) -ge "$PREV_COUNT" ]; then
    echo "PASS: SST count stable (current=$SST_COUNT, previous=$PREV_COUNT)"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Catastrophic SST loss detected (current=$SST_COUNT, previous=$PREV_COUNT)"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

# Store current value for next invocation
echo "$SST_COUNT" > "$PREV_FILE"

sleep 10
exit 0
