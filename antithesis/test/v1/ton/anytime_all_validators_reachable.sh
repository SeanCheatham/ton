#!/usr/bin/env bash
set -euo pipefail

# Driver: All 3 validators are reachable on their UDP ports.
# Each validator binds UDP port 30001 for ADNL P2P communication. If any
# validator's UDP port is unreachable, it cannot participate in consensus.
# This is an "always" property checked during normal operation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
VALIDATOR2_HOST="${VALIDATOR2_HOST:-ton-validator2}"
VALIDATOR3_HOST="${VALIDATOR3_HOST:-ton-validator3}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"

ASSERTION_NAME="All 3 validators are reachable on their UDP ports"

sdk_catalog_always "${ASSERTION_NAME}"

ALL_UP=true
DETAILS=""

for VAL_HOST in "${VALIDATOR_HOST}" "${VALIDATOR2_HOST}" "${VALIDATOR3_HOST}"; do
    if nc -z -w 2 -u "${VAL_HOST}" "${VALIDATOR_PORT}" 2>/dev/null; then
        echo "PASS: ${VAL_HOST}:${VALIDATOR_PORT} is reachable"
        DETAILS="${DETAILS} \"${VAL_HOST}\": true,"
    else
        echo "FAIL: ${VAL_HOST}:${VALIDATOR_PORT} is not reachable"
        DETAILS="${DETAILS} \"${VAL_HOST}\": false,"
        ALL_UP=false
    fi
done

DETAILS="${DETAILS%,}"

if [ "${ALL_UP}" = "true" ]; then
    sdk_always true "${ASSERTION_NAME}" \
        "$(jq -cn "{${DETAILS}}")"
else
    sdk_always false "${ASSERTION_NAME}" \
        "$(jq -cn "{${DETAILS}}")"
fi

exit 0
