#!/usr/bin/env bash
set -euo pipefail

# Driver workload: verify that validator downtime is bounded after initial startup.
# Tracks when the validator was last seen with all ports up (timestamp in
# /shared/validator_last_up). Each invocation:
#   - If all 3 ports are up: update last_up timestamp, emit always(true)
#   - If any port is down: compare current time to last_up
#     - If gap <= 180s: emit always(true) — downtime is within bounds
#     - If gap > 180s: emit always(false) — recovery is taking too long
#     - If no last_up file exists: write current time (benefit of doubt on first observation)
# This catches validators that crash and never recover, or that take excessively
# long to restart after fault injection. Complements existing recovery assertions
# by adding a time bound.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"
LAST_UP_FILE="/shared/validator_last_up"
STARTUP_ID_FILE="/shared/validator_startup_id"
PREV_STARTUP_FILE="/shared/_prev_validator_startup_id"
MAX_DOWNTIME=180

ASSERTION_NAME="Validator downtime is bounded after initial startup"

# Catalog the assertion on first invocation
sdk_catalog_always "${ASSERTION_NAME}"

echo "Checking validator downtime bounds..."

# Restart detection: if the validator's startup_id changed, it restarted —
# reset the downtime timer to give it a full grace period for recovery.
if [ -f "${STARTUP_ID_FILE}" ]; then
    cur_startup=$(cat "${STARTUP_ID_FILE}" 2>/dev/null | tr -d '[:space:]')
    prev_startup=$(cat "${PREV_STARTUP_FILE}" 2>/dev/null | tr -d '[:space:]' || true)
    if [ -n "${cur_startup}" ] && [ "${cur_startup}" != "${prev_startup}" ]; then
        echo "Validator restart detected (startup_id: ${prev_startup} -> ${cur_startup}), resetting downtime timer"
        echo "$(date +%s)" > "${LAST_UP_FILE}"
        echo "${cur_startup}" > "${PREV_STARTUP_FILE}"
    fi
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
    # Validator is fully up — update last_up timestamp and emit true
    echo "${now_ts}" > "${LAST_UP_FILE}"
    echo "PASS: all ports reachable, updating last_up to ${now_ts}"
    sdk_always true "${ASSERTION_NAME}" \
        "$(jq -cn --argjson ts "${now_ts}" \
            '{status: "up", last_up: $ts, downtime_seconds: 0}')"
else
    # Validator is (partially) down — check how long it's been down
    echo "Validator is down (udp=${udp_up}, console=${console_up}, lite=${lite_up})"

    if [ ! -f "${LAST_UP_FILE}" ]; then
        # First time seeing validator down and no prior up recorded — benefit of doubt
        echo "${now_ts}" > "${LAST_UP_FILE}"
        echo "SKIP: no prior up timestamp, initializing last_up to now"
        exit 0
    fi

    last_up_ts=$(cat "${LAST_UP_FILE}" 2>/dev/null || true)
    last_up_ts=$(echo "$last_up_ts" | tr -d '[:space:]')

    if [ -z "${last_up_ts}" ] || ! [[ "${last_up_ts}" =~ ^[0-9]+$ ]]; then
        # Invalid data in file — reset and skip
        echo "${now_ts}" > "${LAST_UP_FILE}"
        echo "SKIP: invalid last_up data, resetting"
        exit 0
    fi

    downtime=$(( now_ts - last_up_ts ))

    if [ "${downtime}" -le "${MAX_DOWNTIME}" ]; then
        echo "PASS: validator is down but only for ${downtime}s (max: ${MAX_DOWNTIME}s)"
        sdk_always true "${ASSERTION_NAME}" \
            "$(jq -cn --argjson dt "${downtime}" --argjson max "${MAX_DOWNTIME}" \
                --argjson last "${last_up_ts}" --argjson now "${now_ts}" \
                '{status: "down_within_bounds", downtime_seconds: $dt, max_downtime: $max, last_up: $last, now: $now}')"
    else
        echo "FAIL: validator has been down for ${downtime}s — exceeds ${MAX_DOWNTIME}s bound"
        sdk_always false "${ASSERTION_NAME}" \
            "$(jq -cn --argjson dt "${downtime}" --argjson max "${MAX_DOWNTIME}" \
                --argjson last "${last_up_ts}" --argjson now "${now_ts}" \
                '{status: "downtime_exceeded", downtime_seconds: $dt, max_downtime: $max, last_up: $last, now: $now, reason: "downtime exceeds bound"}')"
    fi
fi

exit 0
