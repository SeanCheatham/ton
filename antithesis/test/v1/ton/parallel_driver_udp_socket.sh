#!/usr/bin/env bash
source /opt/antithesis/test/v1/ton/helper_sdk.sh
PROPERTY="Validator UDP socket is bound when healthy"

# Heartbeat-only precondition
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
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

UDP_BOUND=$(cat /shared/validator_udp_bound 2>/dev/null | tr -d '[:space:]')

# If the metric file is missing, empty, or still at init value, try direct check
if [[ -z "$UDP_BOUND" || "$UDP_BOUND" == "-1" ]]; then
    # Fallback: read /proc/net/udp and /proc/net/udp6 directly (accessible from same network ns)
    if [ -f /proc/net/udp ] || [ -f /proc/net/udp6 ]; then
        FOUND=$(cat /proc/net/udp /proc/net/udp6 2>/dev/null | awk '$2 ~ /:7531$/ {found=1} END {print found+0}')
        if [ "$FOUND" = "1" ]; then
            UDP_BOUND="1"
        else
            UDP_BOUND="0"
        fi
    else
        echo "UDP metric not available and /proc/net/udp not readable, skipping"
        exit 0
    fi
fi

if [[ "$UDP_BOUND" == "1" ]]; then
    sdk_always true "$PROPERTY" '{"udp_bound":"1"}'
else
    sdk_always false "$PROPERTY" "$(jq -cn --arg val "$UDP_BOUND" '{udp_bound: $val}')"
fi
