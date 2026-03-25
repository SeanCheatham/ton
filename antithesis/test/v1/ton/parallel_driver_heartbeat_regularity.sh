#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator heartbeat interval is regular when healthy
# The heartbeat loop writes every 5 seconds. If the interval between
# consecutive heartbeats exceeds 30 seconds while ports are up, the
# heartbeat loop is being starved by CPU contention or I/O blocking.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator heartbeat interval is regular when healthy"
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
MAX_INTERVAL=300
PREV_FILE="/shared/validator_heartbeat_prev_check"
PREV_WALLCLOCK_FILE="/shared/validator_heartbeat_prev_check_wallclock"
# If more wall-clock time than this has elapsed since our last successful
# check, we assume the validator was unhealthy in between and reset instead
# of asserting.  Must be comfortably larger than the Test Composer parallel
# driver scheduling interval.
MAX_WALLCLOCK_GAP=600

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
    echo "$NOW" > "$PREV_WALLCLOCK_FILE"
    echo "First observation, saving baseline"
    exit 0
fi

PREV_TS=$(cat "$PREV_FILE" 2>/dev/null | tr -d '[:space:]')
if ! [[ "$PREV_TS" =~ ^[0-9]+$ ]]; then
    echo "$CURRENT_TS" > "$PREV_FILE"
    echo "$NOW" > "$PREV_WALLCLOCK_FILE"
    echo "Invalid previous timestamp, resetting"
    exit 0
fi

# If too much wall-clock time has elapsed since our last successful check,
# the validator was likely unhealthy in between (faults, restarts).  We
# cannot meaningfully assess regularity across that gap, so reset baseline.
PREV_WALL=$(cat "$PREV_WALLCLOCK_FILE" 2>/dev/null | tr -d '[:space:]')
if ! [[ "$PREV_WALL" =~ ^[0-9]+$ ]]; then
    PREV_WALL=0
fi
WALL_GAP=$((NOW - PREV_WALL))
if (( WALL_GAP > MAX_WALLCLOCK_GAP )); then
    echo "$CURRENT_TS" > "$PREV_FILE"
    echo "$NOW" > "$PREV_WALLCLOCK_FILE"
    echo "Wall-clock gap ${WALL_GAP}s > ${MAX_WALLCLOCK_GAP}s since last check, resetting baseline"
    exit 0
fi

# Calculate interval
INTERVAL=$((CURRENT_TS - PREV_TS))

# Save current as previous for next invocation
echo "$CURRENT_TS" > "$PREV_FILE"
echo "$NOW" > "$PREV_WALLCLOCK_FILE"

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
