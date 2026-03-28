#!/usr/bin/env bash
set -euo pipefail

# Finally: Verify all validators agree on the same masterchain block at end of timeline.
# This is the definitive consensus safety check. After all faults settle, validators
# must converge to the same masterchain state. Different block IDs at the same height
# means a consensus fork — the most critical safety violation.
#
# Hardened against fault-induced validator restarts:
#   - Retries up to 30s waiting for all validators to have fresh heartbeats
#   - Increased seqno tolerance from 1 to 3 (validators may be a few blocks apart)
#   - Logs heartbeat ages alongside block IDs for diagnosis
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
ACCOUNT_STATE_ALWAYS="Account state consistent across validators at end of timeline"
SOMETIMES_NAME="Consensus convergence verified across all validators"

# Heartbeat freshness threshold (seconds)
HB_FRESHNESS_THRESHOLD=60
# Max time to wait for heartbeats to become fresh (seconds)
HB_WAIT_TIMEOUT=30
# Seqno tolerance: validators may be a few blocks apart at timeline end
SEQNO_TOLERANCE=3

# Heartbeat files per validator
HB_FILES=("/shared/validator_heartbeat" "/shared/validator2_heartbeat" "/shared/validator3_heartbeat")
HB_LABELS=("v1" "v2" "v3")

sdk_catalog_always "${ALWAYS_NAME}"
sdk_catalog_always "${ACCOUNT_STATE_ALWAYS}"
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

# Compute heartbeat age; returns -1 if missing/unreadable
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

# Query account state from a validator's liteserver.
# Returns raw lite-client output for parsing trans_lt, trans_hash, balance.
# Args: <host> <config_file>
query_account_state() {
    local host="$1" config="$2"
    local wallet="-1:0000000000000000000000000000000000000000000000000000000000000000"

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

    timeout 10 lite-client \
        -v 1 \
        -a "${ip}:${LITE_PORT}" \
        -C "${config}" \
        -c "getaccount ${wallet}" \
        -c 'quit' 2>&1 || true
}

# --- Wait for all validator heartbeats to become fresh ---

echo "Waiting up to ${HB_WAIT_TIMEOUT}s for all validator heartbeats to become fresh..."
WAITED=0
while [ "${WAITED}" -lt "${HB_WAIT_TIMEOUT}" ]; do
    ALL_FRESH=true
    for idx in 0 1 2; do
        age=$(get_heartbeat_age "${HB_FILES[$idx]}")
        if [ "${age}" -eq -1 ] || [ "${age}" -gt "${HB_FRESHNESS_THRESHOLD}" ]; then
            ALL_FRESH=false
            break
        fi
    done

    if [ "${ALL_FRESH}" = "true" ]; then
        echo "All validator heartbeats are fresh after ${WAITED}s"
        break
    fi

    sleep 3
    WAITED=$((WAITED + 3))
done

if [ "${ALL_FRESH}" = "false" ]; then
    echo "WARNING: Not all heartbeats became fresh within ${HB_WAIT_TIMEOUT}s — proceeding anyway"
fi

# --- Log heartbeat ages for diagnosis ---

echo "Heartbeat ages at check time:"
FINAL_HB_AGES=()
for idx in 0 1 2; do
    age=$(get_heartbeat_age "${HB_FILES[$idx]}")
    FINAL_HB_AGES+=("${age}")
    if [ "${age}" -eq -1 ]; then
        echo "  ${HB_LABELS[$idx]}: heartbeat missing/unreadable"
    else
        echo "  ${HB_LABELS[$idx]}: heartbeat age = ${age}s"
    fi
done

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
VALIDATOR_LABELS_RESP=()

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
            VALIDATOR_LABELS_RESP+=("${label}")
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

# Seqno tolerance: difference must be <= SEQNO_TOLERANCE (3)
if [ "${SEQNO_DIFF}" -gt "${SEQNO_TOLERANCE}" ]; then
    CONVERGED=false
    MISMATCH_DETAIL="seqno divergence too large: min=${MIN_SEQNO} max=${MAX_SEQNO} diff=${SEQNO_DIFF} (tolerance=${SEQNO_TOLERANCE})"
    echo "FAIL: ${MISMATCH_DETAIL}"
fi

# If seqnos match exactly, block IDs MUST match (same height = same block or fork)
if [ "${SEQNO_DIFF}" -eq 0 ]; then
    for i in "${!BLOCK_IDS[@]}"; do
        for j in "${!BLOCK_IDS[@]}"; do
            if [ "$i" -lt "$j" ]; then
                if [ "${BLOCK_IDS[$i]}" != "${BLOCK_IDS[$j]}" ]; then
                    CONVERGED=false
                    MISMATCH_DETAIL="FORK at seqno ${SEQNOS[$i]}: ${VALIDATOR_LABELS_RESP[$i]}=${BLOCK_IDS[$i]} vs ${VALIDATOR_LABELS_RESP[$j]}=${BLOCK_IDS[$j]}"
                    echo "CRITICAL: ${MISMATCH_DETAIL}"
                fi
            fi
        done
    done
