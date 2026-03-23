#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: RocksDB LOG file size is bounded when validator is healthy
# Reads /shared/validator_rocksdb_log_size (written by validator entrypoint heartbeat loop)
# and asserts the RocksDB LOG file is less than 100MB. An unbounded LOG file indicates
# excessive compaction activity, repeated warnings/errors, or LOG rotation failures.

source "$(dirname "$0")/helper_sdk.sh"

LOG_SIZE_LIMIT=104857600  # 100MB in bytes

# Skip if heartbeat is stale
if [ ! -f /shared/validator_heartbeat ]; then
    echo "Heartbeat file not present yet, skipping"
    sleep 10
    exit 0
fi

NOW=$(date +%s)
HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || echo "0")
if ! [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
    echo "Invalid heartbeat value, skipping"
    sleep 10
    exit 0
fi

HB_AGE=$((NOW - HB_TS))
if [ "$HB_AGE" -gt 90 ]; then
    echo "Heartbeat stale (${HB_AGE}s old), skipping"
    sleep 10
    exit 0
fi

# Read RocksDB LOG size
if [ ! -f /shared/validator_rocksdb_log_size ]; then
    echo "RocksDB LOG size file not present yet, skipping"
    sleep 10
    exit 0
fi

LOG_SIZE=$(cat /shared/validator_rocksdb_log_size 2>/dev/null || echo "0")

if ! [[ "$LOG_SIZE" =~ ^[0-9]+$ ]]; then
    echo "Invalid RocksDB LOG size value: $LOG_SIZE, skipping"
    sleep 10
    exit 0
fi

if [ "$LOG_SIZE" -eq 0 ]; then
    echo "RocksDB LOG size not yet available, skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson size "$LOG_SIZE" --argjson limit "$LOG_SIZE_LIMIT" \
    '{log_size_bytes: $size, log_size_mb: ($size / 1048576 * 100 | floor / 100), limit_bytes: $limit, limit_mb: ($limit / 1048576)}')

if [ "$LOG_SIZE" -lt "$LOG_SIZE_LIMIT" ]; then
    sdk_always true "RocksDB LOG file size is bounded when validator is healthy" "$DETAILS"
else
    sdk_always false "RocksDB LOG file size is bounded when validator is healthy" "$DETAILS"
fi

sleep 10
exit 0
