#!/usr/bin/env bash

# Serial driver: Validator config file content is stable over time
# Reads the config.json content hash twice with a 10-second delay.
# The hash must be identical — config changes during normal operation
# indicate corruption or unauthorized mutation.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator config file content is stable over time"
HEARTBEAT_MAX_AGE=60

# Precondition: heartbeat must be fresh
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s > ${HEARTBEAT_MAX_AGE}s), skipping"
            sdk_always true "$ASSERTION_NAME" '{"status":"heartbeat_stale"}'
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"
        sdk_always true "$ASSERTION_NAME" '{"status":"heartbeat_invalid"}'
        exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"heartbeat_not_present"}'
    exit 0
fi

# Read first config hash
HASH1=$(cat /shared/validator_config_hash 2>/dev/null || true)
HASH1=$(echo "$HASH1" | tr -d '[:space:]')
if [ -z "$HASH1" ] || [ "$HASH1" = "unavailable" ]; then
    echo "Config hash not available yet, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"metric_not_available"}'
    exit 0
fi

echo "First config hash: ${HASH1}"
sleep 10

# Read second config hash
HASH2=$(cat /shared/validator_config_hash 2>/dev/null || true)
HASH2=$(echo "$HASH2" | tr -d '[:space:]')
if [ -z "$HASH2" ] || [ "$HASH2" = "unavailable" ]; then
    echo "Config hash became unavailable during wait, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"metric_became_unavailable"}'
    exit 0
fi

echo "Second config hash: ${HASH2}"

DETAILS=$(jq -cn --arg h1 "$HASH1" --arg h2 "$HASH2" '{hash_before: $h1, hash_after: $h2}')

if [ "$HASH1" = "$HASH2" ]; then
    echo "PASS: Config hash stable (${HASH1})"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Config hash changed (${HASH1} -> ${HASH2})"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
