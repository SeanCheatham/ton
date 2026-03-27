#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: RocksDB CURRENT file is valid when validator is healthy
# Reads /shared/validator_current_valid (written by validator entrypoint heartbeat loop)
# and asserts the CURRENT file exists and is non-empty when healthy. CURRENT is the root
# of the RocksDB metadata chain (CURRENT → MANIFEST → SST files). A missing or empty
# CURRENT file means the database cannot open — unrecoverable, silent corruption.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="RocksDB CURRENT file is valid when validator is healthy"

echo "Checking RocksDB CURRENT file validity..."

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

# Read CURRENT validity from shared volume
if [ ! -f /shared/validator_current_valid ]; then
    echo "CURRENT validity file not present yet, skipping"
    sleep 10
    exit 0
fi

CURRENT_VALID=$(cat /shared/validator_current_valid 2>/dev/null || true)
CURRENT_VALID=$(echo "$CURRENT_VALID" | tr -d '[:space:]')

if [ -z "$CURRENT_VALID" ] || ! [[ "$CURRENT_VALID" =~ ^[01]$ ]]; then
    echo "Invalid CURRENT validity value: '$CURRENT_VALID', skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson valid "$CURRENT_VALID" '{current_valid: $valid}')

if [ "$CURRENT_VALID" -eq 1 ]; then
    echo "PASS: RocksDB CURRENT file exists and is non-empty"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: RocksDB CURRENT file is missing or empty while validator is healthy"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
