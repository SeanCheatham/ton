#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator keyring file permissions are restrictive when healthy
# Reads /shared/validator_keyring_perms (written by validator entrypoint heartbeat loop).
# Private key files in keyring/ must not be world-writable or group-writable.
# A world-readable private key is a critical security defect.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator keyring file permissions are restrictive when healthy"
VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

sleep 10

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

if [ ! -f /shared/validator_keyring_perms ]; then
    echo "Keyring perms file not present yet, skipping"
    sleep 10
    exit 0
fi

PERMS_OK=$(cat /shared/validator_keyring_perms 2>/dev/null || echo "-1")

if [ "$PERMS_OK" = "-1" ]; then
    echo "Keyring perms not yet checked, skipping"
    sleep 10
    exit 0
fi

if ! [[ "$PERMS_OK" =~ ^[01]$ ]]; then
    echo "Invalid keyring perms value: $PERMS_OK, skipping"
    sleep 10
    exit 0
fi

KEYRING_COUNT=$(cat /shared/validator_keyring_count 2>/dev/null || echo "0")
DETAILS=$(jq -cn --argjson perms_ok "$PERMS_OK" --argjson count "${KEYRING_COUNT:-0}" \
    '{perms_ok: ($perms_ok == 1), keyring_count: $count}')

if [ "$PERMS_OK" = "1" ]; then
    echo "PASS: All keyring files have restrictive permissions"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: One or more keyring files have overly permissive permissions"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

sleep 10
exit 0
