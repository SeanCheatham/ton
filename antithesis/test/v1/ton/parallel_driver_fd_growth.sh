#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator open file descriptor count is not monotonically growing
# Reads /shared/validator_fd_history (written by validator entrypoint heartbeat loop).
# If the last 10 consecutive readings are strictly monotonically increasing AND
# total growth exceeds 100 FDs, emit always(false) — likely FD leak.
# Complements the point-in-time FD bound (10000) and deleted FD checks.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator open FD count is not monotonically growing"
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
MIN_ENTRIES=5
GROWTH_THRESHOLD=100
HEARTBEAT_MAX_AGE=60

# Use heartbeat-only precondition instead of all-3-ports.
# Under fault injection, all 3 ports are rarely up simultaneously for the
# 25+ seconds needed to accumulate 5 readings. The heartbeat file proves
# the validator process is actively running, which is sufficient context.
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s > ${HEARTBEAT_MAX_AGE}s), skipping"
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"
        exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"
    exit 0
fi

if [ ! -f /shared/validator_fd_history ]; then
    echo "Metric not available yet (validator may have just restarted)"
    sdk_always true "$ASSERTION_NAME" '{"status":"metric_not_yet_available","note":"heartbeat fresh but metric file pending"}'
    exit 0
fi

# Read last 10 entries (format: timestamp:fd_count)
mapfile -t ENTRIES < <(tail -"$MIN_ENTRIES" /shared/validator_fd_history 2>/dev/null)

if [ ${#ENTRIES[@]} -lt "$MIN_ENTRIES" ]; then
    echo "Insufficient data points (${#ENTRIES[@]}/${MIN_ENTRIES}), skipping"
    exit 0
fi

# Extract FD count values
FD_VALUES=()
for entry in "${ENTRIES[@]}"; do
    val="${entry#*:}"
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        FD_VALUES+=("$val")
    fi
done

if [ ${#FD_VALUES[@]} -lt "$MIN_ENTRIES" ]; then
    echo "Insufficient valid FD values, skipping"
    exit 0
fi

# Check if all 10 are strictly monotonically increasing
MONOTONIC=true
for ((i=1; i<${#FD_VALUES[@]}; i++)); do
    if [ "${FD_VALUES[$i]}" -le "${FD_VALUES[$((i-1))]}" ]; then
        MONOTONIC=false
        break
    fi
done

FIRST_FD="${FD_VALUES[0]}"
LAST_FD="${FD_VALUES[$((${#FD_VALUES[@]}-1))]}"
GROWTH=$((LAST_FD - FIRST_FD))

if [ "$MONOTONIC" = "true" ] && [ "$GROWTH" -gt "$GROWTH_THRESHOLD" ]; then
    echo "FAIL: FD count monotonically increasing over ${MIN_ENTRIES} readings, growth=${GROWTH} (>${GROWTH_THRESHOLD} threshold)"
    DETAILS=$(jq -cn --argjson first "$FIRST_FD" --argjson last "$LAST_FD" \
        --argjson growth "$GROWTH" --argjson threshold "$GROWTH_THRESHOLD" \
        --argjson count "${#FD_VALUES[@]}" \
        '{first_fd: $first, last_fd: $last, growth: $growth, threshold: $threshold, readings: $count, monotonic: true}')
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
else
    echo "PASS: FD count not monotonically growing (monotonic=${MONOTONIC}, growth=${GROWTH})"
    DETAILS=$(jq -cn --argjson first "$FIRST_FD" --argjson last "$LAST_FD" \
        --argjson growth "$GROWTH" --argjson threshold "$GROWTH_THRESHOLD" \
        --argjson count "${#FD_VALUES[@]}" --argjson monotonic "$MONOTONIC" \
        '{first_fd: $first, last_fd: $last, growth: $growth, threshold: $threshold, readings: $count, monotonic: $monotonic}')
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
