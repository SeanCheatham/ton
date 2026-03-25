#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator heartbeat interval is regular when healthy
# The heartbeat loop writes every 5 seconds. If the interval between
# consecutive heartbeats exceeds 30 seconds while ports are up, the
# heartbeat loop is being starved by CPU contention or I/O blocking.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator heartbeat interval is regular when healthy"
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
MAX_INTERVAL=30
PREV_FILE="/shared/validator_heartbeat_prev_check"

# Precondition: heartbeat file exists
HEARTBEAT_FILE="/shared/validator_heartbeat"
if [[ ! -f "$HEARTBEAT_FILE" ]]; then
    echo "No heartbeat file yet, skipping"
    exit 0
fi

CURRENT_TS=$(cat "$HEARTBEAT_FILE" 2>/dev/null | tr -d '[:space:]')
if ! [[ "$CURRENT_TS" =~ ^[0-9]+$ ]]; then
    echo "Invalid heartbeat timestamp, skipping"
    exit 0
fi

# Precondition: validator healthy (all ports up)
if ! nc -z -w 2 -u "$VALIDATOR_HOST" 30001 2>/dev/null; then exit 0; fi
if ! nc -z -w 2 "$VALIDATOR_HOST" 30002 2>/dev/null; then exit 0; fi
if ! nc -z -w 2 "$VALIDATOR_HOST" 30003 2>/dev/null; then exit 0; fi

# Check heartbeat freshness as additional precondition
NOW=$(date +%s)
AGE=$((NOW - CURRENT_TS))
if (( AGE > 30 )); then
    echo "Heartbeat stale (${AGE}s), skipping"
    exit 0
fi

# Load previous heartbeat timestamp (from our last check)
if [[ ! -f "$PREV_FILE" ]]; then
    # First run -- save current and skip
    echo "$CURRENT_TS" > "$PREV_FILE"
    echo "First observation, saving baseline"
    exit 0
fi

PREV_TS=$(cat "$PREV_FILE" 2>/dev/null | tr -d '[:space:]')
if ! [[ "$PREV_TS" =~ ^[0-9]+$ ]]; then
    echo "$CURRENT_TS" > "$PREV_FILE"
    echo "Invalid previous timestamp, resetting"
    exit 0
fi

# Calculate interval
INTERVAL=$((CURRENT_TS - PREV_TS))

# Save current as previous for next invocation
echo "$CURRENT_TS" > "$PREV_FILE"

# If heartbeat hasn't changed, skip (we may be called faster than the 5s loop)
if (( INTERVAL == 0 )); then
    echo "Heartbeat unchanged since last check, skipping"
    exit 0
fi

# Negative interval shouldn't happen (monotonicity checked elsewhere), skip
if (( INTERVAL < 0 )); then
    echo "Heartbeat went backwards, skipping (handled by monotonicity check)"
    exit 0
fi

DETAILS=$(jq -cn \
    --argjson interval "$INTERVAL" \
    --argjson max "$MAX_INTERVAL" \
    --argjson prev "$PREV_TS" \
    --argjson curr "$CURRENT_TS" \
    '{interval_seconds: $interval, max_allowed: $max, prev_ts: $prev, curr_ts: $curr}')

if (( INTERVAL <= MAX_INTERVAL )); then
    echo "PASS: Heartbeat interval ${INTERVAL}s <= ${MAX_INTERVAL}s"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Heartbeat interval ${INTERVAL}s > ${MAX_INTERVAL}s -- loop may be starved"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
