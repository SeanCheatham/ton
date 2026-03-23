#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: RocksDB LOG file contains no corruption or IO error warnings
# Reads /shared/validator_rocksdb_errors (written by validator entrypoint heartbeat loop)
# and asserts that the count of corruption/IO error indicators in RocksDB LOG files
# is zero when the validator is healthy. This goes deeper than file-existence checks
# (LOCK, MANIFEST, CURRENT, SST) — it inspects RocksDB's own diagnostic output.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
HEARTBEAT_MAX_AGE=60

# Use heartbeat-only precondition instead of all-3-ports.
# The heartbeat proves the validator process is actively running.
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
        echo "Heartbeat value invalid, skipping"
        exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"
    exit 0
fi

if [ ! -f /shared/validator_rocksdb_errors ]; then
    echo "Metric not available yet (validator may have just restarted)"
    sdk_always true "RocksDB LOG file contains no corruption or IO error warnings" '{"status":"metric_not_yet_available","note":"heartbeat fresh but metric file pending"}'
    exit 0
fi

CORRUPTION_COUNT=$(cat /shared/validator_rocksdb_errors 2>/dev/null || echo "-1")

if [ "$CORRUPTION_COUNT" = "-1" ]; then
    echo "RocksDB errors unavailable, skipping"
    exit 0
fi

if ! [[ "$CORRUPTION_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid corruption count: $CORRUPTION_COUNT, skipping"
    exit 0
fi

if [ "$CORRUPTION_COUNT" -gt 0 ]; then
    DETAILS=$(jq -cn --argjson count "$CORRUPTION_COUNT" '{corruption_count: $count}')
    sdk_always false "RocksDB LOG file contains no corruption or IO error warnings" "$DETAILS"
else
    sdk_always true "RocksDB LOG file contains no corruption or IO error warnings" '{"corruption_count":0}'
fi

exit 0
