#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Masterchain block height advances over time.
# Complements the eventually-phase script by also observing block production
# during the parallel fault-injection phase.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
LITE_PORT="${LITE_PORT:-30003}"
ASSERTION_NAME="Masterchain block height advances over time"
HEARTBEAT_MAX_AGE=90

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

# Helper: query masterchain seqno
get_seqno() {
    local output
    output=$(timeout 10 lite-client \
        -v 1 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C /shared/liteserver.config.json \
        -c 'last' \
        -c 'quit' 2>&1) || true
    echo "${output}" | grep -oE '\(-1,[0-9a-fA-F]+,[0-9]+\)' | grep -oE ',[0-9]+\)$' | tr -d ',)' | tail -1 || true
}

echo "Querying initial block height..."
SEQNO_BEFORE=$(get_seqno)

if [ -z "${SEQNO_BEFORE}" ] || ! [[ "${SEQNO_BEFORE}" =~ ^[0-9]+$ ]]; then
    echo "Could not parse initial seqno (got: '${SEQNO_BEFORE}'), skipping"
    exit 0
fi
echo "Initial seqno: ${SEQNO_BEFORE}"

sleep 5

echo "Querying block height after 5s..."
SEQNO_AFTER=$(get_seqno)

if [ -z "${SEQNO_AFTER}" ] || ! [[ "${SEQNO_AFTER}" =~ ^[0-9]+$ ]]; then
    echo "Could not parse seqno after sleep (got: '${SEQNO_AFTER}'), skipping"
    exit 0
fi
echo "Final seqno: ${SEQNO_AFTER}"

DELTA=$(( SEQNO_AFTER - SEQNO_BEFORE ))

DETAILS=$(jq -cn \
    --argjson before "${SEQNO_BEFORE}" \
    --argjson after "${SEQNO_AFTER}" \
    --argjson delta "${DELTA}" \
    '{seqno_before: $before, seqno_after: $after, blocks_produced: $delta}')

if [ "${DELTA}" -gt 0 ]; then
    echo "PASS: block height advanced by ${DELTA} (${SEQNO_BEFORE} -> ${SEQNO_AFTER})"
    sdk_sometimes true "${ASSERTION_NAME}" "${DETAILS}"
else
    echo "No new blocks in 5s (seqno stuck at ${SEQNO_BEFORE})"
    sdk_sometimes false "${ASSERTION_NAME}" "${DETAILS}"
fi

exit 0