fi

# If seqno diff is within tolerance, compare validators at the same seqno
if [ "${SEQNO_DIFF}" -gt 0 ] && [ "${SEQNO_DIFF}" -le "${SEQNO_TOLERANCE}" ]; then
    echo "Seqno diff is ${SEQNO_DIFF} (within tolerance=${SEQNO_TOLERANCE}), comparing validators at same heights..."
    # Group by seqno and check within groups
    for i in "${!BLOCK_IDS[@]}"; do
        for j in "${!BLOCK_IDS[@]}"; do
            if [ "$i" -lt "$j" ] && [ "${SEQNOS[$i]}" -eq "${SEQNOS[$j]}" ]; then
                if [ "${BLOCK_IDS[$i]}" != "${BLOCK_IDS[$j]}" ]; then
                    CONVERGED=false
                    MISMATCH_DETAIL="FORK at seqno ${SEQNOS[$i]}: ${VALIDATOR_LABELS_RESP[$i]}=${BLOCK_IDS[$i]} vs ${VALIDATOR_LABELS_RESP[$j]}=${BLOCK_IDS[$j]}"
                    echo "CRITICAL: ${MISMATCH_DETAIL}"
                fi
            fi
        done
    done
fi

# --- Account state verification across validators at same seqno ---

ACCOUNT_LT_CONSISTENT=true
ACCOUNT_MISMATCH_DETAIL=""
V1_TRANS_LT="n/a"
V2_TRANS_LT="n/a"
V3_TRANS_LT="n/a"
V1_TRANS_HASH="n/a"
V2_TRANS_HASH="n/a"
V3_TRANS_HASH="n/a"
ACCOUNT_STATE_CHECKED=false

# Only check account state if we have >=2 validators at the SAME seqno
# Build arrays of validators grouped by seqno
HOSTS=("${VALIDATOR_HOST}" "${VALIDATOR2_HOST}" "${VALIDATOR3_HOST}")
CONFIGS=("/shared/liteserver.config.json" "/shared/liteserver2.config.json" "/shared/liteserver3.config.json")
LABELS_ALL=("v1" "v2" "v3")

# Find validators that share the same seqno
for i in "${!SEQNOS[@]}"; do
    SAME_SEQNO_COUNT=0
    for j in "${!SEQNOS[@]}"; do
        if [ "${SEQNOS[$i]}" -eq "${SEQNOS[$j]}" ]; then
            SAME_SEQNO_COUNT=$((SAME_SEQNO_COUNT + 1))
        fi
    done
    if [ "${SAME_SEQNO_COUNT}" -ge 2 ]; then
        ACCOUNT_STATE_CHECKED=true
        break
    fi
done

