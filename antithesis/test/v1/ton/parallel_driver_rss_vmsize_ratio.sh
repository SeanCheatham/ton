#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: RSS-to-VmSize ratio is bounded when validator is healthy
# Detects memory fragmentation where virtual address space (VmSize) grows much
# faster than physical memory (VmRSS). A process with 500MB RSS but 8GB VmSize
# is severely fragmented and heading for allocation failures.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="RSS-to-VmSize ratio is bounded when validator is healthy"
HEARTBEAT_MAX_AGE=60
RATIO_THRESHOLD=10

# Heartbeat precondition
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s > ${HEARTBEAT_MAX_AGE}s), skipping"
            sdk_always true "$ASSERTION_NAME" '{"status":"heartbeat_stale"}'
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"
        sdk_always true "$ASSERTION_NAME" '{"status":"heartbeat_invalid"}'
        exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"heartbeat_not_present"}'
    exit 0
fi

# Read RSS and VmSize
RSS_KB=$(cat /shared/validator_mem_rss 2>/dev/null | tr -d '[:space:]')
VMSIZE_KB=$(cat /shared/validator_vmsize 2>/dev/null | tr -d '[:space:]')

# Skip if not yet populated
if [ -z "$RSS_KB" ] || [ "$RSS_KB" = "-1" ] || ! [[ "$RSS_KB" =~ ^[0-9]+$ ]] || [ "$RSS_KB" -le 0 ]; then
    echo "RSS not available yet (value='${RSS_KB:-}'), skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"rss_not_available"}'
    exit 0
fi

if [ -z "$VMSIZE_KB" ] || [ "$VMSIZE_KB" = "-1" ] || ! [[ "$VMSIZE_KB" =~ ^[0-9]+$ ]] || [ "$VMSIZE_KB" -le 0 ]; then
    echo "VmSize not available yet (value='${VMSIZE_KB:-}'), skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"vmsize_not_available"}'
    exit 0
fi

# Compute ratio (integer arithmetic: multiply by 100 for 2 decimal places)
RATIO_X100=$((VMSIZE_KB * 100 / RSS_KB))
RATIO_INT=$((VMSIZE_KB / RSS_KB))

echo "VmSize=${VMSIZE_KB}KB, RSS=${RSS_KB}KB, ratio=${RATIO_X100}/100 (threshold=${RATIO_THRESHOLD})"

DETAILS=$(jq -cn \
    --argjson vmsize_kb "$VMSIZE_KB" \
    --argjson rss_kb "$RSS_KB" \
    --argjson ratio "$RATIO_INT" \
    --argjson ratio_x100 "$RATIO_X100" \
    --argjson threshold "$RATIO_THRESHOLD" \
    '{vmsize_kb: $vmsize_kb, rss_kb: $rss_kb, ratio: $ratio, ratio_x100: $ratio_x100, threshold: $threshold}')

if [ "$RATIO_INT" -lt "$RATIO_THRESHOLD" ]; then
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: VmSize/RSS ratio ${RATIO_INT} exceeds threshold ${RATIO_THRESHOLD}"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
