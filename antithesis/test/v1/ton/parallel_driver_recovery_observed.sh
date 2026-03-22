#!/usr/bin/env bash
set -euo pipefail

# Driver workload: detect validator recovery transitions during active fault injection.
# Tracks the validator's previous health state via /shared/validator_prev_state.
# When a down→up transition is observed (all three ports become reachable after
# previously being down), this emits a "sometimes" assertion with condition=true.
# The "sometimes" semantic requires this to happen at least once during the test run,
# proving the validator can recover while faults are actively being injected.
# Runs repeatedly in parallel during fault injection.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Validator recovers mid-test after going down"
STATE_FILE="/shared/validator_prev_state"

# Catalog the assertion on first invocation
sdk_catalog_sometimes "$ASSERTION_NAME"

echo "Checking validator recovery state..."

# Check all three ports
udp_ok=false
console_ok=false
lite_ok=false

nc -z -u -w 2 "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null && udp_ok=true
nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null && console_ok=true
nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null && lite_ok=true

# Determine current state
if [[ "$udp_ok" == "true" && "$console_ok" == "true" && "$lite_ok" == "true" ]]; then
    current_state="up"
else
    current_state="down"
fi

echo "  UDP:${UDP_PORT}=${udp_ok} TCP:${CONSOLE_PORT}=${console_ok} TCP:${LITE_PORT}=${lite_ok} => ${current_state}"

# Read previous state (default: "unknown" on first run)
if [[ -f "$STATE_FILE" ]]; then
    prev_state=$(cat "$STATE_FILE")
else
    prev_state="unknown"
fi

echo "  Previous state: ${prev_state}, Current state: ${current_state}"

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

details=$(jq -cn \
    --arg prev "$prev_state" \
    --arg curr "$current_state" \
    --arg ts "$timestamp" \
    --argjson udp "$udp_ok" \
    --argjson console "$console_ok" \
    --argjson lite "$lite_ok" \
    '{prev_state: $prev, current_state: $curr, timestamp: $ts, udp_30001: $udp, tcp_30002: $console, tcp_30003: $lite}')

# Detect recovery transition: down → up
if [[ "$prev_state" == "down" && "$current_state" == "up" ]]; then
    echo "RECOVERY DETECTED: validator transitioned from down to up"
    sdk_sometimes true "$ASSERTION_NAME" "$details"
else
    # No recovery transition observed this invocation — register without satisfying
    if [[ "$current_state" == "down" ]]; then
        echo "Validator is down — no recovery transition yet"
    elif [[ "$prev_state" == "unknown" ]]; then
        echo "First invocation — establishing baseline state"
    else
        echo "No state transition (was ${prev_state}, still ${current_state})"
    fi
    sdk_sometimes false "$ASSERTION_NAME" "$details"
fi

# Persist current state for next invocation
echo -n "$current_state" > "$STATE_FILE"

# Always exit 0 so Test Composer keeps re-scheduling this driver
exit 0
