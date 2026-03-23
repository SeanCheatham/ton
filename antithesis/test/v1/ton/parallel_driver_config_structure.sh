#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator config.json contains expected structural keys
# Beyond valid JSON (covered by parallel_driver_config_valid.sh), verifies that
# config.json contains the structural keys that prove proper initialization:
# "@type", "liteservers", and "control". Missing keys indicate structural corruption
# that preserved JSON validity but destroyed functional correctness.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Validator config.json contains expected structural keys"

echo "Checking validator config.json structural keys..."

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

# Check that config is valid JSON first (prerequisite)
CONFIG_VALID=$(cat /shared/validator_config_valid 2>/dev/null || echo "-1")
if [ "$CONFIG_VALID" != "1" ]; then
    echo "SKIP: config not valid JSON (status=${CONFIG_VALID})"
    sleep 10
    exit 0
fi

# Read config keys from shared volume (written by validator heartbeat loop)
if [ ! -f /shared/validator_config_keys ]; then
    echo "SKIP: config keys metric not available yet"
    sleep 10
    exit 0
fi

CONFIG_KEYS=$(cat /shared/validator_config_keys 2>/dev/null || echo "error")

if [ "$CONFIG_KEYS" = "error" ]; then
    echo "FAIL: Could not read config keys"
    DETAILS=$(jq -cn '{status: "error", keys_found: "none"}')
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
    sleep 10
    exit 0
fi

# Check for required keys
REQUIRED_KEYS=("@type" "liteservers" "control")
MISSING=""
PRESENT=""

for key in "${REQUIRED_KEYS[@]}"; do
    if echo "$CONFIG_KEYS" | grep -q "$key"; then
        if [ -n "$PRESENT" ]; then
            PRESENT="${PRESENT}, ${key}"
        else
            PRESENT="${key}"
        fi
    else
        if [ -n "$MISSING" ]; then
            MISSING="${MISSING}, ${key}"
        else
            MISSING="${key}"
        fi
    fi
done

if [ -z "$MISSING" ]; then
    echo "PASS: All required structural keys present: ${PRESENT}"
    DETAILS=$(jq -cn --arg present "$PRESENT" --arg keys "$CONFIG_KEYS" \
        '{status: "all_present", present_keys: $present, all_keys: $keys}')
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: Missing required keys: ${MISSING} (present: ${PRESENT})"
    DETAILS=$(jq -cn --arg missing "$MISSING" --arg present "$PRESENT" --arg keys "$CONFIG_KEYS" \
        '{status: "missing_keys", missing: $missing, present_keys: $present, all_keys: $keys}')
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
