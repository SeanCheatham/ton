#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator metric files are all fresh when healthy
# Meta-infrastructure consistency property. When the validator is healthy,
# ALL /shared/validator_* metric files should have modification times within
# 30 seconds of each other. Catches partial heartbeat loop failures where
# slow operations (e.g., du -sb) block the loop, causing downstream metrics
# to go stale while the heartbeat itself stays fresh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator metric files are all fresh when healthy"

echo "Checking validator metric file freshness consistency..."

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

# Collect mtimes of all validator_* metric files
MIN_MTIME=999999999999
MAX_MTIME=0
FILE_COUNT=0
OLDEST_FILE=""
NEWEST_FILE=""

for f in /shared/validator_*; do
    [ -f "$f" ] || continue
    MTIME=$(stat -c %Y "$f" 2>/dev/null || continue)
    FILE_COUNT=$((FILE_COUNT + 1))
    if [ "$MTIME" -lt "$MIN_MTIME" ]; then
        MIN_MTIME=$MTIME
        OLDEST_FILE=$(basename "$f")
    fi
    if [ "$MTIME" -gt "$MAX_MTIME" ]; then
        MAX_MTIME=$MTIME
        NEWEST_FILE=$(basename "$f")
    fi
done

if [ "$FILE_COUNT" -lt 2 ]; then
    echo "SKIP: fewer than 2 metric files found (${FILE_COUNT})"
    sleep 10
    exit 0
fi

SPREAD=$((MAX_MTIME - MIN_MTIME))
THRESHOLD=30

if [ "$SPREAD" -le "$THRESHOLD" ]; then
    echo "PASS: Metric file mtime spread is ${SPREAD}s across ${FILE_COUNT} files (threshold: ${THRESHOLD}s)"
    DETAILS=$(jq -cn --argjson spread "$SPREAD" --argjson threshold "$THRESHOLD" \
        --argjson file_count "$FILE_COUNT" --arg oldest "$OLDEST_FILE" --arg newest "$NEWEST_FILE" \
        '{mtime_spread_seconds: $spread, threshold: $threshold, file_count: $file_count, oldest_file: $oldest, newest_file: $newest}')
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: Metric file mtime spread is ${SPREAD}s (threshold: ${THRESHOLD}s), oldest=${OLDEST_FILE}, newest=${NEWEST_FILE}"
    DETAILS=$(jq -cn --argjson spread "$SPREAD" --argjson threshold "$THRESHOLD" \
        --argjson file_count "$FILE_COUNT" --arg oldest "$OLDEST_FILE" --arg newest "$NEWEST_FILE" \
        '{mtime_spread_seconds: $spread, threshold: $threshold, file_count: $file_count, oldest_file: $oldest, newest_file: $newest}')
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
