#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: RocksDB LOG contains no write stall indicators when validator is healthy
# Write stalls indicate compaction is falling behind writes, causing cascading
# performance degradation and potential data loss.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="RocksDB LOG contains no write stall indicators when validator is healthy"
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"

# Precondition: heartbeat fresh
HEARTBEAT_FILE="/shared/validator_heartbeat"
if [[ ! -f "$HEARTBEAT_FILE" ]]; then
    echo "No heartbeat file yet, skipping"
    exit 0
fi
HB_TS=$(cat "$HEARTBEAT_FILE" 2>/dev/null || true)
HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
NOW=$(date +%s)
if ! [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
    echo "Invalid heartbeat, skipping"
    exit 0
fi
AGE=$((NOW - HB_TS))
if (( AGE > 30 )); then
    echo "Heartbeat stale (${AGE}s), skipping"
    exit 0
fi

# Precondition: all ports reachable
if ! nc -z -w 2 -u "$VALIDATOR_HOST" 30001 2>/dev/null; then exit 0; fi
if ! nc -z -w 2 "$VALIDATOR_HOST" 30002 2>/dev/null; then exit 0; fi
if ! nc -z -w 2 "$VALIDATOR_HOST" 30003 2>/dev/null; then exit 0; fi

# Check write stall count
STALL_FILE="/shared/validator_rocksdb_write_stalls"
if [[ ! -f "$STALL_FILE" ]]; then
    echo "Write stall metric not yet available, skipping"
    exit 0
fi

STALL_COUNT=$(cat "$STALL_FILE" 2>/dev/null || true)
STALL_COUNT=$(echo "$STALL_COUNT" | tr -d '[:space:]')
if ! [[ "$STALL_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid stall count, skipping"
    exit 0
fi

DETAILS=$(jq -cn --argjson count "$STALL_COUNT" '{write_stall_count: $count}')

if (( STALL_COUNT == 0 )); then
    echo "PASS: No write stalls detected"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: $STALL_COUNT write stall(s) detected in RocksDB LOG"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
