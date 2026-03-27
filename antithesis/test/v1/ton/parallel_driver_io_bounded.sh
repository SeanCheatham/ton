#!/usr/bin/env bash
source /opt/antithesis/test/v1/ton/helper_sdk.sh
VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
PROPERTY="Validator I/O wait time is bounded"
IO_DELTA_LIMIT=500
STATE_FILE="/shared/validator_io_ticks_prev"

# Only check when healthy (all 3 ports up)
udp_up=false; console_up=false; lite_up=false
nc -z -w 1 -u "$VALIDATOR_HOST" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30002 2>/dev/null && console_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "Validator not fully healthy, skipping I/O check"
    exit 0
fi

CURRENT=$(cat /shared/validator_io_ticks 2>/dev/null || echo "-1")
if [[ "$CURRENT" == "-1" || -z "$CURRENT" ]]; then
    echo "No I/O ticks available yet"
    exit 0
fi

PREV=$(cat "$STATE_FILE" 2>/dev/null || echo "")
echo "$CURRENT" > "$STATE_FILE"

if [[ -z "$PREV" ]]; then
    echo "First observation: $CURRENT I/O ticks, skipping comparison"
    exit 0
fi

DELTA=$((CURRENT - PREV))

if [ "$DELTA" -le "$IO_DELTA_LIMIT" ]; then
    sdk_always true "$PROPERTY" "$(jq -cn --argjson delta "$DELTA" --argjson limit "$IO_DELTA_LIMIT" --argjson prev "$PREV" --argjson cur "$CURRENT" '{io_delta: $delta, limit: $limit, prev: $prev, current: $cur}')"
else
    sdk_always false "$PROPERTY" "$(jq -cn --argjson delta "$DELTA" --argjson limit "$IO_DELTA_LIMIT" --argjson prev "$PREV" --argjson cur "$CURRENT" '{io_delta: $delta, limit: $limit, prev: $prev, current: $cur}')"
fi
