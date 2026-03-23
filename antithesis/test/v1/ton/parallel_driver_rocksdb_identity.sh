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
HEARTBEAT_MAX_AGE=60

IDENTITY_FILE="/shared/validator_rocksdb_identity"
FIRST_FILE="/shared/validator_rocksdb_identity_first"
HEARTBEAT_FILE="/shared/validator_heartbeat"

ASSERTION_NAME="RocksDB IDENTITY file is stable when validator is healthy"

sdk_catalog_always "${ASSERTION_NAME}"

echo "Checking RocksDB IDENTITY stability..."

# Use heartbeat-only precondition instead of all-3-ports.
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
if [[ "$age" -gt "$HEARTBEAT_MAX_AGE" ]]; then
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
