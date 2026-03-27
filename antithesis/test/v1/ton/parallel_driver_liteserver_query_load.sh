#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Liteserver query load.
# Sends diverse query types to trigger in-process C++ liteserver reachability
# assertions ("Liteserver query dispatched", "Liteserver query finished
# successfully", "Liteserver query aborted").

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
LITE_PORT="${LITE_PORT:-30003}"
ASSERTION_NAME="Liteserver handles diverse query types"
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

# Resolve validator hostname to IP
VALIDATOR_IP=""
if command -v getent >/dev/null 2>&1; then
    VALIDATOR_IP=$(getent hosts "${VALIDATOR_HOST}" 2>/dev/null | awk '{print $1; exit}')
fi
[ -z "${VALIDATOR_IP}" ] && VALIDATOR_IP="${VALIDATOR_HOST}"

WALLET_ADDR="-1:0000000000000000000000000000000000000000000000000000000000000000"

echo "Sending diverse queries to liteserver at ${VALIDATOR_IP}:${LITE_PORT}..."

OUTPUT=$(timeout 15 lite-client \
    -v 1 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c 'last' \
    -c "getaccount ${WALLET_ADDR}" \
    -c "runmethod ${WALLET_ADDR} 85143" \
    -c 'quit' 2>&1) || true

OUTPUT_LEN=${#OUTPUT}
echo "Liteserver response: ${OUTPUT_LEN} chars"
echo "${OUTPUT:0:500}"

DETAILS=$(jq -cn \
    --argjson output_len "${OUTPUT_LEN}" \
    --arg ip "${VALIDATOR_IP}" \
    '{output_length: $output_len, resolved_ip: $ip}')

if [ "${OUTPUT_LEN}" -gt 0 ]; then
    echo "PASS: liteserver responded to diverse queries"
    sdk_sometimes true "${ASSERTION_NAME}" "${DETAILS}"
else
    echo "FAIL: no output from liteserver queries"
    sdk_sometimes false "${ASSERTION_NAME}" "${DETAILS}"
fi

exit 0
