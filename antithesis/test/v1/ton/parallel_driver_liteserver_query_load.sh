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
GETBLOCK_ASSERTION="Liteserver getblock query returned valid data"
LASTTRANS_ASSERTION="Liteserver transaction history query returned valid data"
VALSTATS_ASSERTION="Liteserver validatorstats query returned valid data"
MASTERCHAIN_INFO_ASSERTION="Liteserver masterchain info query succeeded during load"
MSGQUEUE_ASSERTION="Liteserver outbound queue query returned valid data"
HEARTBEAT_MAX_AGE=60
HEARTBEAT_WAIT_MAX=20   # seconds to wait for heartbeat to appear
HEARTBEAT_WAIT_POLL=2   # seconds between retries

sdk_catalog_sometimes "${ASSERTION_NAME}"
sdk_catalog_sometimes "${GETBLOCK_ASSERTION}"
sdk_catalog_sometimes "${LASTTRANS_ASSERTION}"
sdk_catalog_sometimes "${VALSTATS_ASSERTION}"
sdk_catalog_sometimes "${MASTERCHAIN_INFO_ASSERTION}"
sdk_catalog_sometimes "${MSGQUEUE_ASSERTION}"

# Precondition: heartbeat must be fresh.
# Retry briefly instead of immediately skipping — the validator's heartbeat
# loop may not have written its first entry yet after setup_complete.
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

# --- Second batch: getblock / getblockheader using block ID from `last` ---
BLOCK_ID=""
GETBLOCK_OK=false
GETHEADER_OK=false
GETSTATE_OK=false
GETCONFIG_OK=false

# Parse full block ID from `last` output: (-1,8000000000000000,N):ROOTHASH:FILEHASH
BLOCK_ID=$(echo "${OUTPUT}" | grep -oE '\(-1,[0-9a-fA-F]+,[0-9]+\):[0-9A-Fa-f]+:[0-9A-Fa-f]+' | head -1) || true

if [ -n "${BLOCK_ID}" ]; then
    echo "Parsed block ID: ${BLOCK_ID}"

    # Extract seqno for conditional getstate
    SEQNO=$(echo "${BLOCK_ID}" | grep -oP '\(-1,[0-9a-fA-F]+,\K[0-9]+') || true

    OUTPUT2=$(timeout 15 lite-client \
        -v 1 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C /shared/liteserver.config.json \
        -c "getblock ${BLOCK_ID}" \
        -c "getblockheader ${BLOCK_ID}" \
        -c 'quit' 2>&1) || true

    echo "Block queries response: ${#OUTPUT2} chars"
    echo "${OUTPUT2:0:500}"

    # Check getblock success
    if echo "${OUTPUT2}" | grep -qiE 'block header of|got block|global_id='; then
        GETBLOCK_OK=true
        echo "getblock returned valid data"
    fi

    # Check getblockheader success
    if echo "${OUTPUT2}" | grep -qi 'block header'; then
        GETHEADER_OK=true
        echo "getblockheader returned valid data"
    fi

    # Conditional getstate for low seqnos (heavy operation)
    if [ -n "${SEQNO}" ] && [ "${SEQNO}" -le 50 ] 2>/dev/null; then
        echo "Seqno ${SEQNO} is low, attempting getstate..."
        OUTPUT3=$(timeout 20 lite-client \
            -v 1 \
            -a "${VALIDATOR_IP}:${LITE_PORT}" \
            -C /shared/liteserver.config.json \
            -c "getstate ${BLOCK_ID}" \
            -c 'quit' 2>&1) || true
        if echo "${OUTPUT3}" | grep -qi 'state'; then
            GETSTATE_OK=true
            echo "getstate returned data"
        fi
    fi

    # --- Third batch: config queries ---
    # Exercises LiteQuery::perform_getConfigParams (liteserver.cpp)
    # Params: 0=config contract addr, 1=elector addr, 15=election params, 30=consensus params
    GETCONFIG_OK=false
    OUTPUT4=$(timeout 15 lite-client \
        -v 1 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C /shared/liteserver.config.json \
        -c "getconfig 0" \
        -c "getconfig 1" \
        -c "getconfig 15" \
        -c "getconfig 30" \
        -c 'quit' 2>&1) || true

    echo "Config queries response: ${#OUTPUT4} chars"
    echo "${OUTPUT4:0:500}"

    if echo "${OUTPUT4}" | grep -qi 'ConfigParam'; then
        GETCONFIG_OK=true
        echo "getconfig returned valid config params"
    fi
else
    echo "Could not parse block ID from last output, skipping getblock/getblockheader"
fi

# --- Fourth batch: transaction history + shard info ---
LASTTRANS_OK=false
ALLSHARDS_OK=false

# 1. Parse last_trans_lt and hash from getaccount output (already in OUTPUT variable)
#    Format: "last transaction lt = <lt> hash = <hash>"
TRANS_LT=$(echo "${OUTPUT}" | grep -oP 'last transaction lt = \K[0-9]+' | head -1) || true
TRANS_HASH=$(echo "${OUTPUT}" | grep -oP 'hash = \K[0-9a-fA-F]{64}' | head -1) || true

if [ -n "${TRANS_LT}" ] && [ -n "${TRANS_HASH}" ] && [ "${TRANS_LT}" != "0" ]; then
    OUTPUT5=$(timeout 15 lite-client \
        -v 1 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C /shared/liteserver.config.json \
        -c "lasttrans ${WALLET_ADDR} ${TRANS_LT} ${TRANS_HASH} 5" \
        -c 'quit' 2>&1) || true

    echo "lasttrans response: ${#OUTPUT5} chars"
    echo "${OUTPUT5:0:500}"

    if echo "${OUTPUT5}" | grep -qi 'transaction #'; then
        LASTTRANS_OK=true
        echo "lasttrans returned transaction history"
    fi
