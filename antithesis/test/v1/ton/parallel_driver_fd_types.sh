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

ASSERTION_NAME="Validator has no unexpected file descriptor types"

echo "Checking validator file descriptor types..."

# Heartbeat-only precondition: heartbeat freshness proves the validator process
# is actively running and metrics are valid, regardless of port status.
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
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

# Read unexpected FD count from shared volume
if [ ! -f /shared/validator_unexpected_fds ]; then
    echo "Unexpected FDs file not present yet, skipping"
    sleep 10
    exit 0
fi

UNEXPECTED_FDS=$(cat /shared/validator_unexpected_fds 2>/dev/null || true)
UNEXPECTED_FDS=$(echo "$UNEXPECTED_FDS" | tr -d '[:space:]')

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
