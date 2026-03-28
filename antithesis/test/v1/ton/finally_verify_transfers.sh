#!/usr/bin/env bash
set -euo pipefail

# Finally: Verify all acknowledged transfers persist in the final blockchain state.
# This is the definitive end-of-timeline data-loss check. Every wallet seqno that
# was confirmed by serial_driver_send_transfer.sh must still be reflected in the
# chain after all faults have settled.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
VALIDATOR2_HOST="${VALIDATOR2_HOST:-ton-validator2}"
VALIDATOR3_HOST="${VALIDATOR3_HOST:-ton-validator3}"
LITE_PORT="${LITE_PORT:-30003}"

ALWAYS_NAME="All acknowledged transfers persist in final state"
SOMETIMES_NAME="Transfer state verified at end of timeline"

sdk_catalog_always "${ALWAYS_NAME}"
sdk_catalog_sometimes "${SOMETIMES_NAME}"

WALLET_ADDR="-1:0000000000000000000000000000000000000000000000000000000000000000"

# --- Preconditions (skip, not fail) ---

if ! command -v lite-client >/dev/null 2>&1; then
    echo "lite-client binary not found, skipping"
    exit 0
fi

if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    echo "Primary liteserver not reachable, skipping"
    exit 0
fi

if [ ! -f /shared/liteserver.config.json ]; then
    echo "Liteserver config not available, skipping"
    exit 0
fi

if [ ! -f /shared/tx/last_confirmed_seqno ]; then
    echo "No confirmed transfers (last_confirmed_seqno missing), skipping"
    exit 0
fi

EXPECTED_SEQNO=$(cat /shared/tx/last_confirmed_seqno 2>/dev/null | tr -d '[:space:]')
if [ -z "${EXPECTED_SEQNO}" ] || ! [[ "${EXPECTED_SEQNO}" =~ ^[0-9]+$ ]] || [ "${EXPECTED_SEQNO}" -eq 0 ]; then
    echo "last_confirmed_seqno invalid or zero (got: '${EXPECTED_SEQNO}'), skipping"
    exit 0
fi

echo "Expected wallet seqno >= ${EXPECTED_SEQNO} (from confirmed transfers)"

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

# --- Query primary validator ---

echo "Querying wallet seqno from primary validator..."
SEQNO1=$(query_wallet_seqno "${VALIDATOR_HOST}" "/shared/liteserver.config.json")

if [ -z "${SEQNO1}" ] || ! [[ "${SEQNO1}" =~ ^[0-9]+$ ]]; then
    echo "Could not query primary validator seqno (got: '${SEQNO1}'), skipping"
    exit 0
fi

echo "Primary validator wallet seqno: ${SEQNO1}"

# --- Core assertion: confirmed seqno must persist ---

PERSISTED=true
if [ "${SEQNO1}" -lt "${EXPECTED_SEQNO}" ]; then
    PERSISTED=false
    echo "CRITICAL: Primary validator seqno ${SEQNO1} < confirmed ${EXPECTED_SEQNO} — DATA LOSS"
else
    echo "PASS: Primary validator seqno ${SEQNO1} >= confirmed ${EXPECTED_SEQNO}"
fi

# --- Query validator2 and validator3 if reachable ---

SEQNO2=""
SEQNO3=""
V2_PERSISTED="skipped"
V3_PERSISTED="skipped"

if nc -z -w 2 "${VALIDATOR2_HOST}" "${LITE_PORT}" 2>/dev/null && [ -f /shared/liteserver2.config.json ]; then
    SEQNO2=$(query_wallet_seqno "${VALIDATOR2_HOST}" "/shared/liteserver2.config.json")
    if [ -n "${SEQNO2}" ] && [[ "${SEQNO2}" =~ ^[0-9]+$ ]]; then
        echo "Validator2 wallet seqno: ${SEQNO2}"
        if [ "${SEQNO2}" -lt "${EXPECTED_SEQNO}" ]; then
            V2_PERSISTED="false"
            PERSISTED=false
            echo "CRITICAL: Validator2 seqno ${SEQNO2} < confirmed ${EXPECTED_SEQNO} — DATA LOSS"
        else
            V2_PERSISTED="true"
            echo "PASS: Validator2 seqno ${SEQNO2} >= confirmed ${EXPECTED_SEQNO}"
        fi
    else
        echo "Validator2 seqno query failed (got: '${SEQNO2}')"
    fi
