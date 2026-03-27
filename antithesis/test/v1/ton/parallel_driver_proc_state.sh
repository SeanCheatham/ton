#!/usr/bin/env bash
source /opt/antithesis/test/v1/ton/helper_sdk.sh
VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
PROPERTY="Validator process state is runnable"

# Only check when healthy (all 3 ports up)
udp_up=false; console_up=false; lite_up=false
nc -z -w 1 -u "$VALIDATOR_HOST" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30002 2>/dev/null && console_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    exit 0
fi

STATE=$(cat /shared/validator_proc_state 2>/dev/null || echo "?")
if [[ "$STATE" == "?" || -z "$STATE" ]]; then
    exit 0
fi

if [[ "$STATE" == "R" || "$STATE" == "S" ]]; then
    sdk_always true "$PROPERTY" "{\"state\":\"$STATE\"}"
else
    sdk_always false "$PROPERTY" "{\"state\":\"$STATE\"}"
fi
