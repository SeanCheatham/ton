#!/usr/bin/env bash
source /opt/antithesis/test/v1/ton/helper_sdk.sh
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
PROPERTY="Validator CPU time is advancing when healthy"
STATE_FILE="/shared/validator_cpu_ticks_prev"

# Check if validator is healthy
udp_up=false; console_up=false; lite_up=false
nc -z -w 1 -u "$VALIDATOR_HOST" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30002 2>/dev/null && console_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "Validator not fully healthy, skipping CPU check"
    exit 0
fi

CURRENT=$(cat /shared/validator_cpu_ticks 2>/dev/null || echo "-1")
if [[ "$CURRENT" == "-1" || -z "$CURRENT" ]]; then
    echo "No CPU ticks available yet"
    exit 0
fi

PREV=$(cat "$STATE_FILE" 2>/dev/null || echo "")
echo "$CURRENT" > "$STATE_FILE"

if [[ -z "$PREV" ]]; then
    echo "First observation: $CURRENT ticks, skipping comparison"
    exit 0
fi

if [ "$CURRENT" -gt "$PREV" ]; then
    DELTA=$((CURRENT - PREV))
    sdk_always true "$PROPERTY" "CPU ticks advanced by $DELTA (${PREV} -> ${CURRENT})"
else
    sdk_always false "$PROPERTY" "CPU ticks stalled at $CURRENT (prev: $PREV)"
fi
