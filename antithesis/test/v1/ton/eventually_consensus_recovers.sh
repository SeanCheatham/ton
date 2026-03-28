#!/usr/bin/env bash
set -euo pipefail

# Driver: Consensus recovers after a fault (sometimes).
# Detects DATA-level recovery: block production resumes after a detected fault.
# Different from parallel_driver_recovery_observed.sh which detects PORT-level recovery.
# A validator can have ports up but consensus stalled — this script catches that.
#
# Two-phase state machine persisted in /shared/_consensus_recovery_state:
#   Phase 1 (detect fault): liteserver query fails or heartbeat stale (>60s)
#     → record fault_ts and last_good_seqno
#   Phase 2 (detect recovery): fault was recorded AND liteserver now responds
#     with seqno > last_good_seqno → emit sdk_sometimes true
#
# Runs in the "eventually" phase (faults paused) — ideal for observing recovery.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
LITE_PORT="${LITE_PORT:-30003}"
STATE_FILE="/shared/_consensus_recovery_state"
ASSERTION_NAME="Consensus recovered after fault"
HEARTBEAT_STALE_THRESHOLD=60

sdk_catalog_sometimes "${ASSERTION_NAME}"

# --- Preconditions ---
if [ ! -f /shared/liteserver.config.json ]; then
    echo "Liteserver config not available yet, skipping"
    exit 0
fi
if ! command -v lite-client >/dev/null 2>&1; then
    echo "lite-client binary not found, skipping"
    exit 0
fi

# --- Read persisted state ---
fault_ts=""
last_good_seqno=""
if [ -f "${STATE_FILE}" ]; then
    fault_ts=$(grep -oP '^fault_ts=\K[0-9]+' "${STATE_FILE}" 2>/dev/null || true)
    last_good_seqno=$(grep -oP '^last_good_seqno=\K[0-9]+' "${STATE_FILE}" 2>/dev/null || true)
fi

# --- Resolve validator IP ---
VALIDATOR_IP=""
if command -v getent >/dev/null 2>&1; then
    VALIDATOR_IP=$(getent hosts "${VALIDATOR_HOST}" 2>/dev/null | awk '{print $1; exit}')
fi
[ -z "${VALIDATOR_IP}" ] && VALIDATOR_IP="${VALIDATOR_HOST}"

# --- Try to query current seqno ---
get_seqno() {
    local output
    output=$(timeout 10 lite-client \
        -v 1 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C /shared/liteserver.config.json \
        -c 'last' \
        -c 'quit' 2>&1) || true
    echo "${output}" | grep -oE '\(-1,[0-9a-fA-F]+,[0-9]+\)' | grep -oE ',[0-9]+\)$' | tr -d ',)' | tail -1 || true
}

current_seqno=$(get_seqno)
query_ok=false
if [[ -n "${current_seqno}" && "${current_seqno}" =~ ^[0-9]+$ ]]; then
    query_ok=true
fi

# --- Check heartbeat staleness ---
heartbeat_stale=false
NOW=$(date +%s)
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || echo "0")
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
    if [[ "${HB_TS}" =~ ^[0-9]+$ ]] && [ "${HB_TS}" -gt 0 ]; then
        HB_AGE=$(( NOW - HB_TS ))
        if [ "${HB_AGE}" -gt "${HEARTBEAT_STALE_THRESHOLD}" ]; then
            heartbeat_stale=true
        fi
    else
        heartbeat_stale=true
    fi
else
    # No heartbeat file — could be early startup, treat as unknown (not fault)
    heartbeat_stale=false
fi

echo "State: query_ok=${query_ok} seqno=${current_seqno:-none} heartbeat_stale=${heartbeat_stale} fault_ts=${fault_ts:-none} last_good_seqno=${last_good_seqno:-none}"

# --- State machine ---

# Detect fault: query failed or heartbeat stale
fault_detected=false
if [[ "${query_ok}" == "false" || "${heartbeat_stale}" == "true" ]]; then
    fault_detected=true
fi

if [[ "${fault_detected}" == "true" && -z "${fault_ts}" ]]; then
    # Phase 1: entering fault state — record it
    # Preserve current seqno as last_good if we had one from a previous invocation
    # or use whatever was stored previously
    echo "FAULT DETECTED at ${NOW}: query_ok=${query_ok} heartbeat_stale=${heartbeat_stale}"
    {
        echo "fault_ts=${NOW}"
        if [[ -n "${last_good_seqno}" ]]; then
            echo "last_good_seqno=${last_good_seqno}"
        fi
    } > "${STATE_FILE}"
    sdk_sometimes false "${ASSERTION_NAME}" "$(jq -cn \
        --arg phase "fault_detected" \
        --arg fault_ts "${NOW}" \
        --arg last_good_seqno "${last_good_seqno:-unknown}" \
        --argjson query_ok "${query_ok}" \
        --argjson heartbeat_stale "${heartbeat_stale}" \
        '{phase: $phase, fault_ts: $fault_ts, last_good_seqno: $last_good_seqno, query_ok: $query_ok, heartbeat_stale: $heartbeat_stale}')"
    exit 0
fi

if [[ -n "${fault_ts}" && "${query_ok}" == "true" ]]; then
    # Phase 2: we had a fault, now liteserver responds
    recovered=false
    if [[ -n "${last_good_seqno}" ]]; then
        if [ "${current_seqno}" -gt "${last_good_seqno}" ]; then
            recovered=true
        fi
    else
        # No pre-fault seqno recorded — if we can query at all after a fault, that's recovery
        recovered=true
    fi

    DETAILS=$(jq -cn \
        --arg phase "recovery_check" \
        --arg fault_ts "${fault_ts}" \
        --arg recovery_ts "${NOW}" \
        --arg last_good_seqno "${last_good_seqno:-unknown}" \
        --arg current_seqno "${current_seqno}" \
        --argjson recovered "${recovered}" \
        '{phase: $phase, fault_ts: $fault_ts, recovery_ts: $recovery_ts, last_good_seqno: $last_good_seqno, current_seqno: $current_seqno, recovered: $recovered}')

    if [[ "${recovered}" == "true" ]]; then
        FAULT_DURATION=$(( NOW - fault_ts ))
        echo "CONSENSUS RECOVERY DETECTED: seqno=${current_seqno} > last_good=${last_good_seqno:-none}, fault lasted ~${FAULT_DURATION}s"
        sdk_sometimes true "${ASSERTION_NAME}" "${DETAILS}"
        # Clear fault state so we can detect another cycle
        echo "last_good_seqno=${current_seqno}" > "${STATE_FILE}"
    else
        echo "Post-fault but seqno hasn't advanced yet (current=${current_seqno}, last_good=${last_good_seqno})"
        sdk_sometimes false "${ASSERTION_NAME}" "${DETAILS}"
    fi
    exit 0
fi

# No fault recorded — healthy state. Track last_good_seqno for future fault detection.
if [[ "${query_ok}" == "true" ]]; then
    echo "Healthy — updating last_good_seqno=${current_seqno}"
    echo "last_good_seqno=${current_seqno}" > "${STATE_FILE}"
else
    echo "No state change"
fi

sdk_sometimes false "${ASSERTION_NAME}" "$(jq -cn \
    --arg phase "healthy" \
    --arg current_seqno "${current_seqno:-none}" \
    --argjson query_ok "${query_ok}" \
    '{phase: $phase, current_seqno: $current_seqno, query_ok: $query_ok}')"

exit 0
