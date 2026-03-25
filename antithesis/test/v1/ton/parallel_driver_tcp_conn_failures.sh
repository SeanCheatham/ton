#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator has no TCP connection failures when healthy
# Reads /shared/validator_tcp_conn_failures (AttemptFails:EstabResets from /proc/1/net/snmp)
# written by validator entrypoint heartbeat loop and asserts both counts are zero when
# the validator is healthy. Non-zero counts indicate failed connection handshakes or
# forcefully reset established connections — critical for TON's ADNL peer communication.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"

if [ ! -f /shared/validator_tcp_conn_failures ]; then
    echo "TCP connection failures file not present yet, skipping"
    sleep 10
    exit 0
fi

RAW=$(cat /shared/validator_tcp_conn_failures 2>/dev/null || echo "-1:-1")

if [ "$RAW" = "-1:-1" ]; then
    echo "TCP connection failures data unavailable, skipping"
    sleep 10
    exit 0
fi

ATTEMPT_FAILS=$(echo "$RAW" | cut -d: -f1)
ESTAB_RESETS=$(echo "$RAW" | cut -d: -f2)

if ! [[ "$ATTEMPT_FAILS" =~ ^[0-9]+$ ]] || ! [[ "$ESTAB_RESETS" =~ ^[0-9]+$ ]]; then
    echo "Invalid TCP connection failure values: $RAW, skipping"
    sleep 10
    exit 0
fi

# Check if all 3 ports are reachable
udp_up=false
console_up=false
lite_up=false
nc -z -w 1 -u "${VALIDATOR_HOST}" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "${VALIDATOR_HOST}" 30002 2>/dev/null && console_up=true
nc -z -w 1 "${VALIDATOR_HOST}" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "Validator not fully healthy, skipping assertion"
    sleep 10
    exit 0
fi

if [ "$ATTEMPT_FAILS" -gt 0 ] || [ "$ESTAB_RESETS" -gt 0 ]; then
    DETAILS=$(jq -cn --argjson af "$ATTEMPT_FAILS" --argjson er "$ESTAB_RESETS" '{attempt_fails: $af, estab_resets: $er}')
    sdk_always false "Validator has no TCP connection failures when healthy" "$DETAILS"
else
    sdk_always true "Validator has no TCP connection failures when healthy" '{"attempt_fails":0,"estab_resets":0}'
fi

sleep 10
exit 0
