#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator network bytes are increasing when healthy
# Strengthens the "sometimes non-zero" net bytes check to verify bytes are
# ACTIVELY increasing when healthy. If net_bytes hasn't increased in 2
# consecutive checks (~20s), emits always(false). A validator with ports up
# but zero new traffic is functionally isolated.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
PROPERTY="Validator network bytes are increasing when healthy"
HISTORY_FILE="/shared/_prev_net_bytes"

# Heartbeat precondition: validator process must be alive
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s), skipping"
            exit 0
        fi
    else
        echo "Heartbeat invalid, skipping"; exit 0
    fi
else
    echo "Heartbeat not present, skipping"; exit 0
fi

# Check if validator is healthy
udp_up=false; console_up=false; lite_up=false
nc -z -w 1 -u "$VALIDATOR_HOST" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30002 2>/dev/null && console_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "Validator not fully healthy, skipping network bytes check"
    exit 0
fi

# Read current net bytes
CURRENT=$(cat /shared/validator_net_bytes 2>/dev/null || echo "-1")
if [[ "$CURRENT" == "-1" || -z "$CURRENT" ]]; then
    echo "Net bytes unavailable, skipping"
    exit 0
fi

if ! [[ "$CURRENT" =~ ^[0-9]+$ ]]; then
    echo "Invalid net bytes value: $CURRENT, skipping"
    exit 0
fi

# Append current value to history, keep last 3 lines
echo "$CURRENT" >> "$HISTORY_FILE"
tail -3 "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"

# Read history
LINES=$(wc -l < "$HISTORY_FILE")

if [ "$LINES" -lt 3 ]; then
    echo "Not enough history yet ($LINES observations), skipping"
    exit 0
fi

# Read the last 3 values (2 previous + current)
VAL1=$(sed -n '1p' "$HISTORY_FILE")
VAL2=$(sed -n '2p' "$HISTORY_FILE")
VAL3=$(sed -n '3p' "$HISTORY_FILE")

DETAILS=$(jq -cn \
    --argjson v1 "$VAL1" \
    --argjson v2 "$VAL2" \
    --argjson v3 "$VAL3" \
    '{reading_oldest: $v1, reading_middle: $v2, reading_newest: $v3}')

# If all 3 readings are the same, network has been stalled for ~20+ seconds
if [ "$VAL1" = "$VAL2" ] && [ "$VAL2" = "$VAL3" ]; then
    echo "FAIL: network bytes stalled at $CURRENT for 3 consecutive checks"
    sdk_always false "$PROPERTY" "$DETAILS"
else
    echo "PASS: network bytes are increasing"
    sdk_always true "$PROPERTY" "$DETAILS"
fi

exit 0
