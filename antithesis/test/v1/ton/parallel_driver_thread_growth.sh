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
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"
MIN_ENTRIES=10
GROWTH_THRESHOLD=20

# Only check when validator is healthy (all ports up)
if ! nc -z -w 1 -u "$VALIDATOR_HOST" "$VALIDATOR_PORT" 2>/dev/null; then
    echo "Validator UDP not reachable, skipping"
    sleep 10
    exit 0
fi
if ! nc -z -w 1 "$VALIDATOR_HOST" "$CONSOLE_PORT" 2>/dev/null || \
   ! nc -z -w 1 "$VALIDATOR_HOST" "$LITE_PORT" 2>/dev/null; then
    echo "Validator TCP ports not all reachable, skipping"
    sleep 10
    exit 0
fi

if [ ! -f /shared/validator_thread_history ]; then
    echo "Thread history file not present yet, skipping"
    sleep 10
    exit 0
fi

# Read last 10 entries (format: timestamp:thread_count)
mapfile -t ENTRIES < <(tail -"$MIN_ENTRIES" /shared/validator_thread_history 2>/dev/null)

if [ ${#ENTRIES[@]} -lt "$MIN_ENTRIES" ]; then
    echo "Insufficient data points (${#ENTRIES[@]}/${MIN_ENTRIES}), skipping"
    sleep 10
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
    sleep 10
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

sleep 10
exit 0
