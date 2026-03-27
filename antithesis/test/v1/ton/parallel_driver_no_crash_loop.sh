#!/usr/bin/env bash
set -euo pipefail

# Driver workload: detect crash-loop / rapid oscillation of the validator.
# Tracks state transitions (up/down) with timestamps in /shared/validator_transitions.
# Each invocation:
#   1. Checks all 3 ports to determine current state (up/down)
#   2. Appends "timestamp:state" to the transition log
#   3. Reads recent entries and counts down→up transitions in a 60-second window
#   4. If >3 down→up transitions in that window: emit always(false) — crash loop
#   5. Otherwise: emit always(true)
#
# Resets the transition log when a new validator startup is detected (via startup_id),
# so that Antithesis-injected container restarts don't accumulate false transitions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"
TRANSITIONS_FILE="/shared/validator_transitions"
STARTUP_ID_FILE="/shared/validator_startup_id"
PREV_STARTUP_FILE="/shared/_prev_crash_loop_startup_id"
MAX_TRANSITIONS=3
WINDOW_SECONDS=60

ASSERTION_NAME="Validator does not crash-loop or oscillate rapidly"

# Catalog the assertion on first invocation
sdk_catalog_always "${ASSERTION_NAME}"

echo "Checking for crash-loop / rapid oscillation..."

# Heartbeat precondition: skip during fault injection when validator is dead
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s), skipping"
            exit 0
        fi
    else
        echo "Heartbeat invalid, skipping"; exit 0
    fi
else
    echo "Heartbeat not present, skipping"; exit 0
fi

# Detect validator restart via startup_id — clear transition history on restart.
# Antithesis may restart the container as part of fault injection; those restarts
# should not count toward the crash-loop threshold.
CURRENT_STARTUP=$(cat "$STARTUP_ID_FILE" 2>/dev/null || true)
CURRENT_STARTUP=$(echo "$CURRENT_STARTUP" | tr -d '[:space:]')
PREV_STARTUP=$(cat "$PREV_STARTUP_FILE" 2>/dev/null || true)
PREV_STARTUP=$(echo "$PREV_STARTUP" | tr -d '[:space:]')
if [ -n "$CURRENT_STARTUP" ] && [ "$CURRENT_STARTUP" != "$PREV_STARTUP" ]; then
    echo "Validator restarted (startup_id changed), resetting transition log"
    echo "$CURRENT_STARTUP" > "$PREV_STARTUP_FILE"
    > "${TRANSITIONS_FILE}"
fi

# Check all three ports
udp_up=false
console_up=false
lite_up=false

nc -z -u -w 2 "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null && udp_up=true
nc -z -w 1 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null && console_up=true
nc -z -w 1 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null && lite_up=true

now_ts=$(date +%s)

if [[ "$udp_up" == "true" && "$console_up" == "true" && "$lite_up" == "true" ]]; then
    current_state="up"
else
    current_state="down"
fi

# Append current observation to transition log
echo "${now_ts}:${current_state}" >> "${TRANSITIONS_FILE}"

# Read recent entries within the sliding window
window_start=$(( now_ts - WINDOW_SECONDS ))
transition_count=0
prev_state=""

# Read the transition log and count down→up transitions in the window
while IFS=: read -r ts state; do
    # Skip malformed lines
    [[ "${ts}" =~ ^[0-9]+$ ]] || continue
    # Only consider entries within the window
    [ "${ts}" -ge "${window_start}" ] || continue

    # Count down→up transitions
    if [[ "${prev_state}" == "down" && "${state}" == "up" ]]; then
        transition_count=$(( transition_count + 1 ))
    fi
    prev_state="${state}"
done < "${TRANSITIONS_FILE}"

echo "Window [${window_start}..${now_ts}]: ${transition_count} down→up transitions (max: ${MAX_TRANSITIONS})"

if [ "${transition_count}" -gt "${MAX_TRANSITIONS}" ]; then
    echo "FAIL: ${transition_count} down→up transitions in ${WINDOW_SECONDS}s — crash loop detected"
    sdk_always false "${ASSERTION_NAME}" \
        "$(jq -cn --argjson count "${transition_count}" --argjson max "${MAX_TRANSITIONS}" \
            --argjson window "${WINDOW_SECONDS}" --argjson now "${now_ts}" \
            --arg state "${current_state}" \
            '{status: "crash_loop_detected", down_up_transitions: $count, max_allowed: $max, window_seconds: $window, current_state: $state, now: $now}')"
else
    echo "PASS: oscillation within bounds (${transition_count} <= ${MAX_TRANSITIONS})"
    sdk_always true "${ASSERTION_NAME}" \
        "$(jq -cn --argjson count "${transition_count}" --argjson max "${MAX_TRANSITIONS}" \
            --argjson window "${WINDOW_SECONDS}" --argjson now "${now_ts}" \
            --arg state "${current_state}" \
            '{status: "stable", down_up_transitions: $count, max_allowed: $max, window_seconds: $window, current_state: $state, now: $now}')"
fi

exit 0
