#!/usr/bin/env bash

# Parallel driver: Validator survives protocol confusion attacks on all ports
# Sends well-formed messages from OTHER protocols (TLS, SSH, SMTP, HTTP, DNS, STUN)
# to all validator ports and verifies the validator doesn't crash afterward.
# Tests how the validator's ADNL/TL-B parsers handle structured-but-wrong-protocol data —
# the exact traffic internet-facing validators receive from port scanners and confused clients.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"
ASSERTION_NAME="Validator survives protocol confusion attacks on all ports"
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

# Precondition: all 3 ports must be reachable
if ! nc -z -w 2 -u "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null; then
    echo "UDP port ${UDP_PORT} not reachable, skipping"; exit 0
fi
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null; then
    echo "TCP port ${CONSOLE_PORT} not reachable, skipping"; exit 0
fi
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    echo "TCP port ${LITE_PORT} not reachable, skipping"; exit 0
fi

echo "Sending protocol confusion attacks to ${VALIDATOR_HOST}..."

PACKETS_SENT=0

# === TCP attacks — send to both console (30002) and liteserver (30003) ===
for PORT in "${CONSOLE_PORT}" "${LITE_PORT}"; do
    # (a) TLS 1.2 ClientHello — real TLS record header + random client_random + minimal cipher suite
    { printf '\x16\x03\x01\x00\xf1\x01\x00\x00\xed\x03\x03'; dd if=/dev/urandom bs=32 count=1 2>/dev/null; printf '\x00\x00\x02\x00\xff\x01\x00\x00\xc0'; } | nc -w1 "${VALIDATOR_HOST}" "${PORT}" 2>/dev/null || true
    PACKETS_SENT=$((PACKETS_SENT + 1))

    # (b) SSH-2.0 banner
    printf 'SSH-2.0-OpenSSH_9.0\r\n' | nc -w1 "${VALIDATOR_HOST}" "${PORT}" 2>/dev/null || true
    PACKETS_SENT=$((PACKETS_SENT + 1))

    # (c) SMTP EHLO
    printf 'EHLO scanner.example.com\r\n' | nc -w1 "${VALIDATOR_HOST}" "${PORT}" 2>/dev/null || true
    PACKETS_SENT=$((PACKETS_SENT + 1))

    # (d) HTTP POST (different from existing HTTP GET in tcp_fuzz_liteserver)
    printf 'POST /jsonrpc HTTP/1.1\r\nHost: validator\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}' | nc -w1 "${VALIDATOR_HOST}" "${PORT}" 2>/dev/null || true
    PACKETS_SENT=$((PACKETS_SENT + 1))
done

# === UDP attacks — send to UDP port 30001 ===
# (e) DNS A query for example.com
printf '\xaa\xbb\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01' | nc -w1 -u "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null || true
PACKETS_SENT=$((PACKETS_SENT + 1))

# (f) STUN binding request (magic cookie + random transaction ID)
{ printf '\x00\x01\x00\x00\x21\x12\xa4\x42'; dd if=/dev/urandom bs=12 count=1 2>/dev/null; } | nc -w1 -u "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null || true
PACKETS_SENT=$((PACKETS_SENT + 1))

echo "Sent $PACKETS_SENT protocol confusion payloads. Waiting 2 seconds for processing..."
sleep 2

# Verify validator is still alive after attack
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
if ! nc -z -w 2 -u "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null; then
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
    --argjson packets "$PACKETS_SENT" \
    --argjson survived "$SURVIVED" \
    --arg checks "${CHECKS_DETAIL:-all_passed}" \
    '{packets_sent: $packets, survived: $survived, post_attack_checks: $checks}')

if [ "$SURVIVED" = "true" ]; then
    echo "PASS: Validator survived $PACKETS_SENT protocol confusion payloads on all ports"
    sdk_sometimes true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Validator appears unhealthy after protocol confusion attack: $CHECKS_DETAIL"
    sdk_sometimes false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
