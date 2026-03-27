#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: RocksDB MANIFEST file exists when validator is healthy
# Reads /shared/validator_manifest_count (written by validator entrypoint heartbeat loop)
# and asserts at least one MANIFEST file exists under /var/ton-work/db when healthy.
# RocksDB MANIFEST tracks the LSM tree state — missing MANIFEST means unrecoverable
# database corruption, even if the process appears healthy via port checks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="RocksDB MANIFEST file exists when validator is healthy"

echo "Checking RocksDB MANIFEST file existence..."

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

# Read MANIFEST count from shared volume
if [ ! -f /shared/validator_manifest_count ]; then
    echo "MANIFEST count file not present yet, skipping"
    sleep 10
    exit 0
fi

MANIFEST_COUNT=$(cat /shared/validator_manifest_count 2>/dev/null || true)
MANIFEST_COUNT=$(echo "$MANIFEST_COUNT" | tr -d '[:space:]')

# Validate we got a numeric value
if [ -z "$MANIFEST_COUNT" ] || ! [[ "$MANIFEST_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid MANIFEST count value: '$MANIFEST_COUNT', skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson count "$MANIFEST_COUNT" '{manifest_count: $count}')

if [ "$MANIFEST_COUNT" -gt 0 ]; then
    echo "PASS: Found ${MANIFEST_COUNT} MANIFEST file(s)"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: No MANIFEST files found under /var/ton-work/db"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
