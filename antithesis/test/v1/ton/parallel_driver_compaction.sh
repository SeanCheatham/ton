#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: RocksDB compaction has occurred when validator is mature
# Reads /shared/validator_compaction_count (written by validator entrypoint heartbeat loop).
# RocksDB must periodically compact SST files to reclaim space and maintain performance.
# A "sometimes" assertion: we don't expect compaction every moment, but over a test's
# lifetime at least one compaction event should occur.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="RocksDB compaction has occurred when validator is mature"

# Heartbeat-only precondition: heartbeat freshness proves the validator process
# is actively running and metrics are valid, regardless of port status.
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s > ${HEARTBEAT_MAX_AGE}s), skipping"
            sleep 5; exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"; sleep 5; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"; sleep 5; exit 0
fi

if [ ! -f /shared/validator_compaction_count ]; then
    echo "Compaction count file not present yet, skipping"
    sleep 10
    exit 0
fi

COMPACTION_COUNT=$(cat /shared/validator_compaction_count 2>/dev/null || echo "0")

if ! [[ "$COMPACTION_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid compaction count value: ${COMPACTION_COUNT}, skipping"
    sleep 10
    exit 0
fi

DETAILS=$(jq -cn --argjson count "$COMPACTION_COUNT" '{compaction_events: $count}')

if [ "$COMPACTION_COUNT" -gt 0 ]; then
    echo "PASS: RocksDB compaction observed (${COMPACTION_COUNT} events)"
    sdk_sometimes true "$ASSERTION_NAME" "$DETAILS"
else
    echo "No compaction events observed yet (count=0), waiting"
fi

sleep 10
exit 0
