#!/usr/bin/env bash
set -euo pipefail

# Serial driver: Send pre-generated TON transfer transactions.
# Serial phase prevents seqno races. Sends self-transfer BOCs that were
# pre-generated during zerostate creation in entrypoint-validator.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
LITE_PORT="${LITE_PORT:-30003}"
ASSERTION_NAME="A TON transfer completed successfully"
BALANCE_ALWAYS_NAME="Wallet balance is consistent between transfer invocations"
BALANCE_SOMETIMES_NAME="Transfer read-back balance verified"
REPLAY_ALWAYS_NAME="Duplicate transfer BOC is correctly rejected"
REPLAY_SOMETIMES_NAME="Transfer replay rejection verified"
HEARTBEAT_MAX_AGE=60
BALANCE_FILE="/shared/tx/last_confirmed_balance"

sdk_catalog_sometimes "${ASSERTION_NAME}"
sdk_catalog_always "${BALANCE_ALWAYS_NAME}"
sdk_catalog_sometimes "${BALANCE_SOMETIMES_NAME}"
sdk_catalog_always "${REPLAY_ALWAYS_NAME}"
sdk_catalog_sometimes "${REPLAY_SOMETIMES_NAME}"
sdk_catalog_always "Transfer fee is deducted after confirmed transaction"

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

# Query wallet balance via getaccount
get_wallet_balance() {
    local output
    output=$(timeout 10 lite-client \
        -v 1 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C /shared/liteserver.config.json \
        -c "getaccount ${WALLET_ADDR}" \
        -c 'quit' 2>&1) || true
    # Extract balance in nanograms — format varies but typically "balance: <amount>"
    echo "${output}" | grep -oP 'balance[^0-9]*\K[0-9]+' | head -1 || true
}

echo "Querying wallet seqno..."
SEQNO=$(get_wallet_seqno)

if [ -z "${SEQNO}" ] || ! [[ "${SEQNO}" =~ ^[0-9]+$ ]]; then
    echo "Could not parse wallet seqno (got: '${SEQNO}'), skipping"
    exit 0
fi
echo "Current wallet seqno: ${SEQNO}"

# Balance verification: compare current balance against previous invocation's recorded balance
CURRENT_BALANCE=$(get_wallet_balance)
if [ -n "${CURRENT_BALANCE}" ] && [[ "${CURRENT_BALANCE}" =~ ^[0-9]+$ ]]; then
    echo "Current wallet balance: ${CURRENT_BALANCE}"
    if [ -f "${BALANCE_FILE}" ]; then
        PREV_BALANCE=$(cat "${BALANCE_FILE}" 2>/dev/null | tr -d '[:space:]')
        if [ -n "${PREV_BALANCE}" ] && [[ "${PREV_BALANCE}" =~ ^[0-9]+$ ]]; then
            echo "Previous recorded balance: ${PREV_BALANCE}"
            BAL_DETAILS=$(jq -cn \
                --arg prev "${PREV_BALANCE}" \
                --arg curr "${CURRENT_BALANCE}" \
                '{previous_balance: $prev, current_balance: $curr}')
            BAL_DIFF=$((CURRENT_BALANCE - PREV_BALANCE))
            if [ "$BAL_DIFF" -gt 10000000000 ]; then  # > 10 Grams in nanograms
                echo "FAIL: balance increased by >10G unexpectedly (${PREV_BALANCE} -> ${CURRENT_BALANCE})"
                sdk_always false "${BALANCE_ALWAYS_NAME}" "${BAL_DETAILS}"
            else
                echo "PASS: balance within expected bounds (${PREV_BALANCE} -> ${CURRENT_BALANCE})"
                sdk_always true "${BALANCE_ALWAYS_NAME}" "${BAL_DETAILS}"
                sdk_sometimes true "${BALANCE_SOMETIMES_NAME}" "${BAL_DETAILS}"
            fi
        fi
    else
        echo "No previous balance recorded (first invocation), skipping balance check"
    fi
else
    echo "Could not query wallet balance, skipping balance check"
fi

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

# Poll for seqno advancement (up to 45s, every 3s)
MAX_WAIT=45
WAITED=0
NEW_SEQNO=""
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    sleep 3
    WAITED=$((WAITED + 3))
    NEW_SEQNO=$(get_wallet_seqno)
    if [ -n "${NEW_SEQNO}" ] && [[ "${NEW_SEQNO}" =~ ^[0-9]+$ ]] && [ "${NEW_SEQNO}" -gt "${SEQNO}" ]; then
        echo "Transfer confirmed after ${WAITED}s (seqno ${SEQNO} -> ${NEW_SEQNO})"
        break
    fi
done

