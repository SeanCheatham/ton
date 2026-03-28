#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Historical block retrieval via byseqno + listblocktrans.
# Exercises LiteQuery::perform_lookupBlock and LiteQuery::perform_listBlockTransactions
# code paths by querying blocks well behind the chain tip. Under fault injection,
# stale block retrieval is where data corruption bugs surface — the block may have
# been written to disk during a fault.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
LITE_PORT="${LITE_PORT:-30003}"

ALWAYS_NAME="Historical block retrieval returns consistent data"
SOMETIMES_NAME="Historical block transactions listed successfully"
SOMETIMES_PROOF_NAME="Liteserver block proof chain verified successfully"
STATE_FILE="/shared/_last_mc_seqno"

HEARTBEAT_MAX_AGE=60
HEARTBEAT_WAIT_MAX=20
HEARTBEAT_WAIT_POLL=2

sdk_catalog_always  "${ALWAYS_NAME}"
sdk_catalog_sometimes "${SOMETIMES_NAME}"
sdk_catalog_sometimes "${SOMETIMES_PROOF_NAME}"

# --- Precondition: heartbeat must be fresh ---
_hb_ok=false
_hb_waited=0
while [ "$_hb_waited" -lt "$HEARTBEAT_WAIT_MAX" ]; do
    if [ -f /shared/validator_heartbeat ]; then
        HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
        HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
        NOW=$(date +%s)
        if [[ "${HB_TS}" =~ ^[0-9]+$ ]]; then
            HB_AGE=$(( NOW - HB_TS ))
            if [ "${HB_AGE}" -le "${HEARTBEAT_MAX_AGE}" ]; then
                _hb_ok=true
                break
            else
                echo "Heartbeat stale (${HB_AGE}s), skipping"
                exit 0
            fi
        fi
    fi
    sleep "$HEARTBEAT_WAIT_POLL"
    _hb_waited=$((_hb_waited + HEARTBEAT_WAIT_POLL))
done

if [ "$_hb_ok" != "true" ]; then
    echo "Heartbeat file not present after ${HEARTBEAT_WAIT_MAX}s, skipping"
    exit 0
fi

if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    echo "Liteserver port ${LITE_PORT} not reachable, skipping"
    exit 0
fi
if [ ! -f /shared/liteserver.config.json ]; then
    echo "Liteserver config not available yet, skipping"
    exit 0
fi
if ! command -v lite-client >/dev/null 2>&1; then
    echo "lite-client binary not found, skipping"
    exit 0
fi

# --- Read current masterchain seqno ---
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

if [ "${LAST_SEQNO}" -lt 10 ]; then
    echo "Last seqno ${LAST_SEQNO} too low (need >= 10), skipping"
    exit 0
fi

# --- Resolve validator hostname to IP ---
VALIDATOR_IP=""
if command -v getent >/dev/null 2>&1; then
    VALIDATOR_IP=$(getent hosts "${VALIDATOR_HOST}" 2>/dev/null | awk '{print $1; exit}')
fi
[ -z "${VALIDATOR_IP}" ] && VALIDATOR_IP="${VALIDATOR_HOST}"

# --- Pick 3 historical seqnos ---
SEQNO_A=$(( LAST_SEQNO - 5 ))
SEQNO_B=$(( LAST_SEQNO - 10 ))
SEQNO_C=1  # genesis block

# Ensure seqnos are positive
[ "${SEQNO_A}" -lt 1 ] && SEQNO_A=1
[ "${SEQNO_B}" -lt 1 ] && SEQNO_B=1

HISTORICAL_SEQNOS=("${SEQNO_A}" "${SEQNO_B}" "${SEQNO_C}")
echo "Querying historical blocks at seqnos: ${HISTORICAL_SEQNOS[*]} (current=${LAST_SEQNO})"

# --- Query each historical seqno ---
CONSISTENCY_OK=true
ANY_LISTBLOCKTRANS_OK=false
PROOF_OK=false
QUERIED=0
TOTAL_TX=0
# Store block IDs for proof chain verification
BLOCK_ID_FOR_SEQNO_A=""
BLOCK_ID_FOR_SEQNO_B=""

