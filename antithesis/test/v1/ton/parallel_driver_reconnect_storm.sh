#!/usr/bin/env bash

# Parallel driver: Validator survives rapid TCP reconnection storm
# Rapidly opens and closes 100 TCP connections on each TCP port to test
# connection cleanup/teardown paths under extreme churn. Tests for
# use-after-free, FD leaks, and connection state corruption.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"
ASSERTION_NAME="Validator survives rapid TCP reconnection storm"
HEARTBEAT_MAX_AGE=60
CONNS_PER_PORT=100

sleep 10

# Precondition: heartbeat must be fresh
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s), skipping"
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"; exit 0
fi

# Precondition: all 3 ports must be reachable
if ! nc -z -w 2 -u "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null; then
    echo "UDP port not reachable, skipping"; exit 0
fi
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null; then
    echo "Console port not reachable, skipping"; exit 0
fi
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    echo "Liteserver port not reachable, skipping"; exit 0
fi

# Storm phase: rapidly connect and disconnect on console port
echo "Rapid reconnection storm on console port ${CONSOLE_PORT} (${CONNS_PER_PORT} connections)..."
for i in $(seq 1 "$CONNS_PER_PORT"); do
    nc -z -w 1 "$VALIDATOR_HOST" "$CONSOLE_PORT" 2>/dev/null &
done
wait 2>/dev/null || true

# Storm phase: rapidly connect and disconnect on liteserver port
echo "Rapid reconnection storm on liteserver port ${LITE_PORT} (${CONNS_PER_PORT} connections)..."
for i in $(seq 1 "$CONNS_PER_PORT"); do
    nc -z -w 1 "$VALIDATOR_HOST" "$LITE_PORT" 2>/dev/null &
done
wait 2>/dev/null || true

echo "Storm complete. Waiting 3 seconds for validator to settle..."
sleep 3

# Verification phase
CHECKS_PASSED=0
CHECKS_TOTAL=4
HB_FRESH=false
UDP_OK=false
CONSOLE_OK=false
LITE_OK=false

# Check 1: heartbeat still fresh
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        POST_AGE=$((NOW - HB_TS))
        if [ "$POST_AGE" -le "$HEARTBEAT_MAX_AGE" ]; then
            CHECKS_PASSED=$((CHECKS_PASSED + 1))
            HB_FRESH=true
        fi
    fi
fi

# Check 2: UDP port reachable
if nc -z -w 2 -u "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null; then
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    UDP_OK=true
fi

# Check 3: Console port reachable
if nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null; then
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    CONSOLE_OK=true
fi

# Check 4: Liteserver port reachable
if nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    LITE_OK=true
fi

DETAILS=$(jq -cn \
    --argjson conns "$CONNS_PER_PORT" \
    --argjson passed "$CHECKS_PASSED" \
    --argjson total "$CHECKS_TOTAL" \
    --argjson hb "$HB_FRESH" \
    --argjson udp "$UDP_OK" \
    --argjson console "$CONSOLE_OK" \
    --argjson lite "$LITE_OK" \
    '{connections_per_port: $conns, ports_tested: [30002, 30003], post_storm_checks_passed: $passed, post_storm_checks_total: $total, heartbeat_fresh: $hb, udp_reachable: $udp, console_reachable: $console, liteserver_reachable: $lite}')

if [ "$CHECKS_PASSED" -eq "$CHECKS_TOTAL" ]; then
    echo "PASS: Validator survived rapid reconnection storm (${CONNS_PER_PORT} conns/port)"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Validator unhealthy after reconnection storm (${CHECKS_PASSED}/${CHECKS_TOTAL} checks passed)"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

sleep 10
exit 0
