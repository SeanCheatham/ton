#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator has no zombie child processes when healthy
# Checks for zombie (Z state) processes in the validator container. The validator
# entrypoint spawns a background heartbeat loop before exec'ing validator-engine.
# If any child process dies without being reaped, it becomes a zombie consuming
# PID table entries. This is different from the process-state check (which only
# checks PID 1's own state) — it checks for leaked child processes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Validator has no zombie child processes when healthy"

echo "Checking for zombie processes in validator container..."

# Check all 3 ports — only assert when validator is fully healthy
udp_up=false
console_up=false
lite_up=false

# Heartbeat precondition: validator process must be alive
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s), skipping"
            exit 0
        fi
    else
        echo "Heartbeat invalid, skipping"; exit 0
    fi
else
    echo "Heartbeat not present, skipping"; exit 0
fi

nc -z -u -w 2 "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null && udp_up=true
nc -z -w 1 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null && console_up=true
nc -z -w 1 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "SKIP: not all ports are up (udp=${udp_up}, console=${console_up}, lite=${lite_up})"
    sleep 10
    exit 0
fi

# Read zombie count from shared volume (written by validator heartbeat loop)
if [ ! -f /shared/validator_zombie_count ]; then
    echo "Zombie count file not present yet, skipping"
    sleep 10
    exit 0
fi

ZOMBIE_COUNT=$(cat /shared/validator_zombie_count 2>/dev/null || true)
ZOMBIE_COUNT=$(echo "$ZOMBIE_COUNT" | tr -d '[:space:]')

if [ -z "$ZOMBIE_COUNT" ] || ! [[ "$ZOMBIE_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid zombie count value: '$ZOMBIE_COUNT', skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson count "$ZOMBIE_COUNT" \
    '{zombie_count: $count}')

if [ "$ZOMBIE_COUNT" -eq 0 ]; then
    echo "PASS: No zombie processes found"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: ${ZOMBIE_COUNT} zombie processes found"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
