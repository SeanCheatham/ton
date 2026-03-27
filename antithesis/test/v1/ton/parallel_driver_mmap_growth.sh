#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator memory mapping count is not monotonically growing
# Reads /shared/validator_mmap_history (written by validator entrypoint heartbeat loop).
# If the last 5 consecutive readings are strictly monotonically increasing AND
# total growth exceeds 2000 mappings, emit always(false) — likely mmap leak.
# Detects slow mmap leaks (RocksDB SST handles, arena creation without release)
# invisible to the point-in-time 10,000 mapping bound check.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator memory mapping count is not monotonically growing"
HEARTBEAT_MAX_AGE=60
MIN_ENTRIES=5
GROWTH_THRESHOLD=2000

# Heartbeat precondition
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s > ${HEARTBEAT_MAX_AGE}s), skipping"
            sdk_always true "$ASSERTION_NAME" '{"status":"heartbeat_stale"}'
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"
        sdk_always true "$ASSERTION_NAME" '{"status":"heartbeat_invalid"}'
        exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"heartbeat_not_present"}'
    exit 0
fi

if [ ! -f /shared/validator_mmap_history ]; then
    echo "Mmap history file not present yet, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"history_not_available"}'
    exit 0
fi

# Read last entries (format: timestamp:mmap_count)
mapfile -t ENTRIES < <(tail -"$MIN_ENTRIES" /shared/validator_mmap_history 2>/dev/null)

if [ ${#ENTRIES[@]} -lt "$MIN_ENTRIES" ]; then
    echo "Insufficient data points (${#ENTRIES[@]}/${MIN_ENTRIES}), skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"insufficient_data"}'
    exit 0
fi

# Extract mmap count values
MMAP_VALUES=()
for entry in "${ENTRIES[@]}"; do
    val="${entry#*:}"
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        MMAP_VALUES+=("$val")
    fi
done

if [ ${#MMAP_VALUES[@]} -lt "$MIN_ENTRIES" ]; then
    echo "Insufficient valid mmap values, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"insufficient_valid_values"}'
    exit 0
fi

# Check if all readings are strictly monotonically increasing
MONOTONIC=true
for ((i=1; i<${#MMAP_VALUES[@]}; i++)); do
    if [ "${MMAP_VALUES[$i]}" -le "${MMAP_VALUES[$((i-1))]}" ]; then
        MONOTONIC=false
        break
    fi
done

FIRST_COUNT="${MMAP_VALUES[0]}"
LAST_COUNT="${MMAP_VALUES[$((${#MMAP_VALUES[@]}-1))]}"
GROWTH=$((LAST_COUNT - FIRST_COUNT))

if [ "$MONOTONIC" = "true" ] && [ "$GROWTH" -gt "$GROWTH_THRESHOLD" ]; then
    echo "FAIL: Mmap count monotonically increasing over ${MIN_ENTRIES} readings, growth=${GROWTH} (>${GROWTH_THRESHOLD} threshold)"
    DETAILS=$(jq -cn --argjson first "$FIRST_COUNT" --argjson last "$LAST_COUNT" \
        --argjson growth "$GROWTH" --argjson threshold "$GROWTH_THRESHOLD" \
        --argjson count "${#MMAP_VALUES[@]}" \
        '{first_count: $first, last_count: $last, growth: $growth, threshold: $threshold, readings: $count, monotonic: true}')
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
else
    echo "PASS: Mmap count not monotonically growing (monotonic=${MONOTONIC}, growth=${GROWTH})"
    DETAILS=$(jq -cn --argjson first "$FIRST_COUNT" --argjson last "$LAST_COUNT" \
        --argjson growth "$GROWTH" --argjson threshold "$GROWTH_THRESHOLD" \
        --argjson count "${#MMAP_VALUES[@]}" --argjson monotonic "$MONOTONIC" \
        '{first_count: $first, last_count: $last, growth: $growth, threshold: $threshold, readings: $count, monotonic: $monotonic}')
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
