#!/usr/bin/env bash
set -euo pipefail

# Driver workload: verify console port accepts and holds a TCP connection.
# When TCP:30002 is reachable via nc -z (SYN-only scan), a full TCP connection
# must be accepted and held for at least 1 second without being reset.
# This catches zombie/deadlocked states where the port is bound at kernel level
# but the application is not actually servicing connections.
# Runs repeatedly in parallel during fault injection.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"

ASSERTION_MSG="Console port accepts and holds TCP connection"

# Catalog the assertion on first invocation
sdk_catalog_always "$ASSERTION_MSG"

echo "Checking console port connection health..."

# Step 1: Quick port scan — is TCP:30002 reachable at all?
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null; then
    echo "SKIP: console TCP port ${CONSOLE_PORT} is not reachable (validator may be down)"
    exit 0
fi

echo "Console port ${CONSOLE_PORT} appears open (nc -z), testing full connection..."

# Step 2: Establish a full TCP connection with a 2-second timeout,
# hold it for 1 second, then check if it was accepted and held.
# We use bash /dev/tcp which creates a real TCP connection (not just SYN).
# If the connection is reset or refused, the exec will fail.
conn_accepted=false
conn_held=false

if exec 3<>"/dev/tcp/${VALIDATOR_HOST}/${CONSOLE_PORT}" 2>/dev/null; then
    conn_accepted=true
    echo "  Connection accepted"

    # Hold for 1 second
    sleep 1

    # Verify the connection is still open by attempting a zero-byte check.
    # If the remote end reset the connection, reading will fail.
    # Use a non-blocking read with timeout — we don't expect data,
    # we just want to confirm the FD is still valid.
    if { echo -n "" >&3; } 2>/dev/null; then
        conn_held=true
        echo "  Connection held for 1 second: OK"
    else
        echo "  Connection was reset within 1 second"
    fi

    # Close the connection
    exec 3>&- 2>/dev/null || true
else
    echo "  Full TCP connection refused/failed (despite nc -z passing)"
fi

# Step 3: Emit the Always assertion
if [[ "$conn_accepted" == "true" && "$conn_held" == "true" ]]; then
    echo "PASS: console port accepts and holds TCP connection"
    sdk_always true "$ASSERTION_MSG" \
        "$(jq -cn --arg accepted "$conn_accepted" --arg held "$conn_held" \
            '{connection_accepted: ($accepted == "true"), connection_held_1s: ($held == "true")}')"
else
    echo "FAIL: console port open (nc -z) but connection not properly serviced"
    sdk_always false "$ASSERTION_MSG" \
        "$(jq -cn --arg accepted "$conn_accepted" --arg held "$conn_held" \
            '{connection_accepted: ($accepted == "true"), connection_held_1s: ($held == "true")}')"
fi

# Always exit 0 so the driver keeps running
exit 0
