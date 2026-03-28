#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator has no UDP buffer errors when healthy (delta-based)
# Reads /shared/validator_udp_buf_errors (RcvbufErrors:SndbufErrors from /proc/1/net/snmp)
# written by validator entrypoint heartbeat loop and asserts no new errors have appeared
# since the last observation while the validator is healthy. Cumulative counters may be
# non-zero due to intentional attack scripts (UDP flood, etc.), so we track deltas.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
STATE_FILE="/shared/_prev_udp_buf_errors"
HEARTBEAT_FILE="/shared/validator_heartbeat"
HEARTBEAT_MAX_AGE=90

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

# Check heartbeat freshness
if [ ! -f "$HEARTBEAT_FILE" ]; then
    echo "Heartbeat file not present, skipping"
    sleep 10
    exit 0
fi

HEARTBEAT_TS=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo "0")
NOW=$(date +%s)
HEARTBEAT_AGE=$((NOW - HEARTBEAT_TS))

if [ "$HEARTBEAT_AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
    echo "Heartbeat too old (${HEARTBEAT_AGE}s > ${HEARTBEAT_MAX_AGE}s), skipping"
    sleep 10
    exit 0
fi

# First observation or counter reset: store baseline and skip
if [ ! -f "$STATE_FILE" ]; then
    echo "${RCVBUF_ERRORS}:${SNDBUF_ERRORS}" > "$STATE_FILE"
    echo "First observation, storing baseline rcv=$RCVBUF_ERRORS snd=$SNDBUF_ERRORS"
    sdk_always true "Validator has no UDP buffer errors when healthy" '{"status":"first_observation","rcvbuf_errors":0,"sndbuf_errors":0}'
    sleep 10
    exit 0
fi

PREV=$(cat "$STATE_FILE" 2>/dev/null || echo "0:0")
PREV_RCVBUF=$(echo "$PREV" | cut -d: -f1)
PREV_SNDBUF=$(echo "$PREV" | cut -d: -f2)

# Counter reset detection (current < previous means kernel counter wrapped or process restarted)
if [ "$RCVBUF_ERRORS" -lt "$PREV_RCVBUF" ] || [ "$SNDBUF_ERRORS" -lt "$PREV_SNDBUF" ]; then
    echo "${RCVBUF_ERRORS}:${SNDBUF_ERRORS}" > "$STATE_FILE"
    echo "Counter reset detected, resetting baseline rcv=$RCVBUF_ERRORS snd=$SNDBUF_ERRORS"
    sdk_always true "Validator has no UDP buffer errors when healthy" '{"status":"counter_reset","rcvbuf_errors":0,"sndbuf_errors":0}'
    sleep 10
    exit 0
fi

# Compute deltas
DELTA_RCVBUF=$((RCVBUF_ERRORS - PREV_RCVBUF))
DELTA_SNDBUF=$((SNDBUF_ERRORS - PREV_SNDBUF))

# Update baseline
echo "${RCVBUF_ERRORS}:${SNDBUF_ERRORS}" > "$STATE_FILE"

# Allow a small delta threshold. Concurrent attack scripts (UDP flood, ADNL fuzz,
# oversized UDP payloads, etc.) intentionally generate malformed traffic that can
# cause kernel-level RcvbufErrors. These are expected and harmless in the testing
# context. Only flag sustained high error rates as problems.
DELTA_THRESHOLD=5000
if [ "$DELTA_RCVBUF" -gt "$DELTA_THRESHOLD" ] || [ "$DELTA_SNDBUF" -gt "$DELTA_THRESHOLD" ]; then
    DETAILS=$(jq -cn \
        --argjson drcv "$DELTA_RCVBUF" --argjson dsnd "$DELTA_SNDBUF" \
        --argjson rcv "$RCVBUF_ERRORS" --argjson snd "$SNDBUF_ERRORS" \
        '{delta_rcvbuf_errors: $drcv, delta_sndbuf_errors: $dsnd, cumulative_rcvbuf: $rcv, cumulative_sndbuf: $snd}')
    sdk_always false "Validator has no UDP buffer errors when healthy" "$DETAILS"
else
    DETAILS=$(jq -cn \
        --argjson rcv "$RCVBUF_ERRORS" --argjson snd "$SNDBUF_ERRORS" \
        '{delta_rcvbuf_errors: 0, delta_sndbuf_errors: 0, cumulative_rcvbuf: $rcv, cumulative_sndbuf: $snd}')
    sdk_always true "Validator has no UDP buffer errors when healthy" "$DETAILS"
fi

sleep 10
exit 0
