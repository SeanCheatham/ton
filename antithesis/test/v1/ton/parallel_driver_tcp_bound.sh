#!/usr/bin/env bash
source /opt/antithesis/test/v1/ton/helper_sdk.sh
PROPERTY="TCP control ports are bound in kernel when healthy"

# Heartbeat-only precondition: heartbeat freshness proves the validator process
# is actively running and metrics are valid, regardless of port status.
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
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

TCP_BOUND=$(cat /shared/validator_tcp_bound 2>/dev/null || echo "")
if [[ -z "$TCP_BOUND" || "$TCP_BOUND" == "-1" ]]; then
    exit 0
fi

if [[ "$TCP_BOUND" == "1" ]]; then
    sdk_always true "$PROPERTY" '{"tcp_bound": true}'
else
    sdk_always false "$PROPERTY" '{"tcp_bound": false}'
fi
