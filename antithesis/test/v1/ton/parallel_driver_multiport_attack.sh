#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator survives simultaneous multi-port adversarial traffic
# Attacks all 3 ports (UDP 30001, TCP 30002, TCP 30003) in parallel.
# Tests shared resource contention under coordinated attack — event loop,
# memory allocator, and thread pool all stressed simultaneously.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"
ASSERTION_NAME="Validator survives simultaneous multi-port adversarial traffic"
HEARTBEAT_MAX_AGE=60

echo "Checking preconditions for multi-port attack test..."

# Precondition: heartbeat must be fresh
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s), skipping"
            sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"heartbeat_stale"}'
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"
        sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"heartbeat_invalid"}'
        exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"heartbeat_missing"}'
    exit 0
fi

# Precondition: all 3 ports must be reachable
if ! nc -z -w 2 -u "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null; then
    echo "UDP port ${VALIDATOR_PORT} not reachable, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"udp_not_reachable"}'
    exit 0
fi
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null; then
    echo "TCP console port ${CONSOLE_PORT} not reachable, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"console_not_reachable"}'
    exit 0
fi
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    echo "TCP liteserver port ${LITE_PORT} not reachable, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"liteserver_not_reachable"}'
    exit 0
fi

echo "Launching simultaneous multi-port attack..."

UDP_PACKETS=20
TCP_CONSOLE_CONNS=10
TCP_LITE_CONNS=10

# Attack subshell 1: UDP flood on port 30001
(
    for i in $(seq 1 $UDP_PACKETS); do
        case $((i % 4)) in
            0) BS=4 ;;
            1) BS=32 ;;
            2) BS=256 ;;
            3) BS=1400 ;;
        esac
        dd if=/dev/urandom bs=$BS count=1 2>/dev/null | nc -u -w1 "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null || true
    done
) &
UDP_PID=$!

# Attack subshell 2: TCP garbage on console port 30002
(
    for i in $(seq 1 $TCP_CONSOLE_CONNS); do
        dd if=/dev/urandom bs=256 count=1 2>/dev/null | nc -w1 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null || true
    done
) &
CONSOLE_PID=$!

# Attack subshell 3: TCP garbage on liteserver port 30003
(
    for i in $(seq 1 $TCP_LITE_CONNS); do
        dd if=/dev/urandom bs=256 count=1 2>/dev/null | nc -w1 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null || true
    done
) &
LITE_PID=$!

# Wait for all attack subshells to complete
wait $UDP_PID 2>/dev/null || true
wait $CONSOLE_PID 2>/dev/null || true
wait $LITE_PID 2>/dev/null || true

echo "Attack complete. Waiting 3 seconds for validator to process/recover..."
sleep 3

# Post-attack checks
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
            CHECKS_DETAIL="heartbeat_stale_after_attack(${POST_AGE}s)"
        fi
    else
        SURVIVED=false
        CHECKS_DETAIL="heartbeat_invalid_after_attack"
    fi
else
    SURVIVED=false
    CHECKS_DETAIL="heartbeat_missing_after_attack"
fi

# Check 2: UDP port still reachable
if ! nc -z -w 2 -u "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}udp_unreachable_after_attack"
fi

# Check 3: TCP console port still reachable
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}console_unreachable_after_attack"
fi

# Check 4: TCP liteserver port still reachable
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}liteserver_unreachable_after_attack"
fi

DETAILS=$(jq -cn \
    --argjson udp_packets "$UDP_PACKETS" \
    --argjson tcp_console_conns "$TCP_CONSOLE_CONNS" \
    --argjson tcp_lite_conns "$TCP_LITE_CONNS" \
    --argjson survived "$SURVIVED" \
    --arg checks "${CHECKS_DETAIL:-all_passed}" \
    '{udp_packets: $udp_packets, tcp_console_conns: $tcp_console_conns, tcp_lite_conns: $tcp_lite_conns, survived: $survived, post_attack_checks: $checks}')

if [ "$SURVIVED" = "true" ]; then
    echo "PASS: Validator survived simultaneous multi-port attack"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Validator appears unhealthy after multi-port attack: $CHECKS_DETAIL"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
