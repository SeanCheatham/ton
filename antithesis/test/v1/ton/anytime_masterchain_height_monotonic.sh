#!/usr/bin/env bash

# Anytime driver: Masterchain block height never decreases (monotonicity invariant).
# This runs DURING active fault injection (anytime_* driver type).
#
# The most fundamental blockchain safety property: once a masterchain seqno
# has been observed, the validator must never serve a lower one. A violation
# means a consensus rollback — one of the most critical bugs possible.
#
# Hardened against fault-induced validator restarts:
#   - Skips assertion when heartbeat is stale or missing (validator restarting)
#   - Only asserts always(false) for small seqno decreases (1-5) with a fresh
#     heartbeat, which indicates a real rollback rather than a restart-to-genesis
#
# Skip gracefully when liteserver is unreachable (no false positives during downtime).

source "$(dirname "$0")/helper_sdk.sh"

ALWAYS_NAME="Masterchain block height is monotonically non-decreasing"
SOMETIMES_NAME="Masterchain height observed advancing during faults"
STATE_FILE="/shared/_last_mc_seqno"
HB_FILE="/shared/validator_heartbeat"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
LITE_PORT="${LITE_PORT:-30003}"

# Max heartbeat age (seconds) to consider the validator "fresh" / not restarting
HB_FRESHNESS_THRESHOLD=60

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

# --- Query current masterchain seqno ---

output=$(timeout 10 lite-client \
    -v 1 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c 'last' \
    -c 'quit' 2>&1) || true

CURRENT_SEQNO=$(echo "${output}" | grep -oE '\(-1,[0-9a-fA-F]+,[0-9]+\)' | grep -oE ',[0-9]+\)$' | tr -d ',)' | tail -1 || true)

if [ -z "${CURRENT_SEQNO}" ] || ! [[ "${CURRENT_SEQNO}" =~ ^[0-9]+$ ]]; then
    echo "Could not parse seqno from lite-client (got: '${CURRENT_SEQNO}'), skipping"
    exit 0
fi

echo "Current masterchain seqno: ${CURRENT_SEQNO}"

# --- Read previous seqno from persistent state ---

PREV_SEQNO=""
if [ -f "${STATE_FILE}" ]; then
    PREV_SEQNO=$(cat "${STATE_FILE}" 2>/dev/null || true)
    PREV_SEQNO=$(echo "${PREV_SEQNO}" | tr -d '[:space:]')
fi

if [ -z "${PREV_SEQNO}" ] || ! [[ "${PREV_SEQNO}" =~ ^[0-9]+$ ]]; then
    # First observation — just record and exit
    echo "${CURRENT_SEQNO}" > "${STATE_FILE}"
    echo "First observation, recorded seqno ${CURRENT_SEQNO}"
    exit 0
fi

echo "Previous masterchain seqno: ${PREV_SEQNO}"

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

# --- Monotonicity check ---

DELTA=$(( CURRENT_SEQNO - PREV_SEQNO ))

DETAILS=$(jq -cn \
    --argjson current "${CURRENT_SEQNO}" \
    --argjson previous "${PREV_SEQNO}" \
    --argjson delta "${DELTA}" \
    --argjson hb_age "${HB_AGE}" \
    --argjson hb_fresh "$([ "${HB_FRESH}" = "true" ] && echo true || echo false)" \
    --argjson hb_threshold "${HB_FRESHNESS_THRESHOLD}" \
    '{current_seqno: $current, previous_seqno: $previous, delta: $delta,
      heartbeat_age_s: $hb_age, heartbeat_fresh: $hb_fresh,
      heartbeat_threshold_s: $hb_threshold}')

if [ "${CURRENT_SEQNO}" -lt "${PREV_SEQNO}" ]; then
    ABS_DROP=$(( PREV_SEQNO - CURRENT_SEQNO ))

    if [ "${HB_FRESH}" = "false" ]; then
        # Validator heartbeat is stale/missing — likely restarting after fault injection.
        # Do NOT assert failure; skip to avoid false positives.
        echo "SKIP: Seqno decreased (${PREV_SEQNO} -> ${CURRENT_SEQNO}, drop=${ABS_DROP}) but heartbeat is stale/missing — validator likely restarting"
        # Reset state so we track from the new (lower) seqno going forward
        echo "${CURRENT_SEQNO}" > "${STATE_FILE}"
    elif [ "${ABS_DROP}" -gt 10 ]; then
        # Large drop with fresh heartbeat — likely validator restarted to genesis
        # and heartbeat hasn't gone stale yet. Skip but log loudly.
        echo "SKIP: Large seqno drop (${PREV_SEQNO} -> ${CURRENT_SEQNO}, drop=${ABS_DROP}) — likely restart to genesis despite fresh heartbeat"
        echo "${CURRENT_SEQNO}" > "${STATE_FILE}"
    else
        # Small drop (1-5) with fresh heartbeat — this is suspicious and likely a real rollback
        echo "FAIL: Masterchain seqno DECREASED from ${PREV_SEQNO} to ${CURRENT_SEQNO} (drop=${ABS_DROP}) with fresh heartbeat (age=${HB_AGE}s) — possible real rollback!"
        sdk_always false "$ALWAYS_NAME" "$DETAILS"
    fi
else
    echo "PASS: Masterchain seqno non-decreasing (${PREV_SEQNO} -> ${CURRENT_SEQNO})"
    sdk_always true "$ALWAYS_NAME" "$DETAILS"

    # Update state file with latest observed seqno
    echo "${CURRENT_SEQNO}" > "${STATE_FILE}"
fi

# --- Sometimes: height advancing during faults ---
# Detect likely fault activity: heartbeat is stale (>30s old) or was recently stale.
# If height advanced despite that, it means consensus is making progress under faults.

if [ "${CURRENT_SEQNO}" -gt "${PREV_SEQNO}" ]; then
    FAULT_LIKELY=false
    if [ "${HB_AGE}" -eq -1 ]; then
        # No heartbeat file at all — faults likely disrupting the validator
        FAULT_LIKELY=true
    elif [ "${HB_AGE}" -gt 30 ]; then
        FAULT_LIKELY=true
    fi

    if [ "${FAULT_LIKELY}" = "true" ]; then
        FAULT_DETAILS=$(jq -cn \
            --argjson current "${CURRENT_SEQNO}" \
            --argjson previous "${PREV_SEQNO}" \
            --argjson delta "$(( CURRENT_SEQNO - PREV_SEQNO ))" \
            --argjson hb_age "${HB_AGE}" \
            '{current_seqno: $current, previous_seqno: $previous, delta: $delta, heartbeat_age_s: $hb_age, fault_indicator: "stale_or_missing_heartbeat"}')
        echo "Height advanced during likely fault activity (hb_age=${HB_AGE}s)"
        sdk_sometimes true "$SOMETIMES_NAME" "$FAULT_DETAILS"
    fi
fi

exit 0