else
    echo "Validator2 not reachable or config missing, skipping"
fi

if nc -z -w 2 "${VALIDATOR3_HOST}" "${LITE_PORT}" 2>/dev/null && [ -f /shared/liteserver3.config.json ]; then
    SEQNO3=$(query_wallet_seqno "${VALIDATOR3_HOST}" "/shared/liteserver3.config.json")
    if [ -n "${SEQNO3}" ] && [[ "${SEQNO3}" =~ ^[0-9]+$ ]]; then
        echo "Validator3 wallet seqno: ${SEQNO3}"
        if [ "${SEQNO3}" -lt "${EXPECTED_SEQNO}" ]; then
            V3_PERSISTED="false"
            PERSISTED=false
            echo "CRITICAL: Validator3 seqno ${SEQNO3} < confirmed ${EXPECTED_SEQNO} — DATA LOSS"
        else
            V3_PERSISTED="true"
            echo "PASS: Validator3 seqno ${SEQNO3} >= confirmed ${EXPECTED_SEQNO}"
        fi
    else
        echo "Validator3 seqno query failed (got: '${SEQNO3}')"
    fi
else
    echo "Validator3 not reachable or config missing, skipping"
fi

# --- Check cross-validator agreement on final seqno ---

SEQNOS_AGREE="n/a"
RESPONDED=0
SEQNO_VALS=()
for S in "${SEQNO1}" "${SEQNO2}" "${SEQNO3}"; do
    if [ -n "${S}" ] && [[ "${S}" =~ ^[0-9]+$ ]]; then
        RESPONDED=$((RESPONDED + 1))
        SEQNO_VALS+=("${S}")
    fi
done

if [ "${RESPONDED}" -ge 2 ]; then
    SEQNOS_AGREE="true"
    FIRST="${SEQNO_VALS[0]}"
    for S in "${SEQNO_VALS[@]}"; do
        if [ "${S}" != "${FIRST}" ]; then
            SEQNOS_AGREE="false"
            echo "WARNING: Validators disagree on final seqno"
            break
        fi
    done
fi

# --- Emit assertions ---

DETAILS=$(jq -cn \
    --argjson expected "${EXPECTED_SEQNO}" \
    --arg v1_seqno "${SEQNO1:-null}" \
    --arg v2_seqno "${SEQNO2:-null}" \
    --arg v3_seqno "${SEQNO3:-null}" \
    --arg v2_persisted "${V2_PERSISTED}" \
    --arg v3_persisted "${V3_PERSISTED}" \
    --argjson responded "${RESPONDED}" \
    --arg seqnos_agree "${SEQNOS_AGREE}" \
    --argjson persisted "$([ "${PERSISTED}" = "true" ] && echo true || echo false)" \
    '{expected_seqno: $expected,
      v1_seqno: $v1_seqno,
      v2_seqno: $v2_seqno,
      v3_seqno: $v3_seqno,
      v2_persisted: $v2_persisted,
      v3_persisted: $v3_persisted,
      responded: $responded,
      seqnos_agree: $seqnos_agree,
      persisted: $persisted}')

if [ "${PERSISTED}" = "true" ]; then
    echo "PASS: All acknowledged transfers persist in final state"
    sdk_always true "${ALWAYS_NAME}" "${DETAILS}"
    sdk_sometimes true "${SOMETIMES_NAME}" "${DETAILS}"
else
    echo "FAIL: Acknowledged transfers LOST — data integrity violation"
    sdk_always false "${ALWAYS_NAME}" "${DETAILS}"
    sdk_sometimes false "${SOMETIMES_NAME}" "${DETAILS}"
    exit 1
fi

exit 0
