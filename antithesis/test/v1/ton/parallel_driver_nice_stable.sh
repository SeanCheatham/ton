#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator process scheduling priority is stable when healthy
# Checks that the nice value (scheduling priority) of the validator process
# remains constant throughout the test. A change indicates priority inversion.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator process scheduling priority is stable when healthy"
HEARTBEAT_MAX_AGE=60

echo "Checking preconditions for nice value stability..."

# Precondition: heartbeat must be fresh
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s), skipping"
            sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"heartbeat_stale"}'
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"
        sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"heartbeat_invalid"}'
        exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"heartbeat_missing"}'
    exit 0
fi

# Precondition: nice value file must exist and be valid
if [ ! -f /shared/validator_nice ]; then
    echo "Nice value file not present yet, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"nice_file_missing"}'
    exit 0
fi

NICE_VAL=$(cat /shared/validator_nice 2>/dev/null | tr -d '[:space:]')
if [ -z "$NICE_VAL" ] || [ "$NICE_VAL" = "unknown" ] || [ "$NICE_VAL" = "-1" ]; then
    echo "Nice value not ready ($NICE_VAL), skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"nice_not_ready"}'
    exit 0
fi

# First observation: record initial value
if [ ! -f /shared/validator_nice_initial ]; then
    echo "$NICE_VAL" > /shared/validator_nice_initial
    echo "Recorded initial nice value: $NICE_VAL"
    sdk_always true "$ASSERTION_NAME" "$(jq -cn --arg nice "$NICE_VAL" '{status:"initial_recorded",nice:$nice}')"
    exit 0
fi

INITIAL_NICE=$(cat /shared/validator_nice_initial 2>/dev/null | tr -d '[:space:]')

if [ "$NICE_VAL" = "$INITIAL_NICE" ]; then
    DETAILS=$(jq -cn \
        --arg current "$NICE_VAL" \
        --arg initial "$INITIAL_NICE" \
        --argjson stable true \
        '{current_nice: $current, initial_nice: $initial, stable: $stable}')
    echo "PASS: Nice value stable at $NICE_VAL"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    DETAILS=$(jq -cn \
        --arg current "$NICE_VAL" \
        --arg initial "$INITIAL_NICE" \
        --argjson stable false \
        '{current_nice: $current, initial_nice: $initial, stable: $stable}')
    echo "FAIL: Nice value changed from $INITIAL_NICE to $NICE_VAL"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
