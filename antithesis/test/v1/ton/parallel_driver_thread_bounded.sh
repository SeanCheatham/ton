#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator thread count is bounded
# Reads /shared/validator_thread_count (written by validator entrypoint heartbeat loop)
# and asserts the thread count stays below 200 when healthy. Catches thread leaks
# under fault injection that would eventually exhaust system resources.

source "$(dirname "$0")/helper_sdk.sh"

THREAD_LIMIT=200
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"

if [ ! -f /shared/validator_thread_count ]; then
    echo "Thread count file not present yet, skipping"
    sleep 10
    exit 0
fi

THREAD_COUNT=$(cat /shared/validator_thread_count 2>/dev/null || echo "-1")

if [ "$THREAD_COUNT" = "-1" ]; then
    echo "Thread count unavailable, skipping"
    sleep 10
    exit 0
fi

if ! [[ "$THREAD_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid thread count value: $THREAD_COUNT, skipping"
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

DETAILS=$(jq -cn --argjson count "$THREAD_COUNT" --argjson limit "$THREAD_LIMIT" \
    '{thread_count: $count, thread_limit: $limit}')

if [ "$THREAD_COUNT" -lt "$THREAD_LIMIT" ]; then
    sdk_always true "Validator thread count is bounded" "$DETAILS"
else
    sdk_always false "Validator thread count is bounded" "$DETAILS"
fi

sleep 10
exit 0
