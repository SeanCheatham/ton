#!/usr/bin/env bash
source /opt/antithesis/test/v1/ton/helper_sdk.sh
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
PROPERTY="TCP control ports are bound in kernel when healthy"

# Only check when healthy (all 3 ports up)
udp_up=false; console_up=false; lite_up=false
nc -z -w 1 -u "$VALIDATOR_HOST" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30002 2>/dev/null && console_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    exit 0
fi

TCP_BOUND=$(cat /shared/validator_tcp_bound 2>/dev/null || echo "")
if [[ -z "$TCP_BOUND" ]]; then
    exit 0
fi

if [[ "$TCP_BOUND" == "1" ]]; then
    sdk_always true "$PROPERTY" "Both TCP ports bound in kernel"
else
    sdk_always false "$PROPERTY" "One or both TCP ports missing from kernel socket table"
fi
