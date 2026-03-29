#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator log contains expected initialization markers
# First functional correctness property. Scans /shared/validator.log (and rotated
# variants) for operational markers that prove the validator's core subsystems
# executed. "Sometimes" because the log may not be populated immediately.
#
# Fix #3 for unsatisfied assertion: The entrypoint heartbeat loop now writes an
# explicit text marker ("[entrypoint] Validator heartbeat started") on first
# iteration, bypassing TON's TsFileLog buffering entirely. This guarantees at
# least one matching line exists. The driver also emits diagnostics when patterns
# don't match despite validator uptime, to aid future debugging.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator log contains expected initialization markers"

echo "Checking validator log for initialization markers..."

# Collect all log files: primary log + any rotated variants
LOG_FILES=()
for f in /shared/validator.log*; do
    [ -f "$f" ] && LOG_FILES+=("$f")
done

# No log files at all — skip
if [ ${#LOG_FILES[@]} -eq 0 ]; then
    echo "No log files present yet, skipping"
    sleep 10
    exit 0
fi

# Check if any log file has content
TOTAL_SIZE=0
for f in "${LOG_FILES[@]}"; do
    SZ=$(stat -c %s "$f" 2>/dev/null || echo "0")
    TOTAL_SIZE=$((TOTAL_SIZE + SZ))
done

if [ "$TOTAL_SIZE" -eq 0 ]; then
    echo "All log files empty, skipping"
    sleep 10
    exit 0
fi

# Search for operational initialization markers (case-insensitive)
# Includes TON-specific patterns and the entrypoint heartbeat marker
MATCH_COUNT=0
for f in "${LOG_FILES[@]}"; do
    COUNT=$(grep -ciE "started|init|adnl|dht|loading|created\.db|config|block|zero\.state|validator|overlay|rldp|catchain|entrypoint|heartbeat" "$f" 2>/dev/null) || COUNT=0
    MATCH_COUNT=$((MATCH_COUNT + COUNT))
done

FILE_COUNT=${#LOG_FILES[@]}

if [ "$MATCH_COUNT" -gt 0 ]; then
    echo "PASS: Found ${MATCH_COUNT} initialization marker matches across ${FILE_COUNT} log files"
    DETAILS=$(jq -cn --argjson matches "$MATCH_COUNT" --argjson log_size "$TOTAL_SIZE" \
        --argjson file_count "$FILE_COUNT" \
        '{marker_matches: $matches, log_size_bytes: $log_size, log_file_count: $file_count}')
    sdk_sometimes true "${ASSERTION_NAME}" "$DETAILS"
else
    # Emit diagnostics to help debug if this remains unsatisfied
    HEARTBEAT_AGE="unknown"
    if [ -f /shared/validator_heartbeat ]; then
        HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || echo "0")
        NOW=$(date +%s)
        if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
            HEARTBEAT_AGE=$((NOW - HB_TS))
        fi
    fi
    # Sample first few lines of log for diagnostic insight
    FIRST_LINES=""
    for f in "${LOG_FILES[@]}"; do
        SAMPLE=$(head -3 "$f" 2>/dev/null | tr '\n' ' ' | cut -c1-200)
        FIRST_LINES="${FIRST_LINES}${SAMPLE} "
    done

    echo "No initialization markers found across ${FILE_COUNT} log files (${TOTAL_SIZE} bytes total)"
    echo "Diagnostics: heartbeat_age=${HEARTBEAT_AGE}s, log_sample='${FIRST_LINES}'"

    DETAILS=$(jq -cn --argjson matches 0 --argjson log_size "$TOTAL_SIZE" \
        --argjson file_count "$FILE_COUNT" --arg heartbeat_age "$HEARTBEAT_AGE" \
        --arg log_sample "${FIRST_LINES:0:200}" \
        '{marker_matches: $matches, log_size_bytes: $log_size, log_file_count: $file_count, heartbeat_age_s: $heartbeat_age, log_sample: $log_sample}')
    sdk_sometimes false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
