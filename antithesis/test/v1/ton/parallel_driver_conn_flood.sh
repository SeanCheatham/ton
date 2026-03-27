#!/usr/bin/env bash

# Parallel driver: Validator survives TCP connection flood on all ports
# Opens 30+ simultaneous TCP connections to each TCP port (30002, 30003)
# to test connection table exhaustion resilience. After the flood, verifies
# heartbeat is still fresh and all 3 ports remain reachable.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"
ASSERTION_NAME="Validator survives TCP connection flood on all ports"
HEARTBEAT_MAX_AGE=60
CONN_COUNT=30

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

# Precondition: both TCP ports must be reachable
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    echo "TCP port ${LITE_PORT} not reachable, skipping"
    exit 0
fi
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null; then
    echo "TCP port ${CONSOLE_PORT} not reachable, skipping"
    exit 0
fi

echo "Opening ${CONN_COUNT} simultaneous TCP connections to liteserver port ${LITE_PORT}..."
for i in $(seq 1 "$CONN_COUNT"); do
    nc -w5 "${VALIDATOR_HOST}" "${LITE_PORT}" < /dev/null 2>/dev/null &
done

echo "Opening ${CONN_COUNT} simultaneous TCP connections to console port ${CONSOLE_PORT}..."
for i in $(seq 1 "$CONN_COUNT"); do
    nc -w5 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" < /dev/null 2>/dev/null &
done

TOTAL_CONNS=$((CONN_COUNT * 2))
echo "Opened ${TOTAL_CONNS} total connections. Waiting 3 seconds..."
sleep 3

# Kill any remaining background nc processes
kill $(jobs -p) 2>/dev/null || true
wait 2>/dev/null || true

echo "Waiting 2 seconds for validator to stabilize..."
sleep 2

# Verify validator is still alive after connection flood
SURVIVED=true
CHECKS_DETAIL=""

# Check 1: heartbeat still fresh
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        POST_AGE=$((NOW - HB_TS))
        if [ "$POST_AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            SURVIVED=false
            CHECKS_DETAIL="heartbeat_stale_after_flood(${POST_AGE}s)"
        fi
    else
        SURVIVED=false
        CHECKS_DETAIL="heartbeat_invalid_after_flood"
    fi
else
    SURVIVED=false
    CHECKS_DETAIL="heartbeat_missing_after_flood"
fi

# Check 2: UDP port still reachable
if ! nc -z -w 2 -u "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}udp_unreachable_after_flood"
fi

# Check 3: TCP console port still reachable
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}console_unreachable_after_flood"
fi

# Check 4: TCP liteserver port still reachable
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}liteserver_unreachable_after_flood"
fi

DETAILS=$(jq -cn \
    --argjson conns "$TOTAL_CONNS" \
    --argjson survived "$SURVIVED" \
    --arg checks "${CHECKS_DETAIL:-all_passed}" \
    '{connections_opened: $conns, survived: $survived, post_flood_checks: $checks}')

if [ "$SURVIVED" = "true" ]; then
    echo "PASS: Validator survived ${TOTAL_CONNS} simultaneous TCP connections"
    sdk_sometimes true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Validator unhealthy after TCP connection flood: $CHECKS_DETAIL"
    sdk_sometimes false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
