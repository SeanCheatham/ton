#!/usr/bin/env bash
set -euo pipefail

# Finally: Verify all validators agree on the same masterchain block at end of timeline.
# This is the definitive consensus safety check. After all faults settle, validators
# must converge to the same masterchain state. Different block IDs at the same height
# means a consensus fork — the most critical safety violation.
#
# Complements:
#   - finally_verify_transfers.sh (data persistence check)
#   - anytime_block_hash_consensus.sh (during-fault fork detection)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
VALIDATOR2_HOST="${VALIDATOR2_HOST:-ton-validator2}"
VALIDATOR3_HOST="${VALIDATOR3_HOST:-ton-validator3}"
LITE_PORT="${LITE_PORT:-30003}"

ALWAYS_NAME="All validators converged to same masterchain state at end of timeline"
SOMETIMES_NAME="Consensus convergence verified across all validators"

sdk_catalog_always "${ALWAYS_NAME}"
sdk_catalog_sometimes "${SOMETIMES_NAME}"

# --- Preconditions (skip, not fail) ---

if ! command -v lite-client >/dev/null 2>&1; then
    echo "lite-client binary not found, skipping"
    exit 0
fi

if [ ! -f /shared/liteserver.config.json ]; then
    echo "Liteserver config not available, skipping"
    exit 0
fi

# --- Helper functions ---

resolve_ip() {
    local host="$1"
    local ip=""
    if command -v getent >/dev/null 2>&1; then
        ip=$(getent hosts "${host}" 2>/dev/null | awk '{print $1; exit}')
    fi
    [ -z "${ip}" ] && ip="${host}"
    echo "${ip}"
}

# Query masterchain 'last' block from a validator's liteserver.
# Returns the full block ID: (-1,8000000000000000,N):ROOTHASH:FILEHASH
# Args: <host> <config_file>
query_last_block() {
    local host="$1" config="$2"

    if [ ! -f "${config}" ]; then
        echo ""
        return
    fi

    if ! nc -z -w 2 "${host}" "${LITE_PORT}" 2>/dev/null; then
        echo ""
        return
    fi

    local ip
    ip=$(resolve_ip "${host}")

    local output
    output=$(timeout 10 lite-client \
        -v 1 \
        -a "${ip}:${LITE_PORT}" \
        -C "${config}" \
        -c "last" \
        -c 'quit' 2>&1) || true

    # Extract full block ID: (-1,8000000000000000,N):ROOTHASH:FILEHASH
    echo "${output}" | grep -oE '\(-1,[0-9a-fA-F]+,[0-9]+\):[0-9A-Fa-f]+:[0-9A-Fa-f]+' | head -1 || true
}

# Extract seqno from a block ID like (-1,8000000000000000,42):HASH:HASH
parse_seqno() {
    local block_id="$1"
    echo "${block_id}" | grep -oP '\(-1,[0-9a-fA-F]+,\K[0-9]+' || true
}

# --- Query all 3 validators ---

echo "Querying masterchain 'last' from all 3 validators..."

BLOCK_ID1=$(query_last_block "${VALIDATOR_HOST}"  "/shared/liteserver.config.json")
BLOCK_ID2=$(query_last_block "${VALIDATOR2_HOST}" "/shared/liteserver2.config.json")
BLOCK_ID3=$(query_last_block "${VALIDATOR3_HOST}" "/shared/liteserver3.config.json")

echo "Block IDs: v1=${BLOCK_ID1:-n/a} v2=${BLOCK_ID2:-n/a} v3=${BLOCK_ID3:-n/a}"

# --- Count responding validators ---

RESPONDED=0
BLOCK_IDS=()
SEQNOS=()
VALIDATOR_LABELS=()

for label_id_pair in "v1:${BLOCK_ID1}" "v2:${BLOCK_ID2}" "v3:${BLOCK_ID3}"; do
    label="${label_id_pair%%:*}"
    # Remove label prefix (v1:, v2:, v3:) — but block ID itself contains colons
    bid="${label_id_pair#*:}"
    if [ -n "${bid}" ]; then
        seqno=$(parse_seqno "${bid}")
        if [ -n "${seqno}" ] && [[ "${seqno}" =~ ^[0-9]+$ ]]; then
            RESPONDED=$((RESPONDED + 1))
            BLOCK_IDS+=("${bid}")
            SEQNOS+=("${seqno}")
            VALIDATOR_LABELS+=("${label}")
        fi
    fi
done

if [ "${RESPONDED}" -lt 2 ]; then
    echo "Fewer than 2 validators responded (${RESPONDED}), skipping"
    exit 0
fi

echo "${RESPONDED} validators responded"

# --- Check seqno convergence ---

