#!/usr/bin/env bash

# Anytime driver: Cross-validator block hash consensus (fork detection).
# This runs DURING active fault injection (anytime_* driver type).
#
# The strongest consensus safety check: validators must agree on the actual
# block content (root hash + file hash) at a given height, not just the seqno.
# Two validators reporting the same seqno but different hashes = consensus fork.
#
# Uses MIN(all validators' latest seqnos) - 3 as the check height, ensuring
# the checked block is well below ALL validators' confirmed tips and fully
# finalized by every validator. This avoids false positives from sync lag
# after fault-induced restarts (previously used a state file from v1 only).
#
# Hardened against fault-induced validator restarts:
#   - Checks heartbeat freshness for all validators before comparing
#   - Skips comparison if any validator's heartbeat is stale (may be catching up)
#   - Requires ALL validators to report their latest seqno
#   - Skips if any validator's latest seqno is more than 5 behind others (still syncing)
#   - Includes block IDs, seqnos, and heartbeat ages in assertion details
#
# Skip gracefully when infrastructure is unavailable (no false positives).

source "$(dirname "$0")/helper_sdk.sh"

ALWAYS_NAME="Cross-validator block hash matches at same height"
SOMETIMES_NAME="Block hash verified across multiple validators"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
VALIDATOR2_HOST="${VALIDATOR2_HOST:-ton-validator2}"
VALIDATOR3_HOST="${VALIDATOR3_HOST:-ton-validator3}"
LITE_PORT="${LITE_PORT:-30003}"

# Heartbeat freshness threshold (seconds)
HB_FRESHNESS_THRESHOLD=60
# Max seqno lag before considering a validator "still syncing"
MAX_SEQNO_LAG=5

# Heartbeat files per validator
HB_FILES=("/shared/validator_heartbeat" "/shared/validator2_heartbeat" "/shared/validator3_heartbeat")
HB_LABELS=("v1" "v2" "v3")

# Catalog both assertions up front
sdk_catalog_always  "$ALWAYS_NAME"
sdk_catalog_sometimes "$SOMETIMES_NAME"

# --- Precondition checks (skip, never fail) ---

if ! command -v lite-client >/dev/null 2>&1; then
    echo "lite-client binary not found, skipping"
    exit 0
fi

# CHECK_SEQNO is computed after querying all validators' latest seqnos (below).

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

# --- Helper: query latest seqno from a validator ---
# Args: <host> <config_file>
# Returns: seqno number, or empty string on failure

query_latest_seqno() {
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

    echo "${output}" | grep -oE '\(-1,[0-9a-fA-F]+,[0-9]+\)' | grep -oE ',[0-9]+\)$' | tr -d ',)' | tail -1 || true
}

# --- Check heartbeat freshness for all validators ---

echo "Checking heartbeat freshness for all validators..."
HB_AGES=()
ANY_STALE=false

for idx in 0 1 2; do
    age=$(get_heartbeat_age "${HB_FILES[$idx]}")
    HB_AGES+=("${age}")
    if [ "${age}" -eq -1 ]; then
        echo "  ${HB_LABELS[$idx]}: heartbeat missing/unreadable"
        ANY_STALE=true
    elif [ "${age}" -gt "${HB_FRESHNESS_THRESHOLD}" ]; then
        echo "  ${HB_LABELS[$idx]}: heartbeat stale (age=${age}s > ${HB_FRESHNESS_THRESHOLD}s)"
        ANY_STALE=true
    else
        echo "  ${HB_LABELS[$idx]}: heartbeat fresh (age=${age}s)"
    fi
done

if [ "${ANY_STALE}" = "true" ]; then
    echo "SKIP: At least one validator has stale/missing heartbeat — may be catching up after restart"
    exit 0
fi

# --- Query latest seqno from all validators to detect sync lag ---

echo "Checking latest seqnos to detect sync lag..."
HOSTS=("${VALIDATOR_HOST}" "${VALIDATOR2_HOST}" "${VALIDATOR3_HOST}")
CONFIGS=("/shared/liteserver.config.json" "/shared/liteserver2.config.json" "/shared/liteserver3.config.json")

LATEST_SEQNOS=()
ALL_HAVE_SEQNO=true

for idx in 0 1 2; do
    s=$(query_latest_seqno "${HOSTS[$idx]}" "${CONFIGS[$idx]}")
    if [ -z "${s}" ] || ! [[ "${s}" =~ ^[0-9]+$ ]]; then
        echo "  ${HB_LABELS[$idx]}: could not query latest seqno"
        ALL_HAVE_SEQNO=false
        LATEST_SEQNOS+=("0")
    else
        echo "  ${HB_LABELS[$idx]}: latest seqno = ${s}"
        LATEST_SEQNOS+=("${s}")
    fi
