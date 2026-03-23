#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator disk usage is bounded
# Reads /shared/validator_disk_usage (written by validator entrypoint heartbeat loop)
# and asserts total /var/ton-work disk usage stays below 5GB when the validator is healthy.
# Catches unchecked growth from WAL files, temporary files, incomplete compactions,
# and log accumulation that could exhaust container storage.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

DISK_LIMIT=5368709120  # 5GB in bytes
ASSERTION_NAME="Validator disk usage is bounded"

echo "Checking validator disk usage..."

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

# Read disk usage from shared volume
if [ ! -f /shared/validator_disk_usage ]; then
    echo "Disk usage file not present yet, skipping"
    sleep 10
    exit 0
fi

DISK_USAGE=$(cat /shared/validator_disk_usage 2>/dev/null | tr -d '[:space:]')

# Validate we got a numeric value
if [ -z "$DISK_USAGE" ] || ! [[ "$DISK_USAGE" =~ ^-?[0-9]+$ ]]; then
    echo "Invalid disk usage value: '$DISK_USAGE', skipping"
    sleep 10
    exit 0
fi

# Skip if metric unavailable
if [ "$DISK_USAGE" -eq -1 ]; then
    echo "Disk usage metric unavailable (-1), skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson usage "$DISK_USAGE" --argjson limit "$DISK_LIMIT" \
    '{disk_usage_bytes: $usage, limit_bytes: $limit}')

if [ "$DISK_USAGE" -lt "$DISK_LIMIT" ]; then
    echo "PASS: Disk usage ${DISK_USAGE} < ${DISK_LIMIT} (5GB)"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: Disk usage ${DISK_USAGE} >= ${DISK_LIMIT} (5GB)"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
