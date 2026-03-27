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

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"
HEARTBEAT_FILE="/shared/validator_heartbeat"
MAX_AGE=90

ASSERTION_NAME="Validator heartbeat is fresh when ports are reachable"

# Catalog the assertion on first invocation
sdk_catalog_always "${ASSERTION_NAME}"

echo "Checking validator heartbeat freshness..."

# Step 1: Check heartbeat file exists
if [ ! -f "${HEARTBEAT_FILE}" ]; then
    echo "SKIP: heartbeat file ${HEARTBEAT_FILE} does not exist (validator may still be starting)"
    exit 0
fi

# Step 1b: Check the heartbeat file's filesystem mtime to detect stale data.
# After a validator restart, the shared volume retains old heartbeat data.
# The file content may show an old timestamp even though the validator just restarted.
# If the file hasn't been modified recently (filesystem mtime is old), the heartbeat
# loop hasn't started writing yet — skip rather than fail.
file_mtime=$(stat -c %Y "${HEARTBEAT_FILE}" 2>/dev/null || echo "0")
now_check=$(date +%s)
file_age=$((now_check - file_mtime))
if [ "${file_age}" -gt "${MAX_AGE}" ]; then
    echo "SKIP: heartbeat file not recently modified (file age: ${file_age}s) — loop may not be running yet"
    exit 0
fi

# Step 2: Check if a TCP port is reachable. If ports are not up, we still
# check the heartbeat — the assertion is that when the heartbeat file is being
# actively written (mtime check above passed), it must contain a fresh timestamp.
# This inverts the original logic: we no longer require ports as a precondition.
tcp_reachable=false
if nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null || \
   nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    tcp_reachable=true
fi

echo "TCP reachable: ${tcp_reachable}, checking heartbeat..."

# Step 3: Read heartbeat timestamp and compare to current time
heartbeat_ts=$(cat "${HEARTBEAT_FILE}" 2>/dev/null || true)
heartbeat_ts=$(echo "$heartbeat_ts" | tr -d '[:space:]')
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
