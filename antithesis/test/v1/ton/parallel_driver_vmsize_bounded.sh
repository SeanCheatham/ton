#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator virtual memory size is bounded
# Reads /shared/validator_vmsize (written by validator entrypoint heartbeat loop)
# and asserts VmSize stays below 8GB (8388608 KB). Catches virtual address space
# leaks (mmap leaks, unbounded anonymous mappings, address space fragmentation)
# that are invisible to existing RSS and VmPeak checks.

source "$(dirname "$0")/helper_sdk.sh"

VMSIZE_LIMIT=8388608  # 8GB in KB

# Skip if heartbeat is stale (process not actively running)
if [ ! -f /shared/validator_heartbeat ]; then
    echo "Heartbeat file not present yet, skipping"
    sleep 10
    exit 0
fi

NOW=$(date +%s)
HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || echo "0")
if ! [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
    echo "Invalid heartbeat value, skipping"
    sleep 10
    exit 0
fi

HB_AGE=$((NOW - HB_TS))
if [ "$HB_AGE" -gt 90 ]; then
    echo "Heartbeat stale (${HB_AGE}s old), skipping"
    sleep 10
    exit 0
fi

# Read VmSize
if [ ! -f /shared/validator_vmsize ]; then
    echo "VmSize file not present yet, skipping"
    sleep 10
    exit 0
fi

VMSIZE_KB=$(cat /shared/validator_vmsize 2>/dev/null || echo "-1")

if ! [[ "$VMSIZE_KB" =~ ^-?[0-9]+$ ]]; then
    echo "Invalid VmSize value: $VMSIZE_KB, skipping"
    sleep 10
    exit 0
fi

if [ "$VMSIZE_KB" -eq -1 ]; then
    echo "VmSize not yet available, skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson vmsize "$VMSIZE_KB" --argjson limit "$VMSIZE_LIMIT" \
    '{vmsize_kb: $vmsize, vmsize_mb: ($vmsize / 1024 | floor), limit_kb: $limit, limit_gb: ($limit / 1048576)}')

if [ "$VMSIZE_KB" -lt "$VMSIZE_LIMIT" ]; then
    sdk_always true "Validator virtual memory size is bounded" "$DETAILS"
else
    sdk_always false "Validator virtual memory size is bounded" "$DETAILS"
fi

sleep 10
exit 0
