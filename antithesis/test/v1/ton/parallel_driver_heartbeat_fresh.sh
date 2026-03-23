#!/usr/bin/env bash
set -euo pipefail

# Driver workload: verify the validator heartbeat is fresh when ports are reachable.
# The validator entrypoint writes epoch timestamps to /shared/validator_heartbeat
# every 5 seconds. If the validator's UDP port is reachable (process appears alive)
# but the heartbeat is stale (>30s old) or missing, the validator is likely hung,
# deadlocked, or in a zombie state — a critical failure invisible to port probing.
# This is an "always" property: whenever ports are up, the heartbeat must be fresh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
HEARTBEAT_FILE="/shared/validator_heartbeat"
MAX_AGE=30

ASSERTION_NAME="Validator heartbeat is fresh when ports are reachable"

# Catalog the assertion on first invocation
sdk_catalog_always "${ASSERTION_NAME}"

echo "Checking validator heartbeat freshness..."

# Step 1: Check if the main UDP port is reachable.
# If it's down, the validator is fully down — skip the heartbeat check.
if ! nc -z -u -w 2 "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null; then
    echo "SKIP: validator UDP port ${UDP_PORT} is not reachable (validator may be down)"
    exit 0
fi

echo "UDP port ${UDP_PORT} is reachable, checking heartbeat..."

# Step 2: Check heartbeat file exists
if [ ! -f "${HEARTBEAT_FILE}" ]; then
    echo "FAIL: heartbeat file ${HEARTBEAT_FILE} does not exist but ports are up"
    sdk_always false "${ASSERTION_NAME}" \
        "$(jq -cn '{reason: "heartbeat file missing", heartbeat_file: "missing"}')"
    exit 0
fi

# Step 3: Read heartbeat timestamp and compare to current time
heartbeat_ts=$(cat "${HEARTBEAT_FILE}" 2>/dev/null | tr -d '[:space:]')
now_ts=$(date +%s)

if [ -z "${heartbeat_ts}" ] || ! [[ "${heartbeat_ts}" =~ ^[0-9]+$ ]]; then
    echo "FAIL: heartbeat file exists but contains invalid data: '${heartbeat_ts}'"
    sdk_always false "${ASSERTION_NAME}" \
        "$(jq -cn --arg val "${heartbeat_ts}" '{reason: "invalid heartbeat value", raw_value: $val}')"
    exit 0
fi

delta=$(( now_ts - heartbeat_ts ))

# Step 4: Emit the Always assertion
if [ "${delta}" -le "${MAX_AGE}" ]; then
    echo "PASS: heartbeat is fresh (age: ${delta}s, max: ${MAX_AGE}s)"
    sdk_always true "${ASSERTION_NAME}" \
        "$(jq -cn --argjson delta "${delta}" --argjson max "${MAX_AGE}" --argjson ts "${heartbeat_ts}" \
            '{heartbeat_age_seconds: $delta, max_allowed_seconds: $max, heartbeat_timestamp: $ts}')"
else
    echo "FAIL: heartbeat is stale (age: ${delta}s, max: ${MAX_AGE}s) — possible hang/deadlock"
    sdk_always false "${ASSERTION_NAME}" \
        "$(jq -cn --argjson delta "${delta}" --argjson max "${MAX_AGE}" --argjson ts "${heartbeat_ts}" \
            '{heartbeat_age_seconds: $delta, max_allowed_seconds: $max, heartbeat_timestamp: $ts, reason: "stale heartbeat"}')"
fi

exit 0
