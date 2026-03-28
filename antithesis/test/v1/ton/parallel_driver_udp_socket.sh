#!/usr/bin/env bash
source /opt/antithesis/test/v1/ton/helper_sdk.sh
PROPERTY="Validator UDP socket is bound when healthy"

# Heartbeat-only precondition
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s > ${HEARTBEAT_MAX_AGE}s), skipping"
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"; exit 0
fi

UDP_BOUND=$(cat /shared/validator_udp_bound 2>/dev/null || true)
UDP_BOUND=$(echo "$UDP_BOUND" | tr -d '[:space:]')

# If the metric file is missing, empty, or still at init value, skip.
# The /proc/net/udp fallback was removed because it reads the workload
# container's network namespace, not the validator's — always wrong.
if [[ -z "$UDP_BOUND" || "$UDP_BOUND" == "-1" ]]; then
    echo "SKIP: UDP bound metric not yet available (value='${UDP_BOUND}'), likely startup"
    exit 0
fi

if [[ "$UDP_BOUND" == "1" ]]; then
    sdk_always true "$PROPERTY" '{"udp_bound":"1"}'
else
    sdk_always false "$PROPERTY" "$(jq -cn --arg val "$UDP_BOUND" '{udp_bound: $val}')"
fi
