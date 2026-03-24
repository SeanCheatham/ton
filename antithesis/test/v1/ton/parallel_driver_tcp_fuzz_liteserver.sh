#!/usr/bin/env bash

# Parallel driver: Validator survives malformed TCP traffic on liteserver port
# Sends random/malformed TCP data to the validator's liteserver port (30003)
# and verifies the validator doesn't crash afterward.
# Tests ADNL-over-TCP protocol parsing resilience — liteserver is internet-facing.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
LITE_PORT="${LITE_PORT:-30003}"
ASSERTION_NAME="Validator survives malformed TCP traffic on liteserver port"
HEARTBEAT_MAX_AGE=60

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

# Precondition: TCP liteserver port must be reachable before we start fuzzing
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    echo "TCP port ${LITE_PORT} not reachable, skipping"
    exit 0
fi

echo "Sending malformed TCP data to ${VALIDATOR_HOST}:${LITE_PORT} (liteserver)..."

PACKETS_SENT=0

# (a) 4 bytes of random data
dd if=/dev/urandom bs=4 count=1 2>/dev/null | nc -w1 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null || true
PACKETS_SENT=$((PACKETS_SENT + 1))

# (b) 256 bytes of zeros
dd if=/dev/zero bs=256 count=1 2>/dev/null | nc -w1 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null || true
PACKETS_SENT=$((PACKETS_SENT + 1))

# (c) 1400 bytes of random data
dd if=/dev/urandom bs=1400 count=1 2>/dev/null | nc -w1 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null || true
PACKETS_SENT=$((PACKETS_SENT + 1))

# (d) Valid ADNL-over-TCP length prefix (4 bytes little-endian) followed by garbage
{ printf '\x00\x01\x00\x00'; dd if=/dev/urandom bs=256 count=1 2>/dev/null; } | nc -w1 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null || true
PACKETS_SENT=$((PACKETS_SENT + 1))

# (e) HTTP GET request (common port scan attempt)
printf 'GET / HTTP/1.1\r\nHost: %s\r\n\r\n' "${VALIDATOR_HOST}" | nc -w1 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null || true
PACKETS_SENT=$((PACKETS_SENT + 1))

echo "Sent $PACKETS_SENT malformed TCP payloads. Waiting 2 seconds for processing..."
sleep 2

# Verify validator is still alive after fuzzing
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
            CHECKS_DETAIL="heartbeat_stale_after_fuzz(${POST_AGE}s)"
        fi
    else
        SURVIVED=false
        CHECKS_DETAIL="heartbeat_invalid_after_fuzz"
    fi
else
    SURVIVED=false
    CHECKS_DETAIL="heartbeat_missing_after_fuzz"
fi

# Check 2: UDP port still reachable
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"
if ! nc -z -w 2 -u "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}udp_unreachable_after_fuzz"
fi

# Check 3: TCP console port still reachable
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}console_unreachable_after_fuzz"
fi

# Check 4: TCP liteserver port still reachable
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}liteserver_unreachable_after_fuzz"
fi

DETAILS=$(jq -cn \
    --argjson packets "$PACKETS_SENT" \
    --argjson survived "$SURVIVED" \
    --arg checks "${CHECKS_DETAIL:-all_passed}" \
    '{packets_sent: $packets, survived: $survived, post_fuzz_checks: $checks}')

if [ "$SURVIVED" = "true" ]; then
    echo "PASS: Validator survived $PACKETS_SENT malformed TCP payloads on liteserver port"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Validator appears unhealthy after receiving malformed TCP data on liteserver: $CHECKS_DETAIL"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
