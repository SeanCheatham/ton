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
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="RocksDB OPTIONS file exists and is non-empty when validator is healthy"

echo "Checking RocksDB OPTIONS file..."

# Check all 3 ports — only assert when validator is fully healthy
udp_up=false
console_up=false
lite_up=false

nc -z -u -w 2 "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null && udp_up=true
nc -z -w 1 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null && console_up=true
nc -z -w 1 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "SKIP: not all ports are up (udp=${udp_up}, console=${console_up}, lite=${lite_up})"
    sleep 10
    exit 0
fi

# Check heartbeat freshness
if [ ! -f /shared/validator_heartbeat ]; then
    echo "Heartbeat file not present yet, skipping"
    sleep 10
    exit 0
fi

HB=$(cat /shared/validator_heartbeat 2>/dev/null || echo "0")
NOW=$(date +%s)
AGE=$(( NOW - HB ))
if [ "$AGE" -gt 30 ]; then
    echo "Heartbeat stale (${AGE}s old), skipping"
    sleep 10
    exit 0
fi

# Read OPTIONS file status from shared volume
if [ ! -f /shared/validator_rocksdb_options ]; then
    echo "OPTIONS status file not present yet, skipping"
    sleep 10
    exit 0
fi

RAW=$(cat /shared/validator_rocksdb_options 2>/dev/null | tr -d '[:space:]')

# Parse COUNT:NONEMPTY format
OPTIONS_COUNT=$(echo "$RAW" | cut -d: -f1)
OPTIONS_NONEMPTY=$(echo "$RAW" | cut -d: -f2)

# Validate numeric values
if [ -z "$OPTIONS_COUNT" ] || ! [[ "$OPTIONS_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid OPTIONS count value: '$OPTIONS_COUNT', skipping"
    sleep 10
    exit 0
fi
if [ -z "$OPTIONS_NONEMPTY" ] || ! [[ "$OPTIONS_NONEMPTY" =~ ^[01]$ ]]; then
    echo "Invalid OPTIONS nonempty value: '$OPTIONS_NONEMPTY', skipping"
    sleep 10
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

sleep 10
exit 0
