#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator disk I/O bytes are progressing when healthy
# Reads /shared/validator_io_bytes (written by validator entrypoint heartbeat loop)
# and asserts combined read_bytes + write_bytes increases between consecutive observations.
# A healthy validator constantly reads/writes RocksDB — stalled I/O indicates a hung
# process, blocked I/O scheduler, or filesystem deadlock. Complements I/O wait time
# (iter 17B) which checks latency, not throughput.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator disk I/O bytes are progressing when healthy"
STATE_FILE="/shared/_prev_io_bytes"
STALL_COUNT_FILE="/shared/_io_stall_count"
# Require 3 consecutive stalled observations before failing.
# During fault injection, Antithesis may pause the validator process or inject
# I/O faults, causing transient stalls that aren't real bugs.
MAX_CONSECUTIVE_STALLS=3

echo "Checking validator disk I/O progress..."

# Heartbeat-only precondition: heartbeat freshness proves the validator process
# is actively running and metrics are valid, regardless of port status.
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s > ${HEARTBEAT_MAX_AGE}s), skipping"
            sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"heartbeat_stale"}'
            sleep 5; exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"
        sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"heartbeat_invalid"}'
        sleep 5; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"heartbeat_missing"}'
    sleep 5; exit 0
fi

# Read I/O bytes from shared volume
if [ ! -f /shared/validator_io_bytes ]; then
    echo "I/O bytes file not present yet, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"io_file_missing"}'
    sleep 10
    exit 0
fi

CURRENT=$(cat /shared/validator_io_bytes 2>/dev/null || true)
CURRENT=$(echo "$CURRENT" | tr -d '[:space:]')

if [ -z "$CURRENT" ] || ! [[ "$CURRENT" =~ ^-?[0-9]+$ ]]; then
    echo "Invalid I/O bytes value: '$CURRENT', skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"invalid_value"}'
    sleep 10
    exit 0
fi

if [ "$CURRENT" -lt 0 ]; then
    echo "I/O bytes unavailable ($CURRENT), skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"io_unavailable"}'
    sleep 10
    exit 0
fi

PREV=$(cat "$STATE_FILE" 2>/dev/null || echo "")
echo "$CURRENT" > "$STATE_FILE"

if [ -z "$PREV" ]; then
    echo "First observation: ${CURRENT} bytes, storing baseline"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"first_observation"}'
    sleep 10
    exit 0
fi

if ! [[ "$PREV" =~ ^[0-9]+$ ]]; then
    echo "Invalid previous value: '$PREV', resetting baseline"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"invalid_previous"}'
    sleep 10
    exit 0
fi

if [ "$CURRENT" -gt "$PREV" ]; then
    DELTA=$((CURRENT - PREV))
    # Reset stall counter on progress
    echo "0" > "$STALL_COUNT_FILE"
    DETAILS=$(jq -cn --argjson cur "$CURRENT" --argjson prev "$PREV" --argjson delta "$DELTA" \
        '{current_bytes: $cur, prev_bytes: $prev, delta_bytes: $delta}')
    echo "PASS: I/O bytes progressing (delta: ${DELTA})"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
elif [ "$CURRENT" -eq "$PREV" ]; then
    # Track consecutive stalls — only fail after MAX_CONSECUTIVE_STALLS
    STALL_COUNT=$(cat "$STALL_COUNT_FILE" 2>/dev/null || echo "0")
    STALL_COUNT=$(( ${STALL_COUNT:-0} + 1 ))
    echo "$STALL_COUNT" > "$STALL_COUNT_FILE"
    DETAILS=$(jq -cn --argjson cur "$CURRENT" --argjson prev "$PREV" \
        --argjson stalls "$STALL_COUNT" --argjson max "$MAX_CONSECUTIVE_STALLS" \
        '{current_bytes: $cur, prev_bytes: $prev, delta_bytes: 0, consecutive_stalls: $stalls, max_stalls: $max}')
    if [ "$STALL_COUNT" -ge "$MAX_CONSECUTIVE_STALLS" ]; then
        echo "FAIL: I/O bytes stalled at ${CURRENT} for ${STALL_COUNT} consecutive checks"
        sdk_always false "${ASSERTION_NAME}" "$DETAILS"
    else
        echo "WARN: I/O bytes stalled at ${CURRENT} (${STALL_COUNT}/${MAX_CONSECUTIVE_STALLS}), tolerating"
        sdk_always true "${ASSERTION_NAME}" "$DETAILS"
    fi
else
    # CURRENT < PREV indicates process restart (counters reset) or file-read race.
    # Reset baseline rather than failing.
    echo "I/O bytes decreased (prev=${PREV}, cur=${CURRENT}) — likely process restart, resetting baseline"
    sdk_always true "$ASSERTION_NAME" '{"status":"skipped","reason":"counter_reset"}'
    sleep 10
    exit 0
fi

sleep 10
exit 0
