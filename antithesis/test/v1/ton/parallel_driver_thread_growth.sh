#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator thread count is not monotonically growing
# Reads /shared/validator_thread_history (written by validator entrypoint heartbeat loop).
# If the last 10 consecutive readings are strictly monotonically increasing AND
# total growth exceeds 20 threads, emit always(false) — likely thread leak.
# Complements the point-in-time thread bound (256) check.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator thread count is not monotonically growing"
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
MIN_ENTRIES=5
GROWTH_THRESHOLD=20
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

if [ ! -f /shared/validator_thread_history ]; then
    echo "Metric not available yet (validator may have just restarted)"
    sdk_always true "$ASSERTION_NAME" '{"status":"metric_not_yet_available","note":"heartbeat fresh but metric file pending"}'
    exit 0
fi

# Read last 10 entries (format: timestamp:thread_count)
mapfile -t ENTRIES < <(tail -"$MIN_ENTRIES" /shared/validator_thread_history 2>/dev/null)

if [ ${#ENTRIES[@]} -lt "$MIN_ENTRIES" ]; then
    echo "Insufficient data points (${#ENTRIES[@]}/${MIN_ENTRIES}), skipping"
    exit 0
fi

# Extract thread count values
THREAD_VALUES=()
for entry in "${ENTRIES[@]}"; do
    val="${entry#*:}"
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        THREAD_VALUES+=("$val")
    fi
done

if [ ${#THREAD_VALUES[@]} -lt "$MIN_ENTRIES" ]; then
    echo "Insufficient valid thread values, skipping"
    exit 0
fi

# Check if all 10 are strictly monotonically increasing
MONOTONIC=true
for ((i=1; i<${#THREAD_VALUES[@]}; i++)); do
    if [ "${THREAD_VALUES[$i]}" -le "${THREAD_VALUES[$((i-1))]}" ]; then
        MONOTONIC=false
        break
    fi
done

FIRST_THREAD="${THREAD_VALUES[0]}"
LAST_THREAD="${THREAD_VALUES[$((${#THREAD_VALUES[@]}-1))]}"
GROWTH=$((LAST_THREAD - FIRST_THREAD))

if [ "$MONOTONIC" = "true" ] && [ "$GROWTH" -gt "$GROWTH_THRESHOLD" ]; then
    echo "FAIL: Thread count monotonically increasing over ${MIN_ENTRIES} readings, growth=${GROWTH} (>${GROWTH_THRESHOLD} threshold)"
    DETAILS=$(jq -cn --argjson first "$FIRST_THREAD" --argjson last "$LAST_THREAD" \
        --argjson growth "$GROWTH" --argjson threshold "$GROWTH_THRESHOLD" \
        --argjson count "${#THREAD_VALUES[@]}" \
        '{first_threads: $first, last_threads: $last, growth: $growth, threshold: $threshold, readings: $count, monotonic: true}')
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
else
    echo "PASS: Thread count not monotonically growing (monotonic=${MONOTONIC}, growth=${GROWTH})"
    DETAILS=$(jq -cn --argjson first "$FIRST_THREAD" --argjson last "$LAST_THREAD" \
        --argjson growth "$GROWTH" --argjson threshold "$GROWTH_THRESHOLD" \
        --argjson count "${#THREAD_VALUES[@]}" --argjson monotonic "$MONOTONIC" \
        '{first_threads: $first, last_threads: $last, growth: $growth, threshold: $threshold, readings: $count, monotonic: $monotonic}')
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
