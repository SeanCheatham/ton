#!/usr/bin/env bash

# Anytime driver: Validator heartbeat file contains valid data when present
# This runs even during active fault injection (anytime_* driver type).
# If the heartbeat file exists and is non-empty, it must contain a valid epoch timestamp.
# NO precondition guards — that's the point of anytime_*.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator heartbeat file contains valid data when present"
HB_FILE="/shared/validator_heartbeat"

# If the file doesn't exist at all, that's fine — validator may not have started yet
if [ ! -f "$HB_FILE" ]; then
    echo "Heartbeat file does not exist yet, nothing to validate"
    exit 0
fi

# Read the content
HB_RAW=$(cat "$HB_FILE" 2>/dev/null || true)

# If the file is completely empty, that's acceptable (being written atomically)
if [ -z "$HB_RAW" ]; then
    echo "Heartbeat file is empty, nothing to validate"
    exit 0
fi

# Strip whitespace
HB_VAL=$(echo "$HB_RAW" | tr -d '[:space:]')

# If non-empty, it MUST be a valid epoch timestamp
if [[ "$HB_VAL" =~ ^[0-9]+$ ]] && [ "$HB_VAL" -gt 1700000000 ]; then
    DETAILS=$(jq -cn --arg ts "$HB_VAL" '{status: "valid", timestamp: $ts}')
    echo "PASS: Heartbeat contains valid epoch timestamp: $HB_VAL"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    DETAILS=$(jq -cn --arg raw "$HB_RAW" --arg cleaned "$HB_VAL" '{status: "invalid", raw_value: $raw, cleaned_value: $cleaned}')
    echo "FAIL: Heartbeat contains invalid data: '$HB_RAW'"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
