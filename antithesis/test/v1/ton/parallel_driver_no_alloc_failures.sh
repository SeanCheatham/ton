#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator log contains no memory allocation failures
# Scans /shared/validator.log for memory allocation failure patterns that may not
# trigger a FATAL log line. The validator might catch the exception and continue
# in a degraded state. Detecting these early prevents silent degradation.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Validator log contains no memory allocation failures"
LOG_FILE="/shared/validator.log"
ALLOC_PATTERNS="std::bad_alloc|[Oo]ut of memory|cannot allocate|malloc failed|mmap failed|allocation failed|memory exhausted|Failed to allocate"

sleep 10

# Only check when validator is healthy (all ports up)
if ! nc -z -w 1 -u "$VALIDATOR_HOST" "$VALIDATOR_PORT" 2>/dev/null; then
    echo "Validator UDP not reachable, skipping"
    sleep 10
    exit 0
fi
if ! nc -z -w 1 "$VALIDATOR_HOST" "$CONSOLE_PORT" 2>/dev/null || \
   ! nc -z -w 1 "$VALIDATOR_HOST" "$LITE_PORT" 2>/dev/null; then
    echo "Validator TCP ports not all reachable, skipping"
    sleep 10
    exit 0
fi

# Check that log file exists and is non-empty
if [ ! -s "$LOG_FILE" ]; then
    echo "Log file not present or empty, skipping"
    sleep 10
    exit 0
fi

ALLOC_COUNT=$(grep -cE "$ALLOC_PATTERNS" "$LOG_FILE" 2>/dev/null || echo "0")
TOTAL_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")

if [ "$ALLOC_COUNT" -gt 0 ]; then
    SAMPLE=$(grep -E "$ALLOC_PATTERNS" "$LOG_FILE" 2>/dev/null | head -3 | head -c 500 || true)
    DETAILS=$(jq -cn \
        --argjson count "$ALLOC_COUNT" \
        --argjson total "$TOTAL_LINES" \
        --arg sample "$SAMPLE" \
        '{alloc_failure_count: $count, log_lines_total: $total, sample: $sample}')
    echo "FAIL: Found ${ALLOC_COUNT} memory allocation failure(s) in log"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
else
    DETAILS=$(jq -cn \
        --argjson count 0 \
        --argjson total "$TOTAL_LINES" \
        '{alloc_failure_count: $count, log_lines_total: $total, sample: ""}')
    echo "PASS: No memory allocation failures found in log (${TOTAL_LINES} lines)"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
fi

sleep 10
exit 0
