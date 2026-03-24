#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator startup time is bounded
# Checks that the time from container start to first heartbeat is under 120 seconds.
# Uses /shared/validator_first_heartbeat (written once on the first heartbeat iteration)
# rather than the continuously-updating /shared/validator_heartbeat, which would make
# the measured duration grow indefinitely as the container runs.

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

# Read first heartbeat timestamp (written once on the first heartbeat loop iteration)
if [ ! -f /shared/validator_first_heartbeat ]; then
    echo "First heartbeat not available yet, skipping"
    sleep 5
    exit 0
fi

FIRST_HB=$(cat /shared/validator_first_heartbeat 2>/dev/null | tr -d '[:space:]')

if ! [[ "$FIRST_HB" =~ ^[0-9]+$ ]]; then
    echo "First heartbeat value invalid, skipping"
    sleep 5
    exit 0
fi

# Also verify current heartbeat is fresh (validator is actually running)
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]] && [ "$HB_TS" != "-1" ]; then
        HB_AGE=$((NOW - HB_TS))
        if [ "$HB_AGE" -gt 60 ]; then
            echo "Heartbeat stale (${HB_AGE}s), skipping"
            sleep 5
            exit 0
        fi
    fi
fi

# Compute startup duration: time from container start to first heartbeat
STARTUP_DURATION=$((FIRST_HB - STARTUP_S))

# Sanity: if negative (clock skew), treat as 0
if [ "$STARTUP_DURATION" -lt 0 ]; then
    STARTUP_DURATION=0
fi

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
