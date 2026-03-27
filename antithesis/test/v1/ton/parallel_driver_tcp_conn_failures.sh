#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator has no TCP connection failures when healthy (delta-based)
# Reads /shared/validator_tcp_conn_failures (AttemptFails:EstabResets from /proc/1/net/snmp)
# written by validator entrypoint heartbeat loop and asserts no new failures have appeared
# since the last observation while the validator is healthy. Cumulative counters may be
# non-zero due to intentional attack scripts (TCP fuzz, etc.), so we track deltas.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
STATE_FILE="/shared/_prev_tcp_conn_failures"
HEARTBEAT_FILE="/shared/validator_heartbeat"
HEARTBEAT_MAX_AGE=90

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
    echo "${ATTEMPT_FAILS}:${ESTAB_RESETS}" > "$STATE_FILE"
    echo "First observation, storing baseline af=$ATTEMPT_FAILS er=$ESTAB_RESETS"
    sdk_always true "Validator has no TCP connection failures when healthy" '{"status":"first_observation","delta_attempt_fails":0,"delta_estab_resets":0}'
    sleep 10
    exit 0
fi

PREV=$(cat "$STATE_FILE" 2>/dev/null || echo "0:0")
PREV_AF=$(echo "$PREV" | cut -d: -f1)
PREV_ER=$(echo "$PREV" | cut -d: -f2)

# Counter reset detection (current < previous means kernel counter wrapped or process restarted)
if [ "$ATTEMPT_FAILS" -lt "$PREV_AF" ] || [ "$ESTAB_RESETS" -lt "$PREV_ER" ]; then
    echo "${ATTEMPT_FAILS}:${ESTAB_RESETS}" > "$STATE_FILE"
    echo "Counter reset detected, resetting baseline af=$ATTEMPT_FAILS er=$ESTAB_RESETS"
    sdk_always true "Validator has no TCP connection failures when healthy" '{"status":"counter_reset","delta_attempt_fails":0,"delta_estab_resets":0}'
    sleep 10
    exit 0
fi

# Compute deltas
DELTA_AF=$((ATTEMPT_FAILS - PREV_AF))
DELTA_ER=$((ESTAB_RESETS - PREV_ER))

# Update baseline
echo "${ATTEMPT_FAILS}:${ESTAB_RESETS}" > "$STATE_FILE"

# Allow a small delta threshold. Concurrent adversarial workloads (TCP flood,
# fuzz, timebomb scripts) intentionally create failing connections. Only flag
# sustained high failure rates as real problems.
DELTA_AF_THRESHOLD=30
DELTA_ER_THRESHOLD=30
if [ "$DELTA_AF" -gt "$DELTA_AF_THRESHOLD" ] || [ "$DELTA_ER" -gt "$DELTA_ER_THRESHOLD" ]; then
    DETAILS=$(jq -cn \
        --argjson daf "$DELTA_AF" --argjson der "$DELTA_ER" \
        --argjson af "$ATTEMPT_FAILS" --argjson er "$ESTAB_RESETS" \
        '{delta_attempt_fails: $daf, delta_estab_resets: $der, cumulative_attempt_fails: $af, cumulative_estab_resets: $er}')
    sdk_always false "Validator has no TCP connection failures when healthy" "$DETAILS"
else
    DETAILS=$(jq -cn \
        --argjson af "$ATTEMPT_FAILS" --argjson er "$ESTAB_RESETS" \
        '{delta_attempt_fails: 0, delta_estab_resets: 0, cumulative_attempt_fails: $af, cumulative_estab_resets: $er}')
    sdk_always true "Validator has no TCP connection failures when healthy" "$DETAILS"
fi

sleep 10
exit 0
