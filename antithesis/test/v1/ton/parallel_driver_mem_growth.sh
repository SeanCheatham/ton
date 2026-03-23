#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator RSS memory is not monotonically growing
# Reads /shared/validator_rss_history (written by validator entrypoint heartbeat loop).
# If the last 10 consecutive readings are strictly monotonically increasing AND
# total growth exceeds 50MB (50000 KB), emit always(false) — likely memory leak.
# Detects slow leaks invisible to the point-in-time 2GB RSS bound check.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator RSS memory is not monotonically growing"
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
MIN_ENTRIES=5
GROWTH_THRESHOLD_KB=50000  # 50MB
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

if [ ! -f /shared/validator_rss_history ]; then
    echo "RSS history file not present yet, skipping"
    exit 0
fi

# Read last 10 entries (format: timestamp:rss_kb)
mapfile -t ENTRIES < <(tail -"$MIN_ENTRIES" /shared/validator_rss_history 2>/dev/null)

if [ ${#ENTRIES[@]} -lt "$MIN_ENTRIES" ]; then
    echo "Insufficient data points (${#ENTRIES[@]}/${MIN_ENTRIES}), skipping"
    exit 0
fi

# Extract RSS values
RSS_VALUES=()
for entry in "${ENTRIES[@]}"; do
    val="${entry#*:}"
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        RSS_VALUES+=("$val")
    fi
done

if [ ${#RSS_VALUES[@]} -lt "$MIN_ENTRIES" ]; then
    echo "Insufficient valid RSS values, skipping"
    exit 0
fi

# Check if all 10 are strictly monotonically increasing
MONOTONIC=true
for ((i=1; i<${#RSS_VALUES[@]}; i++)); do
    if [ "${RSS_VALUES[$i]}" -le "${RSS_VALUES[$((i-1))]}" ]; then
        MONOTONIC=false
        break
    fi
done

FIRST_RSS="${RSS_VALUES[0]}"
LAST_RSS="${RSS_VALUES[$((${#RSS_VALUES[@]}-1))]}"
GROWTH=$((LAST_RSS - FIRST_RSS))

if [ "$MONOTONIC" = "true" ] && [ "$GROWTH" -gt "$GROWTH_THRESHOLD_KB" ]; then
    echo "FAIL: RSS monotonically increasing over ${MIN_ENTRIES} readings, growth=${GROWTH}KB (>${GROWTH_THRESHOLD_KB}KB threshold)"
    DETAILS=$(jq -cn --argjson first "$FIRST_RSS" --argjson last "$LAST_RSS" \
        --argjson growth "$GROWTH" --argjson threshold "$GROWTH_THRESHOLD_KB" \
        --argjson count "${#RSS_VALUES[@]}" \
        '{first_rss_kb: $first, last_rss_kb: $last, growth_kb: $growth, threshold_kb: $threshold, readings: $count, monotonic: true}')
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
else
    echo "PASS: RSS not monotonically growing (monotonic=${MONOTONIC}, growth=${GROWTH}KB)"
    DETAILS=$(jq -cn --argjson first "$FIRST_RSS" --argjson last "$LAST_RSS" \
        --argjson growth "$GROWTH" --argjson threshold "$GROWTH_THRESHOLD_KB" \
        --argjson count "${#RSS_VALUES[@]}" --argjson monotonic "$MONOTONIC" \
        '{first_rss_kb: $first, last_rss_kb: $last, growth_kb: $growth, threshold_kb: $threshold, readings: $count, monotonic: $monotonic}')
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
