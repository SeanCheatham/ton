#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: RocksDB CURRENT file references existing MANIFEST when validator is healthy
# Cross-validates the RocksDB metadata chain: reads CURRENT file content (which names the active
# MANIFEST), then verifies that the referenced MANIFEST file actually exists on disk.
# This catches inconsistencies invisible to the independent existence checks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
ASSERTION_NAME="RocksDB CURRENT file references existing MANIFEST when validator is healthy"

echo "Checking CURRENT → MANIFEST cross-reference..."

# Check all 3 ports — only assert when validator is fully healthy
udp_up=false
console_up=false
lite_up=false

nc -z -u -w 2 "${VALIDATOR_HOST}" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "${VALIDATOR_HOST}" 30002 2>/dev/null && console_up=true
nc -z -w 1 "${VALIDATOR_HOST}" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "SKIP: not all ports are up (udp=${udp_up}, console=${console_up}, lite=${lite_up})"
    sleep 10
    exit 0
fi

# Read CURRENT→MANIFEST consistency from shared volume
if [ ! -f /shared/validator_current_manifest_consistent ]; then
    echo "CURRENT→MANIFEST consistency file not present yet, skipping"
    sleep 10
    exit 0
fi

CONSISTENT=$(cat /shared/validator_current_manifest_consistent 2>/dev/null || true)
CONSISTENT=$(echo "$CONSISTENT" | tr -d '[:space:]')

if [ -z "$CONSISTENT" ]; then
    echo "Empty consistency value, skipping"
    sleep 10
    exit 0
fi

# -1 means CURRENT file not found/empty — skip (covered by CURRENT validity check)
if [ "$CONSISTENT" = "-1" ]; then
    echo "CURRENT file not available, skipping cross-reference check"
    sleep 10
    exit 0
fi

if ! [[ "$CONSISTENT" =~ ^[01]$ ]]; then
    echo "Invalid consistency value: '$CONSISTENT', skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson consistent "$CONSISTENT" '{current_manifest_consistent: $consistent}')

if [ "$CONSISTENT" -eq 1 ]; then
    echo "PASS: CURRENT file references an existing MANIFEST file"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: CURRENT file references a non-existent MANIFEST file"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
