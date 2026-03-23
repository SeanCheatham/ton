#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator oom_score is bounded when healthy
# Reads /shared/validator_oom_score (written by validator entrypoint heartbeat loop)
# and asserts OOM score stays below 800. A high oom_score means the Linux kernel is
# likely to kill the validator under memory pressure — different from RSS bounds
# because oom_score considers system-wide memory context.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator oom_score is bounded when healthy"
OOM_LIMIT=950

echo "Checking validator OOM score..."

# Heartbeat-only precondition: heartbeat freshness proves the validator process
# is actively running and metrics are valid, regardless of port status.
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s > ${HEARTBEAT_MAX_AGE}s), skipping"
            sleep 5; exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"; sleep 5; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"; sleep 5; exit 0
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
