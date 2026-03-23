#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator has no stale RocksDB temporary files when healthy
# Reads /shared/validator_rocksdb_tmp_files (written by validator entrypoint heartbeat loop)
# and asserts the count of .tmp/.dbtmp files is <= 20. RocksDB creates these during
# compaction/flush — accumulation indicates repeated failed compactions where the validator
# appears healthy but is silently failing to compact, leading to unbounded growth.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Validator has no stale RocksDB temporary files when healthy"

echo "Checking RocksDB temporary files..."

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

# Read temp file count from shared volume
if [ ! -f /shared/validator_rocksdb_tmp_files ]; then
    echo "Temp file count not present yet, skipping"
    sleep 10
    exit 0
fi

TMP_COUNT=$(cat /shared/validator_rocksdb_tmp_files 2>/dev/null | tr -d '[:space:]')

# Validate numeric value
if [ -z "$TMP_COUNT" ] || ! [[ "$TMP_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid temp file count value: '$TMP_COUNT', skipping"
    sleep 10
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

sleep 10
exit 0
