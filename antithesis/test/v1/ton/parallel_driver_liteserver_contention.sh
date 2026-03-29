#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Liteserver read contention.
# Launches 5 concurrent lite-client processes ALL targeting the SAME block
# and account to create real read-contention on the liteserver.
# Two clients do getaccount, one does runmethod (TVM execution), and two
# do listblocktrans — all on the same masterchain block.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
LITE_PORT="${LITE_PORT:-30003}"
SOMETIMES_ASSERTION="Liteserver handles concurrent queries on same data"
ALWAYS_ASSERTION="Liteserver state is consistent under read contention"
WALLET_ADDR="-1:0000000000000000000000000000000000000000000000000000000000000000"
HEARTBEAT_MAX_AGE=60
HEARTBEAT_WAIT_MAX=20
HEARTBEAT_WAIT_POLL=2
CONCURRENT=5

sdk_catalog_sometimes "${SOMETIMES_ASSERTION}"
sdk_catalog_always "${ALWAYS_ASSERTION}"

# --- Preconditions (same pattern as existing scripts) ---

# Heartbeat must be fresh (with brief retry)
_hb_ok=false
_hb_waited=0
while [ "$_hb_waited" -lt "$HEARTBEAT_WAIT_MAX" ]; do
    if [ -f /shared/validator_heartbeat ]; then
        HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
        HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
        NOW=$(date +%s)
        if [[ "${HB_TS}" =~ ^[0-9]+$ ]]; then
            HB_AGE=$(( NOW - HB_TS ))
            if [ "${HB_AGE}" -le "${HEARTBEAT_MAX_AGE}" ]; then
                _hb_ok=true
                break
            else
                echo "Heartbeat stale (${HB_AGE}s), skipping"
                exit 0
            fi
        fi
    fi
    sleep "$HEARTBEAT_WAIT_POLL"
    _hb_waited=$((_hb_waited + HEARTBEAT_WAIT_POLL))
done

if [ "$_hb_ok" != "true" ]; then
    echo "Heartbeat file not present after ${HEARTBEAT_WAIT_MAX}s, skipping"
    exit 0
fi

# Liteserver port must be reachable
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    echo "Liteserver port ${LITE_PORT} not reachable, skipping"
    exit 0
fi

# Liteserver config must exist
if [ ! -f /shared/liteserver.config.json ]; then
    echo "Liteserver config not available yet, skipping"
    exit 0
fi

# lite-client binary must exist
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

# --- Get current masterchain block ---
echo "Querying current masterchain block..."

LAST_OUTPUT=$(timeout 15 lite-client \
    -v 0 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c 'last' \
    -c 'quit' 2>&1) || true

# Parse full block ID: (-1,8000000000000000,N):ROOTHASH:FILEHASH
BLOCK_ID=$(echo "${LAST_OUTPUT}" | grep -oE '\(-1,[0-9a-fA-F]+,[0-9]+\):[0-9A-Fa-f]+:[0-9A-Fa-f]+' | head -1) || true

if [ -z "${BLOCK_ID}" ]; then
    echo "Could not parse masterchain block ID, skipping"
    exit 0
fi

echo "Target block: ${BLOCK_ID}"
echo "Target account: ${WALLET_ADDR}"
echo "Launching ${CONCURRENT} concurrent lite-client queries on same data..."

# --- Launch 5 concurrent lite-client processes ---
PIDS=()
TMPDIR_CONTENTION=$(mktemp -d)

# Client 1: getaccount on wallet at current block
timeout 20 lite-client \
    -v 0 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c 'last' \
    -c "getaccount ${WALLET_ADDR}" \
    -c 'quit' >"${TMPDIR_CONTENTION}/client1.out" 2>&1 &
PIDS+=($!)

# Client 2: getaccount on same wallet (duplicate read contention)
timeout 20 lite-client \
    -v 0 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c 'last' \
    -c "getaccount ${WALLET_ADDR}" \
    -c 'quit' >"${TMPDIR_CONTENTION}/client2.out" 2>&1 &
PIDS+=($!)

# Client 3: runmethod seqno (TVM execution under contention)
timeout 20 lite-client \
    -v 0 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c 'last' \
    -c "runmethod ${WALLET_ADDR} 85143" \
    -c 'quit' >"${TMPDIR_CONTENTION}/client3.out" 2>&1 &
