#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: RocksDB OPTIONS file exists and is non-empty when validator is healthy
# Reads /shared/validator_rocksdb_options (written by validator entrypoint heartbeat loop)
# and asserts at least one non-empty OPTIONS-* file exists. The OPTIONS file records
# RocksDB's configuration (block size, compression, merge operators). Its absence means
# the database may reopen with wrong settings after a crash, causing subtle data corruption.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
HEARTBEAT_MAX_AGE=60

ASSERTION_NAME="RocksDB OPTIONS file exists and is non-empty when validator is healthy"

echo "Checking RocksDB OPTIONS file..."

# Use heartbeat-only precondition instead of all-3-ports.
# The heartbeat proves the validator process is actively running.
if [ -f /shared/validator_heartbeat ]; then
    HB=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
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

# Read OPTIONS file status from shared volume
if [ ! -f /shared/validator_rocksdb_options ]; then
    echo "OPTIONS status file not present yet, skipping"
    exit 0
fi

RAW=$(cat /shared/validator_rocksdb_options 2>/dev/null | tr -d '[:space:]')

# Parse COUNT:NONEMPTY format
OPTIONS_COUNT=$(echo "$RAW" | cut -d: -f1)
OPTIONS_NONEMPTY=$(echo "$RAW" | cut -d: -f2)

# Validate numeric values
if [ -z "$OPTIONS_COUNT" ] || ! [[ "$OPTIONS_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid OPTIONS count value: '$OPTIONS_COUNT', skipping"
    exit 0
fi
if [ -z "$OPTIONS_NONEMPTY" ] || ! [[ "$OPTIONS_NONEMPTY" =~ ^[01]$ ]]; then
    echo "Invalid OPTIONS nonempty value: '$OPTIONS_NONEMPTY', skipping"
    exit 0
fi

DETAILS=$(jq -cn --argjson count "$OPTIONS_COUNT" --argjson nonempty "$OPTIONS_NONEMPTY" \
    '{options_file_count: $count, first_file_nonempty: $nonempty}')

if [ "$OPTIONS_COUNT" -gt 0 ] && [ "$OPTIONS_NONEMPTY" -eq 1 ]; then
    echo "PASS: Found ${OPTIONS_COUNT} OPTIONS file(s), first is non-empty"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: OPTIONS count=${OPTIONS_COUNT}, nonempty=${OPTIONS_NONEMPTY}"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

exit 0
