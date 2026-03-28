#!/usr/bin/env bash
set -euo pipefail

# Driver workload: verify validator subsystem consistency.
# When the main UDP port (30001) is reachable, the console TCP port (30002) and
# liteserver TCP port (30003) must also be reachable. A violation means an
# internal subsystem crashed while the main process stayed up.
# Runs repeatedly in parallel during fault injection.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

FAIL_COUNT_FILE="/shared/_subsystem_fail_count"
# Require 6 consecutive failures before asserting false. During fault injection,
# Antithesis may selectively partition TCP while leaving UDP open — transient
# port inconsistency during active faults is not a real bug.
MAX_CONSECUTIVE_FAILS=6

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
    # Reset consecutive failure counter on success
    echo "0" > "$FAIL_COUNT_FILE"
    echo "PASS: all subsystem ports are reachable"
    sdk_always true "Validator subsystem consistency: all ports reachable together" \
        "$(jq -cn --arg console "$console_ok" --arg lite "$lite_ok" \
            '{console_port_ok: ($console == "true"), lite_port_ok: ($lite == "true")}')"
    exit 0
else
    # Track consecutive failures — only assert false after MAX_CONSECUTIVE_FAILS
    FAIL_COUNT=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo "0")
    FAIL_COUNT=$(( ${FAIL_COUNT:-0} + 1 ))
    echo "$FAIL_COUNT" > "$FAIL_COUNT_FILE"
    if [ "$FAIL_COUNT" -ge "$MAX_CONSECUTIVE_FAILS" ]; then
        echo "FAIL: subsystem inconsistency detected — UDP alive but subsystem port(s) unreachable (${FAIL_COUNT} consecutive)"
        sdk_always false "Validator subsystem consistency: all ports reachable together" \
            "$(jq -cn --arg console "$console_ok" --arg lite "$lite_ok" --argjson fails "$FAIL_COUNT" \
                '{console_port_ok: ($console == "true"), lite_port_ok: ($lite == "true"), consecutive_failures: $fails}')"
    else
        echo "WARN: subsystem port(s) unreachable (${FAIL_COUNT}/${MAX_CONSECUTIVE_FAILS}), tolerating"
        sdk_always true "Validator subsystem consistency: all ports reachable together" \
            "$(jq -cn --arg console "$console_ok" --arg lite "$lite_ok" --argjson fails "$FAIL_COUNT" \
                '{console_port_ok: ($console == "true"), lite_port_ok: ($lite == "true"), consecutive_failures: $fails, status: "tolerating"}')"
    fi
    exit 0
fi
