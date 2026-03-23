#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: RocksDB LOCK file exists when validator is healthy
# Reads /shared/validator_db_lock (written by validator entrypoint heartbeat loop)
# and asserts the LOCK file exists when all 3 ports are up. The LOCK file is held
# for the lifetime of the RocksDB database — its absence while the process reports
# healthy indicates DB corruption or improper shutdown.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="RocksDB LOCK file exists when validator is healthy"

sdk_catalog_always "${ASSERTION_NAME}"

echo "Checking RocksDB LOCK file..."

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

# Read LOCK file status from shared volume
if [ ! -f /shared/validator_db_lock ]; then
    echo "LOCK status file not present yet, skipping"
    sleep 10
    exit 0
fi

LOCK_PRESENT=$(cat /shared/validator_db_lock 2>/dev/null | tr -d '[:space:]')

if [ -z "$LOCK_PRESENT" ] || ! [[ "$LOCK_PRESENT" =~ ^[01]$ ]]; then
    echo "Invalid LOCK status value: '$LOCK_PRESENT', skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson lock "$LOCK_PRESENT" '{lock_present: $lock}')

if [ "$LOCK_PRESENT" -eq 1 ]; then
    echo "PASS: RocksDB LOCK file exists"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: RocksDB LOCK file missing while validator is healthy"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
