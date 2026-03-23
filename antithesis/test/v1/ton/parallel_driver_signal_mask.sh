#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator critical signals are not blocked when healthy
# Reads /shared/validator_sigblk (written by validator entrypoint heartbeat loop)
# and asserts SIGINT (bit 1) and SIGTERM (bit 14) are not blocked. If these signals
# are blocked, the process can't be cleanly stopped, requiring SIGKILL and risking
# RocksDB corruption due to unclean shutdown.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Validator critical signals are not blocked when healthy"

echo "Checking validator signal mask..."

# Check all 3 ports — only assert when validator is fully healthy
udp_up=false
console_up=false
lite_up=false

nc -z -u -w 2 "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null && udp_up=true
nc -z -w 1 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null && console_up=true
nc -z -w 1 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "SKIP: not all ports are up (udp=${udp_up}, console=${console_up}, lite=${lite_up})"
    sleep 10
    exit 0
fi

# Check heartbeat freshness
if [ ! -f /shared/validator_heartbeat ]; then
    echo "Heartbeat file not present yet, skipping"
    sleep 10
    exit 0
fi

HB=$(cat /shared/validator_heartbeat 2>/dev/null || echo "0")
NOW=$(date +%s)
AGE=$(( NOW - HB ))
if [ "$AGE" -gt 30 ]; then
    echo "Heartbeat stale (${AGE}s old), skipping"
    sleep 10
    exit 0
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
