#!/usr/bin/env bash
set -euo pipefail

# Driver workload: verify memory mapping count is bounded.
# When the validator heartbeat is fresh, the number of memory mappings
# (/proc/1/maps lines) must be below 10000. An unbounded growth indicates
# mmap leaks, arena fragmentation, or RocksDB SST file handle leaks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator memory mapping count is bounded when healthy"
sdk_catalog_always "$ASSERTION_NAME"

# Check heartbeat freshness (within 30s)
NOW=$(date +%s)
if [[ -f /shared/validator_heartbeat ]]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || echo "0")
    if [[ "$HB_TS" =~ ^[0-9]+$ ]] && [ "$HB_TS" -gt 0 ]; then
        HB_AGE=$((NOW - HB_TS))
    else
        HB_AGE=999
    fi
else
    HB_AGE=999
fi

if [ "$HB_AGE" -gt 30 ]; then
    echo "Heartbeat stale (${HB_AGE}s), skipping mmap check"
    exit 0
fi

# Count memory mappings
MAP_COUNT=$(wc -l < /proc/1/maps 2>/dev/null || echo "0")

if [ "$MAP_COUNT" -eq 0 ]; then
    echo "Could not read /proc/1/maps, skipping"
    exit 0
fi

echo "Memory mapping count: ${MAP_COUNT}"

details=$(jq -cn \
    --argjson map_count "$MAP_COUNT" \
    --argjson hb_age "$HB_AGE" \
    '{map_count: $map_count, heartbeat_age_s: $hb_age, threshold: 10000}')

if [ "$MAP_COUNT" -lt 10000 ]; then
    sdk_always true "$ASSERTION_NAME" "$details"
else
    echo "WARNING: Memory mapping count ${MAP_COUNT} exceeds threshold 10000"
    sdk_always false "$ASSERTION_NAME" "$details"
fi

exit 0
