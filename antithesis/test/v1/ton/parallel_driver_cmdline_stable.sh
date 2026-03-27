#!/usr/bin/env bash
set -euo pipefail

# Driver workload: verify the validator process command line is stable.
# The md5sum of /proc/1/cmdline is written by the entrypoint heartbeat loop
# to /shared/validator_cmdline_hash. On first healthy observation, we store
# the hash. On subsequent observations, we verify it hasn't changed.
# A changed cmdline means the process was replaced (exec'd) or restarted
# with different arguments — both indicate serious issues.
# This is an "always" property: the cmdline hash must never change.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
HEARTBEAT_MAX_AGE=60

HASH_FILE="/shared/validator_cmdline_hash"
FIRST_FILE="/shared/validator_cmdline_first"
HEARTBEAT_FILE="/shared/validator_heartbeat"

ASSERTION_NAME="Validator process command line is stable when healthy"

sdk_catalog_always "${ASSERTION_NAME}"

echo "Checking validator process command line stability..."

# Use heartbeat-only precondition instead of all-3-ports.
if [[ ! -f "$HEARTBEAT_FILE" ]]; then
    echo "SKIP: heartbeat file does not exist yet"
    exit 0
fi

hb_ts=$(cat "$HEARTBEAT_FILE" 2>/dev/null || true)
hb_ts=$(echo "$hb_ts" | tr -d '[:space:]')
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

# Step 3: Read current cmdline hash
if [[ ! -f "$HASH_FILE" ]]; then
    echo "Metric not available yet (validator may have just restarted)"
    sdk_always true "${ASSERTION_NAME}" '{"status":"metric_not_yet_available","note":"heartbeat fresh but metric file pending"}'
    exit 0
fi

current_hash=$(cat "$HASH_FILE" 2>/dev/null || true)
current_hash=$(echo "$current_hash" | tr -d '[:space:]')
if [[ -z "$current_hash" ]]; then
    echo "SKIP: cmdline hash file is empty"
    exit 0
fi

echo "  Current cmdline hash: ${current_hash}"

# Step 4: First observation — store and pass
if [[ ! -f "$FIRST_FILE" ]]; then
    echo "  First observation, storing hash"
    echo "$current_hash" > "$FIRST_FILE"
    sdk_always true "${ASSERTION_NAME}" \
        "$(jq -cn --arg hash "$current_hash" '{first_observation: true, hash: $hash}')"
    exit 0
fi

# Step 5: Compare with first observation
first_hash=$(cat "$FIRST_FILE" 2>/dev/null || true)
first_hash=$(echo "$first_hash" | tr -d '[:space:]')
if [[ -z "$first_hash" ]]; then
    echo "  First hash file is empty, resetting"
    echo "$current_hash" > "$FIRST_FILE"
    exit 0
fi

echo "  First observed hash: ${first_hash}"

if [[ "$current_hash" == "$first_hash" ]]; then
    echo "PASS: cmdline hash is stable"
    sdk_always true "${ASSERTION_NAME}" \
        "$(jq -cn --arg cur "$current_hash" --arg first "$first_hash" \
            '{current_hash: $cur, first_hash: $first, stable: true}')"
else
    echo "FAIL: cmdline hash changed! first=${first_hash} current=${current_hash}"
    sdk_always false "${ASSERTION_NAME}" \
        "$(jq -cn --arg cur "$current_hash" --arg first "$first_hash" \
            '{current_hash: $cur, first_hash: $first, stable: false}')"
fi

exit 0
