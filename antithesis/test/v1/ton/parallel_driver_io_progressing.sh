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

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Validator disk I/O bytes are progressing when healthy"
STATE_FILE="/shared/_prev_io_bytes"

echo "Checking validator disk I/O progress..."

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

# Read I/O bytes from shared volume
if [ ! -f /shared/validator_io_bytes ]; then
    echo "I/O bytes file not present yet, skipping"
    sleep 10
    exit 0
fi

CURRENT=$(cat /shared/validator_io_bytes 2>/dev/null | tr -d '[:space:]')

if [ -z "$CURRENT" ] || ! [[ "$CURRENT" =~ ^-?[0-9]+$ ]]; then
    echo "Invalid I/O bytes value: '$CURRENT', skipping"
    sleep 10
    exit 0
fi

if [ "$CURRENT" -lt 0 ]; then
    echo "I/O bytes unavailable ($CURRENT), skipping"
    sleep 10
    exit 0
fi

PREV=$(cat "$STATE_FILE" 2>/dev/null || echo "")
echo "$CURRENT" > "$STATE_FILE"

if [ -z "$PREV" ]; then
    echo "First observation: ${CURRENT} bytes, storing baseline"
    sleep 10
    exit 0
fi

if ! [[ "$PREV" =~ ^[0-9]+$ ]]; then
    echo "Invalid previous value: '$PREV', resetting baseline"
    sleep 10
    exit 0
fi

if [ "$CURRENT" -gt "$PREV" ]; then
    DELTA=$((CURRENT - PREV))
    DETAILS=$(jq -cn --argjson cur "$CURRENT" --argjson prev "$PREV" --argjson delta "$DELTA" \
        '{current_bytes: $cur, prev_bytes: $prev, delta_bytes: $delta}')
    echo "PASS: I/O bytes progressing (delta: ${DELTA})"
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
elif [ "$CURRENT" -eq "$PREV" ]; then
    DETAILS=$(jq -cn --argjson cur "$CURRENT" --argjson prev "$PREV" \
        '{current_bytes: $cur, prev_bytes: $prev, delta_bytes: 0, status: "stalled"}')
    echo "FAIL: I/O bytes stalled at ${CURRENT}"
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
else
    # CURRENT < PREV indicates process restart (counters reset) or file-read race.
    # Reset baseline rather than failing.
    echo "I/O bytes decreased (prev=${PREV}, cur=${CURRENT}) — likely process restart, resetting baseline"
    sleep 10
    exit 0
fi

sleep 10
exit 0
