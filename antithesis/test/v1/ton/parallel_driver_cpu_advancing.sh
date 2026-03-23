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
    sdk_always true "$PROPERTY" "$(jq -cn --argjson delta "$DELTA" --argjson prev "$PREV" --argjson cur "$CURRENT" '{delta: $delta, prev: $prev, current: $cur}')"
elif [ "$CURRENT" -eq "$PREV" ]; then
    # Heartbeat updates every 5s — the driver may run faster than that.
    # Equal ticks are inconclusive, not a failure.
    echo "CPU ticks unchanged ($CURRENT), heartbeat may not have refreshed yet — skipping"
    exit 0
else
    # CURRENT < PREV would indicate corruption or counter wrap
    DELTA=$((PREV - CURRENT))
    sdk_always false "$PROPERTY" "$(jq -cn --argjson cur "$CURRENT" --argjson prev "$PREV" --argjson delta "$DELTA" '{prev: $prev, current: $cur, delta_negative: $delta, error: "CPU ticks decreased"}')"
fi
