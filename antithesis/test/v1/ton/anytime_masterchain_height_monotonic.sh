#!/usr/bin/env bash

# Anytime driver: Masterchain block height never decreases (monotonicity invariant).
# This runs DURING active fault injection (anytime_* driver type).
#
# The most fundamental blockchain safety property: once a masterchain seqno
# has been observed, the validator must never serve a lower one. A violation
# means a consensus rollback — one of the most critical bugs possible.
#
# Skip gracefully when liteserver is unreachable (no false positives during downtime).

source "$(dirname "$0")/helper_sdk.sh"

ALWAYS_NAME="Masterchain block height is monotonically non-decreasing"
SOMETIMES_NAME="Masterchain height observed advancing during faults"
STATE_FILE="/shared/_last_mc_seqno"
HB_FILE="/shared/validator_heartbeat"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
LITE_PORT="${LITE_PORT:-30003}"

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

# --- Monotonicity check ---

DETAILS=$(jq -cn \
    --argjson current "${CURRENT_SEQNO}" \
    --argjson previous "${PREV_SEQNO}" \
    --argjson delta "$(( CURRENT_SEQNO - PREV_SEQNO ))" \
    '{current_seqno: $current, previous_seqno: $previous, delta: $delta}')

if [ "${CURRENT_SEQNO}" -lt "${PREV_SEQNO}" ]; then
    echo "FAIL: Masterchain seqno DECREASED from ${PREV_SEQNO} to ${CURRENT_SEQNO} — possible rollback!"
    sdk_always false "$ALWAYS_NAME" "$DETAILS"
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
    if [ -f "${HB_FILE}" ]; then
        HB_TS=$(cat "${HB_FILE}" 2>/dev/null || true)
        HB_TS=$(echo "${HB_TS}" | tr -d '[:space:]')
        NOW=$(date +%s)
        if [[ "${HB_TS}" =~ ^[0-9]+$ ]]; then
            HB_AGE=$(( NOW - HB_TS ))
            if [ "${HB_AGE}" -gt 30 ]; then
                FAULT_LIKELY=true
            fi
        fi
    else
        # No heartbeat file at all — faults likely disrupting the validator
        FAULT_LIKELY=true
    fi

    if [ "${FAULT_LIKELY}" = "true" ]; then
        FAULT_DETAILS=$(jq -cn \
            --argjson current "${CURRENT_SEQNO}" \
            --argjson previous "${PREV_SEQNO}" \
            --argjson delta "$(( CURRENT_SEQNO - PREV_SEQNO ))" \
            --arg hb_age "${HB_AGE:-unknown}" \
            '{current_seqno: $current, previous_seqno: $previous, delta: $delta, heartbeat_age_s: $hb_age, fault_indicator: "stale_or_missing_heartbeat"}')
        echo "Height advanced during likely fault activity (hb_age=${HB_AGE:-unknown}s)"
        sdk_sometimes true "$SOMETIMES_NAME" "$FAULT_DETAILS"
    fi
fi

exit 0
