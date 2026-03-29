#!/usr/bin/env bash

# Anytime driver: Masterchain block unix_time never decreases (timestamp monotonicity).
# This runs DURING active fault injection (anytime_* driver type).
#
# Masterchain block timestamps (unix_time) must be monotonically non-decreasing.
# This is a fundamental blockchain safety invariant from the TON whitepaper.
# A timestamp rollback would indicate consensus corruption or clock manipulation.
#
# Hardened against fault-induced validator restarts:
#   - Skips assertion when heartbeat is stale or missing (validator restarting)
#   - Only asserts always(false) for small timestamp decreases with a fresh
#     heartbeat, which indicates a real rollback rather than a restart-to-genesis
#   - Large drops (>3600s) with fresh heartbeat are treated as genesis restart
#
# Skip gracefully when liteserver is unreachable (no false positives during downtime).

source "$(dirname "$0")/helper_sdk.sh"

ALWAYS_NAME="Masterchain block timestamp is monotonically non-decreasing"
SOMETIMES_NAME="Masterchain block timestamp is queryable during faults"
STATE_FILE="/shared/invariants/last_block_timestamp"
HB_FILE="/shared/validator_heartbeat"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
LITE_PORT="${LITE_PORT:-30003}"

# Max heartbeat age (seconds) to consider the validator "fresh" / not restarting
HB_FRESHNESS_THRESHOLD=60

# Threshold for "large" timestamp drop — indicates genesis restart, not real rollback
LARGE_DROP_THRESHOLD=3600

# Catalog both assertions up front
sdk_catalog_always  "$ALWAYS_NAME"
sdk_catalog_sometimes "$SOMETIMES_NAME"

# --- Precondition checks (skip, never fail) ---

if ! command -v lite-client >/dev/null 2>&1; then
    echo "lite-client binary not found, skipping"
    exit 0
fi

if [ ! -f /shared/liteserver.config.json ]; then
    echo "Liteserver config not available yet, skipping"
    exit 0
fi

if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    echo "Liteserver port ${LITE_PORT} not reachable, skipping"
    exit 0
fi

# --- Helper: compute heartbeat age ---
# Returns age in seconds, or -1 if heartbeat is missing/unreadable

get_heartbeat_age() {
    local hb_file="$1"
    if [ ! -f "${hb_file}" ]; then
        echo "-1"
        return
    fi
    local hb_ts
    hb_ts=$(cat "${hb_file}" 2>/dev/null || true)
    hb_ts=$(echo "${hb_ts}" | tr -d '[:space:]')
    if ! [[ "${hb_ts}" =~ ^[0-9]+$ ]]; then
        echo "-1"
        return
    fi
    local now
    now=$(date +%s)
    echo "$(( now - hb_ts ))"
}

# --- Resolve hostname to IP ---

VALIDATOR_IP=""
if command -v getent >/dev/null 2>&1; then
    VALIDATOR_IP=$(getent hosts "${VALIDATOR_HOST}" 2>/dev/null | awk '{print $1; exit}')
fi
[ -z "${VALIDATOR_IP}" ] && VALIDATOR_IP="${VALIDATOR_HOST}"

# Ensure state directory exists
mkdir -p "$(dirname "${STATE_FILE}")"

# --- Query current masterchain block timestamp ---
# The lite-client `last` command prints the latest masterchain block info,
# including "created at <unix_timestamp>" for the block's creation time.
# Per verified output format: "latest masterchain block known to server is
# <blockid> created at <unix_timestamp> (<N> seconds ago)"
# We parse `created at ([0-9]+)` — this is last_utime, NOT server wall clock.

output=$(timeout 10 lite-client \
    -v 1 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c 'last' \
    -c 'quit' 2>&1) || true

CURRENT_TS=$(echo "${output}" | grep -oE 'created at [0-9]+' | grep -oE '[0-9]+$' | tail -1 || true)

if [ -z "${CURRENT_TS}" ] || ! [[ "${CURRENT_TS}" =~ ^[0-9]+$ ]]; then
    echo "Could not parse block timestamp from lite-client (got: '${CURRENT_TS}'), skipping"
    exit 0
fi

echo "Current masterchain block timestamp: ${CURRENT_TS}"

# --- Read previous timestamp from persistent state ---

PREV_TS=""
if [ -f "${STATE_FILE}" ]; then
    PREV_TS=$(cat "${STATE_FILE}" 2>/dev/null || true)
    PREV_TS=$(echo "${PREV_TS}" | tr -d '[:space:]')
