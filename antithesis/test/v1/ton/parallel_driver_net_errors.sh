#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Network error and drop counts are zero when validator is healthy
# Reads /shared/validator_net_errors (written by validator entrypoint heartbeat loop)
# and asserts that cumulative network errors (rx_errs + tx_errs + rx_drop + tx_drop)
# are zero when the validator is healthy. Non-zero counts indicate network stack
# corruption, buffer exhaustion, or driver issues invisible to port probing.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"

if [ ! -f /shared/validator_net_errors ]; then
    echo "Net errors file not present yet, skipping"
    sleep 10
    exit 0
fi

NET_ERRORS=$(cat /shared/validator_net_errors 2>/dev/null || echo "-1")

if [ "$NET_ERRORS" = "-1" ]; then
    echo "Net errors unavailable, skipping"
    sleep 10
    exit 0
fi

if ! [[ "$NET_ERRORS" =~ ^[0-9]+$ ]]; then
    echo "Invalid net errors value: $NET_ERRORS, skipping"
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

if [ "$NET_ERRORS" -gt 0 ]; then
    DETAILS=$(jq -cn --argjson errors "$NET_ERRORS" '{net_errors: $errors}')
    sdk_always false "Network error and drop counts are zero when validator is healthy" "$DETAILS"
else
    sdk_always true "Network error and drop counts are zero when validator is healthy" '{"net_errors":0}'
fi

sleep 10
exit 0
