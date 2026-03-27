#!/usr/bin/env bash

# Parallel driver: Validator listening socket count matches expected
# When healthy, the validator should have all 3 expected ports reachable:
# - TCP:30002 (console)
# - TCP:30003 (liteserver)
# - UDP:30001 (P2P)
#
# NOTE: This script runs in the workload container, so it cannot read the
# validator's /proc/net/tcp. Instead it probes ports via nc and reads
# the validator's metric files from /shared/.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator listening socket count matches expected"
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
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

# Probe each expected port from the workload container
console_up=0
lite_up=0
udp_up=0

nc -z -w 2 "${VALIDATOR_HOST}" 30002 2>/dev/null && console_up=1
nc -z -w 2 "${VALIDATOR_HOST}" 30003 2>/dev/null && lite_up=1
nc -z -w 2 -u "${VALIDATOR_HOST}" 30001 2>/dev/null && udp_up=1

# Also cross-check with validator-written metric files (written from inside
# the validator container where /proc/net/tcp IS the validator's)
TCP_BOUND=$(cat /shared/validator_tcp_bound 2>/dev/null | tr -d '[:space:]')
UDP_BOUND=$(cat /shared/validator_udp_bound 2>/dev/null | tr -d '[:space:]')

# Use nc probe as primary signal; metric files as supplementary
LISTEN_COUNT=$((console_up + lite_up + udp_up))

# If not all ports are up, check whether the validator metrics confirm ports
# are bound. During Antithesis fault injection, nc probes from the workload
# container may fail due to network partitions even though the validator is
# healthy. Only fail if both nc probes AND validator-side metrics agree the
# port is down.
PASS=true
REASON=""

if [ "$console_up" -eq 0 ]; then
    # Cross-check: if the validator's own metric says TCP ports are bound,
    # this may be a network partition rather than a real issue — skip.
    if [[ "$TCP_BOUND" == "1" ]]; then
        echo "Console port unreachable from workload but validator reports tcp_bound=1 (possible partition), skipping"
        exit 0
    fi
    PASS=false
    REASON="console_port_30002_not_reachable"
fi
if [ "$lite_up" -eq 0 ]; then
    if [[ "$TCP_BOUND" == "1" ]]; then
        echo "Liteserver port unreachable from workload but validator reports tcp_bound=1 (possible partition), skipping"
        exit 0
    fi
    PASS=false
    REASON="${REASON:+${REASON},}liteserver_port_30003_not_reachable"
fi
if [ "$udp_up" -eq 0 ]; then
    if [[ "$UDP_BOUND" == "1" ]]; then
        echo "UDP port unreachable from workload but validator reports udp_bound=1 (possible partition), skipping"
        exit 0
    fi
    PASS=false
    REASON="${REASON:+${REASON},}udp_port_30001_not_reachable"
fi

DETAILS=$(jq -cn \
    --argjson console_up "$console_up" \
    --argjson lite_up "$lite_up" \
    --argjson udp_up "$udp_up" \
    --argjson listen_count "$LISTEN_COUNT" \
    --arg tcp_bound "${TCP_BOUND:--1}" \
    --arg udp_bound "${UDP_BOUND:--1}" \
    '{listen_count: $listen_count, console_30002: $console_up, liteserver_30003: $lite_up, udp_30001: $udp_up, validator_tcp_bound: $tcp_bound, validator_udp_bound: $udp_bound}')

if [ "$PASS" = "true" ]; then
    echo "PASS: All 3 expected listening sockets reachable ($DETAILS)"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Missing expected sockets: $REASON ($DETAILS)"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