else
    echo "Skipping lasttrans: LT=${TRANS_LT:-empty}, no transactions yet"
fi

# 2. Query shard configuration using block ID from earlier
if [ -n "${BLOCK_ID}" ]; then
    OUTPUT6=$(timeout 15 lite-client \
        -v 1 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C /shared/liteserver.config.json \
        -c "allshards ${BLOCK_ID}" \
        -c 'quit' 2>&1) || true

    echo "allshards response: ${#OUTPUT6} chars"
    echo "${OUTPUT6:0:500}"

    if echo "${OUTPUT6}" | grep -qi 'shard'; then
        ALLSHARDS_OK=true
        echo "allshards returned shard configuration"
    fi
fi

# --- Validator stats query ---
VALSTATS_OK=false
if [ -n "${BLOCK_ID}" ]; then
    OUTPUT_VS=$(timeout 15 lite-client \
        -v 1 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C /shared/liteserver.config.json \
        -c 'validatorstats' \
        -c 'quit' 2>&1) || true

    echo "validatorstats response: ${#OUTPUT_VS} chars"
    echo "${OUTPUT_VS:0:500}"

    if echo "${OUTPUT_VS}" | grep -qi 'validator\|signed\|stat'; then
        VALSTATS_OK=true
        echo "validatorstats returned validator participation data"
    fi
fi

# --- getMasterchainInfo (as counted load query) ---
MCINFO_OK=false
OUTPUT_MC=$(timeout 15 lite-client \
    -v 1 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c 'last' \
    -c 'quit' 2>&1) || true

echo "getMasterchainInfo response: ${#OUTPUT_MC} chars"
echo "${OUTPUT_MC:0:500}"

if echo "${OUTPUT_MC}" | grep -qi 'latest masterchain block'; then
    MCINFO_OK=true
    echo "getMasterchainInfo returned valid data"
fi

# --- Message queue sizes (exercises getBlockOutMsgQueueSize) ---
MSGQUEUE_OK=false
if [ -n "${BLOCK_ID}" ]; then
    OUTPUT_MQ=$(timeout 15 lite-client \
        -v 1 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C /shared/liteserver.config.json \
        -c 'last' \
        -c 'msgqueuesizes' \
        -c 'quit' 2>&1) || true

    echo "msgqueuesizes response: ${#OUTPUT_MQ} chars"
    echo "${OUTPUT_MQ:0:500}"

    if echo "${OUTPUT_MQ}" | grep -qi 'Outbound message queue sizes'; then
        MSGQUEUE_OK=true
        echo "msgqueuesizes returned valid data"
    fi
fi

# --- Emit assertions ---
DETAILS=$(jq -cn \
    --argjson output_len "${OUTPUT_LEN}" \
    --arg ip "${VALIDATOR_IP}" \
    --argjson getblock "${GETBLOCK_OK}" \
    --argjson getheader "${GETHEADER_OK}" \
    --argjson getstate "${GETSTATE_OK}" \
    --argjson getconfig "${GETCONFIG_OK}" \
    --argjson lasttrans "${LASTTRANS_OK}" \
    --argjson allshards "${ALLSHARDS_OK}" \
    --argjson validatorstats "${VALSTATS_OK}" \
    --argjson mcinfo "${MCINFO_OK}" \
    --argjson msgqueue "${MSGQUEUE_OK}" \
    --arg block_id "${BLOCK_ID}" \
    '{output_length: $output_len, resolved_ip: $ip, getblock: $getblock, getblockheader: $getheader, getstate: $getstate, getconfig: $getconfig, lasttrans: $lasttrans, allshards: $allshards, validatorstats: $validatorstats, mcinfo: $mcinfo, msgqueue: $msgqueue, block_id: $block_id}')

if [ "${OUTPUT_LEN}" -gt 0 ]; then
    echo "PASS: liteserver responded to diverse queries"
    sdk_sometimes true "${ASSERTION_NAME}" "${DETAILS}"
else
    echo "FAIL: no output from liteserver queries"
    sdk_sometimes false "${ASSERTION_NAME}" "${DETAILS}"
fi

if [ -n "${BLOCK_ID}" ]; then
    if [ "${GETBLOCK_OK}" = "true" ]; then
        sdk_sometimes true "${GETBLOCK_ASSERTION}" "${DETAILS}"
    else
        sdk_sometimes false "${GETBLOCK_ASSERTION}" "${DETAILS}"
    fi
fi

# Emit lasttrans assertion only when account had transactions (LT != 0)
if [ -n "${TRANS_LT}" ] && [ "${TRANS_LT}" != "0" ]; then
    if [ "${LASTTRANS_OK}" = "true" ]; then
        sdk_sometimes true "${LASTTRANS_ASSERTION}" "${DETAILS}"
    else
        sdk_sometimes false "${LASTTRANS_ASSERTION}" "${DETAILS}"
    fi
fi

# Emit validatorstats assertion
if [ -n "${BLOCK_ID}" ]; then
    if [ "${VALSTATS_OK}" = "true" ]; then
        sdk_sometimes true "${VALSTATS_ASSERTION}" "${DETAILS}"
    else
        sdk_sometimes false "${VALSTATS_ASSERTION}" "${DETAILS}"
    fi
fi

# Emit getMasterchainInfo assertion
if [ "${MCINFO_OK}" = "true" ]; then
    sdk_sometimes true "${MASTERCHAIN_INFO_ASSERTION}" "${DETAILS}"
fi

# Emit msgqueuesizes assertion
if [ "${MSGQUEUE_OK}" = "true" ]; then
    sdk_sometimes true "${MSGQUEUE_ASSERTION}" "${DETAILS}"
fi

exit 0
