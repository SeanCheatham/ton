#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator log file size is bounded
# Checks that /shared/validator.log does not exceed 200MB (209715200 bytes).
# Complements the per-interval log growth rate check (iter 12B) by catching
# cumulative unbounded growth over the full test duration. A 200MB log file
# indicates excessive verbosity, error spam loops, or a logging subsystem bug.
# No heartbeat or port precondition needed — the log file is always accessible.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator log file size is bounded"
MAX_SIZE=209715200  # 200MB in bytes

echo "Checking validator log file size..."

if [ ! -f /shared/validator.log ]; then
    echo "Log file not present yet, skipping"
    exit 0
fi

LOG_SIZE=$(stat -c %s /shared/validator.log 2>/dev/null || echo "0")

if ! [[ "$LOG_SIZE" =~ ^[0-9]+$ ]]; then
    echo "Invalid log size value: '$LOG_SIZE', skipping"
    exit 0
fi

DETAILS=$(jq -cn --argjson size "$LOG_SIZE" --argjson limit "$MAX_SIZE" \
    '{log_size_bytes: $size, max_size_bytes: $limit, log_size_mb: ($size / 1048576 * 100 | floor / 100)}')

if [ "$LOG_SIZE" -lt "$MAX_SIZE" ]; then
    SIZE_MB=$((LOG_SIZE / 1048576))
    echo "PASS: Log file size ${SIZE_MB}MB (limit: 200MB)"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    SIZE_MB=$((LOG_SIZE / 1048576))
    echo "FAIL: Log file size ${SIZE_MB}MB exceeds 200MB limit"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

exit 0
