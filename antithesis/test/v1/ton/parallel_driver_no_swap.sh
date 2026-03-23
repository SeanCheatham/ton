#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator swap usage is zero when healthy
# Reads /shared/validator_swap_kb (written by validator entrypoint heartbeat loop)
# and asserts that swap usage (VmSwap from /proc/1/status) is 0 KB when the
# validator is healthy. A swapped validator suffers extreme latency (100-1000x
# slower than RAM), making it unable to participate in consensus.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"

if [ ! -f /shared/validator_swap_kb ]; then
    echo "Swap KB file not present yet, skipping"
    sleep 10
    exit 0
fi

SWAP_KB=$(cat /shared/validator_swap_kb 2>/dev/null || echo "-1")

if [ "$SWAP_KB" = "-1" ]; then
    echo "Swap KB unavailable, skipping"
    sleep 10
    exit 0
fi

if ! [[ "$SWAP_KB" =~ ^[0-9]+$ ]]; then
    echo "Invalid swap KB value: $SWAP_KB, skipping"
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

if [ "$SWAP_KB" -gt 0 ]; then
    DETAILS=$(jq -cn --argjson swap "$SWAP_KB" '{swap_kb: $swap}')
    sdk_always false "Validator swap usage is zero when healthy" "$DETAILS"
else
    sdk_always true "Validator swap usage is zero when healthy" '{"swap_kb":0}'
fi

sleep 10
exit 0
