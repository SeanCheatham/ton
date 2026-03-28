#!/usr/bin/env bash

# First: Block until the liteserver is ready to accept queries.
# Runs before parallel drivers start, ensuring that the heartbeat file
# exists and lite-client can successfully connect. This fixes the timing
# gap where parallel_driver_liteclient_query.sh would silently skip
# because the heartbeat hadn't been written yet.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
LITE_PORT="${LITE_PORT:-30003}"
MAX_WAIT=90   # seconds — generous for genesis coordination
POLL=2        # seconds between retries

echo "Waiting for liteserver readiness (heartbeat + TCP port)..."

# Phase 1: Wait for the heartbeat file to appear.
# The validator's background loop writes this only after validator-engine
# is exec'd as PID 1, which can take 10-60s depending on genesis coordination.
elapsed=0
while [ "$elapsed" -lt "$MAX_WAIT" ]; do
    if [ -f /shared/validator_heartbeat ]; then
        HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
        if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
            echo "Heartbeat found after ${elapsed}s (ts=${HB_TS})"
            break
        fi
    fi
    sleep "$POLL"
    elapsed=$((elapsed + POLL))
done

if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    echo "WARNING: heartbeat not found after ${MAX_WAIT}s — parallel drivers may skip liteclient queries"
    exit 0
fi

# Phase 2: Wait for the liteserver TCP port to accept connections.
elapsed=0
while [ "$elapsed" -lt "$MAX_WAIT" ]; do
    if nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
        echo "Liteserver TCP port ${LITE_PORT} is reachable after ${elapsed}s"
        break
    fi
    sleep "$POLL"
    elapsed=$((elapsed + POLL))
done

if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    echo "WARNING: liteserver port not reachable after ${MAX_WAIT}s"
    exit 0
fi

# Phase 3: Wait for the liteserver config to be available.
elapsed=0
while [ "$elapsed" -lt "$MAX_WAIT" ]; do
    if [ -f /shared/liteserver.config.json ]; then
        echo "Liteserver config found after ${elapsed}s"
        break
    fi
    sleep "$POLL"
    elapsed=$((elapsed + POLL))
done

if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    echo "WARNING: liteserver config not found after ${MAX_WAIT}s"
    exit 0
fi

# Phase 4: Attempt an actual lite-client query to confirm end-to-end readiness.
# Resolve hostname to IP for lite-client.
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

if command -v lite-client >/dev/null 2>&1; then
    elapsed=0
    while [ "$elapsed" -lt 30 ]; do
        OUTPUT=$(timeout 10 lite-client \
            -v 1 \
            -a "${VALIDATOR_IP}:${LITE_PORT}" \
            -C /shared/liteserver.config.json \
            -c 'last' \
            -c 'quit' 2>&1) || true

        if [ -n "$OUTPUT" ]; then
            echo "Lite-client returned output after ${elapsed}s — liteserver is ready"
            echo "Output preview: ${OUTPUT:0:200}"
            break
        fi
        sleep "$POLL"
        elapsed=$((elapsed + POLL))
    done
else
    echo "WARNING: lite-client binary not found in workload container"
fi

echo "Liteserver readiness gate complete — parallel drivers may now query."
exit 0
