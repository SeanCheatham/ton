#!/bin/bash
set -euo pipefail

# Checks that when the validator is healthy, it has at least 3 threads.
# A validator with fewer threads is in a degraded state (missing workers).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
MIN_THREADS=3

# Check heartbeat freshness
HEARTBEAT_FILE="/shared/validator_heartbeat"
if [[ ! -f "$HEARTBEAT_FILE" ]]; then
    echo "No heartbeat file yet, skipping"
    exit 0
fi

HEARTBEAT_TS=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo "0")
NOW=$(date +%s)
AGE=$(( NOW - HEARTBEAT_TS ))
if (( AGE > 30 )); then
    echo "Heartbeat stale (${AGE}s old), skipping"
    exit 0
fi

# Check all 3 ports reachable
udp_up=false
console_up=false
lite_up=false
nc -z -w 1 -u "${VALIDATOR_HOST}" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "${VALIDATOR_HOST}" 30002 2>/dev/null && console_up=true
nc -z -w 1 "${VALIDATOR_HOST}" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "Validator not fully healthy, skipping assertion"
    sleep 10
    exit 0
fi

# Read thread count
THREAD_FILE="/shared/validator_thread_count"
if [[ ! -f "$THREAD_FILE" ]]; then
    echo "No thread count file yet, skipping"
    exit 0
fi

THREADS=$(cat "$THREAD_FILE" 2>/dev/null || echo "0")
if ! [[ "$THREADS" =~ ^[0-9]+$ ]]; then
    echo "Invalid thread count: ${THREADS}, skipping"
    exit 0
fi

if (( THREADS >= MIN_THREADS )); then
    sdk_always true "Validator thread count meets minimum when healthy" \
        "{\"thread_count\":${THREADS},\"min_threads\":${MIN_THREADS}}"
else
    sdk_always false "Validator thread count meets minimum when healthy" \
        "{\"thread_count\":${THREADS},\"min_threads\":${MIN_THREADS}}"
fi

exit 0
