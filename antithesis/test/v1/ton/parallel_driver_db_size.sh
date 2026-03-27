#!/usr/bin/env bash
set -euo pipefail

# Driver workload: verify the validator's RocksDB database exists and has
# positive size when the validator is healthy (all 3 ports up).
# The validator entrypoint writes the DB directory size (bytes) to
# /shared/validator_db_size every 5 seconds. This driver checks that the
# size is positive. Note: RocksDB compaction legitimately reduces directory
# size (old SST files are merged and deleted), so we do NOT require
# non-decreasing size — only that the DB exists and is non-empty.
# This is an "always" property: whenever the validator is healthy, the DB
# size must be positive.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

DB_SIZE_FILE="/shared/validator_db_size"

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

current_size=$(cat "${DB_SIZE_FILE}" 2>/dev/null || true)
current_size=$(echo "$current_size" | tr -d '[:space:]')

if [ -z "${current_size}" ] || ! [[ "${current_size}" =~ ^[0-9]+$ ]]; then
    echo "FAIL: DB size file contains invalid data: '${current_size}'"
    sdk_always false "${ASSERTION_NAME}" \
        "$(jq -cn --arg val "${current_size}" '{reason: "invalid db_size value", raw_value: $val}')"
    exit 0
fi

# Step 3: Check size is non-zero
# Note: we do NOT check for non-decreasing size because RocksDB compaction
# legitimately reduces directory size by merging and deleting old SST files.
if [ "${current_size}" -eq 0 ]; then
    echo "FAIL: DB size is zero while validator is healthy"
    sdk_always false "${ASSERTION_NAME}" \
        "$(jq -cn '{reason: "db_size is zero", current_bytes: 0}')"
    exit 0
fi

echo "PASS: DB size is ${current_size} bytes (positive)"
sdk_always true "${ASSERTION_NAME}" \
    "$(jq -cn --argjson cur "${current_size}" '{current_bytes: $cur}')"

exit 0
