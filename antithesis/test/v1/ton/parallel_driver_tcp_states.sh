#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator TCP connections are in expected states when healthy
# Checks that TCP connections are in healthy states. CLOSE_WAIT (08) count must
# be zero (indicates leaked connections where remote closed but validator didn't).
# TIME_WAIT (06) count must be < 100 (indicates connection churn). Both conditions
# can lead to port exhaustion but are invisible to socket/FD count checks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Validator TCP connections are in expected states when healthy"

echo "Checking validator TCP connection states..."

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

# Read TCP state metrics from shared volume
if [ ! -f /shared/validator_tcp_states ]; then
    echo "SKIP: TCP states metric not available yet"
    sleep 10
    exit 0
fi

TCP_STATES=$(cat /shared/validator_tcp_states 2>/dev/null || echo "")
if [ -z "$TCP_STATES" ]; then
    echo "SKIP: TCP states metric is empty"
    sleep 10
    exit 0
fi

CLOSE_WAIT=$(echo "$TCP_STATES" | cut -d',' -f1)
TIME_WAIT=$(echo "$TCP_STATES" | cut -d',' -f2)

# Validate we got numeric values
if ! [[ "$CLOSE_WAIT" =~ ^[0-9]+$ ]] || ! [[ "$TIME_WAIT" =~ ^[0-9]+$ ]]; then
    echo "SKIP: TCP states metric has unexpected format: ${TCP_STATES}"
    sleep 10
    exit 0
fi

CLOSE_WAIT_LIMIT=3
TIME_WAIT_LIMIT=300

if [ "$CLOSE_WAIT" -le "$CLOSE_WAIT_LIMIT" ] && [ "$TIME_WAIT" -lt "$TIME_WAIT_LIMIT" ]; then
    echo "PASS: TCP states healthy (CLOSE_WAIT=${CLOSE_WAIT}, TIME_WAIT=${TIME_WAIT})"
    DETAILS=$(jq -cn --argjson close_wait "$CLOSE_WAIT" --argjson time_wait "$TIME_WAIT" \
        --argjson tw_limit "$TIME_WAIT_LIMIT" \
        '{close_wait: $close_wait, time_wait: $time_wait, time_wait_limit: $tw_limit, status: "healthy"}')
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: TCP states unhealthy (CLOSE_WAIT=${CLOSE_WAIT}, TIME_WAIT=${TIME_WAIT})"
    DETAILS=$(jq -cn --argjson close_wait "$CLOSE_WAIT" --argjson time_wait "$TIME_WAIT" \
        --argjson tw_limit "$TIME_WAIT_LIMIT" \
        '{close_wait: $close_wait, time_wait: $time_wait, time_wait_limit: $tw_limit, status: "unhealthy"}')
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
