#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: RocksDB MANIFEST file size is bounded when validator is healthy
# The MANIFEST file records every version edit (compaction, flush, file add/delete).
# If compaction isn't properly cleaning up old versions, the MANIFEST grows unboundedly,
# causing slow DB opens on restart, excessive memory during recovery, and eventual disk
# exhaustion. Bound: 50MB (a healthy MANIFEST should be well under 10MB).

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
HEARTBEAT_MAX_AGE=60
ASSERTION_NAME="RocksDB MANIFEST file size is bounded when validator is healthy"
BOUND=52428800  # 50MB in bytes

# Use heartbeat-only precondition
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
        echo "Heartbeat value invalid, skipping"
        exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"
    exit 0
fi

if [ ! -f /shared/validator_manifest_size ]; then
    echo "MANIFEST size file not present yet, skipping"
    exit 0
fi

MANIFEST_SIZE=$(cat /shared/validator_manifest_size 2>/dev/null || true)
MANIFEST_SIZE=$(echo "$MANIFEST_SIZE" | tr -d '[:space:]')

if [ -z "$MANIFEST_SIZE" ] || ! [[ "$MANIFEST_SIZE" =~ ^[0-9]+$ ]]; then
    echo "Invalid MANIFEST size value: '$MANIFEST_SIZE', skipping"
    exit 0
fi

DETAILS=$(jq -cn --argjson size "$MANIFEST_SIZE" --argjson bound "$BOUND" \
    '{manifest_size_bytes: $size, max_allowed_bytes: $bound}')

if [ "$MANIFEST_SIZE" -lt "$BOUND" ]; then
    echo "PASS: MANIFEST size ${MANIFEST_SIZE} bytes < ${BOUND} byte bound"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: MANIFEST size ${MANIFEST_SIZE} bytes >= ${BOUND} byte bound"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