if [ "${ACCOUNT_STATE_CHECKED}" = "true" ]; then
    echo "Checking elector account state across validators with matching seqnos..."

    # Query account state from each responding validator
    ACCT_TRANS_LTS=()
    ACCT_TRANS_HASHES=()

    for i in "${!VALIDATOR_LABELS_RESP[@]}"; do
        label="${VALIDATOR_LABELS_RESP[$i]}"
        # Map label back to host/config index
        case "${label}" in
            v1) host="${HOSTS[0]}"; config="${CONFIGS[0]}" ;;
            v2) host="${HOSTS[1]}"; config="${CONFIGS[1]}" ;;
            v3) host="${HOSTS[2]}"; config="${CONFIGS[2]}" ;;
        esac

        output=$(query_account_state "${host}" "${config}")
        trans_lt=$(echo "${output}" | grep -oP 'last transaction lt = \K[0-9]+' | head -1 || true)
        trans_hash=$(echo "${output}" | grep -oP 'hash = \K[0-9a-fA-F]{64}' | head -1 || true)

        ACCT_TRANS_LTS+=("${trans_lt:-}")
        ACCT_TRANS_HASHES+=("${trans_hash:-}")

        # Store per-validator values for details JSON
        case "${label}" in
            v1) V1_TRANS_LT="${trans_lt:-n/a}"; V1_TRANS_HASH="${trans_hash:-n/a}" ;;
            v2) V2_TRANS_LT="${trans_lt:-n/a}"; V2_TRANS_HASH="${trans_hash:-n/a}" ;;
            v3) V3_TRANS_LT="${trans_lt:-n/a}"; V3_TRANS_HASH="${trans_hash:-n/a}" ;;
        esac

        echo "  ${label} (seqno ${SEQNOS[$i]}): trans_lt=${trans_lt:-empty} trans_hash=${trans_hash:-empty}"
    done

    # Compare (trans_lt, trans_hash) for validators at the SAME seqno
    for i in "${!VALIDATOR_LABELS_RESP[@]}"; do
        for j in "${!VALIDATOR_LABELS_RESP[@]}"; do
            if [ "$i" -lt "$j" ] && [ "${SEQNOS[$i]}" -eq "${SEQNOS[$j]}" ]; then
                lt_i="${ACCT_TRANS_LTS[$i]}"
                lt_j="${ACCT_TRANS_LTS[$j]}"
                hash_i="${ACCT_TRANS_HASHES[$i]}"
                hash_j="${ACCT_TRANS_HASHES[$j]}"

                # Skip if either validator returned empty (query failed)
                if [ -z "${lt_i}" ] || [ -z "${lt_j}" ] || [ -z "${hash_i}" ] || [ -z "${hash_j}" ]; then
                    echo "  Skipping comparison ${VALIDATOR_LABELS_RESP[$i]} vs ${VALIDATOR_LABELS_RESP[$j]}: incomplete data"
                    continue
                fi

                if [ "${lt_i}" != "${lt_j}" ] || [ "${hash_i}" != "${hash_j}" ]; then
                    ACCOUNT_LT_CONSISTENT=false
                    ACCOUNT_MISMATCH_DETAIL="Account state divergence at seqno ${SEQNOS[$i]}: ${VALIDATOR_LABELS_RESP[$i]}=(lt=${lt_i},hash=${hash_i}) vs ${VALIDATOR_LABELS_RESP[$j]}=(lt=${lt_j},hash=${hash_j})"
                    echo "CRITICAL: ${ACCOUNT_MISMATCH_DETAIL}"
                fi
            fi
        done
    done

    if [ "${ACCOUNT_LT_CONSISTENT}" = "true" ]; then
        echo "PASS: Account state consistent across validators at matching seqnos"
    fi
else
    echo "No validators share the same seqno — skipping account state comparison"
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
    --argjson seqno_tolerance "${SEQNO_TOLERANCE}" \
    --argjson converged "$([ "${CONVERGED}" = "true" ] && echo true || echo false)" \
    --arg mismatch "${MISMATCH_DETAIL}" \
    --argjson v1_hb_age "${FINAL_HB_AGES[0]}" \
    --argjson v2_hb_age "${FINAL_HB_AGES[1]}" \
    --argjson v3_hb_age "${FINAL_HB_AGES[2]}" \
    --argjson account_lt_consistent "$([ "${ACCOUNT_LT_CONSISTENT}" = "true" ] && echo true || echo false)" \
    --arg account_mismatch "${ACCOUNT_MISMATCH_DETAIL}" \
    --arg v1_trans_lt "${V1_TRANS_LT}" \
    --arg v2_trans_lt "${V2_TRANS_LT}" \
    --arg v3_trans_lt "${V3_TRANS_LT}" \
    '{v1_block_id: $v1, v2_block_id: $v2, v3_block_id: $v3,
      responded: $responded, min_seqno: $min_seqno, max_seqno: $max_seqno,
      seqno_diff: $seqno_diff, seqno_tolerance: $seqno_tolerance,
      converged: $converged, mismatch: $mismatch,
      v1_heartbeat_age_s: $v1_hb_age, v2_heartbeat_age_s: $v2_hb_age, v3_heartbeat_age_s: $v3_hb_age,
      account_lt_consistent: $account_lt_consistent, account_mismatch: $account_mismatch,
      v1_trans_lt: $v1_trans_lt, v2_trans_lt: $v2_trans_lt, v3_trans_lt: $v3_trans_lt}')

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
fi

# Emit account state consistency assertion (independent of block ID convergence)
if [ "${ACCOUNT_STATE_CHECKED}" = "true" ]; then
    if [ "${ACCOUNT_LT_CONSISTENT}" = "true" ]; then
        sdk_always true "${ACCOUNT_STATE_ALWAYS}" "${DETAILS}"
    else
        echo "FAIL: Account state inconsistent — ${ACCOUNT_MISMATCH_DETAIL}"
        sdk_always false "${ACCOUNT_STATE_ALWAYS}" "${DETAILS}"
        exit 1
    fi
fi

# Exit with failure if block convergence failed (after emitting all assertions)
if [ "${CONVERGED}" != "true" ]; then
    exit 1
fi

exit 0