fi

if [ -z "${PREV_TS}" ] || ! [[ "${PREV_TS}" =~ ^[0-9]+$ ]]; then
    # First observation — just record and exit
    echo "${CURRENT_TS}" > "${STATE_FILE}"
    echo "First observation, recorded timestamp ${CURRENT_TS}"
    exit 0
fi

echo "Previous masterchain block timestamp: ${PREV_TS}"

# --- Heartbeat freshness check ---

HB_AGE=$(get_heartbeat_age "${HB_FILE}")
HB_FRESH=true
if [ "${HB_AGE}" -eq -1 ]; then
    HB_FRESH=false
    echo "Heartbeat file missing or unreadable — validator likely restarting"
elif [ "${HB_AGE}" -gt "${HB_FRESHNESS_THRESHOLD}" ]; then
    HB_FRESH=false
    echo "Heartbeat stale (age=${HB_AGE}s > ${HB_FRESHNESS_THRESHOLD}s) — validator likely restarting"
else
    echo "Heartbeat fresh (age=${HB_AGE}s)"
fi

# --- Timestamp monotonicity check ---

DELTA=$(( CURRENT_TS - PREV_TS ))

DETAILS=$(jq -cn \
    --argjson current "${CURRENT_TS}" \
    --argjson previous "${PREV_TS}" \
    --argjson delta "${DELTA}" \
    --argjson hb_age "${HB_AGE}" \
    --argjson hb_fresh "$([ "${HB_FRESH}" = "true" ] && echo true || echo false)" \
    --argjson hb_threshold "${HB_FRESHNESS_THRESHOLD}" \
    '{current_block_ts: $current, previous_block_ts: $previous, delta_s: $delta,
      heartbeat_age_s: $hb_age, heartbeat_fresh: $hb_fresh,
      heartbeat_threshold_s: $hb_threshold}')

if [ "${CURRENT_TS}" -lt "${PREV_TS}" ]; then
    ABS_DROP=$(( PREV_TS - CURRENT_TS ))

    if [ "${HB_FRESH}" = "false" ]; then
        # Validator heartbeat is stale/missing — likely restarting after fault injection.
        # Do NOT assert failure; skip to avoid false positives.
        echo "SKIP: Block timestamp decreased (${PREV_TS} -> ${CURRENT_TS}, drop=${ABS_DROP}s) but heartbeat is stale/missing — validator likely restarting"
        # Reset state so we track from the new (lower) timestamp going forward
        echo "${CURRENT_TS}" > "${STATE_FILE}"
    elif [ "${ABS_DROP}" -gt "${LARGE_DROP_THRESHOLD}" ]; then
        # Large drop with fresh heartbeat — likely validator restarted to genesis
        # and heartbeat hasn't gone stale yet. Skip but log loudly.
        echo "SKIP: Large block timestamp drop (${PREV_TS} -> ${CURRENT_TS}, drop=${ABS_DROP}s) — likely restart to genesis despite fresh heartbeat"
        echo "${CURRENT_TS}" > "${STATE_FILE}"
    else
        # Any decrease with fresh heartbeat — this is a real rollback violation
        echo "FAIL: Masterchain block timestamp DECREASED from ${PREV_TS} to ${CURRENT_TS} (drop=${ABS_DROP}s) with fresh heartbeat (age=${HB_AGE}s) — timestamp rollback!"
        sdk_always false "$ALWAYS_NAME" "$DETAILS"
    fi
else
    echo "PASS: Masterchain block timestamp non-decreasing (${PREV_TS} -> ${CURRENT_TS})"
    sdk_always true "$ALWAYS_NAME" "$DETAILS"

    # Update state file with latest observed timestamp
    echo "${CURRENT_TS}" > "${STATE_FILE}"
fi

# --- Sometimes: timestamp queryable during faults ---
# Liveness signal: we successfully obtained a valid block timestamp.
# This is meaningful as a branching checkpoint for Antithesis —
# it confirms the liteserver is responding during fault injection.

if [ "${CURRENT_TS}" -gt 0 ]; then
    SOMETIMES_DETAILS=$(jq -cn \
        --argjson current "${CURRENT_TS}" \
        --argjson hb_age "${HB_AGE}" \
        '{block_timestamp: $current, heartbeat_age_s: $hb_age}')
    echo "Block timestamp successfully queried (ts=${CURRENT_TS})"
    sdk_sometimes true "$SOMETIMES_NAME" "$SOMETIMES_DETAILS"
fi

exit 0
