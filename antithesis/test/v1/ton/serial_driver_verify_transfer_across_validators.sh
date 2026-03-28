#!/usr/bin/env bash
set -euo pipefail

# Serial driver: Cross-validator account state verification after transfer.
# Reads the last confirmed wallet seqno (written by serial_driver_send_transfer.sh),
# then queries ALL 3 validators' liteservers for the wallet seqno and balance.
# Asserts exact agreement on seqno across validators (L2 data consistency).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
VALIDATOR2_HOST="${VALIDATOR2_HOST:-ton-validator2}"
VALIDATOR3_HOST="${VALIDATOR3_HOST:-ton-validator3}"
LITE_PORT="${LITE_PORT:-30003}"
HEARTBEAT_MAX_AGE=60

SOMETIMES_NAME="Cross-validator account state is consistent after transfer"
ALWAYS_NAME="Cross-validator wallet seqno divergence is bounded"

sdk_catalog_sometimes "${SOMETIMES_NAME}"
sdk_catalog_always "${ALWAYS_NAME}"

WALLET_ADDR="-1:0000000000000000000000000000000000000000000000000000000000000000"

# --- Preconditions ---

# All 3 heartbeats must be fresh
for HB_FILE in /shared/validator_heartbeat /shared/validator2_heartbeat /shared/validator3_heartbeat; do
    if [ ! -f "${HB_FILE}" ]; then
        echo "Heartbeat ${HB_FILE} not present yet, skipping"
        exit 0
    fi
    HB_TS=$(cat "${HB_FILE}" 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "${HB_TS}" =~ ^[0-9]+$ ]]; then
        HB_AGE=$(( NOW - HB_TS ))
        if [ "${HB_AGE}" -gt "${HEARTBEAT_MAX_AGE}" ]; then
            echo "Heartbeat ${HB_FILE} stale (${HB_AGE}s), skipping"
            exit 0
        fi
    else
        echo "Heartbeat ${HB_FILE} value invalid, skipping"
        exit 0
    fi
done

# Must have a confirmed transfer
if [ ! -f /shared/tx/last_confirmed_seqno ]; then
    echo "No confirmed transfer yet (last_confirmed_seqno missing), skipping"
    exit 0
fi
EXPECTED_SEQNO=$(cat /shared/tx/last_confirmed_seqno 2>/dev/null | tr -d '[:space:]')
if [ -z "${EXPECTED_SEQNO}" ] || ! [[ "${EXPECTED_SEQNO}" =~ ^[0-9]+$ ]] || [ "${EXPECTED_SEQNO}" -eq 0 ]; then
    echo "last_confirmed_seqno invalid or zero (got: '${EXPECTED_SEQNO}'), skipping"
    exit 0
fi
echo "Expected wallet seqno >= ${EXPECTED_SEQNO}"

# lite-client must be available
if ! command -v lite-client >/dev/null 2>&1; then
    echo "lite-client binary not found, skipping"
    exit 0
fi

# All 3 liteserver ports must be reachable
for H in "${VALIDATOR_HOST}" "${VALIDATOR2_HOST}" "${VALIDATOR3_HOST}"; do
    if ! nc -z -w 2 "${H}" "${LITE_PORT}" 2>/dev/null; then
        echo "Liteserver on ${H}:${LITE_PORT} not reachable, skipping"
        exit 0
    fi
done

# All 3 config files must exist
for CFG in /shared/liteserver.config.json /shared/liteserver2.config.json /shared/liteserver3.config.json; do
    if [ ! -f "${CFG}" ]; then
        echo "Config ${CFG} not available, skipping"
        exit 0
    fi
done

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

# Query wallet seqno via runmethod 85143
# Args: <host> <config>
query_wallet_seqno() {
    local host="$1" config="$2"
    local ip
    ip=$(resolve_ip "${host}")
    local output
    output=$(timeout 10 lite-client \
        -v 1 \
        -a "${ip}:${LITE_PORT}" \
        -C "${config}" \
        -c "runmethod ${WALLET_ADDR} 85143" \
        -c 'quit' 2>&1) || true
    echo "${output}" | grep -oP 'result:\s*\[\s*\K[0-9]+' | head -1 || true
}

# Query account balance via getaccount
# Args: <host> <config>
query_wallet_balance() {
    local host="$1" config="$2"
    local ip
    ip=$(resolve_ip "${host}")
    local output
    output=$(timeout 10 lite-client \
        -v 1 \
        -a "${ip}:${LITE_PORT}" \
        -C "${config}" \
        -c "getaccount ${WALLET_ADDR}" \
        -c 'quit' 2>&1) || true
    # Extract balance from "balance:" line — format varies but typically "balance: <amount>"
    echo "${output}" | grep -oP 'balance[^0-9]*\K[0-9]+' | head -1 || true
}

# --- Query all 3 validators ---

echo "Querying wallet seqno from all 3 validators..."

SEQNO1=$(query_wallet_seqno "${VALIDATOR_HOST}"  "/shared/liteserver.config.json")
SEQNO2=$(query_wallet_seqno "${VALIDATOR2_HOST}" "/shared/liteserver2.config.json")
SEQNO3=$(query_wallet_seqno "${VALIDATOR3_HOST}" "/shared/liteserver3.config.json")

echo "Wallet seqnos: v1=${SEQNO1:-n/a} v2=${SEQNO2:-n/a} v3=${SEQNO3:-n/a}"

echo "Querying wallet balance from all 3 validators..."

BAL1=$(query_wallet_balance "${VALIDATOR_HOST}"  "/shared/liteserver.config.json")
BAL2=$(query_wallet_balance "${VALIDATOR2_HOST}" "/shared/liteserver2.config.json")
BAL3=$(query_wallet_balance "${VALIDATOR3_HOST}" "/shared/liteserver3.config.json")

