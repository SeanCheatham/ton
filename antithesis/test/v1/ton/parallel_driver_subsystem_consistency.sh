#!/usr/bin/env bash
set -euo pipefail

# Driver workload: verify validator subsystem consistency.
# When the main UDP port (30001) is reachable, the console TCP port (30002) and
# liteserver TCP port (30003) must also be reachable. A violation means an
# internal subsystem crashed while the main process stayed up.
# Runs repeatedly in parallel during fault injection.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

# Catalog the assertion on first invocation
sdk_catalog_always "Validator subsystem consistency: all ports reachable together"

echo "Checking validator subsystem consistency..."

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

# Step 1: Check if the main UDP port is reachable.
# If it's down, the validator is fully down — skip the consistency check.
if ! nc -z -u -w 2 "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null; then
    echo "SKIP: validator UDP port ${UDP_PORT} is not reachable (validator may be down)"
    exit 0
fi

echo "UDP port ${UDP_PORT} is reachable, checking subsystem ports..."

# Step 2: Check console TCP port
console_ok=false
if nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null; then
    console_ok=true
    echo "  Console TCP port ${CONSOLE_PORT}: OK"
else
    echo "  Console TCP port ${CONSOLE_PORT}: UNREACHABLE"
fi

# Step 3: Check liteserver TCP port
lite_ok=false
if nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    lite_ok=true
    echo "  Liteserver TCP port ${LITE_PORT}: OK"
else
    echo "  Liteserver TCP port ${LITE_PORT}: UNREACHABLE"
fi

# Step 4: Emit the Always assertion
if [[ "$console_ok" == "true" && "$lite_ok" == "true" ]]; then
    echo "PASS: all subsystem ports are reachable"
    sdk_always true "Validator subsystem consistency: all ports reachable together" \
        "$(jq -cn --arg console "$console_ok" --arg lite "$lite_ok" \
            '{console_port_ok: ($console == "true"), lite_port_ok: ($lite == "true")}')"
    exit 0
else
    echo "FAIL: subsystem inconsistency detected — UDP alive but subsystem port(s) unreachable"
    sdk_always false "Validator subsystem consistency: all ports reachable together" \
        "$(jq -cn --arg console "$console_ok" --arg lite "$lite_ok" \
            '{console_port_ok: ($console == "true"), lite_port_ok: ($lite == "true")}')"
    # Exit 0 so the driver keeps running — the SDK assertion records the violation.
    # A non-zero exit would stop this driver from being re-scheduled by Test Composer.
    exit 0
fi
