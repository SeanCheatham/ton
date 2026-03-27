#!/usr/bin/env bash

# Parallel driver: Validator log output is valid UTF-8
# Samples the tail of the validator log and checks for invalid UTF-8 sequences.
# Invalid encoding indicates potential memory corruption or buffer overflows.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator log output is valid UTF-8"
LOG_FILE="/shared/validator.log"
HEARTBEAT_MAX_AGE=60
SAMPLE_LINES=1000

# Precondition: heartbeat must be fresh
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
        echo "Heartbeat value invalid, skipping"; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"; exit 0
fi

# Precondition: log file must exist with content
if [ ! -f "$LOG_FILE" ]; then
    echo "Log file not present yet, skipping"
    exit 0
fi

LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo "0")
if [ "$LOG_SIZE" -lt 100 ]; then
    echo "Log file too small (${LOG_SIZE} bytes), skipping"
    exit 0
fi

# Sample the tail of the log and check for invalid UTF-8
# Use iconv to attempt conversion — invalid sequences cause errors
SAMPLE=$(tail -n "$SAMPLE_LINES" "$LOG_FILE" 2>/dev/null || true)

if [ -z "$SAMPLE" ]; then
    echo "Empty sample from log tail, skipping"
    exit 0
fi

# Count invalid UTF-8 bytes by attempting iconv conversion
# iconv -f UTF-8 -t UTF-8 will fail on invalid sequences
# We use -c to skip invalid chars and compare lengths
ORIGINAL_LEN=${#SAMPLE}
CLEANED=$(echo "$SAMPLE" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || true)
CLEANED_LEN=${#CLEANED}

INVALID_CHARS=$((ORIGINAL_LEN - CLEANED_LEN))

DETAILS=$(jq -cn \
    --argjson sample_lines "$SAMPLE_LINES" \
    --argjson original_len "$ORIGINAL_LEN" \
    --argjson cleaned_len "$CLEANED_LEN" \
    --argjson invalid_chars "$INVALID_CHARS" \
    --argjson log_size "$LOG_SIZE" \
    '{sample_lines: $sample_lines, original_length: $original_len, cleaned_length: $cleaned_len, invalid_byte_diff: $invalid_chars, log_size_bytes: $log_size}')

# Allow a small tolerance (up to 5 bytes difference) for race conditions in file reads
if [ "$INVALID_CHARS" -le 5 ]; then
    echo "PASS: Validator log is valid UTF-8 (diff=${INVALID_CHARS} bytes)"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Validator log contains invalid UTF-8 (${INVALID_CHARS} bytes difference)"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
