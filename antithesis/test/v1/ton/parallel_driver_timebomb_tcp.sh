#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator survives time-bomb TCP connections
# Opens TCP connections that initially send plausible-looking data (TL length prefix bytes)
# with pauses between bytes, then abruptly blast random garbage mid-stream.
# This simulates a sophisticated attacker who establishes a session then corrupts it.
# Verifies the validator handles mid-stream corruption without crashing or leaking resources.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"
ASSERTION_NAME="Validator survives time-bomb TCP connections"
HEARTBEAT_MAX_AGE=60
TIMEBOMB_CONNS_PER_PORT=5

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

# Attack phase: time-bomb connections to liteserver port
echo "Spawning ${TIMEBOMB_CONNS_PER_PORT} time-bomb connections to liteserver port ${LITE_PORT}..."
for i in $(seq 1 "$TIMEBOMB_CONNS_PER_PORT"); do
    (
        # Send 4 bytes that look like a TL length prefix, 1 second apart (legitimate phase)
        { printf '\x00\x00\x00\x04'; sleep 1; printf '\x00'; sleep 1; printf '\x00'; sleep 1; printf '\x00'; sleep 1; \
          head -c 64 /dev/urandom; } | nc -w 15 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null || true
    ) &
done

# Attack phase: time-bomb connections to console port
echo "Spawning ${TIMEBOMB_CONNS_PER_PORT} time-bomb connections to console port ${CONSOLE_PORT}..."
for i in $(seq 1 "$TIMEBOMB_CONNS_PER_PORT"); do
    (
        { printf '\x00\x00\x00\x04'; sleep 1; printf '\x00'; sleep 1; printf '\x00'; sleep 1; printf '\x00'; sleep 1; \
          head -c 64 /dev/urandom; } | nc -w 15 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null || true
    ) &
done

TOTAL_CONNS=$((TIMEBOMB_CONNS_PER_PORT * 2))
echo "Spawned ${TOTAL_CONNS} time-bomb connections. Waiting 10 seconds..."
sleep 10

# Kill any remaining background processes
kill $(jobs -p) 2>/dev/null || true
wait 2>/dev/null || true

echo "Waiting 2 seconds for validator to stabilize..."
sleep 2

# Verify validator is still alive after time-bomb attack
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
            CHECKS_DETAIL="heartbeat_stale_after_timebomb(${POST_AGE}s)"
        fi
    else
        SURVIVED=false
        CHECKS_DETAIL="heartbeat_invalid_after_timebomb"
    fi
else
    SURVIVED=false
    CHECKS_DETAIL="heartbeat_missing_after_timebomb"
fi

# Check 2: UDP port still reachable
if ! nc -z -w 2 -u "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}udp_unreachable_after_timebomb"
fi

# Check 3: TCP console port still reachable
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}console_unreachable_after_timebomb"
fi

# Check 4: TCP liteserver port still reachable
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}liteserver_unreachable_after_timebomb"
fi

DETAILS=$(jq -cn \
    --argjson conns "$TOTAL_CONNS" \
    --argjson per_port "$TIMEBOMB_CONNS_PER_PORT" \
    --argjson survived "$SURVIVED" \
    --arg checks "${CHECKS_DETAIL:-all_passed}" \
    '{timebomb_connections: $conns, per_port: $per_port, survived: $survived, post_timebomb_checks: $checks}')

if [ "$SURVIVED" = "true" ]; then
    echo "PASS: Validator survived ${TOTAL_CONNS} time-bomb TCP connections"
    sdk_sometimes true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Validator unhealthy after time-bomb TCP connections: $CHECKS_DETAIL"
    sdk_sometimes false "$ASSERTION_NAME" "$DETAILS"
fi

sleep 5
exit 0
