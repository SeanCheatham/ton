#!/usr/bin/env bash

# Anytime driver: Cross-validator block hash consensus (fork detection).
# This runs DURING active fault injection (anytime_* driver type).
#
# The strongest consensus safety check: validators must agree on the actual
# block content (root hash + file hash) at a given height, not just the seqno.
# Two validators reporting the same seqno but different hashes = consensus fork.
#
# Uses a slightly stale seqno (last_mc_seqno - 2) to give validators time to
# replicate, avoiding false positives from propagation delay.
#
# Skip gracefully when infrastructure is unavailable (no false positives).

source "$(dirname "$0")/helper_sdk.sh"

ALWAYS_NAME="Cross-validator block hash matches at same height"
SOMETIMES_NAME="Block hash verified across multiple validators"
STATE_FILE="/shared/_last_mc_seqno"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
VALIDATOR2_HOST="${VALIDATOR2_HOST:-ton-validator2}"
VALIDATOR3_HOST="${VALIDATOR3_HOST:-ton-validator3}"
LITE_PORT="${LITE_PORT:-30003}"

# Catalog both assertions up front
sdk_catalog_always  "$ALWAYS_NAME"
sdk_catalog_sometimes "$SOMETIMES_NAME"

# --- Precondition checks (skip, never fail) ---

if ! command -v lite-client >/dev/null 2>&1; then
    echo "lite-client binary not found, skipping"
    exit 0
fi

if [ ! -f "${STATE_FILE}" ]; then
    echo "State file ${STATE_FILE} not found, skipping"
    exit 0
fi

LAST_SEQNO=$(cat "${STATE_FILE}" 2>/dev/null || true)
LAST_SEQNO=$(echo "${LAST_SEQNO}" | tr -d '[:space:]')

if [ -z "${LAST_SEQNO}" ] || ! [[ "${LAST_SEQNO}" =~ ^[0-9]+$ ]]; then
    echo "Could not parse last_mc_seqno, skipping"
    exit 0
fi

if [ "${LAST_SEQNO}" -lt 3 ]; then
    echo "Last seqno ${LAST_SEQNO} too low (need >= 3), skipping"
    exit 0
fi

# Use a slightly stale seqno to allow propagation
CHECK_SEQNO=$(( LAST_SEQNO - 2 ))
echo "Checking block hash consensus at seqno ${CHECK_SEQNO} (last_mc_seqno=${LAST_SEQNO})"

# --- Helper: resolve hostname to IP ---

resolve_ip() {
    local host="$1"
    local ip=""
    if command -v getent >/dev/null 2>&1; then
        ip=$(getent hosts "${host}" 2>/dev/null | awk '{print $1; exit}')
    fi
    [ -z "${ip}" ] && ip="${host}"
    echo "${ip}"
}

# --- Helper: query block ID at a given seqno ---
# Args: <host> <config_file> <seqno>
# Returns: full block ID string like (-1,8000000000000000,N):ROOTHASH:FILEHASH

query_block_id() {
    local host="$1" config="$2" seqno="$3"

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
        -c "byseqno -1 8000000000000000 ${seqno}" \
        -c 'quit' 2>&1) || true

    # Extract full block ID: (-1,8000000000000000,N):ROOTHASH:FILEHASH
    echo "${output}" | grep -oE '\(-1,[0-9a-fA-F]+,[0-9]+\):[0-9A-Fa-f]+:[0-9A-Fa-f]+' | head -1 || true
}

# --- Query all 3 validators ---

echo "Querying all 3 validators for block at seqno ${CHECK_SEQNO}..."

BLOCK_ID1=$(query_block_id "${VALIDATOR_HOST}"  "/shared/liteserver.config.json"  "${CHECK_SEQNO}")
BLOCK_ID2=$(query_block_id "${VALIDATOR2_HOST}" "/shared/liteserver2.config.json" "${CHECK_SEQNO}")
BLOCK_ID3=$(query_block_id "${VALIDATOR3_HOST}" "/shared/liteserver3.config.json" "${CHECK_SEQNO}")

echo "Block IDs: v1=${BLOCK_ID1:-n/a} v2=${BLOCK_ID2:-n/a} v3=${BLOCK_ID3:-n/a}"

# --- Count responding validators ---

RESPONDED=0
BLOCK_IDS=()
VALIDATOR_LABELS=()

if [ -n "${BLOCK_ID1}" ]; then
    RESPONDED=$((RESPONDED + 1))
    BLOCK_IDS+=("${BLOCK_ID1}")
    VALIDATOR_LABELS+=("v1")
fi
if [ -n "${BLOCK_ID2}" ]; then
    RESPONDED=$((RESPONDED + 1))
    BLOCK_IDS+=("${BLOCK_ID2}")
    VALIDATOR_LABELS+=("v2")
fi
if [ -n "${BLOCK_ID3}" ]; then
    RESPONDED=$((RESPONDED + 1))
    BLOCK_IDS+=("${BLOCK_ID3}")
    VALIDATOR_LABELS+=("v3")
fi

if [ "${RESPONDED}" -lt 2 ]; then
    echo "Fewer than 2 validators responded (${RESPONDED}), skipping"
    exit 0
fi

# --- Compare block IDs across validators ---

FORK_DETECTED=false
MISMATCH_DETAIL=""

for i in "${!BLOCK_IDS[@]}"; do
    for j in "${!BLOCK_IDS[@]}"; do
        if [ "$i" -lt "$j" ]; then
            if [ "${BLOCK_IDS[$i]}" != "${BLOCK_IDS[$j]}" ]; then
                FORK_DETECTED=true
                MISMATCH_DETAIL="${VALIDATOR_LABELS[$i]}=${BLOCK_IDS[$i]} vs ${VALIDATOR_LABELS[$j]}=${BLOCK_IDS[$j]}"
            fi
        fi
    done
done

DETAILS=$(jq -cn \
    --arg v1 "${BLOCK_ID1:-null}" \
    --arg v2 "${BLOCK_ID2:-null}" \
    --arg v3 "${BLOCK_ID3:-null}" \
    --argjson seqno "${CHECK_SEQNO}" \
    --argjson responded "${RESPONDED}" \
    --argjson fork "$([ "${FORK_DETECTED}" = "true" ] && echo true || echo false)" \
    --arg mismatch "${MISMATCH_DETAIL}" \
    '{check_seqno: $seqno, v1_block_id: $v1, v2_block_id: $v2, v3_block_id: $v3, responded: $responded, fork_detected: $fork, mismatch: $mismatch}')

if [ "${FORK_DETECTED}" = "true" ]; then
    echo "FAIL: CONSENSUS FORK DETECTED at seqno ${CHECK_SEQNO}! ${MISMATCH_DETAIL}"
    sdk_always false "$ALWAYS_NAME" "$DETAILS"
else
    echo "PASS: ${RESPONDED} validators agree on block hash at seqno ${CHECK_SEQNO}"
    sdk_always true "$ALWAYS_NAME" "$DETAILS"

    # Sometimes: confirmed cross-validator hash agreement
    sdk_sometimes true "$SOMETIMES_NAME" "$DETAILS"
fi

exit 0
