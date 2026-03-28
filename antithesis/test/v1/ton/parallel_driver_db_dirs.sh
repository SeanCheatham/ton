#!/usr/bin/env bash
set -euo pipefail

# Driver workload: verify database directory count doesn't drop significantly.
# The number of subdirectories under /var/ton-work/db/ should be roughly stable.
# Small decreases (1-3 dirs) are normal — RocksDB removes obsolete SST directories
# during garbage collection / compaction. A large drop (4+) may indicate corruption.
# This is distinct from DB size checks (bytes) and file count checks (files) —
# it monitors the directory tree structure itself.
# This is an "always" property: directory count must not drop beyond tolerance.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
HEARTBEAT_MAX_AGE=60
# RocksDB may remove 1-3 obsolete directories during compaction/GC.
# Only flag drops larger than this tolerance as potential corruption.
TOLERANCE=3

DIR_COUNT_FILE="/shared/validator_db_dir_count"
PREV_FILE="/shared/validator_db_dir_prev"
HEARTBEAT_FILE="/shared/validator_heartbeat"

ASSERTION_NAME="Validator database directory count is non-decreasing when healthy"

sdk_catalog_always "${ASSERTION_NAME}"

echo "Checking validator database directory count..."

# Detect validator restart via startup_id — reset previous count on restart.
# After Antithesis restarts a container, the DB directory structure may change;
# comparing against pre-restart counts would produce false violations.
STARTUP_ID_FILE="/shared/validator_startup_id"
PREV_STARTUP_FILE="/shared/_prev_db_dirs_startup_id"
CURRENT_STARTUP=$(cat "$STARTUP_ID_FILE" 2>/dev/null || true)
CURRENT_STARTUP=$(echo "$CURRENT_STARTUP" | tr -d '[:space:]')
PREV_STARTUP=$(cat "$PREV_STARTUP_FILE" 2>/dev/null || true)
PREV_STARTUP=$(echo "$PREV_STARTUP" | tr -d '[:space:]')
if [ -n "$CURRENT_STARTUP" ] && [ "$CURRENT_STARTUP" != "$PREV_STARTUP" ]; then
    echo "Validator restarted (startup_id changed), resetting previous count"
    echo "$CURRENT_STARTUP" > "$PREV_STARTUP_FILE"
    rm -f "$PREV_FILE"
fi

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

# Step 3: Read current directory count
if [[ ! -f "$DIR_COUNT_FILE" ]]; then
    echo "Metric not available yet (validator may have just restarted)"
    sdk_always true "${ASSERTION_NAME}" '{"status":"metric_not_yet_available","note":"heartbeat fresh but metric file pending"}'
    exit 0
fi

current_count=$(cat "$DIR_COUNT_FILE" 2>/dev/null || true)
current_count=$(echo "$current_count" | tr -d '[:space:]')
if [[ -z "$current_count" ]] || ! [[ "$current_count" =~ ^[0-9]+$ ]]; then
    echo "SKIP: directory count value invalid: '${current_count}'"
    exit 0
fi

echo "  Current directory count: ${current_count}"

# Step 4: First observation — store and pass
if [[ ! -f "$PREV_FILE" ]]; then
    echo "  First observation, storing count"
    echo "$current_count" > "$PREV_FILE"
    sdk_always true "${ASSERTION_NAME}" \
        "$(jq -cn --argjson count "$current_count" '{first_observation: true, dir_count: $count}')"
    exit 0
fi

# Step 5: Compare with previous observation
prev_count=$(cat "$PREV_FILE" 2>/dev/null || true)
prev_count=$(echo "$prev_count" | tr -d '[:space:]')
if [[ -z "$prev_count" ]] || ! [[ "$prev_count" =~ ^[0-9]+$ ]]; then
    echo "  Previous count invalid ('${prev_count}'), resetting"
    echo "$current_count" > "$PREV_FILE"
    exit 0
fi

echo "  Previous directory count: ${prev_count}"

if [[ "$current_count" -ge "$prev_count" ]]; then
    delta=$((current_count - prev_count))
    echo "PASS: directory count is non-decreasing (prev=${prev_count}, current=${current_count}, delta=+${delta})"
    sdk_always true "${ASSERTION_NAME}" \
        "$(jq -cn --argjson cur "$current_count" --argjson prev "$prev_count" --argjson delta "$delta" \
            '{current_count: $cur, prev_count: $prev, delta: $delta, non_decreasing: true}')"
else
    drop=$((prev_count - current_count))
    if [[ "$drop" -le "$TOLERANCE" ]]; then
        echo "PASS: directory count decreased by ${drop} (within tolerance of ${TOLERANCE}) — normal RocksDB GC"
        sdk_always true "${ASSERTION_NAME}" \
            "$(jq -cn --argjson cur "$current_count" --argjson prev "$prev_count" --argjson drop "$drop" --argjson tol "$TOLERANCE" \
                '{current_count: $cur, prev_count: $prev, directories_lost: $drop, tolerance: $tol, within_tolerance: true}')"
    else
        echo "FAIL: directory count decreased significantly! prev=${prev_count} current=${current_count} (lost ${drop} directories, tolerance=${TOLERANCE})"
        sdk_always false "${ASSERTION_NAME}" \
            "$(jq -cn --argjson cur "$current_count" --argjson prev "$prev_count" --argjson drop "$drop" --argjson tol "$TOLERANCE" \
                '{current_count: $cur, prev_count: $prev, directories_lost: $drop, tolerance: $tol, within_tolerance: false}')"
    fi
fi

# Update previous count for next invocation
echo "$current_count" > "$PREV_FILE"

exit 0
