#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator survives empty UDP packets
# Sends zero-length UDP datagrams to the ADNL port. Empty packets can
# trigger off-by-one errors, null dereferences, or division-by-zero
# in packet length calculations. All other UDP tests send non-empty data.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator survives empty UDP packets"
VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"

# Precondition: heartbeat fresh
HEARTBEAT_FILE="/shared/validator_heartbeat"
if [[ ! -f "$HEARTBEAT_FILE" ]]; then
    echo "No heartbeat file yet, skipping"
    exit 0
fi
HB_TS=$(cat "$HEARTBEAT_FILE" 2>/dev/null || true)
HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
NOW=$(date +%s)
if ! [[ "$HB_TS" =~ ^[0-9]+$ ]]; then exit 0; fi
AGE=$((NOW - HB_TS))
if (( AGE > 30 )); then
    echo "Heartbeat stale (${AGE}s), skipping"
    exit 0
fi

# Precondition: all 3 ports reachable
udp_up=false; console_up=false; lite_up=false
nc -z -w 1 -u "$VALIDATOR_HOST" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30002 2>/dev/null && console_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "Validator not fully healthy before attack, skipping"
    exit 0
fi

echo "Sending empty UDP packets to ${VALIDATOR_HOST}:${VALIDATOR_PORT}..."

# Send 10 empty (zero-length) UDP datagrams
SENT=0
for i in $(seq 1 10); do
    echo -n "" | nc -u -w 1 "$VALIDATOR_HOST" "$VALIDATOR_PORT" 2>/dev/null || true
    SENT=$((SENT + 1))
done
echo "Sent $SENT empty UDP packets"

# Brief wait for any delayed impact
sleep 2

# Verify validator survived
SURVIVED=true
CHECKS_DETAIL=""

# Check heartbeat still fresh
HB_TS2=$(cat "$HEARTBEAT_FILE" 2>/dev/null | tr -d '[:space:]' || echo "0")
NOW2=$(date +%s)
AGE2=$((NOW2 - HB_TS2))
if (( AGE2 > 60 )); then
    SURVIVED=false
    CHECKS_DETAIL="heartbeat_stale"
fi

# Check all ports still reachable
udp_up2=false; console_up2=false; lite_up2=false
nc -z -w 1 -u "$VALIDATOR_HOST" 30001 2>/dev/null && udp_up2=true
nc -z -w 1 "$VALIDATOR_HOST" 30002 2>/dev/null && console_up2=true
nc -z -w 1 "$VALIDATOR_HOST" 30003 2>/dev/null && lite_up2=true

if [[ "$udp_up2" != "true" ]]; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}udp_down"
fi
if [[ "$console_up2" != "true" ]]; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}console_down"
fi
if [[ "$lite_up2" != "true" ]]; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}lite_down"
fi

DETAILS=$(jq -cn \
    --argjson sent "$SENT" \
    --argjson survived "$SURVIVED" \
    --arg checks "${CHECKS_DETAIL:-all_passed}" \
    '{empty_packets_sent: $sent, survived: $survived, post_attack_checks: $checks}')

if [[ "$SURVIVED" == "true" ]]; then
    echo "PASS: Validator survived empty UDP packets"
    sdk_sometimes true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Validator unhealthy after empty UDP packets ($CHECKS_DETAIL)"
    sdk_sometimes false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
