#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator has no leaked deleted file descriptors
# Reads /shared/validator_deleted_fds (written by validator entrypoint heartbeat loop)
# and asserts the count of FDs pointing to "(deleted)" files is below 50. Catches resource
# leaks where files are deleted but handles remain open, causing invisible disk exhaustion.
# This checks FD quality (vs iteration 11B which checks FD quantity).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Validator has no leaked deleted file descriptors"
DELETED_FD_LIMIT=50

echo "Checking deleted file descriptor count..."

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

# Read deleted FD count from shared volume
if [ ! -f /shared/validator_deleted_fds ]; then
    echo "Deleted FDs file not present yet, skipping"
    sleep 10
    exit 0
fi

DELETED_FDS=$(cat /shared/validator_deleted_fds 2>/dev/null | tr -d '[:space:]')

if [ -z "$DELETED_FDS" ] || ! [[ "$DELETED_FDS" =~ ^[0-9]+$ ]]; then
    echo "Invalid deleted FD count value: '$DELETED_FDS', skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson count "$DELETED_FDS" --argjson limit "$DELETED_FD_LIMIT" \
    '{deleted_fd_count: $count, deleted_fd_limit: $limit}')

if [ "$DELETED_FDS" -lt "$DELETED_FD_LIMIT" ]; then
    echo "PASS: ${DELETED_FDS} deleted FDs (limit: ${DELETED_FD_LIMIT})"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: ${DELETED_FDS} deleted FDs exceeds limit of ${DELETED_FD_LIMIT}"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
