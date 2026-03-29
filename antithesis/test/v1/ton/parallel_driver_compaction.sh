#!/usr/bin/env bash

# Parallel driver: RocksDB compaction has occurred when validator is mature
# Detects compaction by monitoring MANIFEST file size growth over time.
# Every compaction writes a version edit to the MANIFEST file, so size growth
# is a guaranteed side-effect regardless of RocksDB log configuration.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="RocksDB compaction has occurred when validator is mature"

# Heartbeat-only precondition
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s > ${HEARTBEAT_MAX_AGE}s), skipping"
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"; exit 0
fi

# Read current MANIFEST total size from the validator's metric
if [ ! -f /shared/validator_manifest_total_size ]; then
    echo "MANIFEST size file not present yet, skipping"
    exit 0
fi

CURRENT_SIZE=$(cat /shared/validator_manifest_total_size 2>/dev/null || true)
CURRENT_SIZE=$(echo "$CURRENT_SIZE" | tr -d '[:space:]')

if ! [[ "$CURRENT_SIZE" =~ ^[0-9]+$ ]]; then
    echo "Invalid MANIFEST size value: ${CURRENT_SIZE}, skipping"
    exit 0
fi

BASELINE_FILE="/shared/_prev_manifest_size"

# On first invocation, store baseline and exit
if [ ! -f "$BASELINE_FILE" ]; then
    echo "$CURRENT_SIZE" > "$BASELINE_FILE"
    echo "Stored baseline MANIFEST size: ${CURRENT_SIZE} bytes"
    sdk_sometimes false "$ASSERTION_NAME" "$(jq -cn --argjson current "$CURRENT_SIZE" '{manifest_bytes: $current, baseline_bytes: $current, growth_bytes: 0}')"
    exit 0
fi

BASELINE=$(cat "$BASELINE_FILE" 2>/dev/null || true)
BASELINE=$(echo "$BASELINE" | tr -d '[:space:]')

if ! [[ "$BASELINE" =~ ^[0-9]+$ ]]; then
    # Reset baseline if corrupted
    echo "$CURRENT_SIZE" > "$BASELINE_FILE"
    echo "Baseline was invalid, reset to ${CURRENT_SIZE}"
    exit 0
fi

GROWTH=$((CURRENT_SIZE - BASELINE))
DETAILS=$(jq -cn --argjson current "$CURRENT_SIZE" --argjson baseline "$BASELINE" --argjson growth "$GROWTH" \
    '{manifest_bytes: $current, baseline_bytes: $baseline, growth_bytes: $growth}')

# Compaction detected if MANIFEST has grown by at least 1KB
if [ "$GROWTH" -ge 1024 ]; then
    echo "PASS: RocksDB compaction detected (MANIFEST grew by ${GROWTH} bytes)"
    sdk_sometimes true "$ASSERTION_NAME" "$DETAILS"
else
    echo "No compaction detected yet (MANIFEST growth: ${GROWTH} bytes)"
    sdk_sometimes false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