if [ -z "${NEW_SEQNO}" ] || ! [[ "${NEW_SEQNO}" =~ ^[0-9]+$ ]]; then
    echo "Could not parse seqno after ${WAITED}s polling (got: '${NEW_SEQNO}'), skipping"
    exit 0
fi
echo "New wallet seqno: ${NEW_SEQNO} (after ${WAITED}s)"

DETAILS=$(jq -cn \
    --argjson before "${SEQNO}" \
    --argjson after "${NEW_SEQNO}" \
    --argjson wait "${WAITED}" \
    '{seqno_before: $before, seqno_after: $after, poll_seconds: $wait}')

if [ "${NEW_SEQNO}" -gt "${SEQNO}" ]; then
    echo "PASS: transfer completed (seqno ${SEQNO} -> ${NEW_SEQNO})"
    echo "${NEW_SEQNO}" > /shared/tx/last_confirmed_seqno
    sdk_sometimes true "${ASSERTION_NAME}" "${DETAILS}"
    # Record post-transfer balance for next invocation's read-back verification
    POST_BALANCE=$(get_wallet_balance)
    if [ -n "${POST_BALANCE}" ] && [[ "${POST_BALANCE}" =~ ^[0-9]+$ ]]; then
        echo "${POST_BALANCE}" > "${BALANCE_FILE}"
        echo "Recorded post-transfer balance: ${POST_BALANCE}"
    fi

    # Within-invocation fee deduction check: balance must decrease after a confirmed tx (gas fees apply even for self-transfers)
    if [ -n "${CURRENT_BALANCE}" ] && [[ "${CURRENT_BALANCE}" =~ ^[0-9]+$ ]] && \
       [ -n "${POST_BALANCE}" ] && [[ "${POST_BALANCE}" =~ ^[0-9]+$ ]]; then
        FEE_DETAILS=$(jq -cn \
            --arg pre "${CURRENT_BALANCE}" \
            --arg post "${POST_BALANCE}" \
            '{pre_transfer_balance: $pre, post_transfer_balance: $post}')
        if [ "${POST_BALANCE}" -lt "${CURRENT_BALANCE}" ]; then
            echo "PASS: fee deducted after confirmed tx (${CURRENT_BALANCE} -> ${POST_BALANCE})"
            sdk_always true "Transfer fee is deducted after confirmed transaction" "${FEE_DETAILS}"
        else
            echo "FAIL: balance did not decrease despite confirmed seqno advance (${CURRENT_BALANCE} -> ${POST_BALANCE})"
            sdk_always false "Transfer fee is deducted after confirmed transaction" "${FEE_DETAILS}"
        fi
    else
        echo "Skipping fee deduction check: pre or post balance not available"
    fi

    # Replay protection test: re-send the SAME BOC (seqno=N, but contract now expects N+1)
    echo "Replay test: re-sending consumed BOC for seqno ${SEQNO}..."
    REPLAY_OUTPUT=$(timeout 10 lite-client \
        -v 1 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C /shared/liteserver.config.json \
        -c "sendfile ${BOC_FILE}" \
        -c 'quit' 2>&1) || true
    echo "Replay send output: ${REPLAY_OUTPUT:0:300}"

    sleep 3

    echo "Replay test: re-querying wallet seqno..."
    REPLAY_SEQNO=$(get_wallet_seqno)
    if [ -n "${REPLAY_SEQNO}" ] && [[ "${REPLAY_SEQNO}" =~ ^[0-9]+$ ]]; then
        REPLAY_DETAILS=$(jq -cn \
            --argjson original "${SEQNO}" \
            --argjson after_transfer "${NEW_SEQNO}" \
            --argjson after_replay "${REPLAY_SEQNO}" \
            '{original_seqno: $original, after_transfer: $after_transfer, after_replay: $after_replay}')
        if [ "${REPLAY_SEQNO}" -eq "${NEW_SEQNO}" ]; then
            echo "PASS: replay correctly rejected (seqno still ${NEW_SEQNO})"
            sdk_always true "${REPLAY_ALWAYS_NAME}" "${REPLAY_DETAILS}"
            sdk_sometimes true "${REPLAY_SOMETIMES_NAME}" "${REPLAY_DETAILS}"
        else
            echo "FAIL: replay protection failed! seqno advanced to ${REPLAY_SEQNO}"
            sdk_always false "${REPLAY_ALWAYS_NAME}" "${REPLAY_DETAILS}"
        fi
    else
        echo "Could not query seqno after replay test, skipping replay assertion"
    fi
else
    echo "Transfer not yet confirmed (seqno still ${SEQNO})"
    sdk_sometimes false "${ASSERTION_NAME}" "${DETAILS}"
fi

exit 0
