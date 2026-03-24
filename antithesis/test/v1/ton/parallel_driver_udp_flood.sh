#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator survives rapid mixed UDP flood
# Sends 50 rapid UDP packets of varying sizes (0, 1, 32, 256, 1400, 8192 bytes)
# to the ADNL port (30001) with no delays between packets. Tests sustained
# high-throughput packet processing resilience. Different from existing ADNL fuzz
# (5 packets with implicit delays) and oversized UDP (single large packet).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"
ASSERTION_NAME="Validator survives rapid mixed UDP flood"
HEARTBEAT_MAX_AGE=60

echo "Checking preconditions for UDP flood test..."

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

# Precondition: UDP port must be reachable
if ! nc -z -w 2 -u "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null; then
    echo "UDP port ${VALIDATOR_PORT} not reachable, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"udp_not_reachable"}'
    exit 0
fi

echo "Sending 50 rapid mixed-size UDP packets to ${VALIDATOR_HOST}:${VALIDATOR_PORT}..."

PACKETS_SENT=0
for i in $(seq 1 50); do
    case $((i % 6)) in
        0)
            # Empty packet
            printf '' | nc -u -w1 "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null &
            ;;
        1)
            # 1 byte
            dd if=/dev/urandom bs=1 count=1 2>/dev/null | nc -u -w1 "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null &
            ;;
        2)
            # 32 bytes (ADNL header size)
            dd if=/dev/urandom bs=32 count=1 2>/dev/null | nc -u -w1 "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null &
            ;;
        3)
            # 256 bytes (partial handshake)
            dd if=/dev/urandom bs=256 count=1 2>/dev/null | nc -u -w1 "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null &
            ;;
        4)
            # 1400 bytes (near MTU)
            dd if=/dev/urandom bs=1400 count=1 2>/dev/null | nc -u -w1 "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null &
            ;;
        5)
            # 8192 bytes (oversized)
            dd if=/dev/urandom bs=8192 count=1 2>/dev/null | nc -u -w1 "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null &
            ;;
    esac
    PACKETS_SENT=$((PACKETS_SENT + 1))
done

# Wait for all background sends to complete
wait 2>/dev/null || true

echo "Sent $PACKETS_SENT packets. Waiting 3 seconds for processing..."
sleep 3

# Post-flood checks: verify validator is still alive
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
    --argjson packets "$PACKETS_SENT" \
    --argjson survived "$SURVIVED" \
    --arg checks "${CHECKS_DETAIL:-all_passed}" \
    '{packets_sent: $packets, survived: $survived, post_flood_checks: $checks}')

if [ "$SURVIVED" = "true" ]; then
    echo "PASS: Validator survived $PACKETS_SENT rapid mixed-size UDP packets"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Validator appears unhealthy after UDP flood: $CHECKS_DETAIL"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
