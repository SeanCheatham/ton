#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator has no unexpected file descriptor types
# Reads /shared/validator_unexpected_fds (written by validator entrypoint heartbeat loop)
# and asserts the count is 0 when healthy. All FDs should be regular files, sockets,
# pipes, expected /dev entries, anon_inode, or /proc entries. Unexpected types indicate
# bugs or compromised state. Goes deeper than fd_bounded (count) and deleted_fds (leaks)
# — checks FD quality/type.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Validator has no unexpected file descriptor types"

echo "Checking validator file descriptor types..."

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

# Read unexpected FD count from shared volume
if [ ! -f /shared/validator_unexpected_fds ]; then
    echo "Unexpected FDs file not present yet, skipping"
    sleep 10
    exit 0
fi

UNEXPECTED_FDS=$(cat /shared/validator_unexpected_fds 2>/dev/null | tr -d '[:space:]')

if [ -z "$UNEXPECTED_FDS" ] || ! [[ "$UNEXPECTED_FDS" =~ ^[0-9]+$ ]]; then
    echo "Invalid unexpected FDs value: '$UNEXPECTED_FDS', skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson count "$UNEXPECTED_FDS" \
    '{unexpected_fd_count: $count}')

if [ "$UNEXPECTED_FDS" -eq 0 ]; then
    echo "PASS: No unexpected file descriptor types"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: ${UNEXPECTED_FDS} unexpected file descriptor types found"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
