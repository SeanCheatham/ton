#!/usr/bin/env bash

# Parallel driver: Validator process is single-threaded-leader stable
# PID 1 inside the validator container must always be the validator-engine process.
# Catches bugs where the entrypoint's background heartbeat subshell outlives the
# main process, or where the validator crashes and is replaced by an unrelated process.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator process is single-threaded-leader stable"
HEARTBEAT_MAX_AGE=60

# Precondition: heartbeat must be fresh
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s), skipping"
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"; exit 0
fi

# Read PID 1 comm from shared metric (written by validator heartbeat loop)
if [ ! -f /shared/validator_pid1_comm ]; then
    echo "PID1 comm file not available yet, skipping"
    exit 0
fi

PID1_COMM=$(cat /shared/validator_pid1_comm 2>/dev/null | tr -d '[:space:]')

if [ -z "$PID1_COMM" ]; then
    echo "PID1 comm is empty, skipping"
    exit 0
fi

# validator-engine gets truncated to 15 chars: "validator-engi" in /proc/1/comm
# Match both the full name and the truncated version
MATCHES=false
case "$PID1_COMM" in
    validator-engi*) MATCHES=true ;;
    validator-engine*) MATCHES=true ;;
esac

DETAILS=$(jq -cn \
    --arg comm "$PID1_COMM" \
    --argjson matches "$MATCHES" \
    '{pid1_comm: $comm, is_validator_engine: $matches}')

if [ "$MATCHES" = "true" ]; then
    echo "PASS: PID 1 is validator-engine (comm=$PID1_COMM)"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: PID 1 is NOT validator-engine (comm=$PID1_COMM)"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
