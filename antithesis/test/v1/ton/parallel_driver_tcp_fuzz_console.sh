#!/usr/bin/env bash

# Parallel driver: Validator survives malformed TCP traffic on console port
# Sends random/malformed TCP data to the validator's console port (30002)
# and verifies the validator doesn't crash afterward.
# Tests TL-based console protocol parsing resilience.
# Completes adversarial coverage of all 3 network-facing ports.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
ASSERTION_NAME="Validator survives malformed TCP traffic on console port"
HEARTBEAT_MAX_AGE=60

# Precondition: heartbeat must be fresh
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
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

# Precondition: TCP console port must be reachable before we start fuzzing
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null; then
    echo "TCP port ${CONSOLE_PORT} not reachable, skipping"
    exit 0
fi

echo "Sending malformed TCP data to ${VALIDATOR_HOST}:${CONSOLE_PORT} (console)..."

PACKETS_SENT=0

# (a) 4 bytes of random data
dd if=/dev/urandom bs=4 count=1 2>/dev/null | nc -w1 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null || true
PACKETS_SENT=$((PACKETS_SENT + 1))

# (b) 256 bytes of zeros
dd if=/dev/zero bs=256 count=1 2>/dev/null | nc -w1 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null || true
PACKETS_SENT=$((PACKETS_SENT + 1))

# (c) 1400 bytes of random data
dd if=/dev/urandom bs=1400 count=1 2>/dev/null | nc -w1 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null || true
PACKETS_SENT=$((PACKETS_SENT + 1))

# (d) Single null byte
printf '\x00' | nc -w1 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null || true
PACKETS_SENT=$((PACKETS_SENT + 1))

# (e) HTTP GET request (common port scan attempt)
printf 'GET / HTTP/1.1\r\nHost: %s\r\n\r\n' "${VALIDATOR_HOST}" | nc -w1 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null || true
PACKETS_SENT=$((PACKETS_SENT + 1))

echo "Sent $PACKETS_SENT malformed TCP payloads. Waiting for validator to recover..."
sleep 5

# Helper: check port reachability with retries (bounded)
check_port_with_retry() {
    local host="$1" port="$2" proto="$3" max_retries=4 delay=2
    for i in $(seq 1 "$max_retries"); do
        if [ "$proto" = "udp" ]; then
            nc -z -w 2 -u "$host" "$port" 2>/dev/null && return 0
        else
            nc -z -w 2 "$host" "$port" 2>/dev/null && return 0
        fi
        [ "$i" -lt "$max_retries" ] && sleep "$delay"
    done
    return 1
}

# Verify validator is still alive after fuzzing
SURVIVED=true
CHECKS_DETAIL=""

# Check 1: heartbeat still fresh (with extended window for post-fuzz recovery)
POST_FUZZ_HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        POST_AGE=$((NOW - HB_TS))
        if [ "$POST_AGE" -gt "$POST_FUZZ_HEARTBEAT_MAX_AGE" ]; then
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

# Check 2: UDP port still reachable (with retries)
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"
if ! check_port_with_retry "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" "udp"; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}udp_unreachable_after_fuzz"
fi

# Check 3: TCP console port still reachable (with retries — most likely to be transiently down)
if ! check_port_with_retry "${VALIDATOR_HOST}" "${CONSOLE_PORT}" "tcp"; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}console_unreachable_after_fuzz"
fi

# Check 4: TCP liteserver port still reachable (with retries)
LITE_PORT="${LITE_PORT:-30003}"
if ! check_port_with_retry "${VALIDATOR_HOST}" "${LITE_PORT}" "tcp"; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}liteserver_unreachable_after_fuzz"
fi

DETAILS=$(jq -cn \
    --argjson packets "$PACKETS_SENT" \
    --argjson survived "$SURVIVED" \
    --arg checks "${CHECKS_DETAIL:-all_passed}" \
    '{packets_sent: $packets, survived: $survived, post_fuzz_checks: $checks}')

if [ "$SURVIVED" = "true" ]; then
    echo "PASS: Validator survived $PACKETS_SENT malformed TCP payloads on console port"
    sdk_sometimes true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Validator appears unhealthy after receiving malformed TCP data on console: $CHECKS_DETAIL"
    sdk_sometimes false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
