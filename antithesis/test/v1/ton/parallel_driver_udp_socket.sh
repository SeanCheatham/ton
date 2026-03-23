#!/usr/bin/env bash
source /opt/antithesis/test/v1/ton/helper_sdk.sh
PROPERTY="Validator UDP socket is bound when healthy"

# Heartbeat-only precondition: heartbeat freshness proves the validator process
# is actively running and metrics are valid, regardless of port status.
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s > ${HEARTBEAT_MAX_AGE}s), skipping"
            sleep 5; exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"; sleep 5; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"; sleep 5; exit 0
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
