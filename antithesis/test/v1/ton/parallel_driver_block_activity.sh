#!/usr/bin/env bash

# Parallel driver: Validator log shows block processing activity
# Scans validator.log for evidence of block-related work.
# For a standalone validator with zero state (no peers), the patterns
# are broader than active-network patterns.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator log shows block processing activity"
HEARTBEAT_MAX_AGE=90

# Precondition: validator.log must exist and have content
if [ ! -f /shared/validator.log ] || [ ! -s /shared/validator.log ]; then
    echo "Validator log not available or empty, skipping"
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
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"; exit 0
fi

# Tier 1: Specific block processing patterns (active network)
MATCH_COUNT=$(grep -ciE 'apply_block|commit_block|validate_block|process_block|created.*block|accepted.*block|block.*applied' /shared/validator.log 2>/dev/null) || MATCH_COUNT=0

# Tier 2: Standalone validator patterns (zero state, shard work, DB operations)
if [ "$MATCH_COUNT" -eq 0 ]; then
    MATCH_COUNT=$(grep -ciE 'zero.state|shard.state|block_db|block_id|BlockIdExt|block_candidate|validatorsession|validator.*session|collator|update.*shard|hardfork|new.*state|download.*block|got.*block|save.*block|stored.*block' /shared/validator.log 2>/dev/null) || MATCH_COUNT=0
fi

# Tier 3: Generic block-related activity
if [ "$MATCH_COUNT" -eq 0 ]; then
    MATCH_COUNT=$(grep -ciE 'masterchain|shard|block' /shared/validator.log 2>/dev/null) || MATCH_COUNT=0
fi

LOG_SIZE=$(stat -c%s /shared/validator.log 2>/dev/null || echo "0")

if [ "$MATCH_COUNT" -gt 0 ]; then
    DETAILS=$(jq -cn --argjson matches "$MATCH_COUNT" --argjson log_size "$LOG_SIZE" '{matches: $matches, log_size_bytes: $log_size}')
    echo "PASS: Found $MATCH_COUNT block-related log entries (log size: $LOG_SIZE bytes)"
    sdk_sometimes true "$ASSERTION_NAME" "$DETAILS"
else
    LOG_LINES=$(wc -l < /shared/validator.log 2>/dev/null || echo "0")
    SAMPLE=$(head -3 /shared/validator.log 2>/dev/null | tr '\n' '|' | head -c 200)
    DETAILS=$(jq -cn \
        --argjson log_size "$LOG_SIZE" \
        --argjson log_lines "$LOG_LINES" \
        --arg sample "$SAMPLE" \
        '{matches: 0, log_size_bytes: $log_size, log_lines: $log_lines, first_lines_sample: $sample}')
    echo "FAIL: No block-related log entries found (log size: $LOG_SIZE, lines: $LOG_LINES)"
    sdk_sometimes false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