echo "Wallet balances: v1=${BAL1:-n/a} v2=${BAL2:-n/a} v3=${BAL3:-n/a}"

# --- Count responding validators ---

RESPONDED=0
SEQNOS=()
LABELS=()
for PAIR in "v1:${SEQNO1}" "v2:${SEQNO2}" "v3:${SEQNO3}"; do
    LABEL="${PAIR%%:*}"
    S="${PAIR#*:}"
    if [ -n "${S}" ] && [[ "${S}" =~ ^[0-9]+$ ]]; then
        RESPONDED=$((RESPONDED + 1))
        SEQNOS+=("${S}")
        LABELS+=("${LABEL}")
    fi
done

if [ "${RESPONDED}" -lt 2 ]; then
    echo "Fewer than 2 validators responded with seqno (${RESPONDED}), skipping"
    exit 0
fi

# --- Check seqno divergence (Always guard: bounded divergence) ---

MAX_DIVERGENCE=1
DIVERGED=false
MAX_SEEN_DIFF=0
for i in "${!SEQNOS[@]}"; do
    for j in "${!SEQNOS[@]}"; do
        if [ "$i" -lt "$j" ]; then
            DIFF=$(( ${SEQNOS[$i]} - ${SEQNOS[$j]} ))
            [ "${DIFF}" -lt 0 ] && DIFF=$(( -DIFF ))
            [ "${DIFF}" -gt "${MAX_SEEN_DIFF}" ] && MAX_SEEN_DIFF="${DIFF}"
            if [ "${DIFF}" -gt "${MAX_DIVERGENCE}" ]; then
                DIVERGED=true
            fi
        fi
    done
done

ALWAYS_DETAILS=$(jq -cn \
    --arg v1 "${SEQNO1:-null}" \
    --arg v2 "${SEQNO2:-null}" \
    --arg v3 "${SEQNO3:-null}" \
    --argjson max_diff "${MAX_SEEN_DIFF}" \
    --argjson max_allowed "${MAX_DIVERGENCE}" \
    '{v1_seqno: $v1, v2_seqno: $v2, v3_seqno: $v3, max_diff: $max_diff, max_allowed: $max_allowed}')

if [ "${DIVERGED}" = "true" ]; then
    echo "FAIL: wallet seqno divergence ${MAX_SEEN_DIFF} exceeds bound ${MAX_DIVERGENCE}"
    sdk_always false "${ALWAYS_NAME}" "${ALWAYS_DETAILS}"
else
    echo "PASS: wallet seqno divergence bounded (max diff: ${MAX_SEEN_DIFF})"
    sdk_always true "${ALWAYS_NAME}" "${ALWAYS_DETAILS}"
fi

# --- Check exact seqno agreement (Sometimes: all agree exactly) ---

ALL_AGREE=true
FIRST="${SEQNOS[0]}"
for S in "${SEQNOS[@]}"; do
    if [ "${S}" != "${FIRST}" ]; then
        ALL_AGREE=false
        break
    fi
done

# Also check balance agreement among responding validators
BAL_RESPONDED=0
BALANCES=()
for B in "${BAL1}" "${BAL2}" "${BAL3}"; do
    if [ -n "${B}" ] && [[ "${B}" =~ ^[0-9]+$ ]]; then
        BAL_RESPONDED=$((BAL_RESPONDED + 1))
        BALANCES+=("${B}")
    fi
done

BAL_AGREE=true
if [ "${BAL_RESPONDED}" -ge 2 ]; then
    FIRST_BAL="${BALANCES[0]}"
    for B in "${BALANCES[@]}"; do
        if [ "${B}" != "${FIRST_BAL}" ]; then
            BAL_AGREE=false
            break
        fi
    done
fi

CONSISTENT=false
if [ "${ALL_AGREE}" = "true" ] && [ "${BAL_AGREE}" = "true" ] && [ "${RESPONDED}" -ge 2 ]; then
    CONSISTENT=true
fi

SOMETIMES_DETAILS=$(jq -cn \
    --arg v1_seqno "${SEQNO1:-null}" \
    --arg v2_seqno "${SEQNO2:-null}" \
    --arg v3_seqno "${SEQNO3:-null}" \
    --arg v1_bal "${BAL1:-null}" \
    --arg v2_bal "${BAL2:-null}" \
    --arg v3_bal "${BAL3:-null}" \
    --argjson responded "${RESPONDED}" \
    --argjson bal_responded "${BAL_RESPONDED}" \
    --argjson seqno_agree "$([ "${ALL_AGREE}" = "true" ] && echo true || echo false)" \
    --argjson bal_agree "$([ "${BAL_AGREE}" = "true" ] && echo true || echo false)" \
    --arg expected_seqno "${EXPECTED_SEQNO}" \
    '{v1_seqno: $v1_seqno, v2_seqno: $v2_seqno, v3_seqno: $v3_seqno,
      v1_balance: $v1_bal, v2_balance: $v2_bal, v3_balance: $v3_bal,
      responded: $responded, bal_responded: $bal_responded,
      seqno_agree: $seqno_agree, bal_agree: $bal_agree,
      expected_seqno: $expected_seqno}')

if [ "${CONSISTENT}" = "true" ]; then
    echo "PASS: cross-validator account state consistent (seqno=${FIRST}, balance agreement=${BAL_AGREE})"
    sdk_sometimes true "${SOMETIMES_NAME}" "${SOMETIMES_DETAILS}"
else
    echo "Account state not yet consistent across validators (seqno_agree=${ALL_AGREE}, bal_agree=${BAL_AGREE})"
    sdk_sometimes false "${SOMETIMES_NAME}" "${SOMETIMES_DETAILS}"
fi

exit 0
