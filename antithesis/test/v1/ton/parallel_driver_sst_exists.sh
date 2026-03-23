#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: RocksDB SST files exist when validator is healthy
# Reads /shared/validator_sst_count (written by validator entrypoint heartbeat loop)
# and asserts that at least one .sst file exists when the validator is healthy.
# SST files are the actual data storage in RocksDB — without them, the metadata
# chain (LOCK → CURRENT → MANIFEST) is meaningless.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"

if [ ! -f /shared/validator_sst_count ]; then
    echo "SST count file not present yet, skipping"
    sleep 10
    exit 0
fi

SST_COUNT=$(cat /shared/validator_sst_count 2>/dev/null || echo "-1")

if ! [[ "$SST_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid SST count value: $SST_COUNT, skipping"
    sleep 10
    exit 0
fi

# Check if all 3 ports are reachable
udp_up=false
console_up=false
lite_up=false
nc -z -w 1 -u "${VALIDATOR_HOST}" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "${VALIDATOR_HOST}" 30002 2>/dev/null && console_up=true
nc -z -w 1 "${VALIDATOR_HOST}" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "Validator not fully healthy, skipping assertion"
    sleep 10
    exit 0
fi

# Confirm heartbeat freshness (< 30s old)
if [ -f /shared/validator_heartbeat ]; then
    HEARTBEAT=$(cat /shared/validator_heartbeat 2>/dev/null || echo "0")
    NOW=$(date +%s)
    AGE=$((NOW - HEARTBEAT))
    if [ "$AGE" -gt 30 ]; then
        echo "Heartbeat stale (${AGE}s old), skipping"
        sleep 10
        exit 0
    fi
fi

# Check DB maturity: a freshly started standalone validator may not have flushed
# any memtables to SST files yet. Only assert if the DB is mature enough
# (has a non-trivial size indicating data has been written to disk).
DB_SIZE=0
if [ -f /shared/validator_db_size ]; then
    DB_SIZE=$(cat /shared/validator_db_size 2>/dev/null || echo "0")
fi

DETAILS=$(jq -cn --argjson count "$SST_COUNT" --argjson db_size "$DB_SIZE" '{sst_count: $count, db_size_bytes: $db_size}')

if [ "$SST_COUNT" -gt 0 ]; then
    sdk_always true "RocksDB SST files exist when validator is healthy" "$DETAILS"
elif [ "$DB_SIZE" -lt 1048576 ]; then
    # DB is less than 1MB — too early for SST files to exist, skip
    echo "DB size ${DB_SIZE} bytes is too small for SST files, skipping assertion"
else
    sdk_always false "RocksDB SST files exist when validator is healthy" "$DETAILS"
fi

sleep 10
exit 0
