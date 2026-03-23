#!/usr/bin/env bash
set -euo pipefail

# Driver workload: verify the validator's RocksDB database exists and is
# non-decreasing in size when the validator is healthy (all 3 ports up).
# The validator entrypoint writes the DB directory size (bytes) to
# /shared/validator_db_size every 5 seconds. This driver compares the
# current value to the previous observation stored in
# /shared/validator_db_size_prev.  A decrease or zero size while all ports
# are up indicates data loss, corruption, or silent state eviction.
# This is an "always" property: whenever the validator is healthy, the DB
# size must be positive and non-decreasing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

DB_SIZE_FILE="/shared/validator_db_size"
PREV_SIZE_FILE="/shared/validator_db_size_prev"

ASSERTION_NAME="Validator database exists and grows when healthy"

# Catalog the assertion on first invocation
sdk_catalog_always "${ASSERTION_NAME}"

echo "Checking validator database size..."

# Step 1: Check all 3 ports — only assert when validator is fully healthy
udp_up=false
console_up=false
lite_up=false

nc -z -u -w 2 "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null && udp_up=true
nc -z -w 1 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null && console_up=true
nc -z -w 1 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "SKIP: not all ports are up (udp=${udp_up}, console=${console_up}, lite=${lite_up})"
    exit 0
fi

echo "All ports are up, checking DB size..."

# Step 2: Read current DB size from shared volume
if [ ! -f "${DB_SIZE_FILE}" ]; then
    echo "FAIL: DB size file ${DB_SIZE_FILE} does not exist but validator is healthy"
    sdk_always false "${ASSERTION_NAME}" \
        "$(jq -cn '{reason: "db_size file missing"}')"
    exit 0
fi

current_size=$(cat "${DB_SIZE_FILE}" 2>/dev/null | tr -d '[:space:]')

if [ -z "${current_size}" ] || ! [[ "${current_size}" =~ ^[0-9]+$ ]]; then
    echo "FAIL: DB size file contains invalid data: '${current_size}'"
    sdk_always false "${ASSERTION_NAME}" \
        "$(jq -cn --arg val "${current_size}" '{reason: "invalid db_size value", raw_value: $val}')"
    exit 0
fi

# Step 3: Check size is non-zero
if [ "${current_size}" -eq 0 ]; then
    echo "FAIL: DB size is zero while validator is healthy"
    sdk_always false "${ASSERTION_NAME}" \
        "$(jq -cn '{reason: "db_size is zero", current_bytes: 0}')"
    exit 0
fi

# Step 4: Compare to previous observation (if available)
if [ -f "${PREV_SIZE_FILE}" ]; then
    prev_size=$(cat "${PREV_SIZE_FILE}" 2>/dev/null | tr -d '[:space:]')
    if [ -n "${prev_size}" ] && [[ "${prev_size}" =~ ^[0-9]+$ ]] && [ "${prev_size}" -gt 0 ]; then
        if [ "${current_size}" -lt "${prev_size}" ]; then
            echo "FAIL: DB size decreased from ${prev_size} to ${current_size} bytes"
            sdk_always false "${ASSERTION_NAME}" \
                "$(jq -cn --argjson cur "${current_size}" --argjson prev "${prev_size}" \
                    '{reason: "db_size decreased", current_bytes: $cur, previous_bytes: $prev, delta: ($cur - $prev)}')"
            # Still update prev so we track from new baseline
            echo "${current_size}" > "${PREV_SIZE_FILE}"
            exit 0
        fi
        echo "PASS: DB size non-decreasing (prev=${prev_size}, cur=${current_size})"
        sdk_always true "${ASSERTION_NAME}" \
            "$(jq -cn --argjson cur "${current_size}" --argjson prev "${prev_size}" \
                '{current_bytes: $cur, previous_bytes: $prev, delta: ($cur - $prev)}')"
    else
        echo "PASS: DB size is ${current_size} bytes (previous value invalid, resetting)"
        sdk_always true "${ASSERTION_NAME}" \
            "$(jq -cn --argjson cur "${current_size}" '{current_bytes: $cur, previous_bytes: null, reason: "first valid observation"}')"
    fi
else
    echo "PASS: DB size is ${current_size} bytes (first observation)"
    sdk_always true "${ASSERTION_NAME}" \
        "$(jq -cn --argjson cur "${current_size}" '{current_bytes: $cur, previous_bytes: null, reason: "first observation"}')"
fi

# Save current size for next invocation
echo "${current_size}" > "${PREV_SIZE_FILE}"

exit 0
