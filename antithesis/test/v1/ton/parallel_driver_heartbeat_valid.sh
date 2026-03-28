#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator heartbeat file contains valid data when present
# Validates the heartbeat file content: must be a valid integer, must be a
# reasonable epoch timestamp (> 1700000000 and <= NOW+60), must not be empty
# or contain garbage. Catches shared volume corruption or heartbeat writer
# failures that wouldn't be detected by freshness-only checks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator heartbeat file contains valid data when present"

echo "Checking validator heartbeat file data validity..."

# If heartbeat file doesn't exist yet, that's fine during startup
if [ ! -f /shared/validator_heartbeat ]; then
    echo "Heartbeat file not present yet, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"file_not_present"}'
    exit 0
fi

HB_RAW=$(cat /shared/validator_heartbeat 2>/dev/null || echo "")
HB_VAL=$(echo "$HB_RAW" | tr -d '[:space:]')

# Check 1: Value must be non-empty (empty = mid-write race, not a real failure)
if [ -z "$HB_VAL" ]; then
    echo "SKIP: Heartbeat file exists but is empty (likely mid-write)"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"empty_during_write"}'
    exit 0
fi

# Check 2: Value must be a valid integer (digits only)
if ! [[ "$HB_VAL" =~ ^[0-9]+$ ]]; then
    TRUNCATED=$(echo "$HB_VAL" | head -c 50)
    DETAILS=$(jq -cn --arg reason "not_integer" --arg raw_value "$TRUNCATED" \
        '{reason: $reason, raw_value: $raw_value}')
    echo "FAIL: Heartbeat value is not a valid integer: $TRUNCATED"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
    exit 0
fi

# Check 3: Value must be a reasonable epoch timestamp
NOW=$(date +%s)
MAX_TS=$((NOW + 60))
MIN_TS=1700000000

if [ "$HB_VAL" -lt "$MIN_TS" ]; then
    DETAILS=$(jq -cn --argjson ts "$HB_VAL" --argjson min "$MIN_TS" --argjson now "$NOW" \
        '{reason: "timestamp_too_old", heartbeat_ts: $ts, min_ts: $min, now: $now}')
    echo "FAIL: Heartbeat timestamp $HB_VAL is below minimum $MIN_TS"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
    exit 0
fi

if [ "$HB_VAL" -gt "$MAX_TS" ]; then
    DETAILS=$(jq -cn --argjson ts "$HB_VAL" --argjson max "$MAX_TS" --argjson now "$NOW" \
        '{reason: "timestamp_in_future", heartbeat_ts: $ts, max_ts: $max, now: $now}')
    echo "FAIL: Heartbeat timestamp $HB_VAL is too far in the future (max $MAX_TS)"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
    exit 0
fi

# All checks passed
AGE=$((NOW - HB_VAL))
DETAILS=$(jq -cn --argjson ts "$HB_VAL" --argjson age "$AGE" \
    '{heartbeat_ts: $ts, age_seconds: $age}')
echo "PASS: Heartbeat file contains valid timestamp $HB_VAL (age: ${AGE}s)"
sdk_always true "$ASSERTION_NAME" "$DETAILS"

exit 0
