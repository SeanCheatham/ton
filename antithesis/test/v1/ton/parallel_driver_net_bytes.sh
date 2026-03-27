#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Network bytes transferred is non-zero when healthy
# Reads /shared/validator_net_bytes (written by validator entrypoint heartbeat loop)
# and asserts that cumulative network bytes (rx+tx) are non-zero at least once
# when the validator is healthy. A validator with all ports up but zero traffic
# is functionally isolated.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"

if [ ! -f /shared/validator_net_bytes ]; then
    echo "Net bytes file not present yet, skipping"
    sleep 10
    exit 0
fi

NET_BYTES=$(cat /shared/validator_net_bytes 2>/dev/null || echo "-1")

if [ "$NET_BYTES" = "-1" ]; then
    echo "Net bytes unavailable, skipping"
    sleep 10
    exit 0
fi

if ! [[ "$NET_BYTES" =~ ^[0-9]+$ ]]; then
    echo "Invalid net bytes value: $NET_BYTES, skipping"
    sleep 10
    exit 0
fi

# Check if all 3 ports are reachable
udp_up=false
console_up=false
lite_up=false
nc -z -w 1 -u "${VALIDATOR_HOST}" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "${VALIDATOR_HOST}" 30002 2>/dev/null && console_up=true
nc -z -w 1 "${VALIDATOR_HOST}" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "Validator not fully healthy, skipping assertion"
    sleep 10
    exit 0
fi

if [ "$NET_BYTES" -gt 0 ]; then
    DETAILS=$(jq -cn --argjson bytes "$NET_BYTES" '{net_bytes: $bytes}')
    sdk_sometimes true "Network bytes transferred is non-zero when healthy" "$DETAILS"
else
    sdk_sometimes false "Network bytes transferred is non-zero when healthy" '{"net_bytes":0}'
fi

sleep 10
exit 0
