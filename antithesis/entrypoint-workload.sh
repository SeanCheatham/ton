#!/usr/bin/env bash
set -euo pipefail

# Entrypoint for the workload container.
# Waits for the validator to be ready, then emits setup_complete and sleeps.
# Test Composer will run test commands from /opt/antithesis/test/v1/ton/.

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"

CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

echo "Workload container starting..."
echo "Waiting for validator to be reachable..."

# Bounded wait — up to 120 seconds for the validator UDP port to come up
for i in $(seq 1 60); do
    if nc -z -u "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null; then
        echo "Validator is reachable on UDP port ${VALIDATOR_PORT}"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "Warning: validator UDP not reachable after 120s, continuing anyway"
    fi
    sleep 2
done

# Wait for TCP subsystem ports (liteserver and console) to come up
echo "Waiting for validator TCP subsystem ports..."
for i in $(seq 1 30); do
    console_up=false
    lite_up=false
    nc -z -w 1 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null && console_up=true
    nc -z -w 1 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null && lite_up=true
    if [[ "$console_up" == "true" && "$lite_up" == "true" ]]; then
        echo "Console (${CONSOLE_PORT}) and liteserver (${LITE_PORT}) TCP ports are up"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "Warning: TCP subsystem ports not all reachable after 60s, continuing anyway"
        echo "  Console ${CONSOLE_PORT}: ${console_up}, Liteserver ${LITE_PORT}: ${lite_up}"
    fi
    sleep 2
done

# Catalog SDK assertions before signaling setup complete
source /opt/antithesis/test/v1/ton/helper_sdk.sh
sdk_catalog_always "Validator subsystem consistency: all ports reachable together"
sdk_catalog_sometimes "Validator recovers fully after fault injection"
sdk_catalog_sometimes "Validator recovers mid-test after going down"
sdk_catalog_sometimes "Validator is alive during parallel driver phase"
sdk_catalog_always "Validator heartbeat is fresh when ports are reachable"
sdk_catalog_always "Validator downtime is bounded after initial startup"
sdk_catalog_always "Console port accepts and holds TCP connection"
sdk_catalog_always "Validator does not crash-loop or oscillate rapidly"
echo "Assertion catalog emitted."

# Signal that setup is complete
/usr/local/bin/setup-complete.sh

echo "Setup complete. Sleeping to allow Test Composer to run commands..."
exec sleep infinity
