#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator log contains expected initialization markers
# First functional correctness property. Scans /shared/validator.log for operational
# markers that prove the validator's core subsystems (ADNL networking, DHT, database)
# executed. All previous properties check infrastructure health; this verifies the
# validator actually ran its protocol code. "Sometimes" because the log may not be
# populated immediately.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator log contains expected initialization markers"
LOG_FILE="/shared/validator.log"

echo "Checking validator log for initialization markers..."

# Check if log file exists and is non-empty
if [ ! -f "$LOG_FILE" ]; then
    echo "Log file not present yet, skipping"
    sleep 10
    exit 0
fi

if [ ! -s "$LOG_FILE" ]; then
    echo "Log file is empty, skipping"
    sleep 10
    exit 0
fi

# Search for operational initialization markers (case-insensitive)
MATCH_COUNT=$(grep -ciE "started|init|adnl|dht|loading|created.db|config" "$LOG_FILE" 2>/dev/null || echo "0")
LOG_SIZE=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo "0")

if [ "$MATCH_COUNT" -gt 0 ]; then
    echo "PASS: Found ${MATCH_COUNT} initialization marker matches in log"
    DETAILS=$(jq -cn --argjson matches "$MATCH_COUNT" --argjson log_size "$LOG_SIZE" \
        '{marker_matches: $matches, log_size_bytes: $log_size}')
    sdk_sometimes true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "No initialization markers found in log (${LOG_SIZE} bytes)"
    DETAILS=$(jq -cn --argjson matches 0 --argjson log_size "$LOG_SIZE" \
        '{marker_matches: $matches, log_size_bytes: $log_size}')
    sdk_sometimes false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
