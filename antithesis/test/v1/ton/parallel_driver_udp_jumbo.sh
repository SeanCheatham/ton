#!/bin/bash
set -euo pipefail

# Sends oversized UDP datagrams to the validator's ADNL port (30001)
# and verifies the validator doesn't crash. Tests buffer overflow resilience.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"

# Check heartbeat freshness (precondition: validator healthy before attack)
HEARTBEAT_FILE="/shared/validator_heartbeat"
if [[ ! -f "$HEARTBEAT_FILE" ]]; then
    echo "No heartbeat file yet, skipping"
    exit 0
fi

HEARTBEAT_TS=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo "0")
NOW=$(date +%s)
AGE=$(( NOW - HEARTBEAT_TS ))
if (( AGE > 30 )); then
    echo "Heartbeat stale (${AGE}s old), skipping"
    exit 0
fi

# Check all 3 ports reachable before attack
udp_up=false
console_up=false
lite_up=false
nc -z -w 1 -u "${VALIDATOR_HOST}" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "${VALIDATOR_HOST}" 30002 2>/dev/null && console_up=true
nc -z -w 1 "${VALIDATOR_HOST}" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "Validator not fully healthy before attack, skipping"
    exit 0
fi

# Send oversized UDP payloads
echo "Sending oversized UDP payloads to ${VALIDATOR_HOST}:${VALIDATOR_PORT}..."

# 8KB payload
dd if=/dev/urandom bs=8192 count=1 2>/dev/null | nc -u -w1 "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null || true
echo "Sent 8KB payload"

# 16KB payload
dd if=/dev/urandom bs=16384 count=1 2>/dev/null | nc -u -w1 "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null || true
echo "Sent 16KB payload"

# 64KB payload (max UDP payload = 65507 bytes)
dd if=/dev/urandom bs=65507 count=1 2>/dev/null | nc -u -w1 "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null || true
echo "Sent 64KB payload"

# Wait for any delayed impact
sleep 2

# Verify validator survived
CHECKS_DETAIL=""
SURVIVED=true

# Check heartbeat still fresh
HEARTBEAT_TS2=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo "0")
NOW2=$(date +%s)
AGE2=$(( NOW2 - HEARTBEAT_TS2 ))
if (( AGE2 > 60 )); then
    SURVIVED=false
    CHECKS_DETAIL="heartbeat_stale"
fi

# Check all ports still reachable
udp_up2=false
console_up2=false
lite_up2=false
nc -z -w 1 -u "${VALIDATOR_HOST}" 30001 2>/dev/null && udp_up2=true
nc -z -w 1 "${VALIDATOR_HOST}" 30002 2>/dev/null && console_up2=true
nc -z -w 1 "${VALIDATOR_HOST}" 30003 2>/dev/null && lite_up2=true

if [[ "$udp_up2" != "true" ]]; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}udp_down"
fi
if [[ "$console_up2" != "true" ]]; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}console_down"
fi
if [[ "$lite_up2" != "true" ]]; then
    SURVIVED=false
    CHECKS_DETAIL="${CHECKS_DETAIL:+${CHECKS_DETAIL},}lite_down"
fi

if [[ "$SURVIVED" == "true" ]]; then
    sdk_sometimes true "Validator survives oversized UDP payloads" \
        "{\"packets_sent\":3,\"sizes\":\"8KB,16KB,64KB\",\"survived\":true,\"post_fuzz_checks\":\"all_passed\"}"
else
    sdk_sometimes false "Validator survives oversized UDP payloads" \
        "{\"packets_sent\":3,\"sizes\":\"8KB,16KB,64KB\",\"survived\":false,\"post_fuzz_checks\":\"${CHECKS_DETAIL}\"}"
fi

exit 0
