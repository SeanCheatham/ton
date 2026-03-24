#!/usr/bin/env bash

# Parallel driver: Validator survives concurrent lite-client queries
# Launches multiple simultaneous lite-client connections to stress-test
# the liteserver's concurrent connection handling.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
LITE_PORT="${LITE_PORT:-30003}"
ASSERTION_NAME="Validator survives concurrent lite-client queries"
HEARTBEAT_MAX_AGE=60
CONCURRENT=3

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

# Precondition: liteserver port must be reachable
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    echo "Liteserver port ${LITE_PORT} not reachable, skipping"
    exit 0
fi

# Precondition: liteserver config must exist
if [ ! -f /shared/liteserver.config.json ]; then
    echo "Liteserver config not available yet, skipping"
    exit 0
fi

# Precondition: lite-client binary must exist
if ! command -v lite-client >/dev/null 2>&1; then
    echo "lite-client binary not found, skipping"
    exit 0
fi

# Resolve validator hostname to IP
VALIDATOR_IP=""
if command -v getent >/dev/null 2>&1; then
    VALIDATOR_IP=$(getent hosts "${VALIDATOR_HOST}" 2>/dev/null | awk '{print $1; exit}')
fi
if [ -z "$VALIDATOR_IP" ]; then
    VALIDATOR_IP=$(grep -m1 "${VALIDATOR_HOST}" /etc/hosts 2>/dev/null | awk '{print $1; exit}')
fi
if [ -z "$VALIDATOR_IP" ]; then
    VALIDATOR_IP="${VALIDATOR_HOST}"
fi

echo "Launching ${CONCURRENT} concurrent lite-client queries to ${VALIDATOR_IP}:${LITE_PORT}..."

# Launch concurrent lite-client processes
PIDS=()
for i in $(seq 1 "$CONCURRENT"); do
    timeout 15 lite-client \
        -v 0 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C /shared/liteserver.config.json \
        -c 'last' \
        -c 'quit' >/dev/null 2>&1 &
    PIDS+=($!)
done

# Wait for all to complete, collect exit codes
FAILURES=0
for pid in "${PIDS[@]}"; do
    if ! wait "$pid" 2>/dev/null; then
        FAILURES=$((FAILURES + 1))
    fi
done

echo "Concurrent queries complete: ${FAILURES}/${CONCURRENT} failed"

# After concurrent stress, check validator is still alive
sleep 1
STILL_UP=false
if nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    STILL_UP=true
fi

HB_FRESH=false
if [ -f /shared/validator_heartbeat ]; then
    HB_TS2=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW2=$(date +%s)
    if [[ "$HB_TS2" =~ ^[0-9]+$ ]]; then
        AGE2=$((NOW2 - HB_TS2))
        if [ "$AGE2" -le "$HEARTBEAT_MAX_AGE" ]; then
            HB_FRESH=true
        fi
    fi
fi

DETAILS=$(jq -cn \
    --argjson concurrent "$CONCURRENT" \
    --argjson failures "$FAILURES" \
    --argjson port_up "$STILL_UP" \
    --argjson hb_fresh "$HB_FRESH" \
    '{concurrent_queries: $concurrent, failures: $failures, port_still_up: $port_up, heartbeat_still_fresh: $hb_fresh}')

if [ "$STILL_UP" = "true" ] && [ "$HB_FRESH" = "true" ]; then
    echo "PASS: Validator survived ${CONCURRENT} concurrent lite-client queries"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Validator unhealthy after concurrent lite-client queries (port_up=${STILL_UP}, hb_fresh=${HB_FRESH})"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
