#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator keyring directory is non-empty when healthy
# Reads /shared/validator_keyring_count (written by validator entrypoint heartbeat loop).
# The keyring directory (/var/ton-work/db/keyring/) contains cryptographic keys for
# liteserver and console authentication. If fault injection corrupts or deletes these
# keys, the validator cannot authenticate connections — appearing healthy but silently
# failing all client operations.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator keyring directory is non-empty when healthy"
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

if [ ! -f /shared/validator_keyring_count ]; then
    echo "Keyring count file not present yet, skipping"
    sleep 10
    exit 0
fi

KEYRING_COUNT=$(cat /shared/validator_keyring_count 2>/dev/null || echo "-1")

if ! [[ "$KEYRING_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid keyring count value: ${KEYRING_COUNT}, skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson count "$KEYRING_COUNT" '{keyring_file_count: $count}')

if [ "$KEYRING_COUNT" -ge 1 ]; then
    echo "PASS: Keyring directory contains ${KEYRING_COUNT} file(s)"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Keyring directory is empty (count=${KEYRING_COUNT})"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

sleep 10
exit 0
