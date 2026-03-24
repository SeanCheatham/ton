#!/usr/bin/env bash

# Parallel driver: RocksDB compaction has occurred when validator is mature
# A "sometimes" assertion: we don't expect compaction every moment, but over a test's
# lifetime at least one compaction event should occur.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="RocksDB compaction has occurred when validator is mature"

# Heartbeat-only precondition
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s > ${HEARTBEAT_MAX_AGE}s), skipping"
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"; exit 0
fi

if [ ! -f /shared/validator_compaction_count ]; then
    echo "Compaction count file not present yet, skipping"
    exit 0
fi

COMPACTION_COUNT=$(cat /shared/validator_compaction_count 2>/dev/null | tr -d '[:space:]')

if ! [[ "$COMPACTION_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid compaction count value: ${COMPACTION_COUNT}, skipping"
    exit 0
fi

DETAILS=$(jq -cn --argjson count "$COMPACTION_COUNT" '{compaction_events: $count}')

if [ "$COMPACTION_COUNT" -gt 0 ]; then
    echo "PASS: RocksDB compaction observed (${COMPACTION_COUNT} events)"
    sdk_sometimes true "$ASSERTION_NAME" "$DETAILS"
else
    echo "No compaction events observed yet (count=0)"
    sdk_sometimes false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
