#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator config file remains valid JSON
# Reads /shared/validator_config_valid (written by validator entrypoint heartbeat loop)
# and asserts config.json is valid JSON when the validator is healthy. Catches config
# corruption from partial writes during disk faults or truncation during process kills.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Validator config file remains valid JSON"

sdk_catalog_always "${ASSERTION_NAME}"

echo "Checking validator config file validity..."

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

# Read config validity status from shared volume
if [ ! -f /shared/validator_config_valid ]; then
    echo "Config validity file not present yet, skipping"
    sleep 10
    exit 0
fi

CONFIG_VALID=$(cat /shared/validator_config_valid 2>/dev/null || true)
CONFIG_VALID=$(echo "$CONFIG_VALID" | tr -d '[:space:]')

# -1 means config.json doesn't exist yet, skip
if [ -z "$CONFIG_VALID" ] || [ "$CONFIG_VALID" = "-1" ]; then
    echo "Config file not present yet or metric unavailable, skipping"
    sleep 10
    exit 0
fi

if ! [[ "$CONFIG_VALID" =~ ^[01]$ ]]; then
    echo "Invalid config validity value: '$CONFIG_VALID', skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson valid "$CONFIG_VALID" '{config_valid: $valid}')

if [ "$CONFIG_VALID" -eq 1 ]; then
    echo "PASS: config.json is valid JSON"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: config.json is NOT valid JSON while validator is healthy"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
