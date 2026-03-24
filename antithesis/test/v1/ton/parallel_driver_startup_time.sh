#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator startup time is bounded
# Checks that the time from container start to first fresh heartbeat is under 120 seconds.
# A validator that takes too long indicates initialization bugs, config problems, or
# resource contention. Evaluated once per container lifecycle — result is persisted.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator startup time is bounded"
LIMIT=120

# Read startup ID (nanosecond epoch of container start)
if [ ! -f /shared/validator_startup_id ]; then
    echo "Startup ID not available yet, skipping"
    sleep 5
    exit 0
fi

STARTUP_ID=$(cat /shared/validator_startup_id 2>/dev/null | tr -d '[:space:]')
if ! [[ "$STARTUP_ID" =~ ^[0-9]+$ ]] || [ "$STARTUP_ID" = "-1" ]; then
    echo "Startup ID invalid or not set, skipping"
    sleep 5
    exit 0
fi

# Convert from nanoseconds to seconds
STARTUP_S=$((STARTUP_ID / 1000000000))

# Read heartbeat timestamp
if [ ! -f /shared/validator_heartbeat ]; then
    echo "Heartbeat not available yet, skipping"
    sleep 5
    exit 0
fi

HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
NOW=$(date +%s)

if ! [[ "$HB_TS" =~ ^[0-9]+$ ]] || [ "$HB_TS" = "-1" ]; then
    echo "Heartbeat value invalid, skipping"
    sleep 5
    exit 0
fi

# Check if heartbeat is fresh (validator is actually running)
HB_AGE=$((NOW - HB_TS))
if [ "$HB_AGE" -gt 60 ]; then
    echo "Heartbeat stale (${HB_AGE}s), skipping"
    sleep 5
    exit 0
fi

# Check if already computed for this startup generation
COMPUTED_FILE="/shared/_startup_time_computed"
COMPUTED_GEN_FILE="/shared/_startup_time_gen"

# If already computed for this startup generation, re-emit the same result
if [ -f "$COMPUTED_FILE" ] && [ -f "$COMPUTED_GEN_FILE" ]; then
    PREV_GEN=$(cat "$COMPUTED_GEN_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ "$PREV_GEN" = "$STARTUP_ID" ]; then
        STARTUP_DURATION=$(cat "$COMPUTED_FILE" 2>/dev/null | tr -d '[:space:]')
        DETAILS=$(jq -cn --argjson duration "$STARTUP_DURATION" --argjson limit "$LIMIT" '{startup_duration_s: $duration, limit_s: $limit}')
        if [ "$STARTUP_DURATION" -le "$LIMIT" ]; then
            sdk_always true "$ASSERTION_NAME" "$DETAILS"
        else
            sdk_always false "$ASSERTION_NAME" "$DETAILS"
        fi
        sleep 30
        exit 0
    fi
fi

# Compute startup duration
STARTUP_DURATION=$((HB_TS - STARTUP_S))

# Sanity: if negative (clock skew), treat as 0
if [ "$STARTUP_DURATION" -lt 0 ]; then
    STARTUP_DURATION=0
fi

# Persist result
echo "$STARTUP_DURATION" > "$COMPUTED_FILE"
echo "$STARTUP_ID" > "$COMPUTED_GEN_FILE"

DETAILS=$(jq -cn --argjson duration "$STARTUP_DURATION" --argjson limit "$LIMIT" '{startup_duration_s: $duration, limit_s: $limit}')

if [ "$STARTUP_DURATION" -le "$LIMIT" ]; then
    echo "PASS: Validator started in ${STARTUP_DURATION}s (limit: ${LIMIT}s)"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Validator startup took ${STARTUP_DURATION}s (limit: ${LIMIT}s)"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

sleep 30
exit 0
