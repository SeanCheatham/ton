#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Global config ton-global.config remains valid JSON
# Reads /shared/validator_global_config_valid (written by validator entrypoint heartbeat loop)
# and asserts ton-global.config is valid JSON when the validator is healthy. This file defines
# network identity, DHT nodes, zero-state, and consensus parameters. Complements the existing
# config.json check (iteration 14C) by covering the other critical config file.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Global config ton-global.config remains valid JSON"

echo "Checking ton-global.config validity..."

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

# Read global config validity status from shared volume
if [ ! -f /shared/validator_global_config_valid ]; then
    echo "Global config validity file not present yet, skipping"
    sleep 10
    exit 0
fi

GLOBAL_CONFIG_VALID=$(cat /shared/validator_global_config_valid 2>/dev/null || true)
GLOBAL_CONFIG_VALID=$(echo "$GLOBAL_CONFIG_VALID" | tr -d '[:space:]')

# -1 means ton-global.config doesn't exist yet, skip
if [ -z "$GLOBAL_CONFIG_VALID" ] || [ "$GLOBAL_CONFIG_VALID" = "-1" ]; then
    echo "Global config file not present yet or metric unavailable, skipping"
    sleep 10
    exit 0
fi

if ! [[ "$GLOBAL_CONFIG_VALID" =~ ^[01]$ ]]; then
    echo "Invalid global config validity value: '$GLOBAL_CONFIG_VALID', skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson valid "$GLOBAL_CONFIG_VALID" '{global_config_valid: $valid}')

if [ "$GLOBAL_CONFIG_VALID" -eq 1 ]; then
    echo "PASS: ton-global.config is valid JSON"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: ton-global.config is NOT valid JSON while validator is healthy"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
