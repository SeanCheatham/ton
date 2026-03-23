#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator file descriptor count is bounded
# Reads /shared/validator_fd_count (written by validator entrypoint heartbeat loop)
# and asserts the FD count stays below 10000. Catches FD leaks from RocksDB,
# network connections, and archive files that accumulate under fault injection.

source "$(dirname "$0")/helper_sdk.sh"

FD_LIMIT=10000

if [ ! -f /shared/validator_fd_count ]; then
    echo "FD count file not present yet, skipping"
    sleep 10
    exit 0
fi

FD_COUNT=$(cat /shared/validator_fd_count 2>/dev/null || echo "0")

# Validate we got a numeric value
if ! [[ "$FD_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid FD count value: $FD_COUNT, skipping"
    sleep 10
    exit 0
fi

if [ "$FD_COUNT" -gt 0 ] && [ "$FD_COUNT" -lt "$FD_LIMIT" ]; then
    DETAILS=$(jq -cn --argjson count "$FD_COUNT" --argjson limit "$FD_LIMIT" \
        '{fd_count: $count, fd_limit: $limit}')
    sdk_always true "Validator file descriptor count is bounded" "$DETAILS"
elif [ "$FD_COUNT" -ge "$FD_LIMIT" ]; then
    DETAILS=$(jq -cn --argjson count "$FD_COUNT" --argjson limit "$FD_LIMIT" \
        '{fd_count: $count, fd_limit: $limit}')
    sdk_always false "Validator file descriptor count is bounded" "$DETAILS"
fi

sleep 10
exit 0
