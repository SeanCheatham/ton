#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator socket count is not monotonically growing
# Reads /shared/validator_sock_history (written by validator entrypoint heartbeat loop).
# If the last 5 consecutive readings are strictly monotonically increasing AND
# total growth exceeds 50 sockets, emit always(false) — likely socket/connection leak.
# Complements the point-in-time socket bound check.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator socket count is not monotonically growing"
VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
MIN_ENTRIES=5
GROWTH_THRESHOLD=50
HEARTBEAT_MAX_AGE=60
STARTUP_GRACE=60          # seconds after startup to ignore monotonic growth (startup socket ramp)

# Use heartbeat-only precondition instead of all-3-ports.
# Under fault injection, all 3 ports are rarely up simultaneously for the
# 25+ seconds needed to accumulate 5 readings. The heartbeat file proves
# the validator process is actively running, which is sufficient context.
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
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

if [ ! -f /shared/validator_sock_history ]; then
    echo "Metric not available yet (validator may have just restarted)"
    sdk_always true "$ASSERTION_NAME" '{"status":"metric_not_yet_available","note":"heartbeat fresh but metric file pending"}'
    exit 0
fi

# Read last N entries (format: timestamp:sock_count)
mapfile -t ENTRIES < <(tail -"$MIN_ENTRIES" /shared/validator_sock_history 2>/dev/null)

if [ ${#ENTRIES[@]} -lt "$MIN_ENTRIES" ]; then
    echo "Insufficient data points (${#ENTRIES[@]}/${MIN_ENTRIES}), skipping"
    exit 0
fi

# Extract timestamps and socket count values
SOCK_VALUES=()
ENTRY_TIMESTAMPS=()
for entry in "${ENTRIES[@]}"; do
    ts="${entry%%:*}"
    val="${entry#*:}"
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        SOCK_VALUES+=("$val")
        ENTRY_TIMESTAMPS+=("$ts")
    fi
done

if [ ${#SOCK_VALUES[@]} -lt "$MIN_ENTRIES" ]; then
    echo "Insufficient valid socket values, skipping"
    exit 0
fi

# Check if all entries are strictly monotonically increasing
MONOTONIC=true
for ((i=1; i<${#SOCK_VALUES[@]}; i++)); do
    if [ "${SOCK_VALUES[$i]}" -le "${SOCK_VALUES[$((i-1))]}" ]; then
        MONOTONIC=false
        break
    fi
done

FIRST_SOCK="${SOCK_VALUES[0]}"
LAST_SOCK="${SOCK_VALUES[$((${#SOCK_VALUES[@]}-1))]}"
GROWTH=$((LAST_SOCK - FIRST_SOCK))

# Startup grace: if the oldest reading in our window is within STARTUP_GRACE
# seconds of the validator start, skip the monotonic growth check.
# During startup the validator opens peer connections, etc., causing
# a legitimate socket ramp from ~3 to ~119.
IN_STARTUP_GRACE=false
if [ -f /shared/validator_startup_id ]; then
    STARTUP_NS=$(cat /shared/validator_startup_id 2>/dev/null || true)
    STARTUP_NS=$(echo "$STARTUP_NS" | tr -d '[:space:]')
    if [[ "$STARTUP_NS" =~ ^[0-9]+$ ]] && [ "${#ENTRY_TIMESTAMPS[@]}" -gt 0 ]; then
        STARTUP_S=$((STARTUP_NS / 1000000000))
        OLDEST_TS="${ENTRY_TIMESTAMPS[0]}"
        if [[ "$OLDEST_TS" =~ ^[0-9]+$ ]]; then
            SINCE_STARTUP=$((OLDEST_TS - STARTUP_S))
            if [ "$SINCE_STARTUP" -lt "$STARTUP_GRACE" ]; then
                IN_STARTUP_GRACE=true
            fi
        fi
    fi
fi

if [ "$IN_STARTUP_GRACE" = "true" ] && [ "$MONOTONIC" = "true" ] && [ "$GROWTH" -gt "$GROWTH_THRESHOLD" ]; then
    echo "PASS (startup grace): Socket growth=${GROWTH} monotonic=${MONOTONIC} but within ${STARTUP_GRACE}s of startup — expected ramp"
    DETAILS=$(jq -cn --argjson first "$FIRST_SOCK" --argjson last "$LAST_SOCK" \
        --argjson growth "$GROWTH" --argjson threshold "$GROWTH_THRESHOLD" \
        --argjson count "${#SOCK_VALUES[@]}" \
        '{first_sock: $first, last_sock: $last, growth: $growth, threshold: $threshold, readings: $count, monotonic: true, startup_grace: true}')
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
elif [ "$MONOTONIC" = "true" ] && [ "$GROWTH" -gt "$GROWTH_THRESHOLD" ]; then
    echo "FAIL: Socket count monotonically increasing over ${MIN_ENTRIES} readings, growth=${GROWTH} (>${GROWTH_THRESHOLD} threshold)"
    DETAILS=$(jq -cn --argjson first "$FIRST_SOCK" --argjson last "$LAST_SOCK" \
        --argjson growth "$GROWTH" --argjson threshold "$GROWTH_THRESHOLD" \
        --argjson count "${#SOCK_VALUES[@]}" \
        '{first_sock: $first, last_sock: $last, growth: $growth, threshold: $threshold, readings: $count, monotonic: true}')
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
else
    echo "PASS: Socket count not monotonically growing (monotonic=${MONOTONIC}, growth=${GROWTH})"
    DETAILS=$(jq -cn --argjson first "$FIRST_SOCK" --argjson last "$LAST_SOCK" \
        --argjson growth "$GROWTH" --argjson threshold "$GROWTH_THRESHOLD" \
        --argjson count "${#SOCK_VALUES[@]}" --argjson monotonic "$MONOTONIC" \
        '{first_sock: $first, last_sock: $last, growth: $growth, threshold: $threshold, readings: $count, monotonic: $monotonic}')
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
