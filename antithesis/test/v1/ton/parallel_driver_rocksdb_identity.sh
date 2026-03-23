#!/usr/bin/env bash
set -euo pipefail

# Driver workload: verify RocksDB IDENTITY file is stable when validator is healthy.
# RocksDB's IDENTITY file contains a unique UUID for the database instance.
# If this changes, the database was recreated from scratch (data loss) or corrupted.
# This is stronger than file existence checks — it verifies database identity
# continuity across fault injection.
# This is an "always" property: the IDENTITY must never change while healthy.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

IDENTITY_FILE="/shared/validator_rocksdb_identity"
FIRST_FILE="/shared/validator_rocksdb_identity_first"
HEARTBEAT_FILE="/shared/validator_heartbeat"

ASSERTION_NAME="RocksDB IDENTITY file is stable when validator is healthy"

sdk_catalog_always "${ASSERTION_NAME}"

echo "Checking RocksDB IDENTITY stability..."

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

# Step 2: Check heartbeat freshness
if [[ ! -f "$HEARTBEAT_FILE" ]]; then
    echo "SKIP: heartbeat file does not exist yet"
    exit 0
fi

hb_ts=$(cat "$HEARTBEAT_FILE" 2>/dev/null | tr -d '[:space:]')
now=$(date +%s)
if [[ -z "$hb_ts" ]] || ! [[ "$hb_ts" =~ ^[0-9]+$ ]]; then
    echo "SKIP: heartbeat value invalid"
    exit 0
fi
age=$((now - hb_ts))
if [[ "$age" -gt 30 ]]; then
    echo "SKIP: heartbeat is stale (${age}s old)"
    exit 0
fi

# Step 3: Read current identity
if [[ ! -f "$IDENTITY_FILE" ]]; then
    echo "SKIP: RocksDB identity file does not exist yet"
    exit 0
fi

current_identity=$(cat "$IDENTITY_FILE" 2>/dev/null | tr -d '[:space:]')
if [[ -z "$current_identity" ]]; then
    echo "SKIP: RocksDB identity file is empty"
    exit 0
fi

echo "  Current RocksDB identity: ${current_identity}"

# Step 4: First observation — store and pass
if [[ ! -f "$FIRST_FILE" ]]; then
    echo "  First observation, storing identity"
    echo "$current_identity" > "$FIRST_FILE"
    sdk_always true "${ASSERTION_NAME}" \
        "$(jq -cn --arg id "$current_identity" '{first_observation: true, identity: $id}')"
    exit 0
fi

# Step 5: Compare with first observation
first_identity=$(cat "$FIRST_FILE" 2>/dev/null | tr -d '[:space:]')
if [[ -z "$first_identity" ]]; then
    echo "  First identity file is empty, resetting"
    echo "$current_identity" > "$FIRST_FILE"
    exit 0
fi

echo "  First observed identity: ${first_identity}"

if [[ "$current_identity" == "$first_identity" ]]; then
    echo "PASS: RocksDB identity is stable"
    sdk_always true "${ASSERTION_NAME}" \
        "$(jq -cn --arg cur "$current_identity" --arg first "$first_identity" \
            '{current_identity: $cur, first_identity: $first, stable: true}')"
else
    echo "FAIL: RocksDB identity changed! first=${first_identity} current=${current_identity}"
    sdk_always false "${ASSERTION_NAME}" \
        "$(jq -cn --arg cur "$current_identity" --arg first "$first_identity" \
            '{current_identity: $cur, first_identity: $first, stable: false}')"
fi

exit 0
