#!/usr/bin/env bash
set -euo pipefail

# Serial driver: Send pre-generated TON transfer transactions.
# Serial phase prevents seqno races. Sends self-transfer BOCs that were
# pre-generated during zerostate creation in entrypoint-validator.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
LITE_PORT="${LITE_PORT:-30003}"
ASSERTION_NAME="A TON transfer completed successfully"
HEARTBEAT_MAX_AGE=60

sdk_catalog_sometimes "${ASSERTION_NAME}"

# Precondition: heartbeat must be fresh
if [ ! -f /shared/validator_heartbeat ]; then
    echo "Heartbeat file not present yet, skipping"
    exit 0
fi
HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
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

# Precondition: liteserver reachable, config exists, lite-client available
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

# Precondition: transaction BOCs must exist
if [ ! -f /shared/tx/count ]; then
    echo "Transaction BOCs not generated yet, skipping"
    exit 0
fi

# Resolve validator hostname to IP
VALIDATOR_IP=""
if command -v getent >/dev/null 2>&1; then
    VALIDATOR_IP=$(getent hosts "${VALIDATOR_HOST}" 2>/dev/null | awk '{print $1; exit}')
fi
[ -z "${VALIDATOR_IP}" ] && VALIDATOR_IP="${VALIDATOR_HOST}"

WALLET_ADDR="-1:0000000000000000000000000000000000000000000000000000000000000000"

# Query wallet seqno via runmethod 85143 (the "seqno" get-method)
get_wallet_seqno() {
    local output
    output=$(timeout 10 lite-client \
        -v 1 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C /shared/liteserver.config.json \
        -c "runmethod ${WALLET_ADDR} 85143" \
        -c 'quit' 2>&1) || true
    echo "${output}" | grep -oP 'result:\s*\[\s*\K[0-9]+' | head -1 || true
}

echo "Querying wallet seqno..."
SEQNO=$(get_wallet_seqno)

if [ -z "${SEQNO}" ] || ! [[ "${SEQNO}" =~ ^[0-9]+$ ]]; then
    echo "Could not parse wallet seqno (got: '${SEQNO}'), skipping"
    exit 0
fi
echo "Current wallet seqno: ${SEQNO}"

BOC_FILE="/shared/tx/transfer_seqno_${SEQNO}.boc"
if [ ! -f "${BOC_FILE}" ]; then
    echo "BOC file for seqno ${SEQNO} not found (exhausted?), skipping"
    exit 0
fi

echo "Sending transaction with seqno ${SEQNO}..."
SEND_OUTPUT=$(timeout 10 lite-client \
    -v 1 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c "sendfile ${BOC_FILE}" \
    -c 'quit' 2>&1) || true
echo "Send output: ${SEND_OUTPUT:0:300}"

# Wait for the transaction to be included in a block
sleep 5

echo "Re-querying wallet seqno..."
NEW_SEQNO=$(get_wallet_seqno)

if [ -z "${NEW_SEQNO}" ] || ! [[ "${NEW_SEQNO}" =~ ^[0-9]+$ ]]; then
    echo "Could not parse new seqno (got: '${NEW_SEQNO}'), skipping"
    exit 0
fi
echo "New wallet seqno: ${NEW_SEQNO}"

DETAILS=$(jq -cn \
    --argjson before "${SEQNO}" \
    --argjson after "${NEW_SEQNO}" \
    '{seqno_before: $before, seqno_after: $after}')

if [ "${NEW_SEQNO}" -gt "${SEQNO}" ]; then
    echo "PASS: transfer completed (seqno ${SEQNO} -> ${NEW_SEQNO})"
    sdk_sometimes true "${ASSERTION_NAME}" "${DETAILS}"
else
    echo "Transfer not yet confirmed (seqno still ${SEQNO})"
    sdk_sometimes false "${ASSERTION_NAME}" "${DETAILS}"
fi

exit 0
