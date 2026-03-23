#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator oom_score is bounded when healthy
# Reads /shared/validator_oom_score (written by validator entrypoint heartbeat loop)
# and asserts OOM score stays below 800. A high oom_score means the Linux kernel is
# likely to kill the validator under memory pressure — different from RSS bounds
# because oom_score considers system-wide memory context.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Validator oom_score is bounded when healthy"
OOM_LIMIT=800

echo "Checking validator OOM score..."

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

# Read OOM score from shared volume
if [ ! -f /shared/validator_oom_score ]; then
    echo "OOM score file not present yet, skipping"
    sleep 10
    exit 0
fi

OOM_SCORE=$(cat /shared/validator_oom_score 2>/dev/null | tr -d '[:space:]')

if [ -z "$OOM_SCORE" ] || ! [[ "$OOM_SCORE" =~ ^-?[0-9]+$ ]]; then
    echo "Invalid OOM score value: '$OOM_SCORE', skipping"
    sleep 10
    exit 0
fi

if [ "$OOM_SCORE" -lt 0 ]; then
    echo "OOM score unavailable ($OOM_SCORE), skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson score "$OOM_SCORE" --argjson limit "$OOM_LIMIT" \
    '{oom_score: $score, oom_limit: $limit}')

if [ "$OOM_SCORE" -lt "$OOM_LIMIT" ]; then
    echo "PASS: OOM score ${OOM_SCORE} (limit: ${OOM_LIMIT})"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: OOM score ${OOM_SCORE} exceeds limit of ${OOM_LIMIT}"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