done

if [ "${ALL_HAVE_SEQNO}" != "true" ]; then
    echo "SKIP: Not all validators reported their latest seqno"
    exit 0
fi

# Find max seqno
MAX_LATEST=0
for s in "${LATEST_SEQNOS[@]}"; do
    if [ "${s}" -gt "${MAX_LATEST}" ]; then
        MAX_LATEST="${s}"
    fi
done

# Check if any validator is lagging too far behind
for idx in 0 1 2; do
    lag=$(( MAX_LATEST - LATEST_SEQNOS[$idx] ))
    if [ "${lag}" -gt "${MAX_SEQNO_LAG}" ]; then
        echo "SKIP: ${HB_LABELS[$idx]} is ${lag} blocks behind max (${LATEST_SEQNOS[$idx]} vs ${MAX_LATEST}) — still syncing"
        exit 0
    fi
done

# Use MIN(all validators' latest seqnos) - 3 as the check height.
# This guarantees the checked block is well below ALL validators' confirmed tips,
# ensuring every validator has fully finalized it.
MIN_SEQNO="${LATEST_SEQNOS[0]}"
for s in "${LATEST_SEQNOS[@]}"; do
    if [ "${s}" -lt "${MIN_SEQNO}" ]; then
        MIN_SEQNO="${s}"
    fi
done
CHECK_SEQNO=$(( MIN_SEQNO - 3 ))

if [ "${CHECK_SEQNO}" -lt 1 ]; then
    echo "CHECK_SEQNO ${CHECK_SEQNO} too low (need >= 1, MIN_SEQNO=${MIN_SEQNO}), skipping"
    exit 0
fi

echo "Checking block hash consensus at seqno ${CHECK_SEQNO} (MIN_SEQNO=${MIN_SEQNO}, MAX_SEQNO=${MAX_LATEST})"

# --- Query all 3 validators for block at CHECK_SEQNO ---

echo "Querying all 3 validators for block at seqno ${CHECK_SEQNO}..."

BLOCK_ID1=$(query_block_id "${VALIDATOR_HOST}"  "/shared/liteserver.config.json"  "${CHECK_SEQNO}")
BLOCK_ID2=$(query_block_id "${VALIDATOR2_HOST}" "/shared/liteserver2.config.json" "${CHECK_SEQNO}")
BLOCK_ID3=$(query_block_id "${VALIDATOR3_HOST}" "/shared/liteserver3.config.json" "${CHECK_SEQNO}")

echo "Block IDs: v1=${BLOCK_ID1:-n/a} v2=${BLOCK_ID2:-n/a} v3=${BLOCK_ID3:-n/a}"

# --- Count responding validators ---

RESPONDED=0
BLOCK_IDS=()
VALIDATOR_LABELS_RESP=()

if [ -n "${BLOCK_ID1}" ]; then
    RESPONDED=$((RESPONDED + 1))
    BLOCK_IDS+=("${BLOCK_ID1}")
    VALIDATOR_LABELS_RESP+=("v1")
fi
if [ -n "${BLOCK_ID2}" ]; then
    RESPONDED=$((RESPONDED + 1))
    BLOCK_IDS+=("${BLOCK_ID2}")
    VALIDATOR_LABELS_RESP+=("v2")
fi
if [ -n "${BLOCK_ID3}" ]; then
    RESPONDED=$((RESPONDED + 1))
    BLOCK_IDS+=("${BLOCK_ID3}")
    VALIDATOR_LABELS_RESP+=("v3")
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
                MISMATCH_DETAIL="${VALIDATOR_LABELS_RESP[$i]}=${BLOCK_IDS[$i]} vs ${VALIDATOR_LABELS_RESP[$j]}=${BLOCK_IDS[$j]}"
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
    --argjson v1_latest "${LATEST_SEQNOS[0]}" \
    --argjson v2_latest "${LATEST_SEQNOS[1]}" \
    --argjson v3_latest "${LATEST_SEQNOS[2]}" \
    --argjson v1_hb_age "${HB_AGES[0]}" \
    --argjson v2_hb_age "${HB_AGES[1]}" \
    --argjson v3_hb_age "${HB_AGES[2]}" \
    '{check_seqno: $seqno, v1_block_id: $v1, v2_block_id: $v2, v3_block_id: $v3,
      responded: $responded, fork_detected: $fork, mismatch: $mismatch,
      v1_latest_seqno: $v1_latest, v2_latest_seqno: $v2_latest, v3_latest_seqno: $v3_latest,
      v1_heartbeat_age_s: $v1_hb_age, v2_heartbeat_age_s: $v2_hb_age, v3_heartbeat_age_s: $v3_hb_age}')

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
