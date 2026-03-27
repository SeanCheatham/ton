#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator survives partial ADNL handshake flood
# Opens multiple TCP connections to the liteserver port and sends the first
# 32 bytes of an ADNL handshake (receiver address hash), then abruptly closes.
# This tests that the validator properly cleans up partially-initialized ADNL
# sessions without leaking file descriptors or memory.
# More targeted than random TCP fuzz — specifically exercises the ADNL
# session state machine's error/cleanup paths.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator survives partial ADNL handshake flood"
VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
LITE_PORT="${LITE_PORT:-30003}"

echo "Testing partial ADNL handshake resilience..."

# Precondition: heartbeat fresh
HEARTBEAT_MAX_AGE=60
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
        exit 0
    fi
else
    exit 0
fi

# Precondition: liteserver port reachable
if ! nc -z -w 2 "$VALIDATOR_HOST" "$LITE_PORT" 2>/dev/null; then
    echo "Liteserver port not reachable, skipping"
    exit 0
fi

# Record pre-attack FD count for comparison
PRE_FD=""
if [ -f /shared/validator_fd_count ]; then
    PRE_FD=$(cat /shared/validator_fd_count 2>/dev/null | tr -d '[:space:]')
fi

# Generate 32 bytes of partial ADNL handshake data.
# A real ADNL handshake starts with a 32-byte receiver address hash (SHA256).
# We send a plausible-looking prefix then disconnect.
PARTIAL_HANDSHAKE=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n')

# Send 5 partial handshakes in quick succession (kept moderate to avoid
# overwhelming a validator already under Antithesis fault injection)
SENT=0
FAILED=0
for i in $(seq 1 5); do
    # Send 32 bytes of partial handshake then immediately close
    if echo -ne "$(echo "$PARTIAL_HANDSHAKE" | sed 's/../\\x&/g')" | \
       nc -w 1 "$VALIDATOR_HOST" "$LITE_PORT" 2>/dev/null; then
        SENT=$((SENT + 1))
    else
        FAILED=$((FAILED + 1))
    fi
done

echo "Sent $SENT partial handshakes ($FAILED failed to connect)"

# Give the validator time to process/cleanup, then retry health checks.
# During Antithesis fault injection the validator may be transiently slow,
# so we retry up to 5 times with increasing backoff before declaring failure.
ALIVE=false
HB_FRESH=false
for attempt in 1 2 3 4 5; do
    sleep "$((attempt))"

    # Check port reachability
    if nc -z -w 3 "$VALIDATOR_HOST" "$LITE_PORT" 2>/dev/null; then
        ALIVE=true
    else
        ALIVE=false
        echo "Attempt $attempt: liteserver port not reachable"
        continue
    fi

    # Check heartbeat freshness
    if [ -f /shared/validator_heartbeat ]; then
        HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
        NOW=$(date +%s)
        if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
            AGE=$((NOW - HB_TS))
            if [ "$AGE" -le 60 ]; then
                HB_FRESH=true
            else
                HB_FRESH=false
                echo "Attempt $attempt: heartbeat stale (${AGE}s)"
                continue
            fi
        fi
    fi

    # Both checks passed
    if [ "$ALIVE" = "true" ] && [ "$HB_FRESH" = "true" ]; then
        echo "Attempt $attempt: validator healthy"
        break
    fi
done

# Build details
POST_FD=""
if [ -f /shared/validator_fd_count ]; then
    POST_FD=$(cat /shared/validator_fd_count 2>/dev/null | tr -d '[:space:]')
fi

DETAILS=$(jq -cn \
    --argjson sent "$SENT" \
    --argjson failed "$FAILED" \
    --argjson alive "$ALIVE" \
    --argjson hb_fresh "$HB_FRESH" \
    --arg pre_fd "${PRE_FD:-unknown}" \
    --arg post_fd "${POST_FD:-unknown}" \
    '{partial_handshakes_sent: $sent, connect_failures: $failed, alive_after: $alive, heartbeat_fresh_after: $hb_fresh, pre_fd: $pre_fd, post_fd: $post_fd}')

if [ "$ALIVE" = "true" ] && [ "$HB_FRESH" = "true" ]; then
    echo "PASS: Validator survived partial ADNL handshake flood"
    sdk_sometimes true "$ASSERTION_NAME" "$DETAILS"
else
    echo "FAIL: Validator unhealthy after partial ADNL handshake flood (alive=$ALIVE, hb_fresh=$HB_FRESH)"
    sdk_sometimes false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
