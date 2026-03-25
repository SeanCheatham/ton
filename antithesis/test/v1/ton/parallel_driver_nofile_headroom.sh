#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator resource limits are adequate for operation
# Reads /shared/validator_nofile_limit and /shared/validator_fd_count to check
# that the NOFILE soft limit provides adequate headroom above current FD usage.
# Different from parallel_driver_fd_bounded.sh (which checks absolute count) —
# this checks whether the system allows enough headroom above current usage.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator resource limits are adequate for operation"
MIN_NOFILE=1024

# Heartbeat freshness precondition
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s), skipping"
            sleep 10; exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"; sleep 10; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"; sleep 10; exit 0
fi

# Read metrics
if [ ! -f /shared/validator_nofile_limit ] || [ ! -f /shared/validator_fd_count ]; then
    echo "Metric files not present yet, skipping"
    sleep 10; exit 0
fi

NOFILE_LIMIT=$(cat /shared/validator_nofile_limit 2>/dev/null | tr -d '[:space:]')
FD_COUNT=$(cat /shared/validator_fd_count 2>/dev/null | tr -d '[:space:]')

# Skip if values are missing or invalid
if ! [[ "$NOFILE_LIMIT" =~ ^[0-9]+$ ]] || [ "$NOFILE_LIMIT" = "-1" ]; then
    echo "NOFILE limit unavailable ($NOFILE_LIMIT), skipping"
    sleep 10; exit 0
fi
if ! [[ "$FD_COUNT" =~ ^[0-9]+$ ]] || [ "$FD_COUNT" = "-1" ]; then
    echo "FD count unavailable ($FD_COUNT), skipping"
    sleep 10; exit 0
fi

# Calculate usage percentage (avoid division by zero)
if [ "$NOFILE_LIMIT" -gt 0 ]; then
    USAGE_PCT=$(( FD_COUNT * 100 / NOFILE_LIMIT ))
else
    USAGE_PCT=100
fi

# Check two conditions:
# 1. NOFILE limit >= 1024 (minimum reasonable for any server process)
# 2. Current FD count < NOFILE limit / 2 (at least 50% headroom)
HALF_LIMIT=$(( NOFILE_LIMIT / 2 ))
LIMIT_ADEQUATE=true

if [ "$NOFILE_LIMIT" -lt "$MIN_NOFILE" ]; then
    LIMIT_ADEQUATE=false
    echo "FAIL: NOFILE limit ($NOFILE_LIMIT) below minimum ($MIN_NOFILE)"
fi

if [ "$FD_COUNT" -ge "$HALF_LIMIT" ]; then
    LIMIT_ADEQUATE=false
    echo "FAIL: FD count ($FD_COUNT) >= 50% of NOFILE limit ($NOFILE_LIMIT), usage ${USAGE_PCT}%"
fi

DETAILS=$(jq -cn \
    --argjson fd_count "$FD_COUNT" \
    --argjson nofile_limit "$NOFILE_LIMIT" \
    --argjson usage_pct "$USAGE_PCT" \
    --argjson min_nofile "$MIN_NOFILE" \
    '{fd_count: $fd_count, nofile_limit: $nofile_limit, usage_pct: $usage_pct, min_nofile: $min_nofile}')

if [ "$LIMIT_ADEQUATE" = "true" ]; then
    echo "PASS: FD count=$FD_COUNT, NOFILE limit=$NOFILE_LIMIT, usage=${USAGE_PCT}%"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

sleep 10
exit 0
