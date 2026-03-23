#!/usr/bin/env bash
set -euo pipefail

# Driver workload: verify heartbeat timestamp is monotonically non-decreasing.
# The epoch timestamp in /shared/validator_heartbeat must never decrease compared
# to the previous observation. A decreasing heartbeat indicates: file corruption,
# state resets, clock anomalies, or the heartbeat loop being replaced by a
# different process writing garbage.
# This is fundamentally different from heartbeat freshness (which checks staleness)
# — monotonicity catches corruption and regressions that freshness checks miss.
# Runs repeatedly in parallel during fault injection.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_MSG="Validator heartbeat timestamp is monotonically non-decreasing"

HEARTBEAT_FILE="/shared/validator_heartbeat"
PREV_FILE="/shared/validator_heartbeat_prev"

# Catalog the assertion on first invocation
sdk_catalog_always "$ASSERTION_MSG"

echo "Checking heartbeat timestamp monotonicity..."

# Step 1: Read current heartbeat — skip if file doesn't exist or is empty
if [[ ! -f "$HEARTBEAT_FILE" ]]; then
    echo "SKIP: heartbeat file does not exist yet (validator hasn't started)"
    exit 0
fi

current_ts=$(cat "$HEARTBEAT_FILE" 2>/dev/null || true)
current_ts=$(echo "$current_ts" | tr -d '[:space:]')

if [[ -z "$current_ts" ]]; then
    echo "SKIP: heartbeat file is empty"
    exit 0
fi

# Validate it's a number
if ! [[ "$current_ts" =~ ^[0-9]+$ ]]; then
    echo "SKIP: heartbeat value is not a valid integer: '${current_ts}'"
    exit 0
fi

echo "  Current heartbeat: ${current_ts}"

# Step 2: Read previous observation — if none, store current and skip
if [[ ! -f "$PREV_FILE" ]]; then
    echo "  First observation, storing for next comparison"
    echo "$current_ts" > "$PREV_FILE"
    exit 0
fi

prev_ts=$(cat "$PREV_FILE" 2>/dev/null || true)
prev_ts=$(echo "$prev_ts" | tr -d '[:space:]')

if [[ -z "$prev_ts" ]] || ! [[ "$prev_ts" =~ ^[0-9]+$ ]]; then
    echo "  Previous value invalid ('${prev_ts}'), resetting"
    echo "$current_ts" > "$PREV_FILE"
    exit 0
fi

echo "  Previous heartbeat: ${prev_ts}"

# Step 3: Compare — current must be >= previous
if [[ "$current_ts" -ge "$prev_ts" ]]; then
    delta=$((current_ts - prev_ts))
    echo "PASS: heartbeat is non-decreasing (delta: +${delta}s)"
    sdk_always true "$ASSERTION_MSG" \
        "$(jq -cn --argjson current "$current_ts" --argjson prev "$prev_ts" --argjson delta "$delta" \
            '{current_ts: $current, prev_ts: $prev, delta_seconds: $delta, monotonic: true}')"
else
    delta=$((prev_ts - current_ts))
    echo "FAIL: heartbeat decreased! prev=${prev_ts} current=${current_ts} (regression: -${delta}s)"
    sdk_always false "$ASSERTION_MSG" \
        "$(jq -cn --argjson current "$current_ts" --argjson prev "$prev_ts" --argjson delta "$delta" \
            '{current_ts: $current, prev_ts: $prev, regression_seconds: $delta, monotonic: false}')"
fi

# Step 4: Store current value for next invocation
echo "$current_ts" > "$PREV_FILE"

# Always exit 0 so the driver keeps running
exit 0