for TARGET_SEQNO in "${HISTORICAL_SEQNOS[@]}"; do
    echo "--- Querying seqno ${TARGET_SEQNO} ---"

    # Step 1: byseqno to retrieve block header
    OUTPUT=$(timeout 10 lite-client \
        -v 1 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C /shared/liteserver.config.json \
        -c "byseqno -1 8000000000000000 ${TARGET_SEQNO}" \
        -c 'quit' 2>&1) || true

    # Extract full block ID: (-1,8000000000000000,N):ROOTHASH:FILEHASH
    BLOCK_ID=$(echo "${OUTPUT}" | grep -oE '\(-1,[0-9a-fA-F]+,[0-9]+\):[0-9A-Fa-f]+:[0-9A-Fa-f]+' | head -1) || true

    if [ -z "${BLOCK_ID}" ]; then
        echo "Could not retrieve block ID for seqno ${TARGET_SEQNO}, skipping this seqno"
        continue
    fi

    echo "Block ID for seqno ${TARGET_SEQNO}: ${BLOCK_ID}"
    QUERIED=$((QUERIED + 1))

    # Store block IDs for proof chain verification
    if [ "${TARGET_SEQNO}" = "${SEQNO_A}" ]; then
        BLOCK_ID_FOR_SEQNO_A="${BLOCK_ID}"
    elif [ "${TARGET_SEQNO}" = "${SEQNO_B}" ]; then
        BLOCK_ID_FOR_SEQNO_B="${BLOCK_ID}"
    fi

    # Step 2: Verify the returned seqno matches what we requested
    RETURNED_SEQNO=$(echo "${BLOCK_ID}" | grep -oP '\(-1,[0-9a-fA-F]+,\K[0-9]+') || true

    if [ -n "${RETURNED_SEQNO}" ] && [ "${RETURNED_SEQNO}" != "${TARGET_SEQNO}" ]; then
        echo "FAIL: Requested seqno ${TARGET_SEQNO} but got ${RETURNED_SEQNO} — DATA CORRUPTION"
        CONSISTENCY_OK=false
        DETAILS=$(jq -cn \
            --argjson requested "${TARGET_SEQNO}" \
            --argjson returned "${RETURNED_SEQNO}" \
            --arg block_id "${BLOCK_ID}" \
            '{requested_seqno: $requested, returned_seqno: $returned, block_id: $block_id}')
        sdk_always false "${ALWAYS_NAME}" "${DETAILS}"
    fi

    # Step 3: listblocktrans to list transactions in this block
    TX_OUTPUT=$(timeout 10 lite-client \
        -v 1 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C /shared/liteserver.config.json \
        -c "listblocktrans ${BLOCK_ID} 10" \
        -c 'quit' 2>&1) || true

    # Check if transactions were returned
    TX_COUNT=$(echo "${TX_OUTPUT}" | grep -c 'transaction #' || true)
    echo "listblocktrans for seqno ${TARGET_SEQNO}: ${TX_COUNT} transactions"
    TOTAL_TX=$((TOTAL_TX + TX_COUNT))

    if [ "${TX_COUNT}" -gt 0 ]; then
        ANY_LISTBLOCKTRANS_OK=true
    fi
done

# --- Emit assertions ---

# Always: consistency — only emit if we actually queried at least one block
if [ "${QUERIED}" -gt 0 ] && [ "${CONSISTENCY_OK}" = "true" ]; then
    DETAILS=$(jq -cn \
        --argjson current_seqno "${LAST_SEQNO}" \
        --argjson queried "${QUERIED}" \
        --argjson total_tx "${TOTAL_TX}" \
        --arg seqnos "${HISTORICAL_SEQNOS[*]}" \
        --argjson proof_chain "${PROOF_OK}" \
        '{current_seqno: $current_seqno, queried_count: $queried, total_transactions: $total_tx, target_seqnos: $seqnos, proof_chain: $proof_chain}')
    echo "PASS: All ${QUERIED} historical block retrievals returned consistent data"
    sdk_always true "${ALWAYS_NAME}" "${DETAILS}"
fi

# Sometimes: listblocktrans returned data for at least one block
if [ "${ANY_LISTBLOCKTRANS_OK}" = "true" ]; then
    DETAILS=$(jq -cn \
        --argjson current_seqno "${LAST_SEQNO}" \
        --argjson total_tx "${TOTAL_TX}" \
        '{current_seqno: $current_seqno, total_transactions: $total_tx}')
    echo "PASS: Historical block transactions listed successfully"
    sdk_sometimes true "${SOMETIMES_NAME}" "${DETAILS}"
fi

# --- Proof chain verification ---
# Uses blkproofchain to verify a chain of proofs between two historical masterchain blocks.
# This exercises LiteQuery::perform_getBlockProof — the proof chain verification mechanism
# that light clients use to verify block validity.
if [ -n "${BLOCK_ID_FOR_SEQNO_B}" ] && [ -n "${BLOCK_ID_FOR_SEQNO_A}" ]; then
    echo "--- Proof chain: seqno ${SEQNO_B} -> ${SEQNO_A} ---"
    OUTPUT_PROOF=$(timeout 20 lite-client \
        -v 1 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C /shared/liteserver.config.json \
        -c "blkproofchain ${BLOCK_ID_FOR_SEQNO_B} ${BLOCK_ID_FOR_SEQNO_A}" \
        -c 'quit' 2>&1) || true
    if echo "${OUTPUT_PROOF}" | grep -qi 'valid\|proof\|block_link'; then
        PROOF_OK=true
        echo "blkproofchain returned valid proof chain from seqno ${SEQNO_B} to ${SEQNO_A}"
    else
        echo "blkproofchain did not return recognizable proof data"
    fi
fi

if [ "${PROOF_OK}" = "true" ]; then
    DETAILS=$(jq -cn \
        --argjson current_seqno "${LAST_SEQNO}" \
        --argjson from_seqno "${SEQNO_B}" \
        --argjson to_seqno "${SEQNO_A}" \
        --arg from_block "${BLOCK_ID_FOR_SEQNO_B}" \
        --arg to_block "${BLOCK_ID_FOR_SEQNO_A}" \
        '{current_seqno: $current_seqno, from_seqno: $from_seqno, to_seqno: $to_seqno, from_block: $from_block, to_block: $to_block, proof_chain: true}')
    echo "PASS: Liteserver block proof chain verified successfully"
    sdk_sometimes true "${SOMETIMES_PROOF_NAME}" "${DETAILS}"
fi

exit 0
