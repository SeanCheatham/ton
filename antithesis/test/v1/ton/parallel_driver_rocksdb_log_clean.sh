#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: RocksDB LOG file contains no corruption or IO error warnings
# Reads /shared/validator_rocksdb_errors (written by validator entrypoint heartbeat loop)
# and asserts that the count of corruption/IO error indicators in RocksDB LOG files
# is zero when the validator is healthy. This goes deeper than file-existence checks
# (LOCK, MANIFEST, CURRENT, SST) — it inspects RocksDB's own diagnostic output.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"

if [ ! -f /shared/validator_rocksdb_errors ]; then
    echo "RocksDB errors file not present yet, skipping"
    sleep 10
    exit 0
fi

CORRUPTION_COUNT=$(cat /shared/validator_rocksdb_errors 2>/dev/null || echo "-1")

if [ "$CORRUPTION_COUNT" = "-1" ]; then
    echo "RocksDB errors unavailable, skipping"
    sleep 10
    exit 0
fi

if ! [[ "$CORRUPTION_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid corruption count: $CORRUPTION_COUNT, skipping"
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

if [ "$CORRUPTION_COUNT" -gt 0 ]; then
    DETAILS=$(jq -cn --argjson count "$CORRUPTION_COUNT" '{corruption_count: $count}')
    sdk_always false "RocksDB LOG file contains no corruption or IO error warnings" "$DETAILS"
else
    sdk_always true "RocksDB LOG file contains no corruption or IO error warnings" '{"corruption_count":0}'
fi

sleep 10
exit 0
