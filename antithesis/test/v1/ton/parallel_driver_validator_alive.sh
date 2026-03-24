#!/usr/bin/env bash

# Driver workload: verify the validator process is alive.
# Uses heartbeat-based liveness detection (more reliable than UDP nc -z probes
# which are notoriously unreliable in container environments).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator is alive during parallel driver phase"
HEARTBEAT_MAX_AGE=30

# Ensure catalog entry is emitted from within the driver script itself.
# The entrypoint also catalogs this, but emitting it here guarantees the
# assertion appears in snouty even if the entrypoint catalog was missed.
sdk_catalog_sometimes "$ASSERTION_NAME"

if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -le "$HEARTBEAT_MAX_AGE" ]; then
            echo "PASS: validator heartbeat is fresh (${AGE}s old)"
            sdk_sometimes true "$ASSERTION_NAME"
        else
            echo "FAIL: validator heartbeat is stale (${AGE}s > ${HEARTBEAT_MAX_AGE}s)"
            sdk_sometimes false "$ASSERTION_NAME"
        fi
    else
        echo "FAIL: validator heartbeat value invalid"
        sdk_sometimes false "$ASSERTION_NAME"
    fi
else
    echo "FAIL: validator heartbeat file not present"
    sdk_sometimes false "$ASSERTION_NAME"
fi

exit 0
