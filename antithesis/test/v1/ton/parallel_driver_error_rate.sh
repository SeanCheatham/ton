#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator log non-fatal error count is bounded when healthy
# Reads /shared/validator_log_error_count (COUNT:SIZE_KB format) and asserts
# the non-fatal error volume stays within bounds. Different from
# parallel_driver_no_fatal_logs.sh (FATAL/PANIC/SIGSEGV) and
# parallel_driver_no_alloc_failures.sh (bad_alloc/malloc) — this catches
# error storms from subsystem failures that don't crash the process.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator log non-fatal error count is bounded when healthy"
MAX_ERROR_COUNT=1000
MAX_ERROR_RATE_PER_KB=1  # errors per KB of log output
LARGE_LOG_KB=10240        # 10MB threshold for rate-based check

# Heartbeat freshness precondition
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
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

# Read metric
if [ ! -f /shared/validator_log_error_count ]; then
    echo "Error count metric not present yet, skipping"
    sleep 10; exit 0
fi

RAW=$(cat /shared/validator_log_error_count 2>/dev/null || true)
RAW=$(echo "$RAW" | tr -d '[:space:]')

# Parse COUNT:SIZE_KB format
ERROR_COUNT="${RAW%%:*}"
LOG_SIZE_KB="${RAW##*:}"

# Validate numeric
if ! [[ "$ERROR_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid error count ($ERROR_COUNT), skipping"
    sleep 10; exit 0
fi
if ! [[ "$LOG_SIZE_KB" =~ ^[0-9]+$ ]]; then
    echo "Invalid log size ($LOG_SIZE_KB), skipping"
    sleep 10; exit 0
fi

# Skip if log size is 0 (no log output yet)
if [ "$LOG_SIZE_KB" -eq 0 ]; then
    echo "Log size is 0, skipping"
    sleep 10; exit 0
fi

# Calculate error rate per KB
if [ "$LOG_SIZE_KB" -gt 0 ]; then
    ERROR_RATE_PER_KB=$(( ERROR_COUNT / LOG_SIZE_KB ))
else
    ERROR_RATE_PER_KB=0
fi

# Determine if bounded:
# - For large logs (>10MB): use rate-based check (errors per KB < 1)
# - For smaller logs: use absolute bound (< 1000 errors)
BOUNDED=true
if [ "$LOG_SIZE_KB" -gt "$LARGE_LOG_KB" ]; then
    if [ "$ERROR_RATE_PER_KB" -ge "$MAX_ERROR_RATE_PER_KB" ]; then
        BOUNDED=false
        echo "FAIL: Error rate ${ERROR_RATE_PER_KB}/KB exceeds limit ${MAX_ERROR_RATE_PER_KB}/KB (log=${LOG_SIZE_KB}KB, errors=${ERROR_COUNT})"
    fi
else
    if [ "$ERROR_COUNT" -ge "$MAX_ERROR_COUNT" ]; then
        BOUNDED=false
        echo "FAIL: Error count ${ERROR_COUNT} exceeds limit ${MAX_ERROR_COUNT} (log=${LOG_SIZE_KB}KB)"
    fi
fi

DETAILS=$(jq -cn \
    --argjson error_count "$ERROR_COUNT" \
    --argjson log_size_kb "$LOG_SIZE_KB" \
    --argjson error_rate_per_kb "$ERROR_RATE_PER_KB" \
    '{error_count: $error_count, log_size_kb: $log_size_kb, error_rate_per_kb: $error_rate_per_kb}')

if [ "$BOUNDED" = "true" ]; then
    echo "PASS: Error count=$ERROR_COUNT, log size=${LOG_SIZE_KB}KB, rate=${ERROR_RATE_PER_KB}/KB"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

sleep 10
exit 0
