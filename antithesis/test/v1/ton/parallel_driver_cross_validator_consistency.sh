#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Cross-validator consistency check.
# Queries all 3 validators' liteservers and compares masterchain seqnos.
# A "sometimes" assertion: we expect consistent state at least once.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
VALIDATOR2_HOST="${VALIDATOR2_HOST:-validator2}"
VALIDATOR3_HOST="${VALIDATOR3_HOST:-validator3}"
LITE_PORT="${LITE_PORT:-30003}"
ASSERTION_NAME="Multiple validators returned consistent state"
HEARTBEAT_MAX_AGE=60

sdk_catalog_sometimes "${ASSERTION_NAME}"

# Precondition: heartbeat must be fresh
if [ ! -f /shared/validator_heartbeat ]; then
    echo "Heartbeat file not present yet, skipping"
    exit 0
fi
HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
NOW=$(date +%s)
if [[ "${HB_TS}" =~ ^[0-9]+$ ]]; then
    HB_AGE=$(( NOW - HB_TS ))
    if [ "${HB_AGE}" -gt "${HEARTBEAT_MAX_AGE}" ]; then
        echo "Heartbeat stale (${HB_AGE}s), skipping"
        exit 0
    fi
else
    echo "Heartbeat value invalid, skipping"; exit 0
fi

if ! command -v lite-client >/dev/null 2>&1; then
    echo "lite-client binary not found, skipping"
    exit 0
fi

# Query masterchain seqno from a validator's liteserver
# Args: <host> <config_file>
query_seqno() {
    local host="$1" config="$2"
    local ip=""

    if ! [ -f "${config}" ]; then
        echo ""
        return
    fi

    if command -v getent >/dev/null 2>&1; then
        ip=$(getent hosts "${host}" 2>/dev/null | awk '{print $1; exit}')
    fi
    [ -z "${ip}" ] && ip="${host}"

    if ! nc -z -w 2 "${host}" "${LITE_PORT}" 2>/dev/null; then
        echo ""
        return
    fi

    local output
    output=$(timeout 10 lite-client \
        -v 1 \
        -a "${ip}:${LITE_PORT}" \
        -C "${config}" \
        -c 'last' \
        -c 'quit' 2>&1) || true

    echo "${output}" | grep -oE '\(-1,[0-9a-fA-F]+,[0-9]+\)' | grep -oE ',[0-9]+\)$' | tr -d ',)' | tail -1 || true
}

echo "Querying all 3 validators..."

SEQNO1=$(query_seqno "${VALIDATOR_HOST}"  "/shared/liteserver.config.json")
SEQNO2=$(query_seqno "${VALIDATOR2_HOST}" "/shared/liteserver2.config.json")
SEQNO3=$(query_seqno "${VALIDATOR3_HOST}" "/shared/liteserver3.config.json")

echo "Seqnos: v1=${SEQNO1:-n/a} v2=${SEQNO2:-n/a} v3=${SEQNO3:-n/a}"

# Count how many validators responded
RESPONDED=0
SEQNOS=()
for S in "${SEQNO1}" "${SEQNO2}" "${SEQNO3}"; do
    if [ -n "${S}" ] && [[ "${S}" =~ ^[0-9]+$ ]]; then
        RESPONDED=$((RESPONDED + 1))
        SEQNOS+=("${S}")
    fi
done

if [ "${RESPONDED}" -lt 2 ]; then
    echo "Fewer than 2 validators responded (${RESPONDED}), skipping"
    exit 0
fi

# Check if all responding validators' seqnos are within 5 of each other
MAX_DELTA=5
CONSISTENT=true
for i in "${!SEQNOS[@]}"; do
    for j in "${!SEQNOS[@]}"; do
        if [ "$i" -lt "$j" ]; then
            DIFF=$(( ${SEQNOS[$i]} - ${SEQNOS[$j]} ))
            # Absolute value
            [ "${DIFF}" -lt 0 ] && DIFF=$(( -DIFF ))
            if [ "${DIFF}" -gt "${MAX_DELTA}" ]; then
                CONSISTENT=false
            fi
        fi
    done
done

DETAILS=$(jq -cn \
    --arg v1 "${SEQNO1:-null}" \
    --arg v2 "${SEQNO2:-null}" \
    --arg v3 "${SEQNO3:-null}" \
    --argjson responded "${RESPONDED}" \
    --argjson consistent "$([ "${CONSISTENT}" = "true" ] && echo true || echo false)" \
    '{v1_seqno: $v1, v2_seqno: $v2, v3_seqno: $v3, responded: $responded, consistent: $consistent}')

if [ "${CONSISTENT}" = "true" ]; then
    echo "PASS: ${RESPONDED} validators are consistent (within ${MAX_DELTA} blocks)"
    sdk_sometimes true "${ASSERTION_NAME}" "${DETAILS}"
else
    echo "FAIL: validators diverged beyond ${MAX_DELTA} blocks"
    sdk_sometimes false "${ASSERTION_NAME}" "${DETAILS}"
fi

exit 0
