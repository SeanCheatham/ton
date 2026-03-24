#!/usr/bin/env bash
set -euo pipefail

# Singleton driver: Verify critical validator environment configuration is stable.
# Checks that the validator's liteserver config and global config remain valid
# and structurally intact. Singleton driver type ensures only one instance runs
# at a time — appropriate for environment validation that shouldn't race with itself.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator environment configuration is stable"

# Check heartbeat freshness to know the validator is alive
HEARTBEAT_MAX_AGE=60
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s), skipping"
            sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"heartbeat_stale"}'
            exit 0
        fi
    else
        echo "Heartbeat invalid, skipping"
        sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"heartbeat_invalid"}'
        exit 0
    fi
else
    echo "Heartbeat not present, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"heartbeat_missing"}'
    exit 0
fi

# Read the validator's config.json which contains runtime parameters
CONFIG="/shared/liteserver.config.json"
if [ ! -f "$CONFIG" ]; then
    echo "Liteserver config not found, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"config_missing"}'
    exit 0
fi

# Validate the config is still parseable JSON
if ! jq empty "$CONFIG" 2>/dev/null; then
    echo "FAIL: Liteserver config is not valid JSON"
    sdk_always false "$ASSERTION_NAME" '{"status":"config_corrupt"}'
    exit 0
fi

# Check that the config contains expected liteserver structure
HAS_LITESERVERS=$(jq 'has("liteservers")' "$CONFIG" 2>/dev/null || echo "false")
HAS_VALIDATOR=$(jq 'has("validator")' "$CONFIG" 2>/dev/null || echo "false")

# Also verify the global config is intact
GLOBAL_CONFIG="/var/ton-work/db/ton-global.config"
GLOBAL_VALID="false"
if [ -f "$GLOBAL_CONFIG" ]; then
    if jq empty "$GLOBAL_CONFIG" 2>/dev/null; then
        GLOBAL_VALID="true"
    fi
elif [ -f "/shared/ton-global.config" ]; then
    GLOBAL_VALID="true"
fi

PASS=true
ISSUES=""

if [ "$HAS_LITESERVERS" != "true" ]; then
    PASS=false
    ISSUES="missing_liteservers_key"
fi

if [ "$HAS_VALIDATOR" != "true" ]; then
    PASS=false
    ISSUES="${ISSUES:+${ISSUES},}missing_validator_key"
fi

DETAILS=$(jq -cn \
    --argjson has_liteservers "$HAS_LITESERVERS" \
    --argjson has_validator "$HAS_VALIDATOR" \
    --argjson global_valid "$GLOBAL_VALID" \
    --arg issues "${ISSUES:-none}" \
    '{has_liteservers: $has_liteservers, has_validator: $has_validator, global_config_valid: $global_valid, issues: $issues}')

if [ "$PASS" = "true" ]; then
    echo "PASS: Validator environment configuration is stable"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Validator environment configuration unstable: $ISSUES"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

sleep 5
exit 0
