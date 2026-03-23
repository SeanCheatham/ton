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

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Validator metric files are all fresh when healthy"

echo "Checking validator metric file freshness consistency..."

# Check all 3 ports — only assert when validator is fully healthy
udp_up=false
console_up=false
lite_up=false

nc -z -u -w 2 "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null && udp_up=true
nc -z -w 1 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null && console_up=true
nc -z -w 1 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "SKIP: not all ports are up (udp=${udp_up}, console=${console_up}, lite=${lite_up})"
    sleep 10
    exit 0
fi

# Check heartbeat freshness
if [ ! -f /shared/validator_heartbeat ]; then
    echo "Heartbeat file not present yet, skipping"
    sleep 10
    exit 0
fi

HB=$(cat /shared/validator_heartbeat 2>/dev/null || echo "0")
NOW=$(date +%s)
AGE=$(( NOW - HB ))
if [ "$AGE" -gt 30 ]; then
    echo "Heartbeat stale (${AGE}s old), skipping"
    sleep 10
    exit 0
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