PIDS+=($!)

# Client 4: listblocktrans on current masterchain block
timeout 20 lite-client \
    -v 0 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c 'last' \
    -c "listblocktrans ${BLOCK_ID} 20" \
    -c 'quit' >"${TMPDIR_CONTENTION}/client4.out" 2>&1 &
PIDS+=($!)

# Client 5: listblocktrans on same block (duplicate contention)
timeout 20 lite-client \
    -v 0 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c 'last' \
    -c "listblocktrans ${BLOCK_ID} 20" \
    -c 'quit' >"${TMPDIR_CONTENTION}/client5.out" 2>&1 &
PIDS+=($!)

# --- Wait for all and collect results ---
SUCCESSES=0
FAILURES=0
for pid in "${PIDS[@]}"; do
    if wait "$pid" 2>/dev/null; then
        SUCCESSES=$((SUCCESSES + 1))
    else
        FAILURES=$((FAILURES + 1))
    fi
done

echo "Concurrent contention queries complete: ${SUCCESSES}/${CONCURRENT} succeeded, ${FAILURES} failed"

# --- Sometimes assertion: at least 3/5 succeeded ---
DETAILS_CONCURRENT=$(jq -cn \
    --argjson successes "$SUCCESSES" \
    --argjson failures "$FAILURES" \
    --argjson concurrent "$CONCURRENT" \
    --arg block_id "${BLOCK_ID}" \
    --arg wallet "${WALLET_ADDR}" \
    '{successes: $successes, failures: $failures, concurrent: $concurrent, block_id: $block_id, wallet: $wallet}')

if [ "$SUCCESSES" -ge 3 ]; then
    echo "PASS: At least 3/${CONCURRENT} concurrent queries succeeded"
    sdk_sometimes true "${SOMETIMES_ASSERTION}" "${DETAILS_CONCURRENT}"
else
    echo "FAIL: Only ${SUCCESSES}/${CONCURRENT} concurrent queries succeeded"
    sdk_sometimes false "${SOMETIMES_ASSERTION}" "${DETAILS_CONCURRENT}"
fi

# --- Always assertion: post-contention read returns valid data ---
# Do one final getaccount and verify balance/seqno are parseable
echo "Running post-contention consistency check..."
FINAL_OUTPUT=$(timeout 15 lite-client \
    -v 0 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c 'last' \
    -c "getaccount ${WALLET_ADDR}" \
    -c 'quit' 2>&1) || true

BALANCE_OK=false
SEQNO_OK=false

# Check balance is parseable
if echo "${FINAL_OUTPUT}" | grep -qP 'account balance is \d+'; then
    BALANCE_OK=true
    echo "Post-contention balance: parseable"
fi

# Check last transaction lt is parseable (proves account state not corrupted)
if echo "${FINAL_OUTPUT}" | grep -qP 'last transaction lt = \d+'; then
    SEQNO_OK=true
    echo "Post-contention transaction lt: parseable"
fi

CONSISTENT=false
if [ "${BALANCE_OK}" = "true" ] && [ "${SEQNO_OK}" = "true" ]; then
    CONSISTENT=true
fi

DETAILS_CONSISTENT=$(jq -cn \
    --argjson balance_ok "${BALANCE_OK}" \
    --argjson lt_ok "${SEQNO_OK}" \
    --argjson consistent "${CONSISTENT}" \
    --argjson successes "$SUCCESSES" \
    --arg block_id "${BLOCK_ID}" \
    '{balance_parseable: $balance_ok, transaction_lt_parseable: $lt_ok, consistent: $consistent, prior_successes: $successes, block_id: $block_id}')

if [ "${CONSISTENT}" = "true" ]; then
    echo "PASS: Liteserver state consistent after read contention"
    sdk_always true "${ALWAYS_ASSERTION}" "${DETAILS_CONSISTENT}"
else
    echo "FAIL: Liteserver state inconsistent after read contention"
    sdk_always false "${ALWAYS_ASSERTION}" "${DETAILS_CONSISTENT}"
fi

# Cleanup
rm -rf "${TMPDIR_CONTENTION}"

exit 0
