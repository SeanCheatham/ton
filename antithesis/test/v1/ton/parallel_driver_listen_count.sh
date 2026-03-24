#!/usr/bin/env bash

# Parallel driver: Validator listening socket count matches expected
# When healthy, the validator should have exactly:
# - 2 TCP LISTEN sockets (port 30002 console, port 30003 liteserver)
# - 1 UDP socket (port 30001 P2P)
# Fewer = subsystem failed to bind; more = unexpected service or leak.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator listening socket count matches expected"
HEARTBEAT_MAX_AGE=60

# Precondition: heartbeat must be fresh
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s), skipping"
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"; exit 0
fi

# Read TCP LISTEN sockets (state 0A = LISTEN in /proc/net/tcp)
# Check both IPv4 and IPv6 (validator may bind to :: which creates dual-stack sockets)
TCP_LISTEN=0
if [ -f /proc/net/tcp ] || [ -f /proc/net/tcp6 ]; then
    # Count unique LISTEN entries matching our expected ports (7532=30002, 7533=30003)
    TCP_DATA=$(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null)
    TCP_LISTEN=$(echo "$TCP_DATA" | awk '$4 == "0A" {count++} END {print count+0}')
    # Count specifically our expected ports
    TCP_7532=$(echo "$TCP_DATA" | awk '$2 ~ /:7532$/ && $4 == "0A" {count++} END {print count+0}')
    TCP_7533=$(echo "$TCP_DATA" | awk '$2 ~ /:7533$/ && $4 == "0A" {count++} END {print count+0}')
else
    echo "/proc/net/tcp not available, skipping"
    exit 0
fi

# Read UDP sockets
UDP_7531=0
if [ -f /proc/net/udp ] || [ -f /proc/net/udp6 ]; then
    UDP_7531=$(cat /proc/net/udp /proc/net/udp6 2>/dev/null | awk '$2 ~ /:7531$/ {count++} END {print count+0}')
else
    echo "/proc/net/udp not available, skipping"
    exit 0
fi

# Verify: console port (7532) listening, liteserver port (7533) listening, UDP (7531) bound
PASS=true
REASON=""

if [ "$TCP_7532" -eq 0 ]; then
    PASS=false
    REASON="console_port_not_listening"
fi
if [ "$TCP_7533" -eq 0 ]; then
    PASS=false
    REASON="${REASON:+${REASON},}liteserver_port_not_listening"
fi
if [ "$UDP_7531" -eq 0 ]; then
    PASS=false
    REASON="${REASON:+${REASON},}udp_port_not_bound"
fi

DETAILS=$(jq -cn \
    --argjson tcp_listen "$TCP_LISTEN" \
    --argjson tcp_7532 "$TCP_7532" \
    --argjson tcp_7533 "$TCP_7533" \
    --argjson udp_7531 "$UDP_7531" \
    '{tcp_listen_total: $tcp_listen, console_30002: $tcp_7532, liteserver_30003: $tcp_7533, udp_30001: $udp_7531}')

if [ "$PASS" = "true" ]; then
    echo "PASS: All expected listening sockets found ($DETAILS)"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Missing expected sockets: $REASON ($DETAILS)"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
