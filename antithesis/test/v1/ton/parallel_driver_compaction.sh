#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: RocksDB compaction has occurred when validator is mature
# Reads /shared/validator_compaction_count (written by validator entrypoint heartbeat loop).
# RocksDB must periodically compact SST files to reclaim space and maintain performance.
# A "sometimes" assertion: we don't expect compaction every moment, but over a test's
# lifetime at least one compaction event should occur.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="RocksDB compaction has occurred when validator is mature"
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

# Only check when validator is healthy (all ports up)
if ! nc -z -w 1 -u "$VALIDATOR_HOST" "$VALIDATOR_PORT" 2>/dev/null; then
    echo "Validator UDP not reachable, skipping"
    sleep 10
    exit 0
fi
if ! nc -z -w 1 "$VALIDATOR_HOST" "$CONSOLE_PORT" 2>/dev/null || \
   ! nc -z -w 1 "$VALIDATOR_HOST" "$LITE_PORT" 2>/dev/null; then
    echo "Validator TCP ports not all reachable, skipping"
    sleep 10
    exit 0
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
