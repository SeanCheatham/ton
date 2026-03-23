#!/usr/bin/env bash
source /opt/antithesis/test/v1/ton/helper_sdk.sh
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
PROPERTY="Validator UDP socket is bound when healthy"

# Only check when healthy (all 3 ports up)
udp_up=false; console_up=false; lite_up=false
nc -z -w 1 -u "$VALIDATOR_HOST" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30002 2>/dev/null && console_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    exit 0
fi

UDP_BOUND=$(cat /shared/validator_udp_bound 2>/dev/null || echo "-1")
if [[ "$UDP_BOUND" == "-1" || -z "$UDP_BOUND" ]]; then
    exit 0
fi

if [[ "$UDP_BOUND" == "1" ]]; then
    sdk_always true "$PROPERTY"
else
    sdk_always false "$PROPERTY" "{\"udp_bound\":\"$UDP_BOUND\"}"
fi
