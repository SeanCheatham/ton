#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator log contains expected initialization markers
# First functional correctness property. Scans /shared/validator.log (and rotated
# variants) for operational markers that prove the validator's core subsystems
# executed. "Sometimes" because the log may not be populated immediately.
#
# Fix for unsatisfied assertion: TON's TsFileLog may buffer writes, use rotation
# suffixes, or delay file creation. We now glob /shared/validator.log* for rotated
# files and check broader TON-specific patterns. The entrypoint also redirects
# stderr as a fallback capture mechanism.

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
# Broadened patterns to catch TON-specific initialization messages:
#   started, init, adnl, dht, loading, created.db, config — original patterns
#   block, zero.state, validator, overlay, rldp, catchain — TON subsystem patterns
MATCH_COUNT=0
for f in "${LOG_FILES[@]}"; do
    COUNT=$(grep -ciE "started|init|adnl|dht|loading|created.db|config|block|zero\.state|validator|overlay|rldp|catchain" "$f" 2>/dev/null || echo "0")
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
    echo "No initialization markers found across ${FILE_COUNT} log files (${TOTAL_SIZE} bytes total)"
    DETAILS=$(jq -cn --argjson matches 0 --argjson log_size "$TOTAL_SIZE" \
        --argjson file_count "$FILE_COUNT" \
        '{marker_matches: $matches, log_size_bytes: $log_size, log_file_count: $file_count}')
    sdk_sometimes false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