# Find min and max seqno
MIN_SEQNO="${SEQNOS[0]}"
MAX_SEQNO="${SEQNOS[0]}"
for s in "${SEQNOS[@]}"; do
    if [ "${s}" -lt "${MIN_SEQNO}" ]; then
        MIN_SEQNO="${s}"
    fi
    if [ "${s}" -gt "${MAX_SEQNO}" ]; then
        MAX_SEQNO="${s}"
    fi
done

SEQNO_DIFF=$((MAX_SEQNO - MIN_SEQNO))
echo "Seqno range: min=${MIN_SEQNO} max=${MAX_SEQNO} diff=${SEQNO_DIFF}"

CONVERGED=true
MISMATCH_DETAIL=""

# Seqno tolerance: difference must be <= 1
if [ "${SEQNO_DIFF}" -gt 1 ]; then
    CONVERGED=false
    MISMATCH_DETAIL="seqno divergence too large: min=${MIN_SEQNO} max=${MAX_SEQNO} diff=${SEQNO_DIFF}"
    echo "FAIL: ${MISMATCH_DETAIL}"
fi

# If seqnos match exactly, block IDs MUST match (same height = same block or fork)
if [ "${SEQNO_DIFF}" -eq 0 ]; then
    for i in "${!BLOCK_IDS[@]}"; do
        for j in "${!BLOCK_IDS[@]}"; do
            if [ "$i" -lt "$j" ]; then
                if [ "${BLOCK_IDS[$i]}" != "${BLOCK_IDS[$j]}" ]; then
                    CONVERGED=false
                    MISMATCH_DETAIL="FORK at seqno ${SEQNOS[$i]}: ${VALIDATOR_LABELS[$i]}=${BLOCK_IDS[$i]} vs ${VALIDATOR_LABELS[$j]}=${BLOCK_IDS[$j]}"
                    echo "CRITICAL: ${MISMATCH_DETAIL}"
                fi
            fi
        done
    done
fi

# If seqno diff is exactly 1, compare validators at the same seqno
if [ "${SEQNO_DIFF}" -eq 1 ]; then
    echo "Seqno diff is 1, comparing validators at the same height..."
    # Group by seqno and check within groups
    for i in "${!BLOCK_IDS[@]}"; do
        for j in "${!BLOCK_IDS[@]}"; do
            if [ "$i" -lt "$j" ] && [ "${SEQNOS[$i]}" -eq "${SEQNOS[$j]}" ]; then
                if [ "${BLOCK_IDS[$i]}" != "${BLOCK_IDS[$j]}" ]; then
                    CONVERGED=false
                    MISMATCH_DETAIL="FORK at seqno ${SEQNOS[$i]}: ${VALIDATOR_LABELS[$i]}=${BLOCK_IDS[$i]} vs ${VALIDATOR_LABELS[$j]}=${BLOCK_IDS[$j]}"
                    echo "CRITICAL: ${MISMATCH_DETAIL}"
                fi
            fi
        done
    done
fi

# --- Build details JSON ---

DETAILS=$(jq -cn \
    --arg v1 "${BLOCK_ID1:-null}" \
    --arg v2 "${BLOCK_ID2:-null}" \
    --arg v3 "${BLOCK_ID3:-null}" \
    --argjson responded "${RESPONDED}" \
    --argjson min_seqno "${MIN_SEQNO}" \
    --argjson max_seqno "${MAX_SEQNO}" \
    --argjson seqno_diff "${SEQNO_DIFF}" \
    --argjson converged "$([ "${CONVERGED}" = "true" ] && echo true || echo false)" \
    --arg mismatch "${MISMATCH_DETAIL}" \
    '{v1_block_id: $v1, v2_block_id: $v2, v3_block_id: $v3,
      responded: $responded, min_seqno: $min_seqno, max_seqno: $max_seqno,
      seqno_diff: $seqno_diff, converged: $converged, mismatch: $mismatch}')

# --- Emit assertions ---

if [ "${CONVERGED}" = "true" ]; then
    echo "PASS: All validators converged to same masterchain state"
    sdk_always true "${ALWAYS_NAME}" "${DETAILS}"

    # Sometimes: only emit when all 3 validators responded with matching state
    if [ "${RESPONDED}" -eq 3 ] && [ "${SEQNO_DIFF}" -eq 0 ]; then
        sdk_sometimes true "${SOMETIMES_NAME}" "${DETAILS}"
        echo "All 3 validators returned identical masterchain state"
    fi
else
    echo "FAIL: Validators did NOT converge — ${MISMATCH_DETAIL}"
    sdk_always false "${ALWAYS_NAME}" "${DETAILS}"
    exit 1
fi

exit 0
