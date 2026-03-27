#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator logs contain no fatal errors
# Scans /shared/validator.log for fatal error patterns (FATAL, PANIC, SIGSEGV, etc.)
# and asserts that none are found. Catches internal crashes, memory corruption,
# assertion failures, and signal-based kills invisible to port-based checks.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"

LOG_FILE="/shared/validator.log"
FATAL_PATTERNS="FATAL|[Pp]anic|SIGSEGV|SIGABRT|Aborted|Segmentation fault|std::terminate|stack smashing|double free|corrupted"

# Only check if the log file exists (validator may not have started yet)
if [ ! -f "$LOG_FILE" ]; then
    echo "Log file not present yet, skipping"
    sleep 10
    exit 0
fi

FATAL_COUNT=$(grep -ciE "$FATAL_PATTERNS" "$LOG_FILE" 2>/dev/null || echo "0")

if [ "$FATAL_COUNT" -gt 0 ]; then
    SAMPLE=$(grep -iE "$FATAL_PATTERNS" "$LOG_FILE" 2>/dev/null | tail -3 | head -c 500 || true)
    DETAILS=$(jq -cn \
        --argjson count "$FATAL_COUNT" \
        --arg sample "$SAMPLE" \
        '{fatal_count: $count, sample_lines: $sample}')
    sdk_always false "Validator logs contain no fatal errors" "$DETAILS"
else
    sdk_always true "Validator logs contain no fatal errors" '{"fatal_count":0}'
fi

sleep 10
exit 0
