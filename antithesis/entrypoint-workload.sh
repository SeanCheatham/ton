#!/usr/bin/env bash
set -euo pipefail

# Entrypoint for the workload container.
# Waits for the validator to be ready, then emits setup_complete and sleeps.
# Test Composer will run test commands from /opt/antithesis/test/v1/ton/.

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"

echo "Workload container starting..."
echo "Waiting for validator to be reachable..."

# Bounded wait — up to 120 seconds for the validator to come up
for i in $(seq 1 60); do
    if nc -z -u "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null; then
        echo "Validator is reachable on UDP port ${VALIDATOR_PORT}"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "Warning: validator not reachable after 120s, continuing anyway"
    fi
    sleep 2
done

# Catalog SDK assertions before signaling setup complete
source /opt/antithesis/test/v1/ton/helper_sdk.sh
sdk_catalog_always "Validator subsystem consistency: all ports reachable together"
echo "Assertion catalog emitted."

# Signal that setup is complete
/usr/local/bin/setup-complete.sh

echo "Setup complete. Sleeping to allow Test Composer to run commands..."
exec sleep infinity
