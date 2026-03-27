#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator listening socket accept queue is bounded
# Reads /shared/validator_accept_queue (written by validator entrypoint heartbeat loop)
# and asserts the accept queue depth stays below 128 when the validator is healthy.
# A growing accept queue means the validator isn't calling accept() fast enough,
# which is a leading indicator of connection handling degradation invisible to port probes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ACCEPT_Q_LIMIT=128
ASSERTION_NAME="Validator listening socket accept queue is bounded"

sdk_catalog_always "${ASSERTION_NAME}"

echo "Checking accept queue depth..."

# Precondition: heartbeat must be fresh
HEARTBEAT_MAX_AGE=60
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s), skipping"
            sleep 10
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"; sleep 10; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"; sleep 10; exit 0
fi

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

# Read accept queue depth from shared volume
if [ ! -f /shared/validator_accept_queue ]; then
    echo "Accept queue file not present yet, skipping"
    sleep 10
    exit 0
fi

ACCEPT_Q_MAX=$(cat /shared/validator_accept_queue 2>/dev/null || true)
ACCEPT_Q_MAX=$(echo "$ACCEPT_Q_MAX" | tr -d '[:space:]')

# Validate we got a numeric value
if [ -z "$ACCEPT_Q_MAX" ] || ! [[ "$ACCEPT_Q_MAX" =~ ^[0-9]+$ ]]; then
    echo "Invalid accept queue value: '$ACCEPT_Q_MAX', skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson depth "$ACCEPT_Q_MAX" --argjson limit "$ACCEPT_Q_LIMIT" \
    '{accept_queue_depth: $depth, limit: $limit}')

if [ "$ACCEPT_Q_MAX" -lt "$ACCEPT_Q_LIMIT" ]; then
    echo "PASS: Accept queue depth ${ACCEPT_Q_MAX} < ${ACCEPT_Q_LIMIT}"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: Accept queue depth ${ACCEPT_Q_MAX} >= ${ACCEPT_Q_LIMIT}"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
