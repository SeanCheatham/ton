#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Network socket count is bounded
# Reads /shared/validator_sock_count (written by validator entrypoint heartbeat loop)
# and asserts the TCP socket count stays below 1000 when the validator is healthy.
# Catches connection leaks and TIME_WAIT socket accumulation from network partitions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

SOCK_LIMIT=1000
ASSERTION_NAME="Network socket count is bounded"

sdk_catalog_always "${ASSERTION_NAME}"

echo "Checking network socket count..."

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

# Read socket count from shared volume
if [ ! -f /shared/validator_sock_count ]; then
    echo "Socket count file not present yet, skipping"
    sleep 10
    exit 0
fi

SOCK_COUNT=$(cat /shared/validator_sock_count 2>/dev/null | tr -d '[:space:]')

# Validate we got a numeric value
if [ -z "$SOCK_COUNT" ] || ! [[ "$SOCK_COUNT" =~ ^-?[0-9]+$ ]]; then
    echo "Invalid socket count value: '$SOCK_COUNT', skipping"
    sleep 10
    exit 0
fi

# Skip if metric unavailable
if [ "$SOCK_COUNT" -eq -1 ]; then
    echo "Socket count metric unavailable (-1), skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson count "$SOCK_COUNT" --argjson limit "$SOCK_LIMIT" \
    '{sock_count: $count, sock_limit: $limit}')

if [ "$SOCK_COUNT" -lt "$SOCK_LIMIT" ]; then
    echo "PASS: TCP socket count ${SOCK_COUNT} < ${SOCK_LIMIT}"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: TCP socket count ${SOCK_COUNT} >= ${SOCK_LIMIT}"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
