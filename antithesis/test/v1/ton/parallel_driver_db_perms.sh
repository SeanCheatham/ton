#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator database file permissions are correct when healthy
# Reads /shared/validator_db_perms (written by validator entrypoint heartbeat loop).
# When the validator is healthy, critical database files must be readable and writable.
# Corrupted permissions after a crash can prevent recovery on restart.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator database file permissions are correct when healthy"
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

# Only check when validator is healthy (all ports up)
if ! nc -z -w 1 -u "$VALIDATOR_HOST" "$VALIDATOR_PORT" 2>/dev/null; then
    echo "Validator UDP not reachable, skipping"
    sleep 10
    exit 0
fi
if ! nc -z -w 1 "$VALIDATOR_HOST" "$CONSOLE_PORT" 2>/dev/null || \
   ! nc -z -w 1 "$VALIDATOR_HOST" "$LITE_PORT" 2>/dev/null; then
    echo "Validator TCP ports not all reachable, skipping"
    sleep 10
    exit 0
fi

if [ ! -f /shared/validator_db_perms ]; then
    echo "DB permissions file not present yet, skipping"
    sleep 10
    exit 0
fi

PERM_OK=$(cat /shared/validator_db_perms 2>/dev/null || echo "-1")

if ! [[ "$PERM_OK" =~ ^[01]$ ]]; then
    echo "Invalid permissions value: $PERM_OK, skipping"
    sleep 10
    exit 0
fi

if [ "$PERM_OK" = "1" ]; then
    echo "PASS: All critical DB files have correct permissions"
    DETAILS=$(jq -cn '{permissions_ok: true}')
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: One or more critical DB files have incorrect permissions"
    DETAILS=$(jq -cn '{permissions_ok: false, description: "CURRENT, LOCK, or MANIFEST file is not readable or writable"}')
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

sleep 10
exit 0
