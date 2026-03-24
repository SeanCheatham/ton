#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Lite-client can query validator and get a response
# First functional correctness assertion — verifies the validator actually speaks
# the TON protocol, not just that TCP:30003 accepts connections.
# Uses lite-client binary to connect to the liteserver and execute a basic query.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
LITE_PORT="${LITE_PORT:-30003}"
ASSERTION_NAME="Lite-client can query validator and get a response"
HEARTBEAT_MAX_AGE=60

# Precondition: heartbeat must be fresh
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s), skipping"
            sleep 10
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"
        sleep 10
        exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"
    sleep 10
    exit 0
fi

# Precondition: TCP:30003 (liteserver) must be reachable
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    echo "Liteserver port ${LITE_PORT} not reachable, skipping"
    sdk_sometimes false "$ASSERTION_NAME" '{"status":"port_not_reachable"}'
    sleep 10
    exit 0
fi

# Precondition: liteserver config must exist
if [ ! -f /shared/liteserver.config.json ]; then
    echo "Liteserver config not available yet, skipping"
    sleep 10
    exit 0
fi

echo "Querying validator via lite-client..."

# Run lite-client with a basic 'last' command to get the latest block info
# Use -a to specify the address directly (Docker hostname resolution)
OUTPUT=$(timeout 10 lite-client \
    -a "${VALIDATOR_HOST}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c 'last' \
    -c 'quit' 2>&1) || true

echo "Lite-client output: ${OUTPUT:0:500}"

# Check for evidence of a successful response
# lite-client prints "latest masterchain block" or block IDs like (-1,xxx,yyy)
if echo "$OUTPUT" | grep -qiE 'latest masterchain block|server version|masterchain.*block|last block|block = \('; then
    BLOCK_INFO=$(echo "$OUTPUT" | grep -iE 'latest masterchain block|last block|block = \(' | head -1 | tr -d '\n' | head -c 200)
    DETAILS=$(jq -cn --arg info "$BLOCK_INFO" --arg status "success" '{status: $status, block_info: $info}')
    echo "PASS: lite-client query succeeded"
    sdk_sometimes true "$ASSERTION_NAME" "$DETAILS"
else
    # Query did not return expected output
    OUTPUT_SAMPLE=$(echo "$OUTPUT" | head -5 | tr '\n' ' ' | head -c 300)
    DETAILS=$(jq -cn --arg output "$OUTPUT_SAMPLE" --arg status "no_block_response" '{status: $status, output_sample: $output}')
    echo "FAIL: lite-client did not return expected block info"
    sdk_sometimes false "$ASSERTION_NAME" "$DETAILS"
fi

sleep 10
exit 0
