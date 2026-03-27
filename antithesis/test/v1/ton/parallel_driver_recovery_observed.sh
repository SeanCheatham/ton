#!/usr/bin/env bash
set -euo pipefail

# Driver workload: detect validator recovery transitions during active fault injection.
# Uses TWO detection methods:
#   1. Per-port state tracking: ANY single port transitioning from unreachable→reachable
#      counts as recovery (more sensitive than requiring all 3 ports simultaneously).
#   2. Heartbeat-gap detection: heartbeat stale (>20s) then fresh (<10s) indicates
#      process recovery independent of network state.
# The "sometimes" semantic requires this to happen at least once during the test run,
# proving the validator can recover while faults are actively being injected.
#
# Runs repeatedly in parallel during fault injection.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Validator recovers mid-test after going down"
# Per-port state files
PREV_UDP_FILE="/shared/validator_prev_udp"
PREV_CONSOLE_FILE="/shared/validator_prev_console"
PREV_LITE_FILE="/shared/validator_prev_lite"
HEARTBEAT_STATE_FILE="/shared/validator_heartbeat_prev_fresh"

# Catalog the assertion on first invocation
sdk_catalog_sometimes "$ASSERTION_NAME"

echo "Checking validator recovery state..."

# --- Method 1: Per-port detection ---
udp_ok=false
console_ok=false
lite_ok=false

nc -z -u -w 2 "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null && udp_ok=true
nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null && console_ok=true
nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null && lite_ok=true

echo "  UDP:${UDP_PORT}=${udp_ok} TCP:${CONSOLE_PORT}=${console_ok} TCP:${LITE_PORT}=${lite_ok}"

# Read previous per-port states (default: "unknown" on first run)
prev_udp=$(cat "$PREV_UDP_FILE" 2>/dev/null || echo "unknown")
prev_console=$(cat "$PREV_CONSOLE_FILE" 2>/dev/null || echo "unknown")
prev_lite=$(cat "$PREV_LITE_FILE" 2>/dev/null || echo "unknown")

# Per-port recovery: ANY port transitioning from down→up counts
port_recovery=false
if [[ "$prev_udp" == "false" && "$udp_ok" == "true" ]]; then
    port_recovery=true
    echo "PORT RECOVERY DETECTED: UDP:${UDP_PORT} transitioned from down to up"
fi
if [[ "$prev_console" == "false" && "$console_ok" == "true" ]]; then
    port_recovery=true
    echo "PORT RECOVERY DETECTED: TCP:${CONSOLE_PORT} transitioned from down to up"
fi
if [[ "$prev_lite" == "false" && "$lite_ok" == "true" ]]; then
    port_recovery=true
    echo "PORT RECOVERY DETECTED: TCP:${LITE_PORT} transitioned from down to up"
fi

# Persist current per-port states for next invocation
echo -n "$udp_ok" > "$PREV_UDP_FILE"
echo -n "$console_ok" > "$PREV_CONSOLE_FILE"
echo -n "$lite_ok" > "$PREV_LITE_FILE"

# --- Method 2: Heartbeat-gap detection ---
# Thresholds: fresh ≤10s, stale >20s (heartbeat written every 5s)
heartbeat_recovery=false
NOW=$(date +%s)

if [[ -f /shared/validator_heartbeat ]]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || echo "0")
    if [[ "$HB_TS" =~ ^[0-9]+$ ]] && [ "$HB_TS" -gt 0 ]; then
        HB_AGE=$((NOW - HB_TS))
    else
        HB_AGE=999
    fi
else
    HB_AGE=999
fi

# Read previous heartbeat freshness state
if [[ -f "$HEARTBEAT_STATE_FILE" ]]; then
    prev_hb_fresh=$(cat "$HEARTBEAT_STATE_FILE")
else
    prev_hb_fresh="unknown"
fi

# Current heartbeat freshness (lowered thresholds: fresh ≤10s, stale >20s)
if [ "$HB_AGE" -le 10 ]; then
    current_hb_fresh="fresh"
elif [ "$HB_AGE" -gt 20 ]; then
    current_hb_fresh="stale"
else
    # Between 10-20s: keep previous state to avoid flapping
    current_hb_fresh="$prev_hb_fresh"
fi

echo "  Heartbeat age: ${HB_AGE}s, prev_fresh: ${prev_hb_fresh}, current_fresh: ${current_hb_fresh}"

# Heartbeat-based recovery: stale → fresh
if [[ "$prev_hb_fresh" == "stale" && "$current_hb_fresh" == "fresh" ]]; then
    heartbeat_recovery=true
    echo "HEARTBEAT RECOVERY DETECTED: heartbeat transitioned from stale to fresh"
fi

# Persist current heartbeat freshness state
echo -n "$current_hb_fresh" > "$HEARTBEAT_STATE_FILE"

# --- Emit assertion ---
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Determine aggregate port state for details
if [[ "$udp_ok" == "true" && "$console_ok" == "true" && "$lite_ok" == "true" ]]; then
    port_state="up"
else
    port_state="down"
fi

details=$(jq -cn \
    --arg prev_udp "$prev_udp" \
    --arg prev_console "$prev_console" \
    --arg prev_lite "$prev_lite" \
    --arg curr_port "$port_state" \
    --arg prev_hb "$prev_hb_fresh" \
    --arg curr_hb "$current_hb_fresh" \
    --argjson hb_age "$HB_AGE" \
    --argjson port_recovery "$port_recovery" \
    --argjson hb_recovery "$heartbeat_recovery" \
    --arg ts "$timestamp" \
    --argjson udp "$udp_ok" \
    --argjson console "$console_ok" \
    --argjson lite "$lite_ok" \
    '{prev_udp: $prev_udp, prev_console: $prev_console, prev_lite: $prev_lite, current_port_state: $curr_port, prev_heartbeat: $prev_hb, current_heartbeat: $curr_hb, heartbeat_age_s: $hb_age, port_recovery: $port_recovery, heartbeat_recovery: $hb_recovery, timestamp: $ts, udp_30001: $udp, tcp_30002: $console, tcp_30003: $lite}')

# Recovery detected via either method
if [[ "$port_recovery" == "true" || "$heartbeat_recovery" == "true" ]]; then
    echo "RECOVERY DETECTED via port=${port_recovery} heartbeat=${heartbeat_recovery}"
    sdk_sometimes true "$ASSERTION_NAME" "$details"
else
    if [[ "$port_state" == "down" || "$current_hb_fresh" == "stale" ]]; then
        echo "Validator is down/stale — no recovery transition yet"
    elif [[ "$prev_udp" == "unknown" && "$prev_console" == "unknown" && "$prev_lite" == "unknown" && "$prev_hb_fresh" == "unknown" ]]; then
        echo "First invocation — establishing baseline state"
    else
        echo "No state transition (ports: udp=${prev_udp}->${udp_ok} console=${prev_console}->${console_ok} lite=${prev_lite}->${lite_ok}, hb: ${prev_hb_fresh}->${current_hb_fresh})"
    fi
    sdk_sometimes false "$ASSERTION_NAME" "$details"
fi

# Always exit 0 so Test Composer keeps re-scheduling this driver
exit 0
