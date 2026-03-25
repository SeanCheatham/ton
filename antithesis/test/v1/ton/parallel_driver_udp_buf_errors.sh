#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator has no UDP buffer errors when healthy
# Reads /shared/validator_udp_buf_errors (RcvbufErrors:SndbufErrors from /proc/1/net/snmp)
# written by validator entrypoint heartbeat loop and asserts both counts are zero when
# the validator is healthy. Non-zero counts indicate silent UDP packet loss due to
# kernel buffer overflows — critical for TON's ADNL protocol on UDP:30001.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"

if [ ! -f /shared/validator_udp_buf_errors ]; then
    echo "UDP buffer errors file not present yet, skipping"
    sleep 10
    exit 0
fi

UDP_BUF_ERRORS=$(cat /shared/validator_udp_buf_errors 2>/dev/null || echo "-1:-1")

if [ "$UDP_BUF_ERRORS" = "-1:-1" ]; then
    echo "UDP buffer errors data unavailable, skipping"
    sleep 10
    exit 0
fi

RCVBUF_ERRORS=$(echo "$UDP_BUF_ERRORS" | cut -d: -f1)
SNDBUF_ERRORS=$(echo "$UDP_BUF_ERRORS" | cut -d: -f2)

if ! [[ "$RCVBUF_ERRORS" =~ ^[0-9]+$ ]] || ! [[ "$SNDBUF_ERRORS" =~ ^[0-9]+$ ]]; then
    echo "Invalid UDP buffer errors values: $UDP_BUF_ERRORS, skipping"
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

if [ "$RCVBUF_ERRORS" -gt 0 ] || [ "$SNDBUF_ERRORS" -gt 0 ]; then
    DETAILS=$(jq -cn --argjson rcv "$RCVBUF_ERRORS" --argjson snd "$SNDBUF_ERRORS" '{rcvbuf_errors: $rcv, sndbuf_errors: $snd}')
    sdk_always false "Validator has no UDP buffer errors when healthy" "$DETAILS"
else
    sdk_always true "Validator has no UDP buffer errors when healthy" '{"rcvbuf_errors":0,"sndbuf_errors":0}'
fi

sleep 10
exit 0
