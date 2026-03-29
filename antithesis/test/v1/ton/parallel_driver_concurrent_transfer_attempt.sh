#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Race with serial_driver to send the SAME pre-generated
# transfer BOC, creating real contention on the wallet's seqno.  The wallet
# contract's replay-protection (seqno check) should accept exactly one
# submission.  Under Antithesis fault injection the two submissions may arrive
# at different validators in different orders.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
LITE_PORT="${LITE_PORT:-30003}"
ALWAYS_NAME="Wallet seqno advances by at most 1 per block under contention"
SOMETIMES_NAME="Concurrent transfer contention observed"
HEARTBEAT_MAX_AGE=60

WALLET_ADDR="-1:0000000000000000000000000000000000000000000000000000000000000000"

# ---- Precondition: heartbeat must be fresh (file-based, not network) ----
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

# ---- Precondition: liteserver config & lite-client available ----
if [ ! -f /shared/liteserver.config.json ]; then
    echo "Liteserver config not available yet, skipping"
    exit 0
fi
if ! command -v lite-client >/dev/null 2>&1; then
    echo "lite-client binary not found, skipping"
    exit 0
fi

# ---- Precondition: transaction BOCs must exist ----
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

# ---- Precondition: liteserver reachable ----
if ! nc -z -w 2 "${VALIDATOR_IP}" "${LITE_PORT}" 2>/dev/null; then
    echo "Liteserver port ${LITE_PORT} not reachable, skipping"
    exit 0
fi

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

if [ "${SEQNO}" -lt 1 ]; then
    echo "Wallet not yet initialized (seqno < 1), skipping"
    exit 0
fi

# Check if the BOC file for the current seqno exists — this is the same one
# serial_driver_send_transfer.sh would try to send next.
BOC_FILE="/shared/tx/transfer_seqno_${SEQNO}.boc"
if [ ! -f "${BOC_FILE}" ]; then
    echo "BOC file for seqno ${SEQNO} not found (serial_driver already consumed it), skipping"
    exit 0
fi

# Race: send the same BOC that serial_driver will try to send
echo "Contention attempt: sending BOC for seqno ${SEQNO}..."
SEND_OUTPUT=$(timeout 10 lite-client \
    -v 1 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c "sendfile ${BOC_FILE}" \
    -c 'quit' 2>&1) || true
echo "Send output: ${SEND_OUTPUT:0:300}"

# We successfully submitted a BOC — contention was attempted
CONTENTION_DETAILS=$(jq -cn --argjson seqno "${SEQNO}" '{seqno: $seqno}')
sdk_sometimes true "${SOMETIMES_NAME}" "${CONTENTION_DETAILS}"

# Poll for seqno advancement (up to 15s, every 3s)
MAX_WAIT=15
WAITED=0
NEW_SEQNO=""
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    sleep 3
    WAITED=$((WAITED + 3))
    NEW_SEQNO=$(get_wallet_seqno)
    if [ -n "${NEW_SEQNO}" ] && [[ "${NEW_SEQNO}" =~ ^[0-9]+$ ]] && [ "${NEW_SEQNO}" -gt "${SEQNO}" ]; then
        echo "Seqno advanced after ${WAITED}s (seqno ${SEQNO} -> ${NEW_SEQNO})"
        break
    fi
done

if [ -z "${NEW_SEQNO}" ] || ! [[ "${NEW_SEQNO}" =~ ^[0-9]+$ ]]; then
    echo "Could not parse new seqno after ${WAITED}s polling (got: '${NEW_SEQNO}'), skipping assertion"
    exit 0
fi
echo "New wallet seqno: ${NEW_SEQNO} (after ${WAITED}s)"

DELTA=$(( NEW_SEQNO - SEQNO ))
DETAILS=$(jq -cn \
    --argjson before "${SEQNO}" \
    --argjson after "${NEW_SEQNO}" \
    --argjson delta "${DELTA}" \
    '{seqno_before: $before, seqno_after: $after, delta: $delta}')

if [ "${DELTA}" -le 1 ]; then
    echo "PASS: seqno advanced by ${DELTA} (at most 1) under contention"
    sdk_always true "${ALWAYS_NAME}" "${DETAILS}"
else
    echo "FAIL: seqno jumped by ${DELTA} — possible double-spend or seqno skip!"
    sdk_always false "${ALWAYS_NAME}" "${DETAILS}"
fi

exit 0
