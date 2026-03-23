#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator critical signals are not blocked when healthy
# Reads /shared/validator_sigblk (written by validator entrypoint heartbeat loop)
# and asserts SIGINT (bit 1) and SIGTERM (bit 14) are not blocked. If these signals
# are blocked, the process can't be cleanly stopped, requiring SIGKILL and risking
# RocksDB corruption due to unclean shutdown.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator critical signals are not blocked when healthy"

echo "Checking validator signal mask..."

# Heartbeat-only precondition: heartbeat freshness proves the validator process
# is actively running and metrics are valid, regardless of port status.
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s > ${HEARTBEAT_MAX_AGE}s), skipping"
            sleep 5; exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"; sleep 5; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"; sleep 5; exit 0
fi

# Read signal blocked mask from shared volume
if [ ! -f /shared/validator_sigblk ]; then
    echo "Signal mask file not present yet, skipping"
    sleep 10
    exit 0
fi

SIG_HEX=$(cat /shared/validator_sigblk 2>/dev/null | tr -d '[:space:]')

# Validate hex value
if [ -z "$SIG_HEX" ] || ! [[ "$SIG_HEX" =~ ^[0-9a-fA-F]+$ ]]; then
    echo "Invalid signal mask value: '$SIG_HEX', skipping"
    sleep 10
    exit 0
fi

# Convert hex to decimal and check critical signal bits
SIG_DEC=$((16#$SIG_HEX))
SIGINT_BLOCKED=$(( (SIG_DEC >> 1) & 1 ))    # bit 1 = SIGINT (signal 2)
SIGTERM_BLOCKED=$(( (SIG_DEC >> 14) & 1 ))   # bit 14 = SIGTERM (signal 15)
CRITICAL_BLOCKED=$((SIGINT_BLOCKED + SIGTERM_BLOCKED))

DETAILS=$(jq -cn \
    --arg hex "$SIG_HEX" \
    --argjson sigint_blocked "$SIGINT_BLOCKED" \
    --argjson sigterm_blocked "$SIGTERM_BLOCKED" \
    '{sigblk_hex: $hex, sigint_blocked: $sigint_blocked, sigterm_blocked: $sigterm_blocked}')

if [ "$CRITICAL_BLOCKED" -eq 0 ]; then
    echo "PASS: Neither SIGINT nor SIGTERM is blocked (SigBlk=0x${SIG_HEX})"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: Critical signals blocked — SIGINT=${SIGINT_BLOCKED}, SIGTERM=${SIGTERM_BLOCKED} (SigBlk=0x${SIG_HEX})"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
