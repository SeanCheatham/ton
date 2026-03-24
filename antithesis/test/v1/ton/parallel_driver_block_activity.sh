#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator log shows block processing activity
# Scans validator.log for evidence that the validator is actually processing blocks.
# Unlike "initialization markers" (which checks generic startup keywords), this
# specifically looks for block-related operational activity proving the node does real work.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator log shows block processing activity"
HEARTBEAT_MAX_AGE=90

# Precondition: validator.log must exist and have content
if [ ! -f /shared/validator.log ] || [ ! -s /shared/validator.log ]; then
    echo "Validator log not available or empty, skipping"
    sleep 15
    exit 0
fi

# Precondition: heartbeat must be fresh
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s), skipping"
            sleep 15
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"
        sleep 15
        exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"
    sleep 15
    exit 0
fi

# Search log for block-processing patterns
MATCH_COUNT=$(grep -ciE 'apply_block|commit_block|validate_block|process_block|new.block|block.*applied|collat|shard|masterchain.*block|created.*block|accepted.*block' /shared/validator.log 2>/dev/null) || MATCH_COUNT=0

LOG_SIZE=$(stat -c%s /shared/validator.log 2>/dev/null || echo "0")

if [ "$MATCH_COUNT" -gt 0 ]; then
    DETAILS=$(jq -cn --argjson matches "$MATCH_COUNT" --argjson log_size "$LOG_SIZE" '{matches: $matches, log_size_bytes: $log_size}')
    echo "PASS: Found $MATCH_COUNT block-related log entries (log size: $LOG_SIZE bytes)"
    sdk_sometimes true "$ASSERTION_NAME" "$DETAILS"
else
    # Collect diagnostic info
    LOG_LINES=$(wc -l < /shared/validator.log 2>/dev/null || echo "0")
    SAMPLE=$(head -3 /shared/validator.log 2>/dev/null | tr '\n' '|' | head -c 200)
    DETAILS=$(jq -cn \
        --argjson log_size "$LOG_SIZE" \
        --argjson log_lines "$LOG_LINES" \
        --argjson hb_age "$AGE" \
        --arg sample "$SAMPLE" \
        '{matches: 0, log_size_bytes: $log_size, log_lines: $log_lines, heartbeat_age_s: $hb_age, first_lines_sample: $sample}')
    echo "FAIL: No block-related log entries found (log size: $LOG_SIZE, lines: $LOG_LINES)"
    sdk_sometimes false "$ASSERTION_NAME" "$DETAILS"
fi

sleep 15
exit 0
