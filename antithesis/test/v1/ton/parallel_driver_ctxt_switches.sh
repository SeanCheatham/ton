#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator context switch rate is bounded when healthy
# Tracks nonvoluntary context switches from /proc/1/status. If the increase
# exceeds 50000 per check interval, emits always(false). High nonvoluntary
# context switch rates indicate CPU contention, thread starvation, or
# scheduling pathology under fault injection.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
PROPERTY="Validator context switch rate is bounded when healthy"
STATE_FILE="/shared/_prev_ctxt_switches"
MAX_NONVOL_DELTA=50000

# Check if validator is healthy
udp_up=false; console_up=false; lite_up=false
nc -z -w 1 -u "$VALIDATOR_HOST" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30002 2>/dev/null && console_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "Validator not fully healthy, skipping context switch check"
    exit 0
fi

# Read current context switches
CURRENT_RAW=$(cat /shared/validator_ctxt_switches 2>/dev/null || echo "")
if [ -z "$CURRENT_RAW" ]; then
    echo "Context switches file not present yet, skipping"
    exit 0
fi

CUR_VOL=$(echo "$CURRENT_RAW" | cut -d: -f1)
CUR_NONVOL=$(echo "$CURRENT_RAW" | cut -d: -f2)

if [[ "$CUR_VOL" == "-1" || "$CUR_NONVOL" == "-1" ]]; then
    echo "Context switches unavailable, skipping"
    exit 0
fi

if ! [[ "$CUR_VOL" =~ ^[0-9]+$ && "$CUR_NONVOL" =~ ^[0-9]+$ ]]; then
    echo "Invalid context switch values: vol=$CUR_VOL nonvol=$CUR_NONVOL, skipping"
    exit 0
fi

# Read previous values
PREV_RAW=$(cat "$STATE_FILE" 2>/dev/null || echo "")
echo "$CURRENT_RAW" > "$STATE_FILE"

if [ -z "$PREV_RAW" ]; then
    echo "First observation: vol=$CUR_VOL nonvol=$CUR_NONVOL, skipping comparison"
    exit 0
fi

PREV_VOL=$(echo "$PREV_RAW" | cut -d: -f1)
PREV_NONVOL=$(echo "$PREV_RAW" | cut -d: -f2)

if ! [[ "$PREV_VOL" =~ ^[0-9]+$ && "$PREV_NONVOL" =~ ^[0-9]+$ ]]; then
    echo "Invalid previous values, resetting baseline"
    exit 0
fi

# Process restart detection: if current < previous, reset
if [ "$CUR_NONVOL" -lt "$PREV_NONVOL" ]; then
    echo "Context switches decreased (restart?), resetting baseline"
    exit 0
fi

DELTA_VOL=$((CUR_VOL - PREV_VOL))
DELTA_NONVOL=$((CUR_NONVOL - PREV_NONVOL))

DETAILS=$(jq -cn \
    --argjson dv "$DELTA_VOL" \
    --argjson dnv "$DELTA_NONVOL" \
    --argjson cv "$CUR_VOL" \
    --argjson cnv "$CUR_NONVOL" \
    --argjson max "$MAX_NONVOL_DELTA" \
    '{delta_voluntary: $dv, delta_nonvoluntary: $dnv, current_voluntary: $cv, current_nonvoluntary: $cnv, max_nonvoluntary_delta: $max}')

if [ "$DELTA_NONVOL" -gt "$MAX_NONVOL_DELTA" ]; then
    echo "FAIL: nonvoluntary context switch delta $DELTA_NONVOL exceeds threshold $MAX_NONVOL_DELTA"
    sdk_always false "$PROPERTY" "$DETAILS"
else
    echo "PASS: nonvoluntary context switch delta $DELTA_NONVOL within bounds"
    sdk_always true "$PROPERTY" "$DETAILS"
fi

exit 0
