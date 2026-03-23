#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator log growth rate is bounded
# Tracks /shared/validator.log size across invocations and asserts growth
# doesn't exceed 5MB per check interval (~10-30s). Catches error storms,
# infinite retry loops, and debug flooding invisible to the fatal-log check
# which only looks for specific crash patterns.

source "$(dirname "$0")/helper_sdk.sh"

GROWTH_LIMIT=5242880  # 5MB in bytes
PREV_SIZE_FILE="/shared/validator_log_size_prev"
LOG_FILE="/shared/validator.log"

if [ ! -f "$LOG_FILE" ]; then
    echo "Log file not present yet, skipping"
    sleep 10
    exit 0
fi

LOG_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")

# Read previous size (default 0 if file doesn't exist)
PREV_SIZE="0"
if [ -f "$PREV_SIZE_FILE" ]; then
    PREV_SIZE=$(cat "$PREV_SIZE_FILE" 2>/dev/null || echo "0")
fi

# Validate both are numeric
if ! [[ "$LOG_SIZE" =~ ^[0-9]+$ ]]; then
    echo "Invalid log size: $LOG_SIZE, skipping"
    sleep 10
    exit 0
fi
if ! [[ "$PREV_SIZE" =~ ^[0-9]+$ ]]; then
    PREV_SIZE="0"
fi

GROWTH=$((LOG_SIZE - PREV_SIZE))

if [ "$GROWTH" -lt 0 ]; then
    # Log was rotated or truncated — just update prev and skip
    echo "Log size decreased (rotation?), resetting baseline"
    echo "$LOG_SIZE" > "$PREV_SIZE_FILE"
    sleep 10
    exit 0
fi

if [ "$GROWTH" -lt "$GROWTH_LIMIT" ]; then
    DETAILS=$(jq -cn --argjson growth "$GROWTH" --argjson limit "$GROWTH_LIMIT" --argjson size "$LOG_SIZE" \
        '{growth_bytes: $growth, growth_mb: ($growth / 1048576 * 100 | floor / 100), limit_bytes: $limit, total_size_bytes: $size}')
    sdk_always true "Validator log growth rate is bounded" "$DETAILS"
else
    DETAILS=$(jq -cn --argjson growth "$GROWTH" --argjson limit "$GROWTH_LIMIT" --argjson size "$LOG_SIZE" \
        '{growth_bytes: $growth, growth_mb: ($growth / 1048576 * 100 | floor / 100), limit_bytes: $limit, total_size_bytes: $size}')
    sdk_always false "Validator log growth rate is bounded" "$DETAILS"
fi

# Update previous size for next invocation
echo "$LOG_SIZE" > "$PREV_SIZE_FILE"

sleep 10
exit 0
