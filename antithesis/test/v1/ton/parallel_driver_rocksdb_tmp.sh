#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator has no stale RocksDB temporary files when healthy
# Reads /shared/validator_rocksdb_tmp_files (written by validator entrypoint heartbeat loop)
# and asserts the count of .tmp/.dbtmp files is <= 20. RocksDB creates these during
# compaction/flush — accumulation indicates repeated failed compactions where the validator
# appears healthy but is silently failing to compact, leading to unbounded growth.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
HEARTBEAT_MAX_AGE=60

ASSERTION_NAME="Validator has no stale RocksDB temporary files when healthy"

echo "Checking RocksDB temporary files..."

# Use heartbeat-only precondition instead of all-3-ports.
if [ -f /shared/validator_heartbeat ]; then
    HB=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB=$(echo "$HB" | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB))
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

# Read temp file count from shared volume
if [ ! -f /shared/validator_rocksdb_tmp_files ]; then
    echo "Metric not available yet (validator may have just restarted)"
    sdk_always true "${ASSERTION_NAME}" '{"status":"metric_not_yet_available","note":"heartbeat fresh but metric file pending"}'
    exit 0
fi

TMP_COUNT=$(cat /shared/validator_rocksdb_tmp_files 2>/dev/null || true)
TMP_COUNT=$(echo "$TMP_COUNT" | tr -d '[:space:]')

# Validate numeric value
if [ -z "$TMP_COUNT" ] || ! [[ "$TMP_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid temp file count value: '$TMP_COUNT', skipping"
    exit 0
fi

DETAILS=$(jq -cn --argjson count "$TMP_COUNT" --argjson threshold 20 \
    '{tmp_file_count: $count, max_allowed: $threshold}')

if [ "$TMP_COUNT" -le 20 ]; then
    echo "PASS: ${TMP_COUNT} temporary files (threshold: 20)"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: ${TMP_COUNT} temporary files exceeds threshold of 20"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

exit 0
